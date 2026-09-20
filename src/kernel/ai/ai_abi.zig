// MicrOS (µOS) AI Assistant and Tool Call Native ABI Bindings
// SPEC-TECH-AI-001: Exposes inference, tool dispatch, and code extraction syscalls to Macros.
// Zero libc, freestanding, capability-gated.

const std = @import("std");
const eval = @import("../../macros/eval.zig");
const Value = eval.Value;
const vm_mod = @import("../../macros/vm.zig");
const VM = vm_mod.VM;
const ai_mod = @import("../ai.zig");
const cap_mod = @import("../cap/capability.zig");
const actor_mod = @import("../actor.zig");
const serial = @import("../serial.zig");

pub const AiContext = struct {
    ai_inference_fn: ?*const fn (prompt_ptr: [*]const u8, prompt_len: usize, out_ptr: [*]u8, out_len: usize) callconv(.c) usize = null,
    spawn_code_fn: ?*const fn (allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 = null,
    grant_cap_fn: ?*const fn (target_actor: u32, source_slot: u32, rights_mask: u16) anyerror!bool = null,
    cas_put_fn: ?*const fn (data: []const u8, out_hex: *[64]u8) anyerror!void = null,
    cas_get_fn: ?*const fn (hex_hash: []const u8, out_buf: []u8) anyerror!usize = null,
    draw_canvas_fn: ?*const fn (x: u32, y: u32, w: u32, h: u32, color: u32) void = null,
    telemetry_fn: ?*const fn () ai_mod.tools.TelemetrySnapshot = null,
    bundle_read_fn: ?*const fn (name: []const u8) ?[]const u8 = null,
    bundle_list_fn: ?*const fn (prefix: []const u8, out_buf: []u8) usize = null,
    current_actor_fn: ?*const fn () ?*actor_mod.Actor = null,
    supervisor: *actor_mod.Actor = undefined,
    check_auth_fn: ?*const fn (cap_type: cap_mod.CapType, rights: u16) bool = null,
};

var active_ai_ctx: ?*AiContext = null;
var ai_prompt_resp_buf: [16384]u8 = undefined;
var ai_extract_buf: [8192]u8 = undefined;
var ai_tool_scratch: [8192]u8 = undefined;
var ai_tool_res_buf: [16384]u8 = undefined;
var ai_tool_storage_buf: [16384]u8 = undefined;

pub fn setAiContext(ctx: *AiContext) void {
    active_ai_ctx = ctx;
}

pub fn clearAiContext() void {
    active_ai_ctx = null;
}

pub fn nativeSysAiPrompt(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const ctx = active_ai_ctx orelse return error.NoContext;
    const infer_fn = ctx.ai_inference_fn orelse return error.NoAiHandler;
    const prompt = args[0].string;
    const len = infer_fn(prompt.ptr, prompt.len, &ai_prompt_resp_buf, ai_prompt_resp_buf.len);
    if (len == 0) return Value{ .string = "" };
    const duped = try vm.gcAllocator().dupe(u8, ai_prompt_resp_buf[0..len]);
    return Value{ .string = duped };
}

pub fn nativeSysAiExtractCode(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const resp = args[0].string;
    if (ai_mod.client.AiClient.extractCodeBlock(resp, &ai_extract_buf)) |len| {
        const duped = try vm.gcAllocator().dupe(u8, ai_extract_buf[0..len]);
        return Value{ .string = duped };
    }
    return Value{ .string = "" };
}

pub fn nativeSysAiToolCall(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const resp = args[0].string;
    const ctx = active_ai_ctx orelse return error.NoContext;

    const call = ai_mod.tool_parser.extractToolCall(resp, &ai_tool_scratch) orelse {
        return Value{ .string = "" };
    };

    const caller = if (ctx.current_actor_fn) |get_fn| (get_fn() orelse ctx.supervisor) else ctx.supervisor;
    const disp_ctx = ai_mod.dispatcher.DispatcherContext{
        .spawn_fn = ctx.spawn_code_fn,
        .grant_fn = ctx.grant_cap_fn,
        .cas_put_fn = ctx.cas_put_fn,
        .cas_get_fn = ctx.cas_get_fn,
        .draw_canvas_fn = ctx.draw_canvas_fn,
        .telemetry_fn = ctx.telemetry_fn,
        .bundle_read_fn = ctx.bundle_read_fn,
        .bundle_list_fn = ctx.bundle_list_fn,
    };
    const disp = ai_mod.dispatcher.ToolDispatcher.init(
        caller.cspace,
        vm.allocator,
        disp_ctx,
        &ai_tool_storage_buf,
    );

    const result = disp.dispatch(call);
    const len = ai_mod.tool_parser.formatResultJson(result, &ai_tool_res_buf) catch |err| blk: {
        serial.writeString("[kernel] formatResultJson error: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        const fallback = "{\"status\":\"error\",\"message\":\"result buffer overflow\"}";
        @memcpy(ai_tool_res_buf[0..fallback.len], fallback);
        break :blk fallback.len;
    };
    const duped = try vm.gcAllocator().dupe(u8, ai_tool_res_buf[0..len]);
    return Value{ .string = duped };
}
