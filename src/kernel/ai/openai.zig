// MicrOS (µOS) OpenAI & Local Compatible Resident AI Driver
// Supports OpenAI (ChatGPT), vLLM, Ollama, Groq, DeepSeek, and LocalAI endpoints.

const std = @import("std");
const provider_mod = @import("provider.zig");

pub const DEFAULT_CHAT_PATH: []const u8 = "/v1/chat/completions";

pub fn buildPath(buf: []u8) !usize {
    if (buf.len < DEFAULT_CHAT_PATH.len) return error.BufferTooSmall;
    @memcpy(buf[0..DEFAULT_CHAT_PATH.len], DEFAULT_CHAT_PATH);
    return DEFAULT_CHAT_PATH.len;
}

pub fn buildRequestBody(buf: []u8, model: []const u8, system_prompt: []const u8, user_prompt: []const u8) !usize {
    const p1 = "{\"model\":\"";
    const p2 = "\",\"messages\":[{\"role\":\"system\",\"content\":\"";
    const p3 = "\"},{\"role\":\"user\",\"content\":\"";
    const p4 = "\"}],\"temperature\":1.0}";

    var off: usize = 0;
    if (off + p1.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[off .. off + p1.len], p1);
    off += p1.len;

    if (off + model.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[off .. off + model.len], model);
    off += model.len;

    if (off + p2.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[off .. off + p2.len], p2);
    off += p2.len;

    off = try provider_mod.escapeJsonString(buf, off, system_prompt);

    if (off + p3.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[off .. off + p3.len], p3);
    off += p3.len;

    off = try provider_mod.escapeJsonString(buf, off, user_prompt);

    if (off + p4.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[off .. off + p4.len], p4);
    off += p4.len;

    return off;
}

pub fn extractText(json_payload: []const u8, out_buf: []u8) ?usize {
    const key_needle = "\"content\":";
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

test "openai request body generation" {
    var buf: [2048]u8 = undefined;
    const len = try buildRequestBody(&buf, "gpt-4o", "sys instruction", "user prompt");
    try std.testing.expect(len > 0);
    const body = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-4o\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "sys instruction") != null);
}

test "openai extract text" {
    const raw = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Sovereign Root Online\"}}]}";
    var out: [64]u8 = undefined;
    const len = extractText(raw, &out);
    try std.testing.expect(len != null);
    try std.testing.expectEqualStrings("Sovereign Root Online", out[0..len.?]);
}
