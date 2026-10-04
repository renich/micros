// MicrOS (µOS) Native System ABI Bindings
// Exposes microkernel capabilities, actor lifecycle, storage, and IPC to Macros.
// Eradicates legacy POSIX syscall shims in favor of direct capability-mediated operations.

const std = @import("std");
const eval = @import("../macros/eval.zig");
pub const Value = eval.Value;
const vm_mod = @import("../macros/vm.zig");
pub const VM = vm_mod.VM;
const actor_mod = @import("actor.zig");
const ActorRegistry = actor_mod.ActorRegistry;
const Actor = actor_mod.Actor;
const fb_mod = @import("fb.zig");
const Framebuffer = fb_mod.Framebuffer;
const ring_mod = @import("ipc/ring.zig");
const RingBuffer = ring_mod.RingBuffer;
const events_mod = @import("ipc/events.zig");
const serial = @import("serial.zig");
const supervisor_mod = @import("supervisor.zig");
const ps2_mod = @import("drivers/ps2_kbd.zig");
const fiber_mod = @import("../macros/fiber.zig");
const ai_mod = @import("ai.zig");
const bundle_mod = @import("bundle.zig");
const bundle_pack = @import("storage/bundle_pack.zig");
const compositor_mod = @import("compositor.zig");
const WindowManager = compositor_mod.WindowManager;
const WindowMode = compositor_mod.WindowMode;
const Canvas = compositor_mod.Canvas;
const PointerState = compositor_mod.PointerState;
pub const storage_abi = @import("storage/storage_abi.zig");
pub const registerBlockDevice = storage_abi.registerBlockDevice;
pub const setRebuildEngine = storage_abi.setRebuildEngine;
pub const catalog_abi = @import("storage/catalog_abi.zig");
pub const net_abi = @import("net/net_abi.zig");
pub const cap_abi = @import("cap/cap_abi.zig");
pub const PhysFrameInfo = cap_abi.PhysFrameInfo;
pub const console_abi = @import("ipc/console_abi.zig");
pub const fb_abi = @import("compositor/fb_abi.zig");
pub const p2p_abi = @import("../userland/p2pd/p2p_abi.zig");
pub const pkg_abi = @import("../userland/pkgd/pkg_abi.zig");
const cap_mod = @import("cap/capability.zig");
const net_stack_mod = @import("net/stack.zig");
const NetworkStack = net_stack_mod.NetworkStack;

pub const AbiContext = struct {
    registry: *ActorRegistry,
    supervisor: *Actor,
    framebuffer: ?*Framebuffer = null,
    ipc_ring: ?*RingBuffer = null,
    supervisor_ctrl: ?*supervisor_mod.Supervisor = null,
    kbd_ctrl: ?*ps2_mod.Ps2Keyboard = null,
    wm: ?*WindowManager = null,
    canvas: ?*Canvas = null,
    pointer: ?*PointerState = null,
    ai_inference_fn: ?*const fn (prompt_ptr: [*]const u8, prompt_len: usize, out_ptr: [*]u8, out_len: usize) callconv(.c) usize = null,
    spawn_code_fn: ?*const fn (allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 = null,
    cas_put_fn: ?*const fn (data: []const u8, out_hex: *[64]u8) anyerror!void = null,
    cas_get_fn: ?*const fn (hex_hash: []const u8, out_buf: []u8) anyerror!usize = null,
    persist_actor_fn: ?*const fn (actor_id: u32, out_hex: *[64]u8) anyerror!void = null,
    spawn_cas_fn: ?*const fn (allocator: std.mem.Allocator, hex_hash: []const u8) anyerror!u32 = null,
    grant_cap_fn: ?*const fn (target_actor: u32, source_slot: u32, rights_mask: u16) anyerror!bool = null,
    telemetry_fn: ?*const fn () ai_mod.tools.TelemetrySnapshot = null,
    bundle_read_fn: ?*const fn (name: []const u8) ?[]const u8 = null,
    bundle_list_fn: ?*const fn (prefix: []const u8, out_buf: []u8) usize = null,
    current_actor_fn: ?*const fn () ?*Actor = null,
    net_stack: ?*NetworkStack = null,
    p2pd: ?*@import("../userland/p2pd/p2p.zig").P2pDaemon = null,
    frame_info_fn: ?*const fn (frame_idx: usize) ?u64 = null,
    irq_ack_fn: ?*const fn (irq: u8) void = null,
    dma_pin_fn: ?*const fn (virt_addr: usize, len_bytes: usize) ?u64 = null,
};

pub const HarnessContext = AbiContext;

var active_ctx: ?*AbiContext = null;

pub const window_abi = @import("compositor/window_abi.zig");
pub const ai_abi = @import("ai/ai_abi.zig");

var win_ctx: window_abi.WindowContext = .{};
var ai_ctx: ai_abi.AiContext = .{};

pub fn checkCallerAuthority(cap_type: @import("cap/capability.zig").CapType, rights: u16) bool {
    const ctx = active_ctx orelse return false;
    const actor = if (ctx.current_actor_fn) |get_act| (get_act() orelse return false) else ctx.supervisor;
    return actor.hasCap(cap_type, rights);
}

pub fn getCallerActor() ?*Actor {
    const ctx = active_ctx orelse return null;
    return if (ctx.current_actor_fn) |get_act| (get_act() orelse return null) else ctx.supervisor;
}

pub fn getCallerActorId() u32 {
    const actor = getCallerActor() orelse return 0;
    return actor.id;
}

pub fn setContext(ctx: *AbiContext) void {
    active_ctx = ctx;
    storage_abi.caller_auth_fn = checkCallerAuthority;
    catalog_abi.setStorageContext(ctx.cas_put_fn, ctx.cas_get_fn, checkCallerAuthority);
    net_abi.setNetworkContext(ctx.net_stack, checkCallerAuthority, getCallerActorId);
    cap_abi.setCapAbiContext(checkCallerAuthority, ctx.frame_info_fn, ctx.irq_ack_fn, ctx.dma_pin_fn);
    p2p_abi.setP2pContext(ctx.p2pd, checkCallerAuthority);
    pkg_abi.setPkgContext(checkCallerAuthority);

    win_ctx = .{
        .wm = ctx.wm,
        .canvas = ctx.canvas,
        .pointer = ctx.pointer,
        .framebuffer = ctx.framebuffer,
        .supervisor_id = ctx.supervisor.id,
        .check_auth_fn = checkCallerAuthority,
    };
    window_abi.setWindowContext(&win_ctx);

    ai_ctx = .{
        .ai_inference_fn = ctx.ai_inference_fn,
        .spawn_code_fn = ctx.spawn_code_fn,
        .grant_cap_fn = ctx.grant_cap_fn,
        .cas_put_fn = ctx.cas_put_fn,
        .cas_get_fn = ctx.cas_get_fn,
        .telemetry_fn = ctx.telemetry_fn,
        .bundle_read_fn = ctx.bundle_read_fn,
        .bundle_list_fn = ctx.bundle_list_fn,
        .current_actor_fn = ctx.current_actor_fn,
        .supervisor = ctx.supervisor,
        .check_auth_fn = checkCallerAuthority,
    };
    ai_abi.setAiContext(&ai_ctx);
    fb_abi.setContext(ctx.framebuffer, checkCallerAuthority);
    console_abi.setContext(ctx.kbd_ctrl, checkCallerAuthority);
    console_abi.setCallerIdFn(getCallerActorId);
    console_abi.setInputRing(ctx.ipc_ring);
}

pub fn clearContext() void {
    active_ctx = null;
    storage_abi.caller_auth_fn = null;
    pkg_abi.clearPkgContext();
    console_abi.setInputRing(null);
    console_abi.setCallerIdFn(null);
    catalog_abi.clearCatalogContext();
    net_abi.clearNetworkContext();
    cap_abi.clearCapAbiContext();
    window_abi.clearWindowContext();
    ai_abi.clearAiContext();
    fb_abi.setContext(null, null);
    console_abi.setContext(null, null);
}

fn castToU32(val: i64) ?u32 {
    if (val < 0 or val > std.math.maxInt(u32)) return null;
    return @intCast(val);
}

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        const is_num = (c >= '0' and c <= '9');
        const is_lower = (c >= 'a' and c <= 'f');
        const is_upper = (c >= 'A' and c <= 'F');
        if (!is_num and !is_lower and !is_upper) return false;
    }
    return true;
}

fn propagateCallerBudget(ctx: *AbiContext, caller_id: u32, child_id: u32) void {
    if (caller_id >= actor_mod.MAX_ACTORS) return;
    const c_act = ctx.registry.get(caller_id) orelse return;
    defer c_act.release();
    if (c_act.gas_budget == 0) return;
    const ch_act = ctx.registry.get(child_id) orelse return;
    defer ch_act.release();
    ch_act.gas_budget = c_act.gas_budget;
}

fn spawnSingleArg(ctx: *AbiContext, vm: *VM, caller_id: u32, str: []const u8) !Value {
    if (isHex64(str) and ctx.spawn_cas_fn != null) {
        if (!checkCallerAuthority(.storage_device, cap_mod.Rights.READ)) return error.PermissionDenied;
        const child_id = ctx.spawn_cas_fn.?(vm.allocator, str) catch return Value{ .integer = -1 };
        propagateCallerBudget(ctx, caller_id, child_id);
        return Value{ .integer = @as(i64, child_id) };
    }
    const child = try ctx.registry.spawn(vm.allocator, caller_id, str, 32, 0);
    return Value{ .integer = @intCast(child.id) };
}

fn nativeSysActorSpawn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1 or args.len > 2 or args[0] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.actor_control, cap_mod.Rights.WRITE)) return error.PermissionDenied;
    const ctx = active_ctx orelse return error.NoContext;
    const caller_id = getCallerActorId();

    if (args.len == 1) return spawnSingleArg(ctx, vm, caller_id, args[0].string);

    if (args[1] != .string) return error.InvalidArgs;
    const name = args[0].string;
    const target = args[1].string;
    if (isHex64(target) and ctx.spawn_cas_fn != null) {
        if (!checkCallerAuthority(.storage_device, cap_mod.Rights.READ)) return error.PermissionDenied;
        const child_id = ctx.spawn_cas_fn.?(vm.allocator, target) catch return Value{ .integer = -1 };
        propagateCallerBudget(ctx, caller_id, child_id);
        return Value{ .integer = @as(i64, child_id) };
    }
    if (ctx.spawn_code_fn) |spawn_fn| {
        const child_id = spawn_fn(vm.allocator, name, target) catch return Value{ .integer = -1 };
        propagateCallerBudget(ctx, caller_id, child_id);
        return Value{ .integer = @as(i64, child_id) };
    }
    return error.NoSpawnHandler;
}

fn nativeSysActorTerminate(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    if (!checkCallerAuthority(.actor_control, cap_mod.Rights.WRITE)) return error.PermissionDenied;
    const ctx = active_ctx orelse return error.NoContext;
    const id = castToU32(args[0].integer) orelse return error.InvalidArgs;
    if (id == actor_mod.GENESIS_ACTOR_ID) return error.PermissionDenied;
    try ctx.registry.terminate(vm.allocator, id);
    return Value{ .boolean = true };
}

fn nativeSysIpcRecv(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    const caller_id = getCallerActorId();
    const actor = getCallerActor() orelse return error.NoContext;
    var ring: *RingBuffer = undefined;
    if (args.len >= 1 and args[0] == .integer) {
        const handle = castToU32(args[0].integer) orelse return error.InvalidArgs;
        const cap = actor.getCap(handle) orelse return error.InvalidCapability;
        if (cap.cap_type != .ipc_ring or (cap.rights & cap_mod.Rights.READ) == 0) return error.PermissionDenied;
        if (cap.data_size != @sizeOf(RingBuffer) or cap.data_addr == 0) return error.InvalidCapability;
        ring = @ptrFromInt(cap.data_addr);
    } else if (caller_id == 0) {
        const ctx = active_ctx orelse return Value{ .integer = -1 };
        ring = ctx.ipc_ring orelse return Value{ .integer = -1 };
    } else {
        return error.PermissionDenied;
    }
    const frame = ring.pop() orelse return Value{ .integer = -1 };

    if (events_mod.fromMessageFrame(&frame)) |event| {
        if (event.action == .press) {
            return Value{ .integer = if (event.ascii != 0) event.ascii else event.keycode };
        }
    }
    return Value{ .integer = 0 };
}

fn nativeSysFaultCount(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    const caller_id = getCallerActorId();
    if (caller_id != 0 and !checkCallerAuthority(.actor_control, cap_mod.Rights.WRITE)) return error.PermissionDenied;
    const ctx = active_ctx orelse return Value{ .integer = 0 };
    if (ctx.supervisor_ctrl) |sup| {
        return Value{ .integer = @intCast(sup.total_faults) };
    }
    return Value{ .integer = 0 };
}

fn nativeSysYield(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    fiber_mod.yield();
    return Value{ .integer = 0 };
}

fn nativeSysActorState(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1 or args.len > 2) return error.InvalidArgs;
    if (args[0] != .integer) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const reg = ctx.registry;
    const id = castToU32(args[0].integer) orelse return error.InvalidArgs;

    if (id == 0 and args.len == 1) {
        const items = try vm.gcAllocator().alloc(Value, 4);
        items[0] = Value{ .integer = @intCast(reg.active_count) };
        items[1] = Value{ .integer = @intCast(reg.active_count) };
        items[2] = Value{ .integer = 0 };
        items[3] = Value{ .integer = 0 };
        return Value{ .array = items };
    }

    if (reg.get(id)) |actor| {
        defer actor.release();
        if (args.len == 2) {
            const items = try vm.gcAllocator().alloc(Value, 4);
            items[0] = Value{ .integer = @as(i64, @intFromEnum(actor.state)) };
            const name_copy = try vm.gcAllocator().dupe(u8, actor.getName());
            items[1] = Value{ .string = name_copy };
            items[2] = Value{ .integer = @as(i64, @intCast(actor.gas_budget)) };
            items[3] = Value{ .integer = @as(i64, @intCast(actor.supervisor_id)) };
            if (args[1] == .array and args[1].array.len >= 4) {
                @memcpy(args[1].array[0..4], items[0..4]);
            }
            return Value{ .array = items };
        }
        return Value{ .integer = @as(i64, @intFromEnum(actor.state)) };
    }

    if (args.len == 2) {
        const empty = try vm.gcAllocator().alloc(Value, 0);
        return Value{ .array = empty };
    }
    return Value{ .integer = -1 };
}

fn nativeSysActorSetBudget(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 2 or args[0] != .integer or args[1] != .integer) return error.InvalidArgs;
    if (!checkCallerAuthority(.actor_control, cap_mod.Rights.WRITE)) return error.PermissionDenied;
    const ctx = active_ctx orelse return error.NoContext;
    const id = castToU32(args[0].integer) orelse return error.InvalidArgs;
    if (args[1].integer < 0) return error.InvalidArgs;
    const budget: u64 = @intCast(args[1].integer);
    if (ctx.registry.get(id)) |actor| {
        defer actor.release();
        actor.gas_budget = budget;
        return Value{ .boolean = true };
    }
    return Value{ .boolean = false };
}

fn pollRingEvent(ring: *RingBuffer) ?i64 {
    const frame = ring.pop() orelse return null;
    const ev = events_mod.fromMessageFrame(&frame) orelse return null;
    if (ev.action != .press) return null;
    return @as(i64, if (ev.ascii != 0) ev.ascii else ev.keycode);
}

fn storePolledEvent(args: []Value, code: i64) Value {
    if (args.len >= 2 and args[1] == .array and args[1].array.len > 0) {
        args[1].array[0] = Value{ .integer = code };
        return Value{ .integer = 1 };
    }
    return Value{ .integer = code };
}

fn resolvePollRing(actor: *actor_mod.Actor, caller_id: u32, args: []Value) !?*RingBuffer {
    if (args.len >= 1 and args[0] == .integer) {
        const handle = castToU32(args[0].integer) orelse return error.InvalidArgs;
        const cap = actor.getCap(handle) orelse return error.InvalidCapability;
        if ((cap.rights & cap_mod.Rights.READ) == 0) return error.PermissionDenied;
        if (cap.cap_type == .ipc_ring) {
            if (cap.data_size != @sizeOf(RingBuffer) or cap.data_addr == 0) return error.InvalidCapability;
            return @ptrFromInt(cap.data_addr);
        }
        if (cap.cap_type != .actor_control and cap.cap_type != .framebuffer) {
            return error.InvalidCapability;
        }
        return null;
    }
    if (caller_id == 0 or actor.hasCap(.actor_control, cap_mod.Rights.READ) or actor.hasCap(.framebuffer, cap_mod.Rights.READ)) {
        const ctx = active_ctx orelse return null;
        return ctx.ipc_ring;
    }
    return error.PermissionDenied;
}

fn pollFallbackKbd(vm: *VM, actor: *actor_mod.Actor, caller_id: u32) ?i64 {
    const has_auth = (caller_id == 0 or actor.hasCap(.framebuffer, cap_mod.Rights.READ) or actor.hasCap(.actor_control, cap_mod.Rights.READ));
    if (!has_auth) return null;
    const kv = console_abi.nativeSysKbdRead(vm, &[_]Value{}) catch return null;
    if (kv.integer > 0) return kv.integer;
    return null;
}

fn nativeSysEventPoll(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    const caller_id = getCallerActorId();
    const actor = getCallerActor() orelse return error.NoContext;
    const ring = try resolvePollRing(actor, caller_id, args);

    if (ring) |r| {
        if (pollRingEvent(r)) |code| return storePolledEvent(args, code);
    }
    if (pollFallbackKbd(vm, actor, caller_id)) |code| {
        return storePolledEvent(args, code);
    }
    if (args.len >= 2 and args[1] == .array) return Value{ .integer = 0 };
    return Value{ .integer = -1 };
}

fn nativeSysCasPut(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.storage_device, cap_mod.Rights.WRITE)) return error.PermissionDenied;
    const ctx = active_ctx orelse return error.NoContext;
    const put_fn = ctx.cas_put_fn orelse return error.NoStorageHandler;
    var hex_buf: [64]u8 = undefined;
    put_fn(args[0].string, &hex_buf) catch return Value{ .string = "" };
    const duped = try vm.gcAllocator().dupe(u8, &hex_buf);
    return Value{ .string = duped };
}

fn nativeSysCasGet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.storage_device, cap_mod.Rights.READ)) return error.PermissionDenied;
    const ctx = active_ctx orelse return error.NoContext;
    const get_fn = ctx.cas_get_fn orelse return error.NoStorageHandler;
    const buf = try vm.allocator.alloc(u8, 4096);
    defer vm.allocator.free(buf);
    const len = get_fn(args[0].string, buf) catch return Value{ .string = "" };
    const duped = try vm.gcAllocator().dupe(u8, buf[0..len]);
    return Value{ .string = duped };
}

fn nativeSysBundleRead(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const read_fn = ctx.bundle_read_fn orelse return Value{ .string = "" };
    if (read_fn(args[0].string)) |content| {
        const duped = try vm.gcAllocator().dupe(u8, content);
        return Value{ .string = duped };
    }
    return Value{ .string = "" };
}

/// Pack `[tag, content]` pairs into a deterministic MCB bundle.
///
/// Bundle packing is deliberately absent from the application ABI (Cozy Stage 1 cut it with
/// the other 13 syscalls); it is restored here under `rebuild_control`, the same authority the
/// self-rebuilding specification requires for kernel synthesis and staging, and which only the
/// pristine rebuild actor holds.
fn nativeSysBundlePack(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .array) return error.InvalidArgs;
    if (!checkCallerAuthority(.rebuild_control, cap_mod.Rights.WRITE | cap_mod.Rights.EXECUTE)) {
        return error.PermissionDenied;
    }

    const values = args[0].array;
    if (values.len == 0) return Value{ .string = "" };
    if (values.len > bundle_pack.MAX_BUNDLE_ENTRIES) return error.TooManyBundleEntries;

    const entries = try vm.allocator.alloc(bundle_pack.Entry, values.len);
    defer vm.allocator.free(entries);
    for (values, 0..) |value, i| {
        if (value != .array or value.array.len != 2) return error.InvalidArgs;
        if (value.array[0] != .string or value.array[1] != .string) return error.InvalidArgs;
        entries[i] = .{ .tag = value.array[0].string, .content = value.array[1].string };
    }

    return Value{ .string = try bundle_pack.pack(vm.gcAllocator(), entries) };
}

pub fn registerSyscalls(vm: *VM) !void {
    try vm.globals.put("sys_actor_spawn", Value{ .native = nativeSysActorSpawn });
    try vm.globals.put("sys_actor_terminate", Value{ .native = nativeSysActorTerminate });
    try vm.globals.put("sys_actor_state", Value{ .native = nativeSysActorState });
    try vm.globals.put("sys_actor_set_budget", Value{ .native = nativeSysActorSetBudget });
    try vm.globals.put("sys_yield", Value{ .native = nativeSysYield });
    try vm.globals.put("sys_event_poll", Value{ .native = nativeSysEventPoll });
    try vm.globals.put("sys_ipc_recv", Value{ .native = nativeSysIpcRecv });
    try vm.globals.put("sys_kbd_read", Value{ .native = console_abi.nativeSysKbdRead });
    try vm.globals.put("sys_pointer_read", Value{ .native = window_abi.nativeSysPointerRead });
    try vm.globals.put("sys_serial_write", Value{ .native = console_abi.nativeSysSerialWrite });
    try vm.globals.put("sys_serial_read", Value{ .native = console_abi.nativeSysSerialRead });
    try vm.globals.put("sys_fault_count", Value{ .native = nativeSysFaultCount });
    try vm.globals.put("sys_ai_prompt", Value{ .native = ai_abi.nativeSysAiPrompt });
    try vm.globals.put("sys_ai_tool_call", Value{ .native = ai_abi.nativeSysAiToolCall });
    try vm.globals.put("sys_cas_put", Value{ .native = nativeSysCasPut });
    try vm.globals.put("sys_cas_get", Value{ .native = nativeSysCasGet });
    try vm.globals.put("sys_bundle_read", Value{ .native = nativeSysBundleRead });
    try vm.globals.put("sys_bundle_pack", Value{ .native = nativeSysBundlePack });
    try vm.globals.put("sys_window_create", Value{ .native = window_abi.nativeSysWindowCreate });
    try vm.globals.put("sys_window_close", Value{ .native = window_abi.nativeSysWindowClose });
    try vm.globals.put("sys_window_focus", Value{ .native = window_abi.nativeSysWindowFocus });
    try vm.globals.put("sys_window_draw_rect", Value{ .native = window_abi.nativeSysWindowDrawRect });
    try vm.globals.put("sys_window_draw_string", Value{ .native = window_abi.nativeSysWindowDrawString });
    try vm.globals.put("sys_window_commit", Value{ .native = window_abi.nativeSysWindowCommit });
    try vm.globals.put("sys_compositor_flush", Value{ .native = window_abi.nativeSysWindowCommit });
    try storage_abi.registerStorageSyscalls(vm);
    try catalog_abi.registerCatalogSyscalls(vm);
    try net_abi.registerNetworkSyscalls(vm);
    try cap_abi.registerCapSyscalls(vm);
    try p2p_abi.registerP2pSyscalls(vm);
    try pkg_abi.registerPkgSyscalls(vm);
}

pub const registerBindings = registerSyscalls;

fn testMockSpawn(allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 {
    _ = allocator;
    _ = name;
    _ = source;
    return 7;
}

fn testMockSpawnFail(allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 {
    _ = allocator;
    _ = name;
    _ = source;
    return error.CompilationFailed;
}

fn testMockCasPut(data: []const u8, out_hex: *[64]u8) anyerror!void {
    _ = data;
    @memcpy(out_hex, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
}

fn testMockCasGet(hex_hash: []const u8, out_buf: []u8) anyerror!usize {
    _ = hex_hash;
    const msg = "persisted actor content";
    @memcpy(out_buf[0..msg.len], msg);
    return msg.len;
}

fn testMockSpawnCas(allocator: std.mem.Allocator, hex_hash: []const u8) anyerror!u32 {
    _ = allocator;
    _ = hex_hash;
    return 42;
}

fn testMockBundleRead(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "test.mx")) return "print(\"hello\");";
    return null;
}

const TestEnv = struct {
    allocator: std.mem.Allocator,
    chunk: @import("../macros/chunk.zig").Chunk,
    vm: VM,
    registry: ActorRegistry,
    supervisor: *Actor,
    ctx: AbiContext,

    fn init(allocator: std.mem.Allocator) !TestEnv {
        var chunk = @import("../macros/chunk.zig").Chunk.init();
        const vm = try VM.init(allocator, &chunk);
        var reg = ActorRegistry.init();
        var sup = try Actor.init(allocator, 0, "genesis", 16, 0);
        _ = try sup.cspace.insert(cap_mod.Capability{
            .cap_type = .actor_control,
            .rights = cap_mod.Rights.ALL,
            .object_id = 1,
            .data_addr = 0,
            .data_size = 0,
        });
        try reg.register(sup);
        return .{
            .allocator = allocator,
            .chunk = chunk,
            .vm = vm,
            .registry = reg,
            .supervisor = sup,
            .ctx = AbiContext{ .registry = undefined, .supervisor = sup },
        };
    }

    fn activate(self: *TestEnv) !void {
        self.ctx.registry = &self.registry;
        self.ctx.supervisor = self.supervisor;
        setContext(&self.ctx);
        try registerSyscalls(&self.vm);
    }

    fn deinit(self: *TestEnv) void {
        clearContext();
        self.registry.actors[0] = null;
        self.supervisor.deinit(self.allocator);
        self.vm.deinit();
        self.chunk.deinit(self.allocator);
    }
};

test "ABI actor lifecycle native bindings" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    env.ctx.bundle_read_fn = testMockBundleRead;
    try env.activate();

    var state0_args = [_]Value{Value{ .integer = 0 }};
    const state_0 = try nativeSysActorState(&env.vm, &state0_args);
    defer env.allocator.free(state_0.array);
    try std.testing.expectEqual(@as(usize, 4), state_0.array.len);
    try std.testing.expectEqual(@as(i64, 1), state_0.array[0].integer);

    var spawn_args = [_]Value{Value{ .string = "child_1" }};
    const spawn_val = try nativeSysActorSpawn(&env.vm, &spawn_args);
    try std.testing.expectEqual(@as(i64, 1), spawn_val.integer);
    try std.testing.expectEqual(@as(usize, 2), env.registry.active_count);

    const state_0_after = try nativeSysActorState(&env.vm, &state0_args);
    defer env.allocator.free(state_0_after.array);
    try std.testing.expectEqual(@as(i64, 2), state_0_after.array[0].integer);

    var child_args = [_]Value{ Value{ .integer = 1 }, Value{ .boolean = true } };
    const state_child = try nativeSysActorState(&env.vm, &child_args);
    try std.testing.expectEqual(@as(usize, 4), state_child.array.len);
    try std.testing.expectEqualStrings("child_1", state_child.array[1].string);
    env.allocator.free(state_child.array[1].string);
    env.allocator.free(state_child.array);

    var child_1arg = [_]Value{Value{ .integer = 1 }};
    const state_int = try nativeSysActorState(&env.vm, &child_1arg);
    try std.testing.expectEqual(@as(i64, 1), state_int.integer);

    var term_genesis = [_]Value{Value{ .integer = 0 }};
    try std.testing.expectError(error.PermissionDenied, nativeSysActorTerminate(&env.vm, &term_genesis));

    var term_args = [_]Value{Value{ .integer = 1 }};
    const term_val = try nativeSysActorTerminate(&env.vm, &term_args);
    try std.testing.expectEqual(true, term_val.boolean);
    try std.testing.expectEqual(@as(usize, 1), env.registry.active_count);
}

test "ABI bundle read native binding" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    env.ctx.bundle_read_fn = testMockBundleRead;
    try env.activate();

    var bread_args = [_]Value{Value{ .string = "test.mx" }};
    const bread_val = try nativeSysBundleRead(&env.vm, &bread_args);
    defer env.allocator.free(bread_val.string);
    try std.testing.expectEqualStrings("print(\"hello\");", bread_val.string);

    var bmissing_args = [_]Value{Value{ .string = "missing.mx" }};
    const bmissing_val = try nativeSysBundleRead(&env.vm, &bmissing_args);
    try std.testing.expectEqualStrings("", bmissing_val.string);
}

test "ABI native CAS storage and persistence bindings" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    _ = try env.supervisor.cspace.insert(cap_mod.Capability{
        .cap_type = .storage_device,
        .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE,
        .object_id = 2,
        .data_addr = 0,
        .data_size = 0,
    });
    env.ctx.cas_put_fn = testMockCasPut;
    env.ctx.cas_get_fn = testMockCasGet;
    env.ctx.spawn_cas_fn = testMockSpawnCas;
    try env.activate();

    var put_args = [_]Value{Value{ .string = "sample code" }};
    const put_val = try nativeSysCasPut(&env.vm, &put_args);
    defer env.allocator.free(put_val.string);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", put_val.string);

    var get_args = [_]Value{Value{ .string = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }};
    const get_val = try nativeSysCasGet(&env.vm, &get_args);
    defer env.allocator.free(get_val.string);
    try std.testing.expectEqualStrings("persisted actor content", get_val.string);

    var scas_args = [_]Value{Value{ .string = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }};
    const scas_val = try nativeSysActorSpawn(&env.vm, &scas_args);
    try std.testing.expectEqual(@as(i64, 42), scas_val.integer);
}

test "ABI native fault-tolerant spawn" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    env.ctx.spawn_code_fn = testMockSpawnFail;
    try env.activate();

    var fail_args = [_]Value{ Value{ .string = "broken" }, Value{ .string = "syntax error!!" } };
    const fail_val = try nativeSysActorSpawn(&env.vm, &fail_args);
    try std.testing.expectEqual(@as(i64, -1), fail_val.integer);
}

test "ABI native AI tool call execution" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    env.ctx.spawn_code_fn = testMockSpawn;
    try env.activate();

    const tool_json = "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"spawn_actor\",\"args\":{\"name\":\"w\",\"source\":\"sys_yield();\"}}}]}}]}";
    var args = [_]Value{Value{ .string = tool_json }};
    const res_val = try ai_abi.nativeSysAiToolCall(&env.vm, &args);
    defer env.allocator.free(res_val.string);
    try std.testing.expect(std.mem.indexOf(u8, res_val.string, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res_val.string, "\"actor_id\":7") != null);

    var no_tool_args = [_]Value{Value{ .string = "Plain prose" }};
    const empty_val = try ai_abi.nativeSysAiToolCall(&env.vm, &no_tool_args);
    try std.testing.expectEqualStrings("", empty_val.string);
}

test "ABI window and compositor native bindings" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    _ = try env.supervisor.cspace.insert(cap_mod.Capability{
        .cap_type = .framebuffer,
        .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE,
        .object_id = 2,
        .data_addr = 0,
        .data_size = 0,
    });
    var wm = WindowManager.init(env.allocator, 640, 480);
    defer wm.deinit();
    var canvas = try Canvas.init(env.allocator, 640, 480, .rgb_888);
    defer canvas.deinit();
    var ptr = PointerState.init(640, 480);
    env.ctx.wm = &wm;
    env.ctx.canvas = &canvas;
    env.ctx.pointer = &ptr;
    try env.activate();

    var create_args = [_]Value{ Value{ .string = "Terminal" }, Value{ .integer = 320 }, Value{ .integer = 240 }, Value{ .integer = 0 } };
    const win_id_val = try window_abi.nativeSysWindowCreate(&env.vm, &create_args);
    try std.testing.expectEqual(@as(i64, 1), win_id_val.integer);

    var drect_args = [_]Value{ Value{ .integer = 1 }, Value{ .integer = 0 }, Value{ .integer = 0 }, Value{ .integer = 50 }, Value{ .integer = 50 }, Value{ .integer = 0x00FF_0000 } };
    _ = try window_abi.nativeSysWindowDrawRect(&env.vm, &drect_args);

    var dstr_args = [_]Value{ Value{ .integer = 1 }, Value{ .integer = 5 }, Value{ .integer = 5 }, Value{ .string = "OK" }, Value{ .integer = 0x00FF_FFFF }, Value{ .integer = 0 } };
    _ = try window_abi.nativeSysWindowDrawString(&env.vm, &dstr_args);

    var flush_args = [_]Value{};
    const flush_val = try window_abi.nativeSysCompositorFlush(&env.vm, &flush_args);
    try std.testing.expect(flush_val.boolean);

    const ptr_val = try window_abi.nativeSysPointerRead(&env.vm, &flush_args);
    try std.testing.expect(ptr_val.integer != -1);

    var focus_args = [_]Value{Value{ .integer = 1 }};
    const focus_val = try window_abi.nativeSysWindowFocus(&env.vm, &focus_args);
    try std.testing.expect(focus_val.boolean);

    var close_args = [_]Value{Value{ .integer = 1 }};
    const close_val = try window_abi.nativeSysWindowClose(&env.vm, &close_args);
    try std.testing.expect(close_val.boolean);
}

test "sys_ipc_recv rejects unauthorized non-genesis actors without capability" {
    const allocator = std.testing.allocator;
    var registry = actor_mod.ActorRegistry.init();
    var genesis = try actor_mod.Actor.init(allocator, 0, "genesis", 16, 0);
    defer genesis.deinit(allocator);
    var child = try actor_mod.Actor.init(allocator, 1, "untrusted", 16, 0);
    defer child.deinit(allocator);

    var ring = try RingBuffer.init(allocator, 8);
    defer ring.deinit(allocator);

    var ctx = AbiContext{ .registry = &registry, .supervisor = genesis, .ipc_ring = ring };
    setContext(&ctx);
    defer clearContext();

    var chunk = @import("../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);
    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    const CurrentActorHelper = struct {
        var act: ?*Actor = null;
        fn get() ?*Actor {
            return act;
        }
    };
    CurrentActorHelper.act = child;
    ctx.current_actor_fn = CurrentActorHelper.get;

    var no_args = [_]Value{};
    try std.testing.expectError(error.PermissionDenied, nativeSysIpcRecv(&vm, &no_args));
}

test "abi ipc_ring type confusion and framebuffer negative coordinate rejection" {
    const allocator = std.testing.allocator;
    var registry = ActorRegistry.init();
    const genesis = try registry.spawn(allocator, 0, "genesis", 32, 0);
    defer registry.terminate(allocator, genesis.id) catch {};
    const child = try registry.spawn(allocator, genesis.id, "worker", 32, 0);
    defer registry.terminate(allocator, child.id) catch {};

    var dummy: u64 = 0;
    const fake_cap = cap_mod.Capability{
        .cap_type = .ipc_ring,
        .rights = cap_mod.Rights.READ,
        .object_id = 99,
        .data_addr = @intFromPtr(&dummy),
        .data_size = 8,
    };
    const handle = try child.insertCap(fake_cap);

    var ctx = AbiContext{ .registry = &registry, .supervisor = genesis };
    setContext(&ctx);
    defer clearContext();

    var chunk = @import("../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);
    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    const Helper = struct {
        var act: ?*Actor = null;
        fn get() ?*Actor {
            return act;
        }
    };
    Helper.act = child;
    ctx.current_actor_fn = Helper.get;

    var args = [_]Value{Value{ .integer = @intCast(handle) }};
    try std.testing.expectError(error.InvalidCapability, nativeSysIpcRecv(&vm, &args));

    _ = try genesis.insertCap(cap_mod.Capability{
        .cap_type = .framebuffer,
        .rights = cap_mod.Rights.WRITE,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 0,
    });
    Helper.act = genesis;
    var neg_clear = [_]Value{Value{ .integer = -1 }};
    try std.testing.expectError(error.InvalidArgs, fb_abi.nativeSysFbClear(&vm, &neg_clear));
}

test "ABI excision: 13 cut syscalls are absent from VM globals" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    try env.activate();

    const cut_syscalls = [_][]const u8{
        "sys_fb_clear",        "sys_fb_draw_string", "sys_fb_draw_rect",    "sys_kbd_layout",
        "sys_ai_extract_code", "sys_actor_count",    "sys_actor_name",      "sys_actor_spawn_code",
        "sys_actor_wait",      "sys_actor_persist",  "sys_actor_spawn_cas", "sys_git_get_head",
        "sys_git_cat_file",
    };
    for (cut_syscalls) |name| {
        try std.testing.expect(env.vm.globals.get(name) == null);
    }
}

test "ABI demote: sys_fault_count requires actor_control WRITE authority" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    var unauth = try Actor.init(env.allocator, 2, "unauth", 16, 0);
    defer unauth.deinit(env.allocator);
    try env.activate();

    const Helper = struct {
        var act: ?*Actor = null;
        fn get() ?*Actor {
            return act;
        }
    };
    Helper.act = unauth;
    env.ctx.current_actor_fn = Helper.get;

    var no_args = [_]Value{};
    try std.testing.expectError(error.PermissionDenied, nativeSysFaultCount(&env.vm, &no_args));

    Helper.act = env.supervisor;
    const res = try nativeSysFaultCount(&env.vm, &no_args);
    try std.testing.expectEqual(@as(i64, 0), res.integer);
}

test "ABI new: sys_event_poll and sys_actor_set_budget" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    var ring = try RingBuffer.init(env.allocator, 8);
    defer ring.deinit(env.allocator);
    env.ctx.ipc_ring = ring;
    try env.activate();

    var budget_args = [_]Value{ Value{ .integer = 0 }, Value{ .integer = 7500 } };
    const b_res = try nativeSysActorSetBudget(&env.vm, &budget_args);
    try std.testing.expectEqual(true, b_res.boolean);

    var poll_args = [_]Value{};
    const ev_empty = try nativeSysEventPoll(&env.vm, &poll_args);
    try std.testing.expectEqual(@as(i64, -1), ev_empty.integer);

    const key_ev = events_mod.KeyEvent{ .scancode = 0x1E, .action = .press, .modifiers = .{}, .ascii = 65, .keycode = 65 };
    const frame = events_mod.toMessageFrame(key_ev, 1);
    try std.testing.expect(ring.push(frame));
    const ev_val = try nativeSysEventPoll(&env.vm, &poll_args);
    try std.testing.expectEqual(@as(i64, 65), ev_val.integer);
}

test "G4 Gas Budget: sys_actor_set_budget, inheritance, state visibility, and OutOfGas parking" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    try env.activate();

    // 1. Set budget on supervisor
    var budget_args = [_]Value{ Value{ .integer = 0 }, Value{ .integer = 200 } };
    const b_res = try nativeSysActorSetBudget(&env.vm, &budget_args);
    try std.testing.expect(b_res.boolean);
    try std.testing.expectEqual(@as(u64, 200), env.supervisor.gas_budget);

    // 2. Spawn child actor - child inherits supervisor's budget (200)
    const child = try env.registry.spawn(env.allocator, 0, "worker", 16, 0);
    defer {
        env.registry.actors[child.id] = null;
        child.deinit(env.allocator);
    }
    try std.testing.expectEqual(@as(u64, 200), child.gas_budget);

    // 3. State query returns [status, name, gas_budget, supervisor_id]
    var dummy_arr = [_]Value{};
    var state_args = [_]Value{ Value{ .integer = @as(i64, child.id) }, Value{ .array = &dummy_arr } };
    const state_val = try nativeSysActorState(&env.vm, &state_args);
    defer {
        env.vm.gcAllocator().free(state_val.array[1].string);
        env.vm.gcAllocator().free(state_val.array);
    }
    try std.testing.expectEqual(@as(i64, 200), state_val.array[2].integer);

    // 4. Infinite-loop child parks on OutOfGas
    var loop_chunk = @import("../macros/chunk.zig").Chunk.init();
    defer loop_chunk.deinit(env.allocator);
    try loop_chunk.writeChunk(env.allocator, @intFromEnum(@import("../macros/chunk.zig").OpCode.loop));
    try loop_chunk.writeChunk(env.allocator, 0);
    try loop_chunk.writeChunk(env.allocator, 3);

    var loop_vm = try VM.init(env.allocator, &loop_chunk);
    defer loop_vm.deinit();
    loop_vm.setGasLimit(child.gas_budget);

    const run_err = loop_vm.run(0);
    try std.testing.expectError(vm_mod.InterpretError.OutOfGas, run_err);
    if (run_err == vm_mod.InterpretError.OutOfGas) {
        child.state = .paused;
    }
    try std.testing.expectEqual(actor_mod.ActorState.paused, child.state);

    // 5. Bounded child completes cleanly with gas remaining
    var bounded_chunk = @import("../macros/chunk.zig").Chunk.init();
    defer bounded_chunk.deinit(env.allocator);
    try bounded_chunk.writeChunk(env.allocator, @intFromEnum(@import("../macros/chunk.zig").OpCode.return_op));

    var bounded_vm = try VM.init(env.allocator, &bounded_chunk);
    defer bounded_vm.deinit();
    bounded_vm.setGasLimit(100);
    try bounded_vm.run(0);
    try std.testing.expect(bounded_vm.getGasRemaining().? > 0);
}

test "bundle pack requires rebuild_control authority" {
    var env = try TestEnv.init(std.testing.allocator);
    defer env.deinit();
    try env.activate();

    var pair = [_]Value{ Value{ .string = "probe.mx" }, Value{ .string = "sys_serial_write(\"hi\");" } };
    var entries = [_]Value{Value{ .array = pair[0..] }};
    var pack_args = [_]Value{Value{ .array = entries[0..] }};

    // The genesis supervisor holds actor_control only: packing must be denied.
    try std.testing.expectError(error.PermissionDenied, nativeSysBundlePack(&env.vm, pack_args[0..]));

    _ = try env.supervisor.cspace.insert(cap_mod.Capability{
        .cap_type = .rebuild_control,
        .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE | cap_mod.Rights.EXECUTE,
        .object_id = 0x0A,
        .data_addr = 0,
        .data_size = 0,
    });

    const packed_val = try nativeSysBundlePack(&env.vm, pack_args[0..]);
    try std.testing.expect(packed_val == .string);
    defer env.allocator.free(packed_val.string);

    var reader = try bundle_mod.BundleReader.init(packed_val.string);
    try std.testing.expectEqual(@as(u32, 1), reader.header.entry_count);
    try std.testing.expectEqualStrings("sys_serial_write(\"hi\");", reader.findData("probe.mx").?);

    var no_entries: [0]Value = .{};
    var no_entries_args = [_]Value{Value{ .array = no_entries[0..] }};
    const empty_packed = try nativeSysBundlePack(&env.vm, no_entries_args[0..]);
    try std.testing.expectEqualStrings("", empty_packed.string);
}
