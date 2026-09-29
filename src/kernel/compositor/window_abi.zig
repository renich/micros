// MicrOS (µOS) Window Manager and Compositor Native ABI Bindings
// SPEC-TECH-COMP-001: Provides safe, capability-checked window and surface management to Macros.
// Zero libc, freestanding, bounds-checked arithmetic.

const std = @import("std");
const eval = @import("../../macros/eval.zig");
const Value = eval.Value;
const compositor_mod = @import("../compositor.zig");
const WindowManager = compositor_mod.WindowManager;
const WindowMode = compositor_mod.WindowMode;
const Canvas = compositor_mod.Canvas;
const PointerState = compositor_mod.PointerState;
const cap_mod = @import("../cap/capability.zig");
const fb_mod = @import("../fb.zig");

pub const WindowContext = struct {
    wm: ?*WindowManager = null,
    canvas: ?*Canvas = null,
    pointer: ?*PointerState = null,
    framebuffer: ?*fb_mod.Framebuffer = null,
    supervisor_id: u32 = 0,
    check_auth_fn: ?*const fn (cap_type: cap_mod.CapType, rights: u16) bool = null,
};

var active_win_ctx: ?*WindowContext = null;

pub fn setWindowContext(ctx: *WindowContext) void {
    active_win_ctx = ctx;
}

pub fn clearWindowContext() void {
    active_win_ctx = null;
}

fn checkAuth(cap_type: cap_mod.CapType, rights: u16) bool {
    const ctx = active_win_ctx orelse return false;
    const auth_fn = ctx.check_auth_fn orelse return false;
    return auth_fn(cap_type, rights);
}

fn castToU32(val: i64) ?u32 {
    if (val < 0 or val > std.math.maxInt(u32)) return null;
    return @intCast(val);
}

pub fn nativeSysWindowCreate(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 4 or args[0] != .string or args[1] != .integer or
        args[2] != .integer or args[3] != .integer)
    {
        return error.InvalidArgs;
    }
    if (!checkAuth(.framebuffer, cap_mod.Rights.WRITE)) return error.PermissionDenied;
    const ctx = active_win_ctx orelse return Value{ .integer = -1 };
    const wm = ctx.wm orelse return Value{ .integer = -1 };

    const w = castToU32(args[1].integer) orelse return error.InvalidArgs;
    const h = castToU32(args[2].integer) orelse return error.InvalidArgs;
    const mode: WindowMode = if (args[3].integer == 1) .floating else .tiled;

    const win = wm.createWindow(ctx.supervisor_id, args[0].string, w, h, mode) catch {
        return Value{ .integer = -1 };
    };
    return Value{ .integer = @intCast(win.id) };
}

pub fn nativeSysWindowClose(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    if (!checkAuth(.framebuffer, cap_mod.Rights.WRITE)) return error.PermissionDenied;
    const ctx = active_win_ctx orelse return Value{ .boolean = false };
    const wm = ctx.wm orelse return Value{ .boolean = false };
    const win_id = castToU32(args[0].integer) orelse return error.InvalidArgs;

    wm.closeWindow(win_id);
    return Value{ .boolean = true };
}

pub fn nativeSysWindowFocus(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    if (!checkAuth(.framebuffer, cap_mod.Rights.WRITE)) return error.PermissionDenied;
    const ctx = active_win_ctx orelse return Value{ .boolean = false };
    const wm = ctx.wm orelse return Value{ .boolean = false };
    const win_id = castToU32(args[0].integer) orelse return error.InvalidArgs;

    wm.focusWindow(win_id);
    return Value{ .boolean = true };
}

pub fn nativeSysWindowDrawRect(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 6 or args[0] != .integer or args[1] != .integer or
        args[2] != .integer or args[3] != .integer or args[4] != .integer or
        args[5] != .integer)
    {
        return error.InvalidArgs;
    }
    if (!checkAuth(.framebuffer, cap_mod.Rights.WRITE)) return error.PermissionDenied;
    const ctx = active_win_ctx orelse return Value{ .nil = {} };
    const wm = ctx.wm orelse return Value{ .nil = {} };

    const win_id = castToU32(args[0].integer) orelse return error.InvalidArgs;
    const idx = wm.findWindowIndex(win_id) orelse return Value{ .nil = {} };
    const win = wm.windows[idx] orelse return Value{ .nil = {} };

    const x = castToU32(args[1].integer) orelse return error.InvalidArgs;
    const y = castToU32(args[2].integer) orelse return error.InvalidArgs;
    const w = castToU32(args[3].integer) orelse return error.InvalidArgs;
    const h = castToU32(args[4].integer) orelse return error.InvalidArgs;
    const color = castToU32(args[5].integer) orelse return error.InvalidArgs;

    win.surface.drawRect(x, y, w, h, color);
    return Value{ .nil = {} };
}

pub fn nativeSysWindowDrawString(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 6 or args[0] != .integer or args[1] != .integer or
        args[2] != .integer or args[3] != .string or args[4] != .integer or
        args[5] != .integer)
    {
        return error.InvalidArgs;
    }
    if (!checkAuth(.framebuffer, cap_mod.Rights.WRITE)) return error.PermissionDenied;
    const ctx = active_win_ctx orelse return Value{ .nil = {} };
    const wm = ctx.wm orelse return Value{ .nil = {} };

    const win_id = castToU32(args[0].integer) orelse return error.InvalidArgs;
    const idx = wm.findWindowIndex(win_id) orelse return Value{ .nil = {} };
    const win = wm.windows[idx] orelse return Value{ .nil = {} };

    const x = castToU32(args[1].integer) orelse return error.InvalidArgs;
    const y = castToU32(args[2].integer) orelse return error.InvalidArgs;
    const fg = castToU32(args[4].integer) orelse return error.InvalidArgs;
    const bg = castToU32(args[5].integer) orelse return error.InvalidArgs;

    win.surface.drawString(x, y, args[3].string, fg, bg);
    return Value{ .nil = {} };
}

pub fn nativeSysWindowCommit(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    if (!checkAuth(.framebuffer, cap_mod.Rights.WRITE)) return error.PermissionDenied;
    const ctx = active_win_ctx orelse return Value{ .boolean = false };
    const wm = ctx.wm orelse return Value{ .boolean = false };
    const canvas = ctx.canvas orelse return Value{ .boolean = false };

    wm.compose(canvas);
    if (ctx.framebuffer) |fb| {
        canvas.flush(fb);
    }
    return Value{ .boolean = true };
}

pub fn nativeSysCompositorFlush(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    return nativeSysWindowCommit(vm_ptr, args);
}

pub fn nativeSysPointerRead(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    if (!checkAuth(.framebuffer, cap_mod.Rights.READ)) return error.PermissionDenied;
    const ctx = active_win_ctx orelse return Value{ .integer = -1 };
    const ptr = ctx.pointer orelse return Value{ .integer = -1 };
    const px: i64 = @as(u16, @bitCast(@as(i16, @truncate(ptr.x))));
    const py: i64 = @as(u16, @bitCast(@as(i16, @truncate(ptr.y))));
    const packed_coords = px | (py << 16);
    return Value{ .integer = packed_coords };
}
