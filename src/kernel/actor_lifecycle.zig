// MicrOS (µOS) Actor Lifecycle & Execution Runtime
// Handles compilation, fiber attachment, initial capability delegation,
// and execution state transitions for actors.

const std = @import("std");
const actor_mod = @import("actor.zig");
const cap_mod = @import("cap/capability.zig");
const chunk_mod = @import("../macros/chunk.zig");
const compiler_mod = @import("../macros/compiler.zig");
const parser_mod = @import("../macros/parser.zig");
const vm_mod = @import("../macros/vm.zig");
const gc_mod = @import("../macros/gc.zig");
const fiber_mod = @import("../macros/fiber.zig");
const vmm = @import("mem/vmm.zig");
const serial = @import("serial.zig");
const fb_mod = @import("fb.zig");
const abi_mod = @import("abi.zig");

pub const ActorThreadContext = struct {
    allocator: std.mem.Allocator,
    actor: *actor_mod.Actor,
    vm: *vm_mod.VM,
    owns_chunk: bool = true,
};

pub var global_sched: ?*fiber_mod.Scheduler = null;
pub var global_registry: ?*actor_mod.ActorRegistry = null;
pub var global_fb: ?*fb_mod.Framebuffer = null;
pub var bundle_read_fn: ?*const fn (name: []const u8) ?[]const u8 = null;

pub fn init(
    sched: *fiber_mod.Scheduler,
    registry: *actor_mod.ActorRegistry,
    fb: ?*fb_mod.Framebuffer,
    read_fn: ?*const fn (name: []const u8) ?[]const u8,
) void {
    global_sched = sched;
    global_registry = registry;
    global_fb = fb;
    bundle_read_fn = read_fn;
}

pub fn actorYieldCheck(vm: *vm_mod.VM) anyerror!void {
    if (vm.user_data) |ud| {
        const actor: *actor_mod.Actor = @ptrCast(@alignCast(ud));
        if (actor.state == .terminated) return error.ActorTerminated;
    }
}

fn cleanupActorThread(act_ctx: *ActorThreadContext, vm: *vm_mod.VM, actor: *actor_mod.Actor) void {
    if (actor.state == .paused) return;
    if (vm.gc_heap) |h| {
        h.deinit();
        act_ctx.allocator.destroy(h);
        vm.gc_heap = null;
    }
    vm.deinit();
    act_ctx.allocator.destroy(vm);
    if (act_ctx.owns_chunk) {
        vm.chunk.deinit(act_ctx.allocator);
        act_ctx.allocator.destroy(vm.chunk);
    }
    const actor_id = actor.id;
    const alloc = act_ctx.allocator;
    act_ctx.allocator.destroy(act_ctx);
    if (vmm.kernel_pml4_phys != 0 and vmm.readCr3() != vmm.kernel_pml4_phys) {
        vmm.switchAddressSpace(vmm.kernel_pml4_phys);
    }
    if (global_registry) |reg| {
        reg.terminate(alloc, actor_id) catch {
            actor.release();
        };
    } else {
        actor.release();
    }
}

fn logActorCrash(actor: *actor_mod.Actor, vm: *vm_mod.VM, err: anyerror) void {
    if (actor.state != .terminated) actor.state = .faulted;
    serial.writeString("[kernel] Spawned Actor crashed: ");
    serial.writeString(@errorName(err));
    if (err == vm_mod.InterpretError.RuntimeError and vm.last_missing_symbol != null) {
        serial.writeString(" [Undefined: '");
        serial.writeString(vm.last_missing_symbol.?);
        serial.writeString("']");
    }
    serial.writeString(" frames=");
    serial.writeDec(vm.frame_count);
    serial.writeString(" ip=");
    serial.writeHex(vm.ip);
    serial.writeString(" sp=");
    serial.writeHex(vm.sp);
    serial.writeString("\n");
}

pub fn actorThread(ctx: ?*anyopaque) void {
    const act_ctx = @as(*ActorThreadContext, @ptrCast(@alignCast(ctx.?)));
    const actor = act_ctx.actor;
    var vm = act_ctx.vm;
    defer cleanupActorThread(act_ctx, vm, actor);
    if (actor.state == .terminated or actor.state == .faulted) return;
    actor.transitionTo(.running) catch return;
    vm.run(0) catch |err| {
        if (err == vm_mod.InterpretError.OutOfGas) {
            actor.state = .paused;
            serial.writeString("[kernel] Actor parked on OutOfGas\n");
            return;
        }
        logActorCrash(actor, vm, err);
        return;
    };
    actor.state = .terminated;
}

pub fn compileActorScript(allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!*chunk_mod.Chunk {
    const chunk = try allocator.create(chunk_mod.Chunk);
    chunk.* = chunk_mod.Chunk.init();
    errdefer {
        chunk.deinit(allocator);
        allocator.destroy(chunk);
    }
    var compiler = compiler_mod.Compiler.init(allocator, chunk);
    var p = parser_mod.Parser.init(allocator, source);
    while (p.current_token.token_type != .eof) {
        const stmt = p.parseStatement() catch |err| {
            serial.writeString("[kernel] Actor compilation failed for '");
            serial.writeString(name);
            serial.writeString("': ");
            serial.writeString(@errorName(err));
            serial.writeString("\n");
            return err;
        };
        defer stmt.deinit(allocator);
        try compiler.compile(stmt);
    }
    try chunk.writeChunk(allocator, @intFromEnum(chunk_mod.OpCode.return_op));
    return chunk;
}

pub fn logActorSpawn(id: u32, name: []const u8) void {
    serial.writeString("  [  \x1b[32mok\x1b[0m  ] spawn: Actor ");
    serial.writeDec(id);
    serial.writeString(" (");
    serial.writeString(name);
    serial.writeString("\x1b[97m) online\x1b[0m\n");
}

pub fn runVmCollect(ctx: *anyopaque) void {
    const vm_inst: *vm_mod.VM = @ptrCast(@alignCast(ctx));
    if (vm_inst.gc_heap) |h| vm_inst.collect(h);
}

pub fn attachActorVm(allocator: std.mem.Allocator, child: *actor_mod.Actor, chunk: *chunk_mod.Chunk) !void {
    const sched = global_sched orelse return error.SchedulerNotReady;
    const child_vm = try allocator.create(vm_mod.VM);
    try child_vm.initInPlace(allocator, chunk);
    errdefer {
        child_vm.deinit();
        allocator.destroy(child_vm);
    }
    const heap = try allocator.create(gc_mod.Heap);
    heap.* = gc_mod.Heap.init(allocator);
    heap.gc_callback = runVmCollect;
    heap.gc_ctx = child_vm;
    child_vm.gc_heap = heap;
    errdefer {
        heap.deinit();
        allocator.destroy(heap);
    }

    try abi_mod.registerSyscalls(child_vm);
    if (child.gas_budget > 0) {
        child_vm.setGasLimit(child.gas_budget);
    }
    child_vm.user_data = child;
    child_vm.yield_hook = actorYieldCheck;
    const act_ctx = try allocator.create(ActorThreadContext);
    act_ctx.* = .{
        .allocator = allocator,
        .actor = child,
        .vm = child_vm,
        .owns_chunk = true,
    };
    errdefer allocator.destroy(act_ctx);

    _ = child.ref_count.fetchAdd(1, .acquire);
    errdefer _ = child.ref_count.fetchSub(1, .release);

    const fib = try sched.spawn(actorThread, act_ctx);
    child.fiber_ctx = @ptrCast(fib);
}

pub fn isVerifiedSystemScript(name: []const u8, source: []const u8) bool {
    const base = if (std.mem.endsWith(u8, name, ".mx")) name[0 .. name.len - 3] else name;
    const sys_names = [_][]const u8{ "ush", "harness", "installer", "rebuild", "httpd", "web", "vedit", "desk" };
    var is_sys = false;
    for (sys_names) |sname| {
        if (std.mem.eql(u8, base, sname)) {
            is_sys = true;
            break;
        }
    }
    if (!is_sys) return false;
    const read_fn = bundle_read_fn orelse return false;
    var mx_buf: [32]u8 = undefined;
    const bsrc = read_fn(name) orelse blk: {
        if (base.len + 3 > mx_buf.len) break :blk null;
        @memcpy(mx_buf[0..base.len], base);
        @memcpy(mx_buf[base.len .. base.len + 3], ".mx");
        break :blk read_fn(mx_buf[0 .. base.len + 3]);
    } orelse return false;
    return std.mem.eql(u8, bsrc, source);
}

pub fn delegateInitialCaps(child: *actor_mod.Actor, name: []const u8, source: []const u8) !void {
    if (child.supervisor_id != actor_mod.GENESIS_ACTOR_ID) return;
    if (global_fb) |fb| {
        _ = try child.insertCap(.{
            .cap_type = .framebuffer,
            .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE,
            .object_id = 1,
            .data_addr = @intFromPtr(fb),
            .data_size = @sizeOf(fb_mod.Framebuffer),
        });
    }
    const is_ush = std.mem.eql(u8, name, "ush") or std.mem.eql(u8, name, "ush.mx");
    if (!is_ush and !isVerifiedSystemScript(name, source)) {
        // G3: Attenuated set for dynamic / AI-spawned actors:
        // Window/FB granted above (READ | WRITE).
        // CAS storage granted with restricted READ-only rights; no network, no actor control.
        _ = try child.insertCap(.{
            .cap_type = .storage_device,
            .rights = cap_mod.Rights.READ,
            .object_id = 5,
            .data_addr = 0,
            .data_size = 0,
        });
        return;
    }
    _ = try child.insertCap(.{ .cap_type = .actor_control, .rights = cap_mod.Rights.ALL, .object_id = 6, .data_addr = 0, .data_size = 0 });
    // S3-F5: Explicit Genesis grant of storage_device (READ | WRITE) to ush at spawn
    _ = try child.insertCap(.{ .cap_type = .storage_device, .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE, .object_id = 5, .data_addr = 0, .data_size = 0 });
    _ = try child.insertCap(.{ .cap_type = .network_device, .rights = cap_mod.Rights.ALL, .object_id = 4, .data_addr = 0, .data_size = 0 });
}

pub fn spawnActorFromCode(allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 {
    const reg = global_registry orelse return error.NoRegistry;
    const persistent_source = try allocator.dupe(u8, source);
    var source_owned_by_actor = false;
    errdefer if (!source_owned_by_actor) allocator.free(persistent_source);

    const chunk = try compileActorScript(allocator, name, persistent_source);
    errdefer {
        chunk.deinit(allocator);
        allocator.destroy(chunk);
    }

    const pml4_phys = vmm.createActorAddressSpace() orelse return error.OutOfMemory;
    var pml4_owned_by_actor = false;
    errdefer if (!pml4_owned_by_actor and pml4_phys != 0) {
        vmm.destroyActorAddressSpace(pml4_phys);
    };

    const child = try reg.spawn(allocator, actor_mod.GENESIS_ACTOR_ID, name, 16, pml4_phys);
    pml4_owned_by_actor = true;
    child.source = persistent_source;
    source_owned_by_actor = true;
    errdefer {
        reg.terminate(allocator, child.id) catch {};
    }

    try delegateInitialCaps(child, name, persistent_source);
    try attachActorVm(allocator, child, chunk);

    logActorSpawn(child.id, name);
    return child.id;
}

test "delegateInitialCaps attenuates capabilities for dynamic actors" {
    const allocator = std.testing.allocator;
    var fake_buf = [_]u8{0} ** 4096;
    var fake_fb = fb_mod.Framebuffer{
        .base = fake_buf[0..].ptr,
        .size_bytes = fake_buf.len,
        .width = 32,
        .height = 32,
        .stride = 32,
        .format = .bgr_888,
    };
    global_fb = &fake_fb;
    defer global_fb = null;

    const child = try actor_mod.Actor.init(allocator, 5, "harness_exec", 16, 0);
    defer child.deinit(allocator);
    child.supervisor_id = actor_mod.GENESIS_ACTOR_ID;

    try delegateInitialCaps(child, "harness_exec", "sys_window_draw_rect(1,0,0,10,10,0);");

    // Framebuffer has READ | WRITE
    try std.testing.expect(child.cspace.lookup(.framebuffer) != null);
    try std.testing.expect(child.cspace.lookupWithRights(.framebuffer, cap_mod.Rights.READ | cap_mod.Rights.WRITE) != null);

    // Storage is attenuated to READ-only
    try std.testing.expect(child.cspace.lookup(.storage_device) != null);
    try std.testing.expect(child.cspace.lookupWithRights(.storage_device, cap_mod.Rights.READ) != null);
    try std.testing.expect(child.cspace.lookupWithRights(.storage_device, cap_mod.Rights.WRITE) == null);

    // Network and Actor Control are strictly denied
    try std.testing.expect(child.cspace.lookup(.actor_control) == null);
    try std.testing.expect(child.cspace.lookup(.network_device) == null);
}

test "live-synth: G4 budget containment" {
    const allocator = std.testing.allocator;
    const actor = try actor_mod.Actor.init(allocator, 10, "loop_synth", 16, 0);
    defer actor.deinit(allocator);

    const source = "while (true) { x = 1; }";
    const chunk = try compileActorScript(allocator, "loop_synth", source);
    defer {
        chunk.deinit(allocator);
        allocator.destroy(chunk);
    }

    actor.gas_budget = 500;

    var vm = try vm_mod.VM.init(allocator, chunk);
    defer vm.deinit();
    vm.setGasLimit(actor.gas_budget);

    const run_res = vm.run(0);
    try std.testing.expectError(vm_mod.InterpretError.OutOfGas, run_res);
}
