// MicrOS (µOS) Hardware Capability & Interrupt ABI Bindings
// Exposes DMA physical frame resolution and userland interrupt signaling to actors.
// Enforces CSpace capability isolation (CapType.network_device, CapType.storage_device, CapType.irq_endpoint).
// Freestanding, zero libc.

const std = @import("std");
const eval = @import("../../macros/eval.zig");
const Value = eval.Value;
const vm_mod = @import("../../macros/vm.zig");
const VM = vm_mod.VM;
const cap_mod = @import("capability.zig");
const CapType = cap_mod.CapType;
const Rights = cap_mod.Rights;

pub const PhysFrameInfo = extern struct {
    phys_addr: u64,
    size_bytes: u64,
    flags: u32,
    reserved: u32,
};

pub var caller_auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool = null;
pub var frame_info_fn: ?*const fn (frame_idx: usize) ?u64 = null;
pub var irq_ack_fn: ?*const fn (irq: u8) void = null;

pub fn setCapAbiContext(
    auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool,
    info_fn: ?*const fn (frame_idx: usize) ?u64,
    ack_fn: ?*const fn (irq: u8) void,
) void {
    caller_auth_fn = auth_fn;
    frame_info_fn = info_fn;
    irq_ack_fn = ack_fn;
}

pub fn clearCapAbiContext() void {
    caller_auth_fn = null;
    frame_info_fn = null;
    irq_ack_fn = null;
}

fn checkCallerAuthority(cap_type: CapType, rights: u16) bool {
    if (caller_auth_fn) |auth| {
        return auth(cap_type, rights);
    }
    return true;
}

fn castToU32(val: i64) ?u32 {
    if (val < 0 or val > std.math.maxInt(u32)) return null;
    return @intCast(val);
}

pub fn nativeSysFrameInfo(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;

    const has_net = checkCallerAuthority(.network_device, Rights.WRITE);
    const has_storage = checkCallerAuthority(.storage_device, Rights.WRITE);
    if (!has_net and !has_storage) return Value{ .integer = -1 };

    const frame_idx = castToU32(args[0].integer) orelse return Value{ .integer = -1 };
    if (frame_info_fn) |info_fn| {
        const addr = info_fn(frame_idx) orelse return Value{ .integer = -1 };
        return Value{ .integer = @as(i64, @bitCast(addr)) };
    }

    const default_paddr = @as(u64, frame_idx) * 4096;
    return Value{ .integer = @as(i64, @bitCast(default_paddr)) };
}

pub fn nativeSysIrqAck(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    if (!checkCallerAuthority(.irq_endpoint, Rights.WRITE)) return Value{ .boolean = false };

    const irq_val = castToU32(args[0].integer) orelse return Value{ .boolean = false };
    if (irq_ack_fn) |ack_fn| {
        ack_fn(@intCast(irq_val & 0xFF));
    }
    return Value{ .boolean = true };
}

pub fn registerCapSyscalls(vm: *VM) !void {
    try vm.globals.put("sys_frame_info", Value{ .native = nativeSysFrameInfo });
    try vm.globals.put("sys_irq_ack", Value{ .native = nativeSysIrqAck });
}

test "cap_abi: unauthorized caller rejected for frame_info and irq_ack" {
    const authReject = struct {
        fn check(_: CapType, _: u16) bool {
            return false;
        }
    }.check;

    setCapAbiContext(authReject, null, null);
    defer clearCapAbiContext();

    var args = [_]Value{Value{ .integer = 5 }};
    const frame_val = try nativeSysFrameInfo(@ptrFromInt(0x1000), &args);
    try std.testing.expectEqual(@as(i64, -1), frame_val.integer);

    const irq_val = try nativeSysIrqAck(@ptrFromInt(0x1000), &args);
    try std.testing.expect(!irq_val.boolean);
}

test "cap_abi: authorized caller resolves physical address and acks irq" {
    const authAllow = struct {
        fn check(_: CapType, _: u16) bool {
            return true;
        }
    }.check;

    const mockFrame = struct {
        fn get(idx: usize) ?u64 {
            return @as(u64, @intCast(idx)) * 4096 + 0x100000;
        }
    }.get;

    var acked_irq: ?u8 = null;
    const mockAck = struct {
        var target: *?u8 = undefined;
        fn ack(irq: u8) void {
            target.* = irq;
        }
    };
    mockAck.target = &acked_irq;

    setCapAbiContext(authAllow, mockFrame, mockAck.ack);
    defer clearCapAbiContext();

    var frame_args = [_]Value{Value{ .integer = 10 }};
    const frame_val = try nativeSysFrameInfo(@ptrFromInt(0x1000), &frame_args);
    try std.testing.expectEqual(@as(i64, 10 * 4096 + 0x100000), frame_val.integer);

    var irq_args = [_]Value{Value{ .integer = 11 }};
    const irq_val = try nativeSysIrqAck(@ptrFromInt(0x1000), &irq_args);
    try std.testing.expect(irq_val.boolean);
    try std.testing.expectEqual(@as(?u8, 11), acked_irq);
}
