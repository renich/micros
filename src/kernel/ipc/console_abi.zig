// MicrOS (µOS) Console & Terminal Input ABI
// Handles serial stream decoding, ANSI escape sequences, PS/2 scancodes,
// and keyboard layout transformations.

const std = @import("std");
const eval_mod = @import("../../macros/eval.zig");
const Value = eval_mod.Value;
const serial = @import("../serial.zig");
const ps2_mod = @import("../drivers/ps2_kbd.zig");
const cap_mod = @import("../cap/capability.zig");

pub var active_kbd: ?*ps2_mod.Ps2Keyboard = null;
pub var caller_auth_fn: ?*const fn (cap_type: cap_mod.CapType, rights: u16) bool = null;

pub fn setContext(kbd: ?*ps2_mod.Ps2Keyboard, auth_fn: ?*const fn (cap_type: cap_mod.CapType, rights: u16) bool) void {
    active_kbd = kbd;
    caller_auth_fn = auth_fn;
}

fn checkAuth(cap_type: cap_mod.CapType, rights: u16) bool {
    if (caller_auth_fn) |auth| return auth(cap_type, rights);
    return false;
}

pub fn decodeAnsiParam(b3: u8) ?i64 {
    return switch (b3) {
        'A' => ps2_mod.KeyCode.UP,
        'B' => ps2_mod.KeyCode.DOWN,
        'C' => ps2_mod.KeyCode.RIGHT,
        'D' => ps2_mod.KeyCode.LEFT,
        'H' => ps2_mod.KeyCode.HOME,
        'F' => ps2_mod.KeyCode.END,
        '3' => blk: {
            _ = serial.readCharTimeout(30_000);
            break :blk ps2_mod.KeyCode.DELETE;
        },
        '4', '8' => blk: {
            _ = serial.readCharTimeout(30_000);
            break :blk ps2_mod.KeyCode.END;
        },
        '5' => blk: {
            _ = serial.readCharTimeout(30_000);
            break :blk ps2_mod.KeyCode.PAGE_UP;
        },
        '6' => blk: {
            _ = serial.readCharTimeout(30_000);
            break :blk ps2_mod.KeyCode.PAGE_DOWN;
        },
        else => null,
    };
}

pub fn decodeSerialEscape() ?i64 {
    const b2 = serial.readCharTimeout(30_000) orelse return null;
    if (b2 == 'O') {
        const b3 = serial.readCharTimeout(30_000) orelse return null;
        return decodeAnsiParam(b3);
    }
    if (b2 != '[') return @as(i64, b2);
    const b3 = serial.readCharTimeout(30_000) orelse return null;
    if (b3 == '1' or b3 == '7') {
        const b4 = serial.readCharTimeout(30_000) orelse return ps2_mod.KeyCode.HOME;
        if (b4 == '~') return ps2_mod.KeyCode.HOME;
        if (b4 == ';') {
            _ = serial.readCharTimeout(30_000);
            const b6 = serial.readCharTimeout(30_000) orelse return null;
            return decodeAnsiParam(b6);
        }
        return null;
    }
    return decodeAnsiParam(b3);
}

pub fn nativeSysSerialRead(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    if (!checkAuth(.framebuffer, cap_mod.Rights.READ) and !checkAuth(.actor_control, cap_mod.Rights.READ)) {
        return error.PermissionDenied;
    }
    if (serial.readChar()) |c| {
        if (c == 27) {
            if (decodeSerialEscape()) |code| return Value{ .integer = code };
        }
        return Value{ .integer = @as(i64, c) };
    }
    return Value{ .integer = -1 };
}

pub fn nativeSysKbdRead(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    if (!checkAuth(.framebuffer, cap_mod.Rights.READ) and !checkAuth(.actor_control, cap_mod.Rights.READ)) {
        return error.PermissionDenied;
    }
    const kbd = active_kbd orelse return Value{ .integer = -1 };
    if (!ps2_mod.hasData()) return Value{ .integer = -1 };
    const scan = ps2_mod.readScancode();
    if (scan == 0 or scan == 0xFF) return Value{ .integer = -1 };
    const ev = kbd.processScancode(scan) orelse return Value{ .integer = -1 };
    if (ev.action == .press) {
        if (ev.ascii != 0) {
            return Value{ .integer = @as(i64, ev.ascii) };
        }
        if (ev.keycode != 0) {
            return Value{ .integer = @as(i64, ev.keycode) };
        }
    }
    return Value{ .integer = -1 };
}

pub fn nativeSysKbdLayout(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    if (!checkAuth(.framebuffer, cap_mod.Rights.WRITE) and !checkAuth(.actor_control, cap_mod.Rights.WRITE)) {
        return error.PermissionDenied;
    }
    const layout = args[0].integer;
    if (layout == 0) {
        ps2_mod.active_layout = .us_qwerty;
    } else if (layout == 1) {
        ps2_mod.active_layout = .es_latam;
    }
    return Value{ .integer = 0 };
}

pub fn nativeSysSerialWrite(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    serial.writeString(args[0].string);
    return Value{ .nil = {} };
}

test "decodeAnsiParam maps escape sequence characters to keycodes" {
    try std.testing.expectEqual(@as(?i64, ps2_mod.KeyCode.UP), decodeAnsiParam('A'));
    try std.testing.expectEqual(@as(?i64, ps2_mod.KeyCode.DOWN), decodeAnsiParam('B'));
    try std.testing.expectEqual(@as(?i64, ps2_mod.KeyCode.RIGHT), decodeAnsiParam('C'));
    try std.testing.expectEqual(@as(?i64, ps2_mod.KeyCode.LEFT), decodeAnsiParam('D'));
    try std.testing.expectEqual(@as(?i64, ps2_mod.KeyCode.HOME), decodeAnsiParam('H'));
    try std.testing.expectEqual(@as(?i64, ps2_mod.KeyCode.END), decodeAnsiParam('F'));
    try std.testing.expectEqual(@as(?i64, null), decodeAnsiParam('Z'));
}
