// MicrOS (µOS) Gemini Resident AI Driver
// Protocol formatting and payload extraction for Google Gemini.

const std = @import("std");
const provider_mod = @import("provider.zig");
const tools_mod = @import("tools.zig");

pub fn buildPath(buf: []u8, model: []const u8, api_key: []const u8) !usize {
    const prefix = "/v1beta/models/";
    const suffix = ":generateContent?key=";
    const total_len = prefix.len + model.len + suffix.len + api_key.len;
    if (buf.len < total_len) return error.BufferTooSmall;

    var off: usize = 0;
    @memcpy(buf[off .. off + prefix.len], prefix);
    off += prefix.len;
    @memcpy(buf[off .. off + model.len], model);
    off += model.len;
    @memcpy(buf[off .. off + suffix.len], suffix);
    off += suffix.len;
    @memcpy(buf[off .. off + api_key.len], api_key);
    off += api_key.len;
    return off;
}

pub fn buildRequestBody(buf: []u8, system_prompt: []const u8, user_prompt: []const u8) !usize {
    const p1 = "{\"system_instruction\":{\"parts\":[{\"text\":\"";
    const p2 = "\"}]},\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"";
    const p3 = "\"}]}],\"tools\":" ++ tools_mod.GEMINI_TOOLS_JSON ++ ",\"generationConfig\":{\"temperature\":1.0,\"topK\":40,\"maxOutputTokens\":8192,\"thinkingConfig\":{\"thinkingLevel\":\"high\"}}}";

    var off: usize = 0;
    if (off + p1.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[off .. off + p1.len], p1);
    off += p1.len;

    off = try provider_mod.escapeJsonString(buf, off, system_prompt);

    if (off + p2.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[off .. off + p2.len], p2);
    off += p2.len;

    off = try provider_mod.escapeJsonString(buf, off, user_prompt);

    if (off + p3.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[off .. off + p3.len], p3);
    off += p3.len;

    return off;
}

pub fn extractText(json_payload: []const u8, out_buf: []u8) ?usize {
    const key_needle = "\"text\":";
    var search_pos: usize = 0;
    var target_start: ?usize = null;

    while (std.mem.indexOfPos(u8, json_payload, search_pos, key_needle)) |idx| {
        var p = idx + key_needle.len;
        while (p < json_payload.len and (json_payload[p] == ' ' or json_payload[p] == '\t')) {
            p += 1;
        }
        if (p < json_payload.len and json_payload[p] == '"') {
            target_start = p + 1;
        }
        search_pos = idx + key_needle.len;
    }
    const text_start = target_start orelse return null;
    return provider_mod.unescapeJsonString(json_payload[text_start..], out_buf);
}

test "gemini request path format" {
    var buf: [128]u8 = undefined;
    const len = try buildPath(&buf, "gemini-3.8-flash", "test-key");
    try std.testing.expectEqualStrings("/v1beta/models/gemini-3.8-flash:generateContent?key=test-key", buf[0..len]);
}

test "gemini request body format" {
    var buf: [4096]u8 = undefined;
    const len = try buildRequestBody(&buf, "sys prompt", "user prompt");
    try std.testing.expect(len > 0);
    const body = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, body, "sys prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "user prompt") != null);
}

test "gemini extract text" {
    const raw = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hello\\nWorld\"}]}}]}";
    var out: [64]u8 = undefined;
    const len = extractText(raw, &out);
    try std.testing.expect(len != null);
    try std.testing.expectEqualStrings("Hello\nWorld", out[0..len.?]);
}
