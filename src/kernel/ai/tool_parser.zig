// MicrOS (µOS) Zero-Allocation Streaming Tool Call Parser
// Strictly zero-libc, non-allocating JSON parser for Gemini and OpenAI envelopes.

const std = @import("std");
const tools = @import("tools.zig");
const provider_mod = @import("provider.zig");

pub const MIN_SCRATCH_BUF_LEN: usize = 128;
pub const NAME_BUF_LEN: usize = 64;

pub const RawEnvelope = struct {
    name: []const u8,
    args_json: []const u8,
};

pub fn skipWhitespace(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
    }
    return i;
}

pub fn trimToken(tok: []const u8) []const u8 {
    var s: usize = 0;
    while (s < tok.len and (tok[s] == ' ' or tok[s] == '"' or tok[s] == '\'')) : (s += 1) {}
    var e: usize = tok.len;
    while (e > s and (tok[e - 1] == ' ' or tok[e - 1] == '"' or tok[e - 1] == '\'')) : (e -= 1) {}
    return tok[s..e];
}

pub fn findMatchingBrace(src: []const u8, start_idx: usize) ?usize {
    var depth: usize = 0;
    var in_str = false;
    var escape = false;
    var i = start_idx;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (c == '\\' and in_str) {
            escape = true;
            continue;
        }
        if (c == '"') {
            in_str = !in_str;
            continue;
        }
        if (!in_str) {
            if (c == '{') depth += 1;
            if (c == '}') {
                if (depth == 1) return i;
                if (depth > 1) depth -= 1;
            }
        }
    }
    return null;
}

pub fn findKeyColon(json: []const u8, key: []const u8) ?usize {
    var search_idx: usize = 0;
    while (std.mem.indexOfPos(u8, json, search_idx, key)) |pos| {
        search_idx = pos + key.len;
        if (pos == 0 or json[pos - 1] != '"') continue;
        if (pos + key.len >= json.len or json[pos + key.len] != '"') continue;
        const p = skipWhitespace(json, pos + key.len + 1);
        if (p < json.len and json[p] == ':') {
            return skipWhitespace(json, p + 1);
        }
    }
    return null;
}

pub fn extractRawToken(json: []const u8, val_start: usize) []const u8 {
    var p = val_start;
    while (p < json.len) : (p += 1) {
        const c = json[p];
        if (c == ',' or c == '}' or c == ']' or c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            break;
        }
    }
    return json[val_start..p];
}

pub fn parseScalarU32(raw: []const u8) ?u32 {
    const s = trimToken(raw);
    if (s.len == 0) return null;
    if (s[0] == '#') {
        return std.fmt.parseInt(u32, s[1..], 16) catch null;
    }
    if (s.len > 2 and (s[0] == '0' and (s[1] == 'x' or s[1] == 'X'))) {
        return std.fmt.parseInt(u32, s[2..], 16) catch null;
    }
    const dot_idx = std.mem.indexOfScalar(u8, s, '.');
    const int_part = if (dot_idx) |idx| s[0..idx] else s;
    return std.fmt.parseInt(u32, int_part, 10) catch null;
}

pub fn findArgString(args_json: []const u8, key: []const u8, out_buf: []u8) ?[]const u8 {
    const val_start = findKeyColon(args_json, key) orelse return null;
    if (val_start >= args_json.len) return null;
    if (args_json[val_start] == '"') {
        const len = provider_mod.unescapeJsonString(args_json[val_start + 1 ..], out_buf);
        return out_buf[0..len];
    }
    const tok = extractRawToken(args_json, val_start);
    const trimmed = trimToken(tok);
    if (trimmed.len > out_buf.len) return null;
    @memcpy(out_buf[0..trimmed.len], trimmed);
    return out_buf[0..trimmed.len];
}

pub fn findArgU32(args_json: []const u8, key: []const u8) ?u32 {
    const val_start = findKeyColon(args_json, key) orelse return null;
    const tok = extractRawToken(args_json, val_start);
    return parseScalarU32(tok);
}

pub fn extractEnvelopeGemini(json: []const u8, name_buf: []u8) ?RawEnvelope {
    const fc_idx = std.mem.indexOf(u8, json, "\"functionCall\"") orelse return null;
    const fc_slice = json[fc_idx..];
    const name_pos = findKeyColon(fc_slice, "name") orelse return null;
    if (name_pos >= fc_slice.len or fc_slice[name_pos] != '"') return null;
    const name_len = provider_mod.unescapeJsonString(fc_slice[name_pos + 1 ..], name_buf);
    const name = name_buf[0..name_len];

    const args_pos = findKeyColon(fc_slice, "args") orelse return null;
    const obj_start = std.mem.indexOfScalarPos(u8, fc_slice, args_pos, '{') orelse return null;
    const obj_end = findMatchingBrace(fc_slice, obj_start) orelse return null;
    return RawEnvelope{
        .name = name,
        .args_json = fc_slice[obj_start .. obj_end + 1],
    };
}

pub fn extractEnvelopeOpenAi(json: []const u8, name_buf: []u8, arg_buf: []u8) ?RawEnvelope {
    const fn_idx = std.mem.indexOf(u8, json, "\"function\"") orelse return null;
    const fn_slice = json[fn_idx..];
    const name_pos = findKeyColon(fn_slice, "name") orelse return null;
    if (name_pos >= fn_slice.len or fn_slice[name_pos] != '"') return null;
    const name_len = provider_mod.unescapeJsonString(fn_slice[name_pos + 1 ..], name_buf);
    const name = name_buf[0..name_len];

    const arg_pos = findKeyColon(fn_slice, "arguments") orelse return null;
    if (arg_pos >= fn_slice.len) return null;
    if (fn_slice[arg_pos] == '"') {
        const arg_len = provider_mod.unescapeJsonString(fn_slice[arg_pos + 1 ..], arg_buf);
        return RawEnvelope{ .name = name, .args_json = arg_buf[0..arg_len] };
    }
    if (fn_slice[arg_pos] == '{') {
        const obj_end = findMatchingBrace(fn_slice, arg_pos) orelse return null;
        return RawEnvelope{ .name = name, .args_json = fn_slice[arg_pos .. obj_end + 1] };
    }
    return null;
}

fn parseSpawnActorArgs(args_json: []const u8, str_buf: []u8) ?tools.ToolCall {
    if (str_buf.len <= NAME_BUF_LEN) return null;
    const name_buf = str_buf[0..NAME_BUF_LEN];
    const src_buf = str_buf[NAME_BUF_LEN..];
    const act_name = findArgString(args_json, "name", name_buf) orelse "actor";
    const act_source = findArgString(args_json, "source", src_buf) orelse return null;
    return tools.ToolCall{
        .spawn_actor = .{
            .name = act_name,
            .source = act_source,
        },
    };
}

fn parseGrantCapArgs(args_json: []const u8) ?tools.ToolCall {
    const target = findArgU32(args_json, "target_actor") orelse return null;
    const slot = findArgU32(args_json, "source_slot") orelse return null;
    const raw_rights = findArgU32(args_json, "rights_mask") orelse return null;
    return tools.ToolCall{
        .grant_capability = .{
            .target_actor = target,
            .source_slot = slot,
            .rights_mask = @as(u16, @truncate(raw_rights)),
        },
    };
}

fn parseWriteStorageArgs(args_json: []const u8, str_buf: []u8) ?tools.ToolCall {
    const payload = findArgString(args_json, "payload", str_buf) orelse return null;
    return tools.ToolCall{
        .write_storage = .{
            .payload = payload,
        },
    };
}

fn parseReadStorageArgs(args_json: []const u8) ?tools.ToolCall {
    var hash_buf: [tools.MAX_HEX_HASH_LEN]u8 = undefined;
    const hash_str = findArgString(args_json, "hex_hash", &hash_buf) orelse return null;
    if (hash_str.len != tools.MAX_HEX_HASH_LEN) return null;
    return tools.ToolCall{
        .read_storage = .{
            .hex_hash = hash_buf,
        },
    };
}

fn parseDrawCanvasArgs(args_json: []const u8) ?tools.ToolCall {
    const x = findArgU32(args_json, "x") orelse return null;
    const y = findArgU32(args_json, "y") orelse return null;
    const w = findArgU32(args_json, "w") orelse return null;
    const h = findArgU32(args_json, "h") orelse return null;
    const color = findArgU32(args_json, "color") orelse return null;
    return tools.ToolCall{
        .draw_canvas = .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .color = color,
        },
    };
}

pub fn parseToolCall(name: []const u8, args_json: []const u8, str_buf: []u8) ?tools.ToolCall {
    const tt = tools.parseToolType(name) orelse return null;
    return switch (tt) {
        .spawn_actor => parseSpawnActorArgs(args_json, str_buf),
        .grant_capability => parseGrantCapArgs(args_json),
        .write_storage => parseWriteStorageArgs(args_json, str_buf),
        .read_storage => parseReadStorageArgs(args_json),
        .draw_canvas => parseDrawCanvasArgs(args_json),
        .query_telemetry => tools.ToolCall{ .query_telemetry = .{} },
    };
}

pub fn extractToolCall(json_payload: []const u8, scratch_buf: []u8) ?tools.ToolCall {
    if (scratch_buf.len < MIN_SCRATCH_BUF_LEN) return null;
    var name_buf: [NAME_BUF_LEN]u8 = undefined;
    const half = scratch_buf.len / 2;

    if (extractEnvelopeGemini(json_payload, &name_buf)) |env| {
        return parseToolCall(env.name, env.args_json, scratch_buf);
    }
    if (extractEnvelopeOpenAi(json_payload, &name_buf, scratch_buf[0..half])) |env| {
        return parseToolCall(env.name, env.args_json, scratch_buf[half..]);
    }
    return null;
}

pub fn formatResultJson(result: tools.ToolResult, out_buf: []u8) !usize {
    return switch (result) {
        .actor_spawned => |id| (try std.fmt.bufPrint(out_buf, "{{\"status\":\"ok\",\"actor_id\":{d}}}", .{id})).len,
        .capability_granted => |ok| (try std.fmt.bufPrint(out_buf, "{{\"status\":\"ok\",\"granted\":{}}}", .{ok})).len,
        .storage_written => |hash| (try std.fmt.bufPrint(out_buf, "{{\"status\":\"ok\",\"hex_hash\":\"{s}\"}}", .{hash})).len,
        .storage_read => |payload| (try std.fmt.bufPrint(out_buf, "{{\"status\":\"ok\",\"bytes\":{d}}}", .{payload.len})).len,
        .canvas_drawn => (try std.fmt.bufPrint(out_buf, "{{\"status\":\"ok\",\"rendered\":true}}", .{})).len,
        .telemetry => |t| (try std.fmt.bufPrint(
            out_buf,
            "{{\"status\":\"ok\",\"actors\":{d},\"faults\":{d},\"pages\":{d},\"uptime\":{d}}}",
            .{ t.active_actors, t.total_faults, t.free_ram_pages, t.uptime_ticks },
        )).len,
        .error_msg => |msg| (try std.fmt.bufPrint(out_buf, "{{\"status\":\"error\",\"message\":\"{s}\"}}", .{msg})).len,
    };
}

pub fn formatGeminiResponse(buf: []u8, tool_name: []const u8, result_json: []const u8) !usize {
    const p1 = "{\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"name\":\"";
    const p2 = "\",\"response\":";
    const p3 = "}}]}";
    const total = p1.len + tool_name.len + p2.len + result_json.len + p3.len;
    if (buf.len < total) return error.BufferTooSmall;

    var off: usize = 0;
    @memcpy(buf[off .. off + p1.len], p1);
    off += p1.len;
    @memcpy(buf[off .. off + tool_name.len], tool_name);
    off += tool_name.len;
    @memcpy(buf[off .. off + p2.len], p2);
    off += p2.len;
    @memcpy(buf[off .. off + result_json.len], result_json);
    off += result_json.len;
    @memcpy(buf[off .. off + p3.len], p3);
    off += p3.len;
    return off;
}

test "skip whitespace and trim token" {
    const s = "   hello   ";
    try std.testing.expectEqual(@as(usize, 3), skipWhitespace(s, 0));
    try std.testing.expectEqualStrings("hello", trimToken(s));
    try std.testing.expectEqualStrings("quoted", trimToken("\"quoted\""));
}

test "parse scalar u32 formats" {
    try std.testing.expectEqual(@as(u32, 42), parseScalarU32("42").?);
    try std.testing.expectEqual(@as(u32, 42), parseScalarU32("\"42\"").?);
    try std.testing.expectEqual(@as(u32, 42), parseScalarU32("42.0").?);
    try std.testing.expectEqual(@as(u32, 0xFF00FF), parseScalarU32("0xFF00FF").?);
    try std.testing.expectEqual(@as(u32, 0x1234), parseScalarU32("#1234").?);
    try std.testing.expect(parseScalarU32("invalid") == null);
}

test "find key colon and matching brace" {
    const json = "{\"target_actor\": 4, \"rights\": [1, 2]}";
    const pos = findKeyColon(json, "target_actor");
    try std.testing.expect(pos != null);
    try std.testing.expectEqual(@as(usize, 17), pos.?);

    const brace_end = findMatchingBrace(json, 0);
    try std.testing.expect(brace_end != null);
    try std.testing.expectEqual(json.len - 1, brace_end.?);
}

test "extract envelope gemini and parse tool call" {
    const gemini_json =
        "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"draw_canvas\"," ++
        "\"args\":{\"x\": 10, \"y\": 20, \"w\": 100, \"h\": 50, \"color\": 65280}}}]}}]}";
    var scratch: [1024]u8 = undefined;
    const call = extractToolCall(gemini_json, &scratch);
    try std.testing.expect(call != null);
    try std.testing.expectEqual(tools.ToolType.draw_canvas, @as(tools.ToolType, call.?));
    try std.testing.expectEqual(@as(u32, 10), call.?.draw_canvas.x);
    try std.testing.expectEqual(@as(u32, 20), call.?.draw_canvas.y);
    try std.testing.expectEqual(@as(u32, 100), call.?.draw_canvas.w);
    try std.testing.expectEqual(@as(u32, 50), call.?.draw_canvas.h);
    try std.testing.expectEqual(@as(u32, 65280), call.?.draw_canvas.color);
}

test "extract envelope openai escaped arguments" {
    const openai_json =
        "{\"choices\":[{\"message\":{\"tool_calls\":[{\"id\":\"call_1\",\"type\":\"function\"," ++
        "\"function\":{\"name\":\"spawn_actor\",\"arguments\":\"{\\\"name\\\":\\\"worker1\\\",\\\"source\\\":\\\"sys_actor_count();\\\"}\"}}]}}]}";
    var scratch: [1024]u8 = undefined;
    const call = extractToolCall(openai_json, &scratch);
    try std.testing.expect(call != null);
    try std.testing.expectEqual(tools.ToolType.spawn_actor, @as(tools.ToolType, call.?));
    try std.testing.expectEqualStrings("worker1", call.?.spawn_actor.name);
    try std.testing.expectEqualStrings("sys_actor_count();", call.?.spawn_actor.source);
}

test "format tool result and gemini return leg" {
    var res_buf: [128]u8 = undefined;
    const res_len = try formatResultJson(tools.ToolResult{ .actor_spawned = 3 }, &res_buf);
    try std.testing.expectEqualStrings("{\"status\":\"ok\",\"actor_id\":3}", res_buf[0..res_len]);

    var ret_buf: [256]u8 = undefined;
    const ret_len = try formatGeminiResponse(&ret_buf, "spawn_actor", res_buf[0..res_len]);
    try std.testing.expect(std.mem.indexOf(u8, ret_buf[0..ret_len], "\"functionResponse\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ret_buf[0..ret_len], "\"actor_id\":3") != null);
}
