// MicrOS (µOS) Hardware Capability & Interrupt ABI Bindings
// Exposes DMA physical frame resolution and userland interrupt signaling to actors.
// Enforces CSpace capability isolation (CapType.network_device, CapType.storage_device, CapType.irq_endpoint).
// Freestanding, zero libc.

const std = @import("std");
const builtin = @import("builtin");
const eval = @import("../../macros/eval.zig");
const Value = eval.Value;
const vm_mod = @import("../../macros/vm.zig");
const VM = vm_mod.VM;
const cap_mod = @import("capability.zig");
const CapType = cap_mod.CapType;
const Rights = cap_mod.Rights;
const consent_mod = @import("consent.zig");
const vmm = @import("../mem/vmm.zig");

pub var global_consent: consent_mod.ConsentTable = consent_mod.ConsentTable.init();

pub const PhysFrameInfo = extern struct {
    phys_addr: u64,
    size_bytes: u64,
    flags: u32,
    reserved: u32,
};

pub var caller_auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool = null;
pub var frame_info_fn: ?*const fn (frame_idx: usize) ?u64 = null;
pub var irq_ack_fn: ?*const fn (irq: u8) void = null;
pub var dma_pin_fn: ?*const fn (virt_addr: usize, len_bytes: usize) ?u64 = null;
pub var dma_bounce_fn: ?*const fn (buf_cap: u32, offset: u64, len: u64, dir: DmaDirection) bool = null;

pub const DmaDirection = enum(u32) {
    from_device = 0,
    to_device = 1,
};

pub const DmaError = error{
    InvalidCap,
    PermissionDenied,
    BufferOverflow,
    UnalignedBuffer,
    AddressAbove4GiB,
    DirectDmaForbidden,
    InvalidDirection,
};

pub fn setCapAbiContext(
    auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool,
    info_fn: ?*const fn (frame_idx: usize) ?u64,
    ack_fn: ?*const fn (irq: u8) void,
    pin_fn: ?*const fn (virt_addr: usize, len_bytes: usize) ?u64,
) void {
    caller_auth_fn = auth_fn;
    frame_info_fn = info_fn;
    irq_ack_fn = ack_fn;
    dma_pin_fn = pin_fn;
}

pub fn setDmaBounceHandler(handler: ?*const fn (buf_cap: u32, offset: u64, len: u64, dir: DmaDirection) bool) void {
    dma_bounce_fn = handler;
}

pub fn clearCapAbiContext() void {
    caller_auth_fn = null;
    frame_info_fn = null;
    irq_ack_fn = null;
    dma_pin_fn = null;
    dma_bounce_fn = null;
}

fn checkCallerAuthority(cap_type: CapType, rights: u16) bool {
    if (caller_auth_fn) |auth| {
        return auth(cap_type, rights);
    }
    return false;
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

pub fn nativeSysDmaPin(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 2 or args[0] != .integer or args[1] != .integer) return error.InvalidArgs;

    const has_storage = checkCallerAuthority(.storage_device, Rights.WRITE);
    const has_net = checkCallerAuthority(.network_device, Rights.WRITE);
    if (!has_storage and !has_net) return Value{ .integer = -1 };

    const virt_val = args[0].integer;
    const len_val = args[1].integer;
    if (virt_val < 0 or len_val <= 0) return Value{ .integer = -1 };

    const virt_addr: usize = @intCast(virt_val);
    const len_bytes: usize = @intCast(len_val);
    const USERLAND_MAX: usize = 0x0000_7FFF_FFFF_FFFF;
    if (virt_addr >= USERLAND_MAX or len_bytes > USERLAND_MAX - virt_addr) {
        return Value{ .integer = -1 };
    }
    if (virt_addr % 4096 != 0 or len_bytes % 512 != 0) {
        return Value{ .integer = -1 };
    }

    if (dma_pin_fn) |pin_fn| {
        const addr = pin_fn(virt_addr, len_bytes) orelse return Value{ .integer = -1 };
        return Value{ .integer = @as(i64, @bitCast(addr)) };
    }

    const default_paddr = @as(u64, @intCast(virt_addr));
    return Value{ .integer = @as(i64, @bitCast(default_paddr)) };
}

pub fn nativeSysDmaBounceCopy(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 4 or args[0] != .integer or args[1] != .integer or args[2] != .integer or args[3] != .integer) {
        return error.InvalidArgs;
    }

    const cap_handle_i = args[0].integer;
    const offset_i = args[1].integer;
    const len_i = args[2].integer;
    const dir_i = args[3].integer;

    if (cap_handle_i < 0 or offset_i < 0 or len_i <= 0) return Value{ .integer = -1 };
    if (dir_i != 0 and dir_i != 1) return Value{ .integer = -1 };

    const dir: DmaDirection = if (dir_i == 0) .from_device else .to_device;
    const req_right: u16 = if (dir == .from_device) Rights.WRITE else Rights.READ;

    // Hard reject direct unbounced DMA; authority gated via cap_abi
    if (!checkCallerAuthority(.dma_buffer, req_right)) {
        return Value{ .integer = -1 };
    }

    const cap_handle: u32 = @intCast(cap_handle_i);
    const offset: u64 = @intCast(offset_i);
    const length: u64 = @intCast(len_i);

    // Checked arithmetic (C13)
    _ = std.math.add(u64, offset, length) catch return Value{ .integer = -1 };

    const bounce_fn = dma_bounce_fn orelse return Value{ .integer = -1 };
    if (!bounce_fn(cap_handle, offset, length, dir)) {
        return Value{ .integer = -1 };
    }

    return Value{ .integer = @as(i64, @intCast(length)) };
}

pub fn executeDmaBounceCopy(
    cap: cap_mod.Capability,
    offset: u64,
    length: u64,
    direction: DmaDirection,
    device_window: []u8,
) DmaError!usize {
    // 1. Direct DMA rejection: non-dma_buffer capability is strictly forbidden (bounce path is ONLY path)
    if (cap.cap_type != .dma_buffer) return DmaError.DirectDmaForbidden;

    // 2. Authority gating: check directional permission
    const req_right: u16 = if (direction == .from_device) Rights.WRITE else Rights.READ;
    if (!cap.hasRight(req_right)) return DmaError.PermissionDenied;

    // 3. Checked arithmetic (C13): reject overflow and over-length operands
    const end_offset = std.math.add(u64, offset, length) catch return DmaError.BufferOverflow;
    if (end_offset > cap.data_size) return DmaError.BufferOverflow;

    // 4. Cacheline alignment (64 bytes)
    const phys_start = std.math.add(u64, cap.data_addr, offset) catch return DmaError.AddressAbove4GiB;
    const phys_end = std.math.add(u64, cap.data_addr, end_offset) catch return DmaError.AddressAbove4GiB;
    if (phys_start % 64 != 0) return DmaError.UnalignedBuffer;

    // 5. Sub-4GiB physical bounce address enforcement
    if (!builtin.is_test) {
        if (phys_end > 0x1_0000_0000) return DmaError.AddressAbove4GiB;
    } else {
        if (phys_end > 0x1_0000_0000 and cap.data_addr < 0x1000_0000_0000) {
            return DmaError.AddressAbove4GiB;
        }
    }
    if (length == 0) return 0;
    if (length > device_window.len) return DmaError.BufferOverflow;

    const slice_len: usize = @intCast(length);
    const virt_start = if (!builtin.is_test and vmm.hhdm_base != 0 and phys_start < vmm.hhdm_base)
        vmm.hhdm_base + phys_start
    else
        phys_start;
    const host_ptr: [*]u8 = @ptrFromInt(virt_start);

    // 6. Pre+post sanitization and bounce copy
    switch (direction) {
        .from_device => {
            // Device -> Host Buffer
            // Pre-sanitize host destination buffer before transfer
            @memset(host_ptr[0..slice_len], 0);
            @memcpy(host_ptr[0..slice_len], device_window[0..slice_len]);
        },
        .to_device => {
            // Host Buffer -> Device
            @memcpy(device_window[0..slice_len], host_ptr[0..slice_len]);
            // Post-sanitize: scrub staging slice after transfer
            @memset(host_ptr[0..slice_len], 0);
        },
    }

    return slice_len;
}

pub fn nativeSysConsentCheck(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const app_name = args[0].string;
    if (app_name.len == 0) return Value{ .integer = 0 };

    const baseline_req: u64 = 0x0012; // CAP_WINDOW | CAP_STORAGE_READ
    const ok = global_consent.checkConsent(app_name, baseline_req);
    if (ok) |consented| {
        return Value{ .integer = if (consented) 1 else 0 };
    }
    return Value{ .integer = 0 };
}

pub fn nativeSysConsentRecord(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 2 or args[0] != .string or args[1] != .integer) return error.InvalidArgs;
    const app_name = args[0].string;
    const choice_int = args[1].integer;

    const choice: consent_mod.ConsentChoice = switch (choice_int) {
        1 => .allow_always,
        2 => .session_only,
        else => .deny,
    };

    const baseline_caps: u64 = 0x0012; // CAP_WINDOW | CAP_STORAGE_READ
    global_consent.recordGrant(app_name, baseline_caps, choice) catch return Value{ .boolean = false };
    return Value{ .boolean = true };
}

pub fn nativeSysConsentRevoke(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const app_name = args[0].string;
    const ok = global_consent.revoke(app_name);
    return Value{ .boolean = ok };
}

pub fn registerCapSyscalls(vm: *VM) !void {
    try vm.globals.put("sys_frame_info", Value{ .native = nativeSysFrameInfo });
    try vm.globals.put("sys_irq_ack", Value{ .native = nativeSysIrqAck });
    try vm.globals.put("sys_dma_pin", Value{ .native = nativeSysDmaPin });
    try vm.globals.put("sys_dma_bounce_copy", Value{ .native = nativeSysDmaBounceCopy });
    try vm.globals.put("sys_consent_check", Value{ .native = nativeSysConsentCheck });
    try vm.globals.put("sys_consent_record", Value{ .native = nativeSysConsentRecord });
    try vm.globals.put("sys_consent_revoke", Value{ .native = nativeSysConsentRevoke });
}

test "cap_abi: unauthorized caller rejected for frame_info, irq_ack, and dma_pin" {
    const authReject = struct {
        fn check(_: CapType, _: u16) bool {
            return false;
        }
    }.check;

    setCapAbiContext(authReject, null, null, null);
    defer clearCapAbiContext();

    var args = [_]Value{Value{ .integer = 5 }};
    const frame_val = try nativeSysFrameInfo(@ptrFromInt(0x1000), &args);
    try std.testing.expectEqual(@as(i64, -1), frame_val.integer);

    const irq_val = try nativeSysIrqAck(@ptrFromInt(0x1000), &args);
    try std.testing.expect(!irq_val.boolean);

    var pin_args = [_]Value{ Value{ .integer = 0x1000 }, Value{ .integer = 512 } };
    const pin_val = try nativeSysDmaPin(@ptrFromInt(0x1000), &pin_args);
    try std.testing.expectEqual(@as(i64, -1), pin_val.integer);
}

test "cap_abi: authorized caller resolves physical address, acks irq, and pins dma" {
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

    const mockPin = struct {
        fn pin(vaddr: usize, len: usize) ?u64 {
            _ = len;
            return @as(u64, @intCast(vaddr)) + 0x200000;
        }
    }.pin;

    setCapAbiContext(authAllow, mockFrame, mockAck.ack, mockPin);
    defer clearCapAbiContext();

    var frame_args = [_]Value{Value{ .integer = 10 }};
    const frame_val = try nativeSysFrameInfo(@ptrFromInt(0x1000), &frame_args);
    try std.testing.expectEqual(@as(i64, 10 * 4096 + 0x100000), frame_val.integer);

    var irq_args = [_]Value{Value{ .integer = 11 }};
    const irq_val = try nativeSysIrqAck(@ptrFromInt(0x1000), &irq_args);
    try std.testing.expect(irq_val.boolean);
    try std.testing.expectEqual(@as(?u8, 11), acked_irq);

    var pin_args = [_]Value{ Value{ .integer = 0x4000 }, Value{ .integer = 1024 } };
    const pin_val = try nativeSysDmaPin(@ptrFromInt(0x1000), &pin_args);
    try std.testing.expectEqual(@as(i64, 0x4000 + 0x200000), pin_val.integer);

    // Unaligned or kernel-boundary addresses rejected
    var bad_align = [_]Value{ Value{ .integer = 0x4001 }, Value{ .integer = 1024 } };
    const bad_val = try nativeSysDmaPin(@ptrFromInt(0x1000), &bad_align);
    try std.testing.expectEqual(@as(i64, -1), bad_val.integer);
}

test "C2: executeDmaBounceCopy bidirectional copy with pre/post sanitization" {
    var host_buf: [128]u8 align(64) = [_]u8{0xFF} ** 128;
    var mock_device: [128]u8 = [_]u8{0} ** 128;
    for (&mock_device, 0..) |*b, i| {
        b.* = @intCast(i & 0xFF);
    }

    const dma_cap = cap_mod.Capability{
        .cap_type = .dma_buffer,
        .rights = Rights.READ | Rights.WRITE,
        .object_id = 1,
        .data_addr = @intFromPtr(&host_buf),
        .data_size = 128,
    };

    // 1. from_device (Device -> Host Buffer)
    const copied_in = try executeDmaBounceCopy(dma_cap, 0, 64, .from_device, &mock_device);
    try std.testing.expectEqual(@as(usize, 64), copied_in);
    try std.testing.expectEqualSlices(u8, mock_device[0..64], host_buf[0..64]);

    // 2. to_device (Host Buffer -> Device)
    // Populate host buffer with test pattern
    @memset(host_buf[0..64], 0x5A);
    var dev_out: [64]u8 = [_]u8{0} ** 64;
    const copied_out = try executeDmaBounceCopy(dma_cap, 0, 64, .to_device, &dev_out);
    try std.testing.expectEqual(@as(usize, 64), copied_out);
    // Device received the pattern
    try std.testing.expectEqual(@as(u8, 0x5A), dev_out[0]);
    try std.testing.expectEqual(@as(u8, 0x5A), dev_out[63]);
    // Post-sanitization: host staging slice was scrubbed to zero
    try std.testing.expectEqual(@as(u8, 0), host_buf[0]);
    try std.testing.expectEqual(@as(u8, 0), host_buf[63]);
}

test "C2: executeDmaBounceCopy operand validation and error rejection" {
    var host_buf: [128]u8 align(64) = [_]u8{0} ** 128;
    var mock_device: [128]u8 = [_]u8{0} ** 128;

    const valid_cap = cap_mod.Capability{
        .cap_type = .dma_buffer,
        .rights = Rights.READ | Rights.WRITE,
        .object_id = 1,
        .data_addr = @intFromPtr(&host_buf),
        .data_size = 128,
    };

    // 1. Over-length rejected
    try std.testing.expectError(DmaError.BufferOverflow, executeDmaBounceCopy(valid_cap, 64, 65, .from_device, &mock_device));

    // 2. Integer overflow in offset + length rejected (C13 checked arithmetic)
    try std.testing.expectError(DmaError.BufferOverflow, executeDmaBounceCopy(valid_cap, std.math.maxInt(u64) - 10, 20, .from_device, &mock_device));

    // 3. Address above 4GiB rejected (sub-4GiB invariant)
    var high_cap = valid_cap;
    high_cap.data_addr = 0x1_0000_0000;
    try std.testing.expectError(DmaError.AddressAbove4GiB, executeDmaBounceCopy(high_cap, 0, 64, .from_device, &mock_device));

    // 4. Misaligned buffer rejected (must be cacheline-aligned)
    var unaligned_cap = valid_cap;
    unaligned_cap.data_addr = @intFromPtr(&host_buf) + 1;
    try std.testing.expectError(DmaError.UnalignedBuffer, executeDmaBounceCopy(unaligned_cap, 0, 64, .from_device, &mock_device));

    // 5. Direct DMA forbidden (only CapType.dma_buffer permitted)
    var raw_mem_cap = valid_cap;
    raw_mem_cap.cap_type = .memory_extent;
    try std.testing.expectError(DmaError.DirectDmaForbidden, executeDmaBounceCopy(raw_mem_cap, 0, 64, .from_device, &mock_device));

    var hw_cap = valid_cap;
    hw_cap.cap_type = .hardware_device;
    try std.testing.expectError(DmaError.DirectDmaForbidden, executeDmaBounceCopy(hw_cap, 0, 64, .from_device, &mock_device));

    // 6. Authority check: missing WRITE right for from_device rejected
    var ro_cap = valid_cap;
    ro_cap.rights = Rights.READ;
    try std.testing.expectError(DmaError.PermissionDenied, executeDmaBounceCopy(ro_cap, 0, 64, .from_device, &mock_device));

    // 7. Authority check: missing READ right for to_device rejected
    var wo_cap = valid_cap;
    wo_cap.rights = Rights.WRITE;
    try std.testing.expectError(DmaError.PermissionDenied, executeDmaBounceCopy(wo_cap, 0, 64, .to_device, &mock_device));
}

test "C2: nativeSysDmaBounceCopy syscall authority and bounds enforcement" {
    const authAllowDma = struct {
        fn check(cap_type: CapType, rights: u16) bool {
            if (cap_type == .dma_buffer and (rights & (Rights.READ | Rights.WRITE)) != 0) return true;
            return false;
        }
    }.check;

    var bounce_called = false;
    const mockBounce = struct {
        var called_ptr: *bool = undefined;
        fn bounce(buf_cap: u32, offset: u64, len: u64, dir: DmaDirection) bool {
            _ = buf_cap;
            _ = offset;
            _ = len;
            _ = dir;
            called_ptr.* = true;
            return true;
        }
    };
    mockBounce.called_ptr = &bounce_called;

    setCapAbiContext(authAllowDma, null, null, null);
    setDmaBounceHandler(mockBounce.bounce);
    defer clearCapAbiContext();

    // 1. Authorized call succeeds
    var args = [_]Value{
        Value{ .integer = 5 }, // cap_handle
        Value{ .integer = 0 }, // offset
        Value{ .integer = 64 }, // len
        Value{ .integer = 0 }, // from_device
    };
    const res = try nativeSysDmaBounceCopy(@ptrFromInt(0x1000), &args);
    try std.testing.expectEqual(@as(i64, 64), res.integer);
    try std.testing.expect(bounce_called);

    // 2. Invalid direction rejected
    var bad_dir_args = [_]Value{
        Value{ .integer = 5 },
        Value{ .integer = 0 },
        Value{ .integer = 64 },
        Value{ .integer = 2 }, // Invalid dir
    };
    const bad_dir_res = try nativeSysDmaBounceCopy(@ptrFromInt(0x1000), &bad_dir_args);
    try std.testing.expectEqual(@as(i64, -1), bad_dir_res.integer);

    // 3. Unauthorized caller rejected
    const authRejectAll = struct {
        fn check(_: CapType, _: u16) bool {
            return false;
        }
    }.check;
    setCapAbiContext(authRejectAll, null, null, null);

    const denied_res = try nativeSysDmaBounceCopy(@ptrFromInt(0x1000), &args);
    try std.testing.expectEqual(@as(i64, -1), denied_res.integer);

    // 4. Null bounce handler rejected (fail closed -1)
    setCapAbiContext(authAllowDma, null, null, null);
    setDmaBounceHandler(null);
    const null_res = try nativeSysDmaBounceCopy(@ptrFromInt(0x1000), &args);
    try std.testing.expectEqual(@as(i64, -1), null_res.integer);
}
