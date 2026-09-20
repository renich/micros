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
        if (in_str) continue;
        if (c == '{') depth += 1;
        if (c == '}' and depth == 1) return i;
        if (c == '}' and depth > 1) depth -= 1;
    }
    return null;
}

pub fn findKeyColon(json: []const u8, key: []const u8) ?usize {
    var i: usize = 0;
    var in_str = false;
    var escaped = false;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\' and in_str) {
            escaped = true;
            continue;
        }
        if (c != '"') continue;
        if (in_str) {
            in_str = false;
            continue;
        }
        const after_q = i + 1;
        if (after_q + key.len < json.len and
            std.mem.startsWith(u8, json[after_q..], key) and
            json[after_q + key.len] == '"')
        {
            const after_closing = after_q + key.len + 1;
            const colon_pos = skipWhitespace(json, after_closing);
            if (colon_pos < json.len and json[colon_pos] == ':') {
                return skipWhitespace(json, colon_pos + 1);
            }
        }
        in_str = true;
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

fn parseRunCommandArgs(args_json: []const u8, str_buf: []u8) ?tools.ToolCall {
    const cmd = findArgString(args_json, "command", str_buf) orelse return null;
    return tools.ToolCall{ .run_command = .{ .command = cmd } };
}

fn parseViewFileArgs(args_json: []const u8, str_buf: []u8) ?tools.ToolCall {
    const path = findArgString(args_json, "path", str_buf) orelse return null;
    return tools.ToolCall{ .view_file = .{ .path = path } };
}

fn parseWriteFileArgs(args_json: []const u8, str_buf: []u8) ?tools.ToolCall {
    if (str_buf.len <= NAME_BUF_LEN) return null;
    const path_buf = str_buf[0..NAME_BUF_LEN];
    const content_buf = str_buf[NAME_BUF_LEN..];
    const path = findArgString(args_json, "path", path_buf) orelse return null;
    const content = findArgString(args_json, "content", content_buf) orelse "";
    return tools.ToolCall{ .write_to_file = .{ .path = path, .content = content } };
}

fn parseReplaceContentArgs(args_json: []const u8, str_buf: []u8) ?tools.ToolCall {
    if (str_buf.len < 512) return null;
    const path_buf = str_buf[0..64];
    const target_buf = str_buf[64..256];
    const repl_buf = str_buf[256..];
    const path = findArgString(args_json, "path", path_buf) orelse return null;
    const target = findArgString(args_json, "target", target_buf) orelse return null;
    const repl = findArgString(args_json, "replacement", repl_buf) orelse "";
    return tools.ToolCall{ .replace_file_content = .{ .path = path, .target = target, .replacement = repl } };
}

fn parseListDirArgs(args_json: []const u8, str_buf: []u8) ?tools.ToolCall {
    const prefix = findArgString(args_json, "prefix", str_buf) orelse "";
    return tools.ToolCall{ .list_dir = .{ .prefix = prefix } };
}

fn parseGrepSearchArgs(args_json: []const u8, str_buf: []u8) ?tools.ToolCall {
    const query = findArgString(args_json, "query", str_buf) orelse return null;
    return tools.ToolCall{ .grep_search = .{ .query = query } };
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

pub fn parseToolCall(name: []const u8, args_json: []const u8, str_buf: []u8) ?tools.ToolCall {
    const tt = tools.parseToolType(name) orelse return null;
    return switch (tt) {
        .run_command => parseRunCommandArgs(args_json, str_buf),
        .view_file => parseViewFileArgs(args_json, str_buf),
        .write_to_file => parseWriteFileArgs(args_json, str_buf),
        .replace_file_content => parseReplaceContentArgs(args_json, str_buf),
        .list_dir => parseListDirArgs(args_json, str_buf),
        .grep_search => parseGrepSearchArgs(args_json, str_buf),
        .spawn_actor => parseSpawnActorArgs(args_json, str_buf),
        .grant_capability => parseGrantCapArgs(args_json),
        .write_storage => parseWriteStorageArgs(args_json, str_buf),
        .read_storage => parseReadStorageArgs(args_json),
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

fn formatSafeString(out_buf: []u8, prefix: []const u8, content: []const u8, suffix: []const u8) !usize {
    const overhead = prefix.len + suffix.len + 3;
    if (out_buf.len <= overhead) return error.BufferTooSmall;
    var off: usize = 0;
    @memcpy(out_buf[off .. off + prefix.len], prefix);
    off += prefix.len;

    for (content) |c| {
        if (off + suffix.len + 3 >= out_buf.len) {
            if (off + suffix.len + 3 < out_buf.len) {
                @memcpy(out_buf[off .. off + 3], "...");
                off += 3;
            }
            break;
        }
        switch (c) {
            '"' => {
                out_buf[off] = '\\';
                out_buf[off + 1] = '"';
                off += 2;
            },
            '\\' => {
                out_buf[off] = '\\';
                out_buf[off + 1] = '\\';
                off += 2;
            },
            '\n' => {
                out_buf[off] = '\\';
                out_buf[off + 1] = 'n';
                off += 2;
            },
            '\r' => {
                out_buf[off] = '\\';
                out_buf[off + 1] = 'r';
                off += 2;
            },
            '\t' => {
                out_buf[off] = '\\';
                out_buf[off + 1] = 't';
                off += 2;
            },
            else => {
                out_buf[off] = c;
                off += 1;
            },
        }
    }
    @memcpy(out_buf[off .. off + suffix.len], suffix);
    off += suffix.len;
    return off;
}

pub fn formatResultJson(result: tools.ToolResult, out_buf: []u8) !usize {
    return switch (result) {
        .command_executed => |out| formatSafeString(out_buf, "{\"status\":\"ok\",\"output\":\"", out, "\"}"),
        .file_viewed => |content| formatSafeString(out_buf, "{\"status\":\"ok\",\"content\":\"", content, "\"}"),
        .file_written => |bytes| (try std.fmt.bufPrint(out_buf, "{{\"status\":\"ok\",\"bytes_written\":{d}}}", .{bytes})).len,
        .content_replaced => |ok| (try std.fmt.bufPrint(out_buf, "{{\"status\":\"ok\",\"replaced\":{}}}", .{ok})).len,
        .dir_listed => |list| formatSafeString(out_buf, "{\"status\":\"ok\",\"listing\":\"", list, "\"}"),
        .search_results => |res| formatSafeString(out_buf, "{\"status\":\"ok\",\"matches\":\"", res, "\"}"),
        .actor_spawned => |id| (try std.fmt.bufPrint(out_buf, "{{\"status\":\"ok\",\"actor_id\":{d}}}", .{id})).len,
        .capability_granted => |ok| (try std.fmt.bufPrint(out_buf, "{{\"status\":\"ok\",\"granted\":{}}}", .{ok})).len,
        .storage_written => |hash| (try std.fmt.bufPrint(out_buf, "{{\"status\":\"ok\",\"hex_hash\":\"{s}\"}}", .{hash})).len,
        .storage_read => |payload| formatSafeString(out_buf, "{\"status\":\"ok\",\"content\":\"", payload, "\"}"),
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
        "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"run_command\"," ++
        "\"args\":{\"command\":\"desk\"}}}]}}]}";
    var scratch: [1024]u8 = undefined;
    const call = extractToolCall(gemini_json, &scratch);
    try std.testing.expect(call != null);
    try std.testing.expectEqual(tools.ToolType.run_command, @as(tools.ToolType, call.?));
    try std.testing.expectEqualStrings("desk", call.?.run_command.command);
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

test "format tool result escapes quotes and newlines" {
    var res_buf: [256]u8 = undefined;
    const res_len = try formatResultJson(tools.ToolResult{ .file_viewed = "x = \"hello\";\ny = 2;\n" }, &res_buf);
    try std.testing.expectEqualStrings("{\"status\":\"ok\",\"content\":\"x = \\\"hello\\\";\\ny = 2;\\n\"}", res_buf[0..res_len]);
}

test "findKeyColon ignores keys embedded in string literals" {
    const json = "{\"command\":\"cat \\\"target\\\": bar\",\"target\":\"main.zig\"}";
    const pos = findKeyColon(json, "target");
    try std.testing.expect(pos != null);
    try std.testing.expectEqualStrings("\"main.zig\"}", json[pos.?..]);
}
