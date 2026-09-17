// MicrOS (µOS) Sovereign Harness Native VM Bindings
// Exposes microkernel capabilities, actor lifecycle, framebuffer, and IPC to Macros.
// Eradicates legacy POSIX syscall shims in favor of direct capability-mediated operations.

const std = @import("std");
const eval = @import("../macros/eval.zig");
const Value = eval.Value;
const vm_mod = @import("../macros/vm.zig");
const VM = vm_mod.VM;
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

pub const HarnessContext = struct {
    registry: *ActorRegistry,
    supervisor: *Actor,
    framebuffer: ?*Framebuffer = null,
    ipc_ring: ?*RingBuffer = null,
    supervisor_ctrl: ?*supervisor_mod.Supervisor = null,
};

var active_ctx: ?*HarnessContext = null;

pub fn setContext(ctx: *HarnessContext) void {
    active_ctx = ctx;
}

pub fn clearContext() void {
    active_ctx = null;
}

fn nativeSysActorCount(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    const ctx = active_ctx orelse return Value{ .integer = 0 };
    return Value{ .integer = @intCast(ctx.registry.active_count) };
}

fn nativeSysActorSpawn(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const child = try ctx.registry.spawn(
        vm.allocator,
        ctx.supervisor.id,
        args[0].string,
        32,
        0,
    );
    return Value{ .integer = @intCast(child.id) };
}

fn nativeSysActorTerminate(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const id: u32 = @intCast(args[0].integer);
    try ctx.registry.terminate(vm.allocator, id);
    return Value{ .boolean = true };
}

fn nativeSysFbClear(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const ctx = active_ctx orelse return Value{ .nil = {} };
    if (ctx.framebuffer) |fb| {
        fb.clear(@intCast(args[0].integer));
    }
    return Value{ .nil = {} };
}

fn nativeSysFbDrawString(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 5 or args[0] != .integer or args[1] != .integer or
        args[2] != .string or args[3] != .integer or args[4] != .integer)
    {
        return error.InvalidArgs;
    }
    const ctx = active_ctx orelse return Value{ .nil = {} };
    if (ctx.framebuffer) |fb| {
        fb.drawString(
            @intCast(args[0].integer),
            @intCast(args[1].integer),
            args[2].string,
            @intCast(args[3].integer),
            @intCast(args[4].integer),
        );
    }
    return Value{ .nil = {} };
}

fn nativeSysFbDrawRect(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 5 or args[0] != .integer or args[1] != .integer or
        args[2] != .integer or args[3] != .integer or args[4] != .integer)
    {
        return error.InvalidArgs;
    }
    const ctx = active_ctx orelse return Value{ .nil = {} };
    if (ctx.framebuffer) |fb| {
        fb.drawRect(
            @intCast(args[0].integer),
            @intCast(args[1].integer),
            @intCast(args[2].integer),
            @intCast(args[3].integer),
            @intCast(args[4].integer),
        );
    }
    return Value{ .nil = {} };
}

fn nativeSysIpcRecv(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    const ctx = active_ctx orelse return Value{ .integer = -1 };
    const ring = ctx.ipc_ring orelse return Value{ .integer = -1 };
    const frame = ring.pop() orelse return Value{ .integer = -1 };

    if (events_mod.fromMessageFrame(&frame)) |event| {
        if (event.action == .press) {
            return Value{ .integer = if (event.ascii != 0) event.ascii else event.keycode };
        }
    }
    return Value{ .integer = 0 };
}

fn nativeSysSerialWrite(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const str = args[0].string;
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        if (str[i] == '\\' and i + 1 < str.len and str[i + 1] == 'n') {
            serial.writeChar('\n');
            i += 1;
        } else {
            serial.writeChar(str[i]);
        }
    }
    return Value{ .nil = {} };
}

fn nativeSysFaultCount(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    const ctx = active_ctx orelse return Value{ .integer = 0 };
    if (ctx.supervisor_ctrl) |sup| {
        return Value{ .integer = @intCast(sup.total_faults) };
    }
    return Value{ .integer = 0 };
}

pub fn registerBindings(vm: *VM) !void {
    try vm.globals.put("sys_actor_count", Value{ .native = nativeSysActorCount });
    try vm.globals.put("sys_actor_spawn", Value{ .native = nativeSysActorSpawn });
    try vm.globals.put("sys_actor_terminate", Value{ .native = nativeSysActorTerminate });
    try vm.globals.put("sys_fb_clear", Value{ .native = nativeSysFbClear });
    try vm.globals.put("sys_fb_draw_string", Value{ .native = nativeSysFbDrawString });
    try vm.globals.put("sys_fb_draw_rect", Value{ .native = nativeSysFbDrawRect });
    try vm.globals.put("sys_ipc_recv", Value{ .native = nativeSysIpcRecv });
    try vm.globals.put("sys_serial_write", Value{ .native = nativeSysSerialWrite });
    try vm.globals.put("sys_fault_count", Value{ .native = nativeSysFaultCount });
}

test "Harness native bindings registration and execution" {
    const allocator = std.testing.allocator;
    var chunk = @import("../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    var registry = ActorRegistry.init();
    var supervisor = try Actor.init(allocator, 0, "genesis", 16, 0);
    defer supervisor.deinit(allocator);

    var ctx = HarnessContext{
        .registry = &registry,
        .supervisor = supervisor,
        .framebuffer = null,
        .ipc_ring = null,
        .supervisor_ctrl = null,
    };
    setContext(&ctx);
    defer clearContext();

    try registerBindings(&vm);

    // Test sys_actor_count
    var empty_args = [_]Value{};
    const count_val = try nativeSysActorCount(&vm, &empty_args);
    try std.testing.expectEqual(@as(i64, 0), count_val.integer);

    // Test sys_actor_spawn
    var spawn_args = [_]Value{Value{ .string = "child_1" }};
    const spawn_val = try nativeSysActorSpawn(&vm, &spawn_args);
    try std.testing.expectEqual(@as(i64, 0), spawn_val.integer);
    try std.testing.expectEqual(@as(usize, 1), registry.active_count);

    // Verify count updated
    const count2 = try nativeSysActorCount(&vm, &empty_args);
    try std.testing.expectEqual(@as(i64, 1), count2.integer);

    // Test sys_actor_terminate
    var term_args = [_]Value{Value{ .integer = 0 }};
    const term_val = try nativeSysActorTerminate(&vm, &term_args);
    try std.testing.expect(term_val.boolean);
    try std.testing.expectEqual(@as(usize, 0), registry.active_count);
}
