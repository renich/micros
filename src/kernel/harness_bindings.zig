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
const ps2_mod = @import("drivers/ps2_kbd.zig");
const fiber_mod = @import("../macros/fiber.zig");

pub const HarnessContext = struct {
    registry: *ActorRegistry,
    supervisor: *Actor,
    framebuffer: ?*Framebuffer = null,
    ipc_ring: ?*RingBuffer = null,
    supervisor_ctrl: ?*supervisor_mod.Supervisor = null,
    kbd_ctrl: ?*ps2_mod.Ps2Keyboard = null,
    ai_inference_fn: ?*const fn (prompt: []const u8, out_text: []u8) usize = null,
    spawn_code_fn: ?*const fn (allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 = null,
    cas_put_fn: ?*const fn (data: []const u8, out_hex: *[64]u8) anyerror!void = null,
    cas_get_fn: ?*const fn (hex_hash: []const u8, out_buf: []u8) anyerror!usize = null,
    persist_actor_fn: ?*const fn (actor_id: u32, out_hex: *[64]u8) anyerror!void = null,
    spawn_cas_fn: ?*const fn (allocator: std.mem.Allocator, hex_hash: []const u8) anyerror!u32 = null,
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

var ai_prompt_resp_buf: [4096]u8 = undefined;

fn nativeSysSerialRead(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    if (serial.readChar()) |c| {
        return Value{ .integer = @as(i64, c) };
    }
    return Value{ .integer = -1 };
}

fn nativeSysKbdRead(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    const ctx = active_ctx orelse return Value{ .integer = -1 };
    const kbd = ctx.kbd_ctrl orelse return Value{ .integer = -1 };
    if (!ps2_mod.hasData()) return Value{ .integer = -1 };
    const scan = ps2_mod.readScancode();
    if (scan == 0 or scan == 0xFF) return Value{ .integer = -1 };
    const ev = kbd.processScancode(scan) orelse return Value{ .integer = -1 };
    if (ev.action == .press and ev.ascii != 0) {
        return Value{ .integer = @as(i64, ev.ascii) };
    }
    return Value{ .integer = -1 };
}

fn nativeSysAiPrompt(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const infer_fn = ctx.ai_inference_fn orelse return error.NoAiProvider;
    const prompt = args[0].string;
    const len = infer_fn(prompt, &ai_prompt_resp_buf);
    if (len == 0) return Value{ .string = "" };
    return Value{ .string = ai_prompt_resp_buf[0..len] };
}

fn nativeSysActorSpawnCode(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const spawn_fn = ctx.spawn_code_fn orelse return error.NoSpawnHandler;
    const name = args[0].string;
    const src = args[1].string;
    const child_id = try spawn_fn(vm.allocator, name, src);
    return Value{ .integer = @as(i64, child_id) };
}

fn nativeSysYield(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    fiber_mod.yield();
    return Value{ .integer = 0 };
}

fn nativeSysActorName(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const reg = ctx.registry;
    const id: u32 = @intCast(args[0].integer);
    if (reg.get(id)) |actor| {
        return Value{ .string = actor.getName() };
    }
    return Value{ .string = "" };
}

fn nativeSysActorState(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const reg = ctx.registry;
    const id: u32 = @intCast(args[0].integer);
    if (reg.get(id)) |actor| {
        return Value{ .integer = @as(i64, @intFromEnum(actor.state)) };
    }
    return Value{ .integer = -1 };
}

var cas_resp_buf: [4096]u8 = undefined;
var cas_hex_buf: [64]u8 = undefined;

fn nativeSysCasPut(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const put_fn = ctx.cas_put_fn orelse return error.NoStorageHandler;
    put_fn(args[0].string, &cas_hex_buf) catch return Value{ .string = "" };
    return Value{ .string = &cas_hex_buf };
}

fn nativeSysCasGet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const get_fn = ctx.cas_get_fn orelse return error.NoStorageHandler;
    const len = get_fn(args[0].string, &cas_resp_buf) catch return Value{ .string = "" };
    return Value{ .string = cas_resp_buf[0..len] };
}

fn nativeSysActorPersist(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const persist_fn = ctx.persist_actor_fn orelse return error.NoStorageHandler;
    const id: u32 = @intCast(args[0].integer);
    persist_fn(id, &cas_hex_buf) catch return Value{ .string = "" };
    return Value{ .string = &cas_hex_buf };
}

fn nativeSysActorSpawnCas(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const spawn_cas_fn = ctx.spawn_cas_fn orelse return error.NoStorageHandler;
    const child_id = spawn_cas_fn(vm.allocator, args[0].string) catch return Value{ .integer = -1 };
    return Value{ .integer = @as(i64, child_id) };
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
    try vm.globals.put("sys_serial_read", Value{ .native = nativeSysSerialRead });
    try vm.globals.put("sys_kbd_read", Value{ .native = nativeSysKbdRead });
    try vm.globals.put("sys_ai_prompt", Value{ .native = nativeSysAiPrompt });
    try vm.globals.put("sys_actor_spawn_code", Value{ .native = nativeSysActorSpawnCode });
    try vm.globals.put("sys_yield", Value{ .native = nativeSysYield });
    try vm.globals.put("sys_actor_name", Value{ .native = nativeSysActorName });
    try vm.globals.put("sys_actor_state", Value{ .native = nativeSysActorState });
    try vm.globals.put("sys_cas_put", Value{ .native = nativeSysCasPut });
    try vm.globals.put("sys_cas_get", Value{ .native = nativeSysCasGet });
    try vm.globals.put("sys_actor_persist", Value{ .native = nativeSysActorPersist });
    try vm.globals.put("sys_actor_spawn_cas", Value{ .native = nativeSysActorSpawnCas });
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

    // Test new Milestone 13 bindings
    ctx.ai_inference_fn = testMockInfer;
    ctx.spawn_code_fn = testMockSpawn;

    const sread = try nativeSysSerialRead(&vm, &empty_args);
    try std.testing.expect(sread.integer >= -1);

    var prompt_args = [_]Value{Value{ .string = "test prompt" }};
    const prompt_val = try nativeSysAiPrompt(&vm, &prompt_args);
    try std.testing.expectEqualStrings("Mock AI response", prompt_val.string);

    var sc_args = [_]Value{ Value{ .string = "child_worker" }, Value{ .string = "fn run() {}" } };
    const sc_val = try nativeSysActorSpawnCode(&vm, &sc_args);
    try std.testing.expectEqual(@as(i64, 7), sc_val.integer);

    const yld = try nativeSysYield(&vm, &empty_args);
    try std.testing.expectEqual(@as(i64, 0), yld.integer);

    var an_args = [_]Value{Value{ .integer = 999 }};
    const an_val = try nativeSysActorName(&vm, &an_args);
    try std.testing.expectEqualStrings("", an_val.string);

    const as_val = try nativeSysActorState(&vm, &an_args);
    try std.testing.expectEqual(@as(i64, -1), as_val.integer);
}

fn testMockInfer(prompt: []const u8, out_text: []u8) usize {
    _ = prompt;
    const resp = "Mock AI response";
    @memcpy(out_text[0..resp.len], resp);
    return resp.len;
}

fn testMockSpawn(allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 {
    _ = allocator;
    _ = name;
    _ = source;
    return 7;
}

fn testMockCasPut(data: []const u8, out_hex: *[64]u8) anyerror!void {
    _ = data;
    @memcpy(out_hex, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
}

fn testMockCasGet(hex_hash: []const u8, out_buf: []u8) anyerror!usize {
    _ = hex_hash;
    const content = "persisted actor content";
    @memcpy(out_buf[0..content.len], content);
    return content.len;
}

fn testMockPersist(actor_id: u32, out_hex: *[64]u8) anyerror!void {
    _ = actor_id;
    @memcpy(out_hex, "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210");
}

fn testMockSpawnCas(allocator: std.mem.Allocator, hex_hash: []const u8) anyerror!u32 {
    _ = allocator;
    _ = hex_hash;
    return 42;
}

test "Harness storage native bindings" {
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
        .cas_put_fn = testMockCasPut,
        .cas_get_fn = testMockCasGet,
        .persist_actor_fn = testMockPersist,
        .spawn_cas_fn = testMockSpawnCas,
    };
    setContext(&ctx);
    defer clearContext();

    try registerBindings(&vm);

    var put_args = [_]Value{Value{ .string = "sample code" }};
    const put_val = try nativeSysCasPut(&vm, &put_args);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", put_val.string);

    var get_args = [_]Value{Value{ .string = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }};
    const get_val = try nativeSysCasGet(&vm, &get_args);
    try std.testing.expectEqualStrings("persisted actor content", get_val.string);

    var persist_args = [_]Value{Value{ .integer = 1 }};
    const persist_val = try nativeSysActorPersist(&vm, &persist_args);
    try std.testing.expectEqualStrings("fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210", persist_val.string);

    var scas_args = [_]Value{Value{ .string = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }};
    const scas_val = try nativeSysActorSpawnCas(&vm, &scas_args);
    try std.testing.expectEqual(@as(i64, 42), scas_val.integer);
}
