// MicrOS (µOS) x86_64 Fast Syscall (LSTAR/STAR) Substrate
// Provides fast userland syscall/sysret transitions with unforgeable stack isolation and CSpace gating.

const std = @import("std");
const io = @import("io.zig");
const serial = @import("../../serial.zig");
const actor_mod = @import("../../actor.zig");
const cap_mod = @import("../../cap/capability.zig");
const CapType = cap_mod.CapType;
const Rights = cap_mod.Rights;
const vmm = @import("../../mem/vmm.zig");

pub const SyscallNumber = enum(u64) {
    actor_count = 1,
    actor_spawn = 2,
    actor_wait = 3,
    actor_status = 4,
    actor_kill = 5,
    cap_grant = 6,
    cap_revoke = 7,
    mem_map = 8,
    mem_unmap = 9,
    storage_read = 10,
    storage_write = 11,
    ipc_send = 12,
    ipc_recv = 13,
    yield_cpu = 14,
    frame_info = 15,
    irq_ack = 16,
    reboot = 17,
    _,
};

pub const CpuControlBlock = extern struct {
    user_rsp: u64 align(8) = 0,
    kernel_rsp: u64 align(8) = 0,
    current_actor_id: u32 = 0,
    reserved: u32 = 0,
};

pub var cpu_control_block: CpuControlBlock = .{};
var syscall_stack: [16384]u8 align(4096) = undefined;
var active_registry: ?*actor_mod.ActorRegistry = null;
pub var kernel_allocator: ?std.mem.Allocator = null;
pub var frame_info_fn: ?*const fn (usize) ?u64 = null;
pub var irq_ack_fn: ?*const fn (u8) void = null;

pub fn setRegistry(registry: *actor_mod.ActorRegistry) void {
    active_registry = registry;
}

pub fn setAllocator(allocator: std.mem.Allocator) void {
    kernel_allocator = allocator;
}

pub fn setDeviceHandlers(
    info_fn: ?*const fn (usize) ?u64,
    ack_fn: ?*const fn (u8) void,
) void {
    frame_info_fn = info_fn;
    irq_ack_fn = ack_fn;
}

pub fn setActorId(id: u32) void {
    cpu_control_block.current_actor_id = id;
}

pub fn getCallerActor() ?*actor_mod.Actor {
    const reg = active_registry orelse return null;
    return reg.get(cpu_control_block.current_actor_id);
}

pub fn checkCallerAuthority(cap_type: CapType, rights: u16) bool {
    const actor = getCallerActor() orelse return false;
    if (actor.id == 0) return true;
    return actor.hasCap(cap_type, rights);
}

pub fn init() void {
    cpu_control_block.kernel_rsp = @intFromPtr(&syscall_stack) + syscall_stack.len;

    // 1. Enable SCE (System Call Enable) in IA32_EFER
    const efer = io.rdmsr(io.MSR_EFER);
    io.wrmsr(io.MSR_EFER, efer | 1);

    // 2. Configure IA32_STAR
    // Bits 48..63: User CS/SS base selector (0x0018 -> User SS 0x20, User CS 0x28)
    // Bits 32..47: Kernel CS/SS base selector (0x0008 -> Kernel CS 0x08, Kernel SS 0x10)
    const star_val: u64 = (@as(u64, 0x0018) << 48) | (@as(u64, 0x0008) << 32);
    io.wrmsr(io.MSR_STAR, star_val);

    // 3. Configure IA32_LSTAR with assembly entry point address
    io.wrmsr(io.MSR_LSTAR, @intFromPtr(&asmSyscallEntry));

    // 4. Configure IA32_SFMASK to mask IF (0x200), TF (0x100), DF (0x400)
    io.wrmsr(io.MSR_SFMASK, 0x00000700);

    // 5. Configure IA32_KERNEL_GS_BASE to point to CpuControlBlock
    io.wrmsr(io.MSR_KERNEL_GS_BASE, @intFromPtr(&cpu_control_block));
}

pub export fn asmSyscallEntry() callconv(.naked) void {
    asm volatile (
        \\swapgs
        \\movq %%rsp, %%gs:0
        \\movq %%gs:8, %%rsp
        \\pushq %%rcx
        \\pushq %%r11
        \\pushq %%rbp
        \\pushq %%rbx
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\movq %%r8, %%r9
        \\movq %%r10, %%r8
        \\movq %%rdx, %%rcx
        \\movq %%rsi, %%rdx
        \\movq %%rdi, %%rsi
        \\movq %%rax, %%rdi
        \\call *%[dispatch]
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%rbx
        \\popq %%rbp
        \\popq %%r11
        \\popq %%rcx
        \\movq %%gs:0, %%rsp
        \\swapgs
        \\sysretq
        :
        : [dispatch] "r" (&kernelSyscallDispatch),
    );
}

fn handleActorSpawn(name_ptr: u64, name_len: u64) i64 {
    if (!checkCallerAuthority(.actor_control, Rights.WRITE)) return -1;
    if (name_len == 0 or name_len > 32 or name_ptr == 0) return -3;
    const reg = active_registry orelse return -2;
    const alloc = kernel_allocator orelse return -2;
    const name: []const u8 = @as([*]const u8, @ptrFromInt(name_ptr))[0..@intCast(name_len)];
    const pml4_phys = vmm.createActorAddressSpace() orelse return -2;
    const child = reg.spawn(
        alloc,
        cpu_control_block.current_actor_id,
        name,
        16,
        pml4_phys,
    ) catch {
        vmm.destroyActorAddressSpace(pml4_phys);
        return -2;
    };
    return @intCast(child.id);
}

fn handleActorKill(id_val: u64) i64 {
    if (!checkCallerAuthority(.actor_control, Rights.REVOKE)) return -1;
    const reg = active_registry orelse return -2;
    const alloc = kernel_allocator orelse return -2;
    if (id_val > std.math.maxInt(u32)) return -3;
    const id: u32 = @intCast(id_val);
    reg.terminate(alloc, id) catch return -4;
    return 0;
}

fn handleActorStatus(id_val: u64) i64 {
    const reg = active_registry orelse return -1;
    if (id_val > std.math.maxInt(u32)) return -1;
    const actor = reg.get(@intCast(id_val)) orelse return -1;
    return @intFromEnum(actor.state);
}

fn handleCapGrant(target_id: u64, cap_slot: u64, rights_mask: u64) i64 {
    const caller = getCallerActor() orelse return -1;
    if (cap_slot > std.math.maxInt(u32) or target_id > std.math.maxInt(u32)) return -3;
    const slot: u32 = @intCast(cap_slot);
    const target: u32 = @intCast(target_id);

    const cap = caller.getCap(slot) orelse return -2;
    if (!cap.canGrant()) return -1;

    const reg = active_registry orelse return -4;
    const dest = reg.get(target) orelse return -4;

    var granted = cap;
    granted.rights = cap.rights & @as(u16, @truncate(rights_mask));
    const handle = dest.insertCap(granted) catch return -5;
    return @intCast(handle);
}

fn handleCapRevoke(cap_slot: u64) i64 {
    const caller = getCallerActor() orelse return -1;
    if (cap_slot > std.math.maxInt(u32)) return -3;
    const slot: u32 = @intCast(cap_slot);
    caller.revokeCap(slot) catch return -2;
    return 0;
}

fn handleMemMap(virt: u64, phys: u64, flags: u64) i64 {
    if (!checkCallerAuthority(.memory_extent, Rights.WRITE)) return -1;
    const caller = getCallerActor() orelse return -1;
    if (caller.page_table_base == 0) return -2;
    const user_flags = flags | vmm.PAGE_PRESENT | vmm.PAGE_USER;
    if (!vmm.mapPage(caller.page_table_base, virt, phys, user_flags)) {
        return -3;
    }
    return 0;
}

fn handleMemUnmap(virt: u64) i64 {
    if (!checkCallerAuthority(.memory_extent, Rights.WRITE)) return -1;
    const caller = getCallerActor() orelse return -1;
    if (caller.page_table_base == 0) return -2;
    if (!vmm.unmapPage(caller.page_table_base, virt)) {
        return -3;
    }
    return 0;
}

fn handleFrameInfo(frame_idx: u64) i64 {
    const has_net = checkCallerAuthority(.network_device, Rights.WRITE);
    const has_storage = checkCallerAuthority(.storage_device, Rights.WRITE);
    if (!has_net and !has_storage) return -1;

    if (frame_info_fn) |info_fn| {
        const addr = info_fn(@intCast(frame_idx)) orelse return -1;
        return @as(i64, @bitCast(addr));
    }
    return @as(i64, @bitCast(frame_idx * 4096));
}

fn handleIrqAck(irq: u64) i64 {
    if (!checkCallerAuthority(.irq_endpoint, Rights.WRITE)) return -1;
    if (irq_ack_fn) |ack_fn| {
        ack_fn(@intCast(irq & 0xFF));
        return 0;
    }
    return -2;
}

pub export fn kernelSyscallDispatch(
    num: u64,
    a1: u64,
    a2: u64,
    a3: u64,
    a4: u64,
    a5: u64,
) callconv(.c) i64 {
    _ = a4;
    _ = a5;

    const sys_enum: SyscallNumber = @enumFromInt(num);
    return switch (sys_enum) {
        .yield_cpu => 0,
        .actor_count => blk: {
            if (active_registry) |reg| {
                break :blk @as(i64, @intCast(reg.active_count));
            }
            break :blk 0;
        },
        .actor_spawn => handleActorSpawn(a1, a2),
        .actor_kill => handleActorKill(a1),
        .actor_status => handleActorStatus(a1),
        .cap_grant => handleCapGrant(a1, a2, a3),
        .cap_revoke => handleCapRevoke(a1),
        .mem_map => handleMemMap(a1, a2, a3),
        .mem_unmap => handleMemUnmap(a1),
        .frame_info => handleFrameInfo(a1),
        .irq_ack => handleIrqAck(a1),
        .reboot => 0,
        else => -1,
    };
}

test "syscall control block alignment and msr constants" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(CpuControlBlock));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(CpuControlBlock));

    const cb: CpuControlBlock = .{
        .user_rsp = 0x0000_7FFF_FFFF_0000,
        .kernel_rsp = 0xFFFF_8000_0001_0000,
        .current_actor_id = 42,
    };
    try std.testing.expect(cb.user_rsp == 0x0000_7FFF_FFFF_0000);
    try std.testing.expect(cb.kernel_rsp == 0xFFFF_8000_0001_0000);
    try std.testing.expect(cb.current_actor_id == 42);

    const star_calc: u64 = (@as(u64, 0x0018) << 48) | (@as(u64, 0x0008) << 32);
    try std.testing.expectEqual(@as(u64, 0x0018000800000000), star_calc);
}

test "syscall dispatch: genesis actor has root authority" {
    const allocator = std.testing.allocator;
    var registry = actor_mod.ActorRegistry.init();
    setRegistry(&registry);
    setAllocator(allocator);
    setActorId(0);
    defer {
        active_registry = null;
        kernel_allocator = null;
    }

    const genesis = try registry.spawn(allocator, 0, "genesis", 16, 0);
    defer registry.terminate(allocator, genesis.id) catch {};

    // Yield
    try std.testing.expectEqual(@as(i64, 0), kernelSyscallDispatch(@intFromEnum(SyscallNumber.yield_cpu), 0, 0, 0, 0, 0));

    // Actor count
    try std.testing.expectEqual(@as(i64, 1), kernelSyscallDispatch(@intFromEnum(SyscallNumber.actor_count), 0, 0, 0, 0, 0));

    // Actor status
    try std.testing.expectEqual(@as(i64, @intFromEnum(actor_mod.ActorState.ready)), kernelSyscallDispatch(@intFromEnum(SyscallNumber.actor_status), genesis.id, 0, 0, 0, 0));

    // Frame info
    try std.testing.expectEqual(@as(i64, 4096), kernelSyscallDispatch(@intFromEnum(SyscallNumber.frame_info), 1, 0, 0, 0, 0));

    // Reboot
    try std.testing.expectEqual(@as(i64, 0), kernelSyscallDispatch(@intFromEnum(SyscallNumber.reboot), 0, 0, 0, 0, 0));
}

test "syscall dispatch: capability gating rejects untrusted actor without capabilities" {
    const allocator = std.testing.allocator;
    var registry = actor_mod.ActorRegistry.init();
    setRegistry(&registry);
    setAllocator(allocator);
    defer {
        active_registry = null;
        kernel_allocator = null;
    }

    // Spawn Genesis actor at ID 0 first
    const genesis = try registry.spawn(allocator, 0, "genesis", 16, 0);
    defer registry.terminate(allocator, genesis.id) catch {};

    // Spawn untrusted actor (will receive ID 1)
    const untrusted = try registry.spawn(allocator, genesis.id, "untrusted", 16, 0);
    defer registry.terminate(allocator, untrusted.id) catch {};

    try std.testing.expect(untrusted.id != 0);
    setActorId(untrusted.id);

    // Untrusted actor cannot spawn without actor_control capability
    const spawn_res = kernelSyscallDispatch(@intFromEnum(SyscallNumber.actor_spawn), @intFromPtr("test"), 4, 0, 0, 0);
    try std.testing.expectEqual(@as(i64, -1), spawn_res);

    // Untrusted actor cannot query frame_info without network_device or storage_device capability
    const frame_res = kernelSyscallDispatch(@intFromEnum(SyscallNumber.frame_info), 1, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(i64, -1), frame_res);

    // Untrusted actor cannot ack IRQ without irq_endpoint capability
    const irq_res = kernelSyscallDispatch(@intFromEnum(SyscallNumber.irq_ack), 10, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(i64, -1), irq_res);

    // Grant actor network_device capability and verify frame_info succeeds
    const net_cap = cap_mod.Capability{
        .cap_type = .network_device,
        .rights = Rights.READ | Rights.WRITE,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 0,
    };
    _ = try untrusted.insertCap(net_cap);

    const authorized_frame = kernelSyscallDispatch(@intFromEnum(SyscallNumber.frame_info), 2, 0, 0, 0, 0);
    try std.testing.expectEqual(@as(i64, 8192), authorized_frame);
}
