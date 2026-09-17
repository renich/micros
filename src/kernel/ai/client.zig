// MicrOS (µOS) Freestanding Resident AI Client
// Polymorphic dispatcher connecting the Sovereign event loop to any AI engine.

const std = @import("std");
const provider_mod = @import("provider.zig");
const gemini_mod = @import("gemini.zig");
const openai_mod = @import("openai.zig");
const mock_mod = @import("mock.zig");
const http = @import("../net/http.zig");

pub const AiClient = struct {
    config: provider_mod.ProviderConfig,

    pub fn init(config: provider_mod.ProviderConfig) AiClient {
        return AiClient{ .config = config };
    }

    pub fn formatPromptRequest(
        self: *const AiClient,
        req_buf: []u8,
        body_buf: []u8,
        user_prompt: []const u8,
    ) !usize {
        return switch (self.config.provider_type) {
            .gemini => self.formatGemini(req_buf, body_buf, user_prompt),
            .openai, .local_http => self.formatOpenAi(req_buf, body_buf, user_prompt),
            .anthropic => self.formatOpenAi(req_buf, body_buf, user_prompt),
            .mock => 0,
        };
    }

    fn formatGemini(self: *const AiClient, req_buf: []u8, body_buf: []u8, prompt: []const u8) !usize {
        var path_buf: [256]u8 = undefined;
        const path_len = try gemini_mod.buildPath(&path_buf, self.config.model, self.config.api_key);
        const path = path_buf[0..path_len];

        const body_len = try gemini_mod.buildRequestBody(body_buf, provider_mod.SOVEREIGN_SYSTEM_PROMPT, prompt);
        const body = body_buf[0..body_len];

        return try http.formatPostRequest(req_buf, self.config.endpoint, path, "application/json", body);
    }

    fn formatOpenAi(self: *const AiClient, req_buf: []u8, body_buf: []u8, prompt: []const u8) !usize {
        var path_buf: [64]u8 = undefined;
        const path_len = try openai_mod.buildPath(&path_buf);
        const path = path_buf[0..path_len];

        const body_len = try openai_mod.buildRequestBody(
            body_buf,
            self.config.model,
            provider_mod.SOVEREIGN_SYSTEM_PROMPT,
            prompt,
        );
        const body = body_buf[0..body_len];

        var auth_buf: [256]u8 = undefined;
        const auth: ?[]const u8 = if (self.config.api_key.len > 0)
            std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{self.config.api_key}) catch null
        else
            null;

        return try http.formatPostRequestWithAuth(
            req_buf,
            self.config.endpoint,
            path,
            "application/json",
            auth,
            body,
        );
    }

    pub fn extractResponseText(self: *const AiClient, json_payload: []const u8, out_text: []u8) ?usize {
        return switch (self.config.provider_type) {
            .gemini => gemini_mod.extractText(json_payload, out_text),
            .openai, .local_http, .anthropic => openai_mod.extractText(json_payload, out_text),
            .mock => mock_mod.generateResponse("status", out_text) catch null,
        };
    }

    pub fn extractCodeBlock(src: []const u8, out_buf: []u8) ?usize {
        const markers = [_][]const u8{ "```macros", "```mx", "```" };
        for (markers) |m| {
            if (findCodeBlockWithMarker(src, m, out_buf)) |len| {
                return len;
            }
        }
        return null;
    }

    fn findCodeBlockWithMarker(src: []const u8, marker: []const u8, out_buf: []u8) ?usize {
        const start_idx = std.mem.indexOf(u8, src, marker) orelse return null;
        const after_marker = start_idx + marker.len;
        const newline_idx = std.mem.indexOfScalarPos(u8, src, after_marker, '\n') orelse return null;
        const code_start = newline_idx + 1;
        const end_idx = std.mem.indexOfPos(u8, src, code_start, "```") orelse return null;

        if (code_start >= end_idx) return null;
        const code = src[code_start..end_idx];
        const copy_len = @min(code.len, out_buf.len);
        @memcpy(out_buf[0..copy_len], code[0..copy_len]);
        return copy_len;
    }
};

test "client polymorphic request dispatch" {
    const gemini_cfg = provider_mod.ProviderConfig{
        .provider_type = .gemini,
        .endpoint = "generativelanguage.googleapis.com",
        .model = "gemini-3.8-flash",
        .api_key = "key123",
    };
    const client = AiClient.init(gemini_cfg);
    var req_buf: [4096]u8 = undefined;
    var body_buf: [4096]u8 = undefined;
    const len = try client.formatPromptRequest(&req_buf, &body_buf, "Hello AI");
    try std.testing.expect(len > 0);
    try std.testing.expect(std.mem.indexOf(u8, req_buf[0..len], "POST /v1beta/models/") != null);
}

test "client extract code block" {
    const sample = "Directive:\n```macros\nsys_serial_write(\"OK\");\n```\nDone.";
    var code_buf: [64]u8 = undefined;
    const len = AiClient.extractCodeBlock(sample, &code_buf);
    try std.testing.expect(len != null);
    try std.testing.expectEqualStrings("sys_serial_write(\"OK\");\n", code_buf[0..len.?]);
}
