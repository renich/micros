// MicrOS (µOS) Native System ABI Bindings
// Exposes microkernel capabilities, actor lifecycle, storage, and IPC to Macros.
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
const ai_mod = @import("ai.zig");
const compositor_mod = @import("compositor.zig");
const WindowManager = compositor_mod.WindowManager;
const WindowMode = compositor_mod.WindowMode;
const Canvas = compositor_mod.Canvas;
const PointerState = compositor_mod.PointerState;
pub const storage_abi = @import("storage/storage_abi.zig");
pub const registerBlockDevice = storage_abi.registerBlockDevice;
pub const setRebuildEngine = storage_abi.setRebuildEngine;

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
    ai_inference_fn: ?*const fn (prompt: []const u8, out_text: []u8) usize = null,
    spawn_code_fn: ?*const fn (allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 = null,
    cas_put_fn: ?*const fn (data: []const u8, out_hex: *[64]u8) anyerror!void = null,
    cas_get_fn: ?*const fn (hex_hash: []const u8, out_buf: []u8) anyerror!usize = null,
    persist_actor_fn: ?*const fn (actor_id: u32, out_hex: *[64]u8) anyerror!void = null,
    spawn_cas_fn: ?*const fn (allocator: std.mem.Allocator, hex_hash: []const u8) anyerror!u32 = null,
    grant_cap_fn: ?*const fn (target_actor: u32, source_slot: u32, rights_mask: u16) anyerror!bool = null,
    draw_canvas_fn: ?*const fn (x: u32, y: u32, w: u32, h: u32, color: u32) void = null,
    telemetry_fn: ?*const fn () ai_mod.tools.TelemetrySnapshot = null,
    bundle_read_fn: ?*const fn (name: []const u8) ?[]const u8 = null,
};

pub const HarnessContext = AbiContext;

var active_ctx: ?*AbiContext = null;

pub fn setContext(ctx: *AbiContext) void {
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

fn nativeSysWindowCreate(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 4 or args[0] != .string or args[1] != .integer or
        args[2] != .integer or args[3] != .integer)
    {
        return error.InvalidArgs;
    }
    const ctx = active_ctx orelse return Value{ .integer = -1 };
    const wm = ctx.wm orelse return Value{ .integer = -1 };

    const w: u32 = @intCast(@max(0, args[1].integer));
    const h: u32 = @intCast(@max(0, args[2].integer));
    const mode: WindowMode = if (args[3].integer == 1) .floating else .tiled;

    const win = wm.createWindow(ctx.supervisor.id, args[0].string, w, h, mode) catch {
        return Value{ .integer = -1 };
    };
    return Value{ .integer = @intCast(win.id) };
}

fn nativeSysWindowClose(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const ctx = active_ctx orelse return Value{ .boolean = false };
    const wm = ctx.wm orelse return Value{ .boolean = false };

    wm.closeWindow(@intCast(args[0].integer));
    return Value{ .boolean = true };
}

fn nativeSysWindowFocus(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const ctx = active_ctx orelse return Value{ .boolean = false };
    const wm = ctx.wm orelse return Value{ .boolean = false };

    wm.focusWindow(@intCast(args[0].integer));
    return Value{ .boolean = true };
}

fn nativeSysWindowDrawRect(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 6 or args[0] != .integer or args[1] != .integer or
        args[2] != .integer or args[3] != .integer or args[4] != .integer or
        args[5] != .integer)
    {
        return error.InvalidArgs;
    }
    const ctx = active_ctx orelse return Value{ .nil = {} };
    const wm = ctx.wm orelse return Value{ .nil = {} };

    const win_id: u32 = @intCast(args[0].integer);
    const idx = wm.findWindowIndex(win_id) orelse return Value{ .nil = {} };
    const win = wm.windows[idx] orelse return Value{ .nil = {} };

    const x: u32 = @intCast(@max(0, args[1].integer));
    const y: u32 = @intCast(@max(0, args[2].integer));
    const w: u32 = @intCast(@max(0, args[3].integer));
    const h: u32 = @intCast(@max(0, args[4].integer));
    const color: u32 = @intCast(args[5].integer);

    win.surface.drawRect(x, y, w, h, color);
    return Value{ .nil = {} };
}

fn nativeSysWindowDrawString(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 6 or args[0] != .integer or args[1] != .integer or
        args[2] != .integer or args[3] != .string or args[4] != .integer or
        args[5] != .integer)
    {
        return error.InvalidArgs;
    }
    const ctx = active_ctx orelse return Value{ .nil = {} };
    const wm = ctx.wm orelse return Value{ .nil = {} };

    const win_id: u32 = @intCast(args[0].integer);
    const idx = wm.findWindowIndex(win_id) orelse return Value{ .nil = {} };
    const win = wm.windows[idx] orelse return Value{ .nil = {} };

    const x: u32 = @intCast(@max(0, args[1].integer));
    const y: u32 = @intCast(@max(0, args[2].integer));
    const fg: u32 = @intCast(args[4].integer);
    const bg: u32 = @intCast(args[5].integer);

    win.surface.drawString(x, y, args[3].string, fg, bg);
    return Value{ .nil = {} };
}

fn nativeSysCompositorFlush(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    const ctx = active_ctx orelse return Value{ .boolean = false };
    const wm = ctx.wm orelse return Value{ .boolean = false };
    const canvas = ctx.canvas orelse return Value{ .boolean = false };

    wm.compose(canvas);
    if (ctx.framebuffer) |fb| {
        canvas.flush(fb);
    }
    return Value{ .boolean = true };
}

fn nativeSysPointerRead(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    const ctx = active_ctx orelse return Value{ .integer = -1 };
    const ptr = ctx.pointer orelse return Value{ .integer = -1 };
    const px: i64 = @as(u16, @bitCast(@as(i16, @truncate(ptr.x))));
    const py: i64 = @as(u16, @bitCast(@as(i16, @truncate(ptr.y))));
    const packed_coords = px | (py << 16);
    return Value{ .integer = packed_coords };
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
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const infer_fn = ctx.ai_inference_fn orelse return error.NoAiHandler;
    const prompt = args[0].string;
    const len = infer_fn(prompt, &ai_prompt_resp_buf);
    if (len == 0) return Value{ .string = "" };
    const duped = try vm.allocator.dupe(u8, ai_prompt_resp_buf[0..len]);
    return Value{ .string = duped };
}

var ai_extract_buf: [8192]u8 = undefined;

fn nativeSysAiExtractCode(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const resp = args[0].string;
    if (ai_mod.client.AiClient.extractCodeBlock(resp, &ai_extract_buf)) |len| {
        const duped = try vm.allocator.dupe(u8, ai_extract_buf[0..len]);
        return Value{ .string = duped };
    }
    return Value{ .string = "" };
}

var ai_tool_scratch: [8192]u8 = undefined;
var ai_tool_res_buf: [1024]u8 = undefined;
var ai_tool_storage_buf: [1024]u8 = undefined;

fn nativeSysAiToolCall(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const resp = args[0].string;
    const ctx = active_ctx orelse return error.NoContext;

    const call = ai_mod.tool_parser.extractToolCall(resp, &ai_tool_scratch) orelse {
        return Value{ .string = "" };
    };

    const disp_ctx = ai_mod.dispatcher.DispatcherContext{
        .spawn_fn = ctx.spawn_code_fn,
        .grant_fn = ctx.grant_cap_fn,
        .cas_put_fn = ctx.cas_put_fn,
        .cas_get_fn = ctx.cas_get_fn,
        .draw_canvas_fn = ctx.draw_canvas_fn,
        .telemetry_fn = ctx.telemetry_fn,
    };
    const disp = ai_mod.dispatcher.ToolDispatcher.init(
        ctx.supervisor.cspace,
        vm.allocator,
        disp_ctx,
        &ai_tool_storage_buf,
    );

    const result = disp.dispatch(call);
    const len = try ai_mod.tool_parser.formatResultJson(result, &ai_tool_res_buf);
    const duped = try vm.allocator.dupe(u8, ai_tool_res_buf[0..len]);
    return Value{ .string = duped };
}

fn nativeSysActorSpawnCode(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const spawn_fn = ctx.spawn_code_fn orelse return error.NoSpawnHandler;
    const name = args[0].string;
    const src = args[1].string;
    const child_id = spawn_fn(vm.allocator, name, src) catch return Value{ .integer = -1 };
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

fn nativeSysCasPut(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const put_fn = ctx.cas_put_fn orelse return error.NoStorageHandler;
    var hex_buf: [64]u8 = undefined;
    put_fn(args[0].string, &hex_buf) catch return Value{ .string = "" };
    const duped = try vm.allocator.dupe(u8, &hex_buf);
    return Value{ .string = duped };
}

var cas_resp_buf: [4096]u8 = undefined;

fn nativeSysCasGet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const get_fn = ctx.cas_get_fn orelse return error.NoStorageHandler;
    const len = get_fn(args[0].string, &cas_resp_buf) catch return Value{ .string = "" };
    const duped = try vm.allocator.dupe(u8, cas_resp_buf[0..len]);
    return Value{ .string = duped };
}

fn nativeSysActorPersist(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const persist_fn = ctx.persist_actor_fn orelse return error.NoStorageHandler;
    const id: u32 = @intCast(args[0].integer);
    var hex_buf: [64]u8 = undefined;
    persist_fn(id, &hex_buf) catch return Value{ .string = "" };
    const duped = try vm.allocator.dupe(u8, &hex_buf);
    return Value{ .string = duped };
}

fn nativeSysActorSpawnCas(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const spawn_cas_fn = ctx.spawn_cas_fn orelse return error.NoStorageHandler;
    const child_id = spawn_cas_fn(vm.allocator, args[0].string) catch return Value{ .integer = -1 };
    return Value{ .integer = @as(i64, child_id) };
}

fn nativeSysBundleRead(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const read_fn = ctx.bundle_read_fn orelse return Value{ .string = "" };
    if (read_fn(args[0].string)) |content| {
        const duped = try vm.allocator.dupe(u8, content);
        return Value{ .string = duped };
    }
    return Value{ .string = "" };
}

fn nativeSysActorWait(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const ctx = active_ctx orelse return error.NoContext;
    const target_id: u32 = @intCast(args[0].integer);

    while (true) {
        const actor = ctx.registry.get(target_id);
        if (actor == null or actor.?.state == .terminated or actor.?.state == .faulted) {
            break;
        }
        fiber_mod.yield();
    }
    return Value{ .boolean = true };
}

pub fn registerSyscalls(vm: *VM) !void {
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
    try vm.globals.put("sys_ai_extract_code", Value{ .native = nativeSysAiExtractCode });
    try vm.globals.put("sys_ai_tool_call", Value{ .native = nativeSysAiToolCall });
    try vm.globals.put("sys_actor_spawn_code", Value{ .native = nativeSysActorSpawnCode });
    try vm.globals.put("sys_yield", Value{ .native = nativeSysYield });
    try vm.globals.put("sys_actor_name", Value{ .native = nativeSysActorName });
    try vm.globals.put("sys_actor_state", Value{ .native = nativeSysActorState });
    try vm.globals.put("sys_cas_put", Value{ .native = nativeSysCasPut });
    try vm.globals.put("sys_cas_get", Value{ .native = nativeSysCasGet });
    try vm.globals.put("sys_actor_persist", Value{ .native = nativeSysActorPersist });
    try vm.globals.put("sys_actor_spawn_cas", Value{ .native = nativeSysActorSpawnCas });
    try vm.globals.put("sys_bundle_read", Value{ .native = nativeSysBundleRead });
    try vm.globals.put("sys_actor_wait", Value{ .native = nativeSysActorWait });
    try vm.globals.put("sys_window_create", Value{ .native = nativeSysWindowCreate });
    try vm.globals.put("sys_window_close", Value{ .native = nativeSysWindowClose });
    try vm.globals.put("sys_window_focus", Value{ .native = nativeSysWindowFocus });
    try vm.globals.put("sys_window_draw_rect", Value{ .native = nativeSysWindowDrawRect });
    try vm.globals.put("sys_window_draw_string", Value{ .native = nativeSysWindowDrawString });
    try vm.globals.put("sys_compositor_flush", Value{ .native = nativeSysCompositorFlush });
    try vm.globals.put("sys_pointer_read", Value{ .native = nativeSysPointerRead });
    try storage_abi.registerStorageSyscalls(vm);
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

fn testMockPersist(actor_id: u32, out_hex: *[64]u8) anyerror!void {
    _ = actor_id;
    @memcpy(out_hex, "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210");
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

test "ABI actor lifecycle native bindings" {
    const allocator = std.testing.allocator;
    var chunk = @import("../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    var registry = ActorRegistry.init();
    var supervisor = try Actor.init(allocator, 0, "genesis", 16, 0);
    defer supervisor.deinit(allocator);

    var ctx = AbiContext{
        .registry = &registry,
        .supervisor = supervisor,
        .bundle_read_fn = testMockBundleRead,
    };
    setContext(&ctx);
    defer clearContext();

    try registerSyscalls(&vm);

    var empty_args = [_]Value{};
    const count_val = try nativeSysActorCount(&vm, &empty_args);
    try std.testing.expectEqual(@as(i64, 0), count_val.integer);

    var spawn_args = [_]Value{Value{ .string = "child_1" }};
    const spawn_val = try nativeSysActorSpawn(&vm, &spawn_args);
    try std.testing.expectEqual(@as(i64, 0), spawn_val.integer);
    try std.testing.expectEqual(@as(usize, 1), registry.active_count);

    const count2 = try nativeSysActorCount(&vm, &empty_args);
    try std.testing.expectEqual(@as(i64, 1), count2.integer);

    var term_args = [_]Value{Value{ .integer = 0 }};
    const term_val = try nativeSysActorTerminate(&vm, &term_args);
    try std.testing.expectEqual(true, term_val.boolean);
    try std.testing.expectEqual(@as(usize, 0), registry.active_count);
}

test "ABI bundle read native binding" {
    const allocator = std.testing.allocator;
    var chunk = @import("../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    var registry = ActorRegistry.init();
    var supervisor = try Actor.init(allocator, 0, "genesis", 16, 0);
    defer supervisor.deinit(allocator);

    var ctx = AbiContext{
        .registry = &registry,
        .supervisor = supervisor,
        .bundle_read_fn = testMockBundleRead,
    };
    setContext(&ctx);
    defer clearContext();

    try registerSyscalls(&vm);

    var bread_args = [_]Value{Value{ .string = "test.mx" }};
    const bread_val = try nativeSysBundleRead(&vm, &bread_args);
    defer allocator.free(bread_val.string);
    try std.testing.expectEqualStrings("print(\"hello\");", bread_val.string);

    var bmissing_args = [_]Value{Value{ .string = "missing.mx" }};
    const bmissing_val = try nativeSysBundleRead(&vm, &bmissing_args);
    try std.testing.expectEqualStrings("", bmissing_val.string);
}

test "ABI native CAS storage and persistence bindings" {
    const allocator = std.testing.allocator;
    var chunk = @import("../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    var registry = ActorRegistry.init();
    var supervisor = try Actor.init(allocator, 0, "genesis", 16, 0);
    defer supervisor.deinit(allocator);

    var ctx = AbiContext{
        .registry = &registry,
        .supervisor = supervisor,
        .cas_put_fn = testMockCasPut,
        .cas_get_fn = testMockCasGet,
        .persist_actor_fn = testMockPersist,
        .spawn_cas_fn = testMockSpawnCas,
    };
    setContext(&ctx);
    defer clearContext();

    try registerSyscalls(&vm);

    var put_args = [_]Value{Value{ .string = "sample code" }};
    const put_val = try nativeSysCasPut(&vm, &put_args);
    defer allocator.free(put_val.string);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", put_val.string);

    var get_args = [_]Value{Value{ .string = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }};
    const get_val = try nativeSysCasGet(&vm, &get_args);
    defer allocator.free(get_val.string);
    try std.testing.expectEqualStrings("persisted actor content", get_val.string);

    var persist_args = [_]Value{Value{ .integer = 1 }};
    const persist_val = try nativeSysActorPersist(&vm, &persist_args);
    defer allocator.free(persist_val.string);
    try std.testing.expectEqualStrings("fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210", persist_val.string);

    var scas_args = [_]Value{Value{ .string = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" }};
    const scas_val = try nativeSysActorSpawnCas(&vm, &scas_args);
    try std.testing.expectEqual(@as(i64, 42), scas_val.integer);
}

test "ABI native AI extract and fault-tolerant spawn" {
    const allocator = std.testing.allocator;
    var chunk = @import("../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    var registry = ActorRegistry.init();
    var supervisor = try Actor.init(allocator, 0, "genesis", 16, 0);
    defer supervisor.deinit(allocator);

    var ctx = AbiContext{
        .registry = &registry,
        .supervisor = supervisor,
        .spawn_code_fn = testMockSpawnFail,
    };
    setContext(&ctx);
    defer clearContext();

    const md_input = "Here is the code:\n```macros\nvar z = 99;\n```\nDone.";
    var extract_args = [_]Value{Value{ .string = md_input }};
    const ext_val = try nativeSysAiExtractCode(&vm, &extract_args);
    defer allocator.free(ext_val.string);
    try std.testing.expectEqualStrings("var z = 99;\n", ext_val.string);

    var no_code_args = [_]Value{Value{ .string = "Plain prose without code." }};
    const ext_empty = try nativeSysAiExtractCode(&vm, &no_code_args);
    try std.testing.expectEqualStrings("", ext_empty.string);

    var fail_args = [_]Value{ Value{ .string = "broken" }, Value{ .string = "syntax error!!" } };
    const fail_val = try nativeSysActorSpawnCode(&vm, &fail_args);
    try std.testing.expectEqual(@as(i64, -1), fail_val.integer);
}

test "ABI native AI tool call execution" {
    const allocator = std.testing.allocator;
    var chunk = @import("../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    var registry = ActorRegistry.init();
    var supervisor = try Actor.init(allocator, 0, "genesis", 16, 0);
    defer supervisor.deinit(allocator);

    _ = try supervisor.cspace.insert(@import("cap/capability.zig").Capability{
        .cap_type = .actor_control,
        .rights = @import("cap/capability.zig").Rights.READ | @import("cap/capability.zig").Rights.EXECUTE,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 0,
    });

    var ctx = AbiContext{
        .registry = &registry,
        .supervisor = supervisor,
        .spawn_code_fn = testMockSpawn,
    };
    setContext(&ctx);
    defer clearContext();

    const tool_json = "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"spawn_actor\",\"args\":{\"name\":\"w\",\"source\":\"sys_actor_count();\"}}}]}}]}";
    var args = [_]Value{Value{ .string = tool_json }};
    const res_val = try nativeSysAiToolCall(&vm, &args);
    defer allocator.free(res_val.string);
    try std.testing.expect(std.mem.indexOf(u8, res_val.string, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res_val.string, "\"actor_id\":7") != null);

    var no_tool_args = [_]Value{Value{ .string = "Plain prose" }};
    const empty_val = try nativeSysAiToolCall(&vm, &no_tool_args);
    try std.testing.expectEqualStrings("", empty_val.string);
}

test "ABI window and compositor native bindings" {
    const allocator = std.testing.allocator;
    var chunk = @import("../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    var registry = ActorRegistry.init();
    var supervisor = try Actor.init(allocator, 0, "genesis", 16, 0);
    defer supervisor.deinit(allocator);

    var wm = WindowManager.init(allocator, 640, 480);
    defer wm.deinit();

    var canvas = try Canvas.init(allocator, 640, 480, .rgb_888);
    defer canvas.deinit();

    var ptr = PointerState.init(640, 480);

    var ctx = AbiContext{
        .registry = &registry,
        .supervisor = supervisor,
        .wm = &wm,
        .canvas = &canvas,
        .pointer = &ptr,
    };
    setContext(&ctx);
    defer clearContext();

    try registerSyscalls(&vm);

    var create_args = [_]Value{
        Value{ .string = "Terminal" },
        Value{ .integer = 320 },
        Value{ .integer = 240 },
        Value{ .integer = 0 },
    };
    const win_id_val = try nativeSysWindowCreate(&vm, &create_args);
    try std.testing.expectEqual(@as(i64, 1), win_id_val.integer);

    var drect_args = [_]Value{
        Value{ .integer = 1 },
        Value{ .integer = 0 },
        Value{ .integer = 0 },
        Value{ .integer = 50 },
        Value{ .integer = 50 },
        Value{ .integer = 0x00FF_0000 },
    };
    _ = try nativeSysWindowDrawRect(&vm, &drect_args);

    var dstr_args = [_]Value{
        Value{ .integer = 1 },
        Value{ .integer = 5 },
        Value{ .integer = 5 },
        Value{ .string = "OK" },
        Value{ .integer = 0x00FF_FFFF },
        Value{ .integer = 0x0000_0000 },
    };
    _ = try nativeSysWindowDrawString(&vm, &dstr_args);

    var flush_args = [_]Value{};
    const flush_val = try nativeSysCompositorFlush(&vm, &flush_args);
    try std.testing.expect(flush_val.boolean);

    const ptr_val = try nativeSysPointerRead(&vm, &flush_args);
    try std.testing.expect(ptr_val.integer != -1);

    var focus_args = [_]Value{Value{ .integer = 1 }};
    const focus_val = try nativeSysWindowFocus(&vm, &focus_args);
    try std.testing.expect(focus_val.boolean);

    var close_args = [_]Value{Value{ .integer = 1 }};
    const close_val = try nativeSysWindowClose(&vm, &close_args);
    try std.testing.expect(close_val.boolean);
}
