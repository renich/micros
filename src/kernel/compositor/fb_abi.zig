// MicrOS (µOS) Direct Framebuffer ABI
// Exposes direct framebuffer drawing primitives to capability-authorized actors.

const std = @import("std");
const fb_mod = @import("../fb.zig");
const cap_mod = @import("../cap/capability.zig");
const eval_mod = @import("../../macros/eval.zig");
const Value = eval_mod.Value;

pub var active_fb: ?*fb_mod.Framebuffer = null;
pub var caller_auth_fn: ?*const fn (cap_type: cap_mod.CapType, rights: u16) bool = null;

pub fn setContext(fb: ?*fb_mod.Framebuffer, auth_fn: ?*const fn (cap_type: cap_mod.CapType, rights: u16) bool) void {
    active_fb = fb;
    caller_auth_fn = auth_fn;
}

fn checkAuth(cap_type: cap_mod.CapType, rights: u16) bool {
    if (caller_auth_fn) |auth| return auth(cap_type, rights);
    return false;
}

fn castToU32(val: i64) ?u32 {
    if (val < 0 or val > std.math.maxInt(u32)) return null;
    return @intCast(val);
}

pub fn nativeSysFbClear(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    if (!checkAuth(.framebuffer, cap_mod.Rights.WRITE)) return error.PermissionDenied;
    const color = castToU32(args[0].integer) orelse return error.InvalidArgs;
    if (active_fb) |fb| {
        fb.clear(color);
    }
    return Value{ .nil = {} };
}

pub fn nativeSysFbDrawString(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 5 or args[0] != .integer or args[1] != .integer or
        args[2] != .string or args[3] != .integer or args[4] != .integer)
    {
        return error.InvalidArgs;
    }
    if (!checkAuth(.framebuffer, cap_mod.Rights.WRITE)) return error.PermissionDenied;
    const x = castToU32(args[0].integer) orelse return error.InvalidArgs;
    const y = castToU32(args[1].integer) orelse return error.InvalidArgs;
    const color = castToU32(args[3].integer) orelse return error.InvalidArgs;
    const bg = castToU32(args[4].integer) orelse return error.InvalidArgs;
    if (active_fb) |fb| {
        fb.drawString(x, y, args[2].string, color, bg);
    }
    return Value{ .nil = {} };
}

pub fn nativeSysFbDrawRect(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 5 or args[0] != .integer or args[1] != .integer or
        args[2] != .integer or args[3] != .integer or args[4] != .integer)
    {
        return error.InvalidArgs;
    }
    if (!checkAuth(.framebuffer, cap_mod.Rights.WRITE)) return error.PermissionDenied;
    const x = castToU32(args[0].integer) orelse return error.InvalidArgs;
    const y = castToU32(args[1].integer) orelse return error.InvalidArgs;
    const w = castToU32(args[2].integer) orelse return error.InvalidArgs;
    const h = castToU32(args[3].integer) orelse return error.InvalidArgs;
    const color = castToU32(args[4].integer) orelse return error.InvalidArgs;
    if (active_fb) |fb| {
        fb.drawRect(x, y, w, h, color);
    }
    return Value{ .nil = {} };
}
