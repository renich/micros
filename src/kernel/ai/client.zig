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
        const text_res = switch (self.config.provider_type) {
            .gemini => gemini_mod.extractText(json_payload, out_text),
            .openai, .local_http, .anthropic => openai_mod.extractText(json_payload, out_text),
            .mock => mock_mod.generateResponse("status", out_text) catch null,
        };
        if (text_res) |len| return len;
        if (std.mem.indexOf(u8, json_payload, "\"functionCall\"") != null or
            std.mem.indexOf(u8, json_payload, "\"tool_calls\"") != null or
            std.mem.indexOf(u8, json_payload, "\"function\"") != null)
        {
            const copy_len = @min(json_payload.len, out_text.len);
            @memcpy(out_text[0..copy_len], json_payload[0..copy_len]);
            return copy_len;
        }
        return null;
    }

    pub fn extractCodeBlock(src: []const u8, out_buf: []u8) ?usize {
        if (extractRstCodeBlock(src, out_buf)) |len| return len;
        return extractMarkdownCodeBlock(src, out_buf);
    }
};

fn checkRstDirective(src: []const u8, dir: []const u8, out_buf: []u8) ?usize {
    const pos = std.mem.indexOf(u8, src, dir) orelse return null;
    return parseRstBlockBody(src[pos + dir.len ..], out_buf);
}

fn extractRstCodeBlock(src: []const u8, out_buf: []u8) ?usize {
    const directives = [_][]const u8{
        ".. code-block:: macros",
        ".. code-block:: mx",
        ".. code-block::",
    };
    for (directives) |dir| {
        if (checkRstDirective(src, dir, out_buf)) |len| return len;
    }
    return null;
}

fn extractMarkdownCodeBlock(src: []const u8, out_buf: []u8) ?usize {
    const markers = [_][]const u8{ "```macros", "```mx", "```" };
    for (markers) |m| {
        if (findCodeBlockWithMarker(src, m, out_buf)) |len| return len;
    }
    return null;
}

fn skipDirectiveHeader(src: []const u8) usize {
    var i: usize = 0;
    while (i < src.len and src[i] != '\n') : (i += 1) {}
    if (i < src.len and src[i] == '\n') i += 1;
    while (i < src.len) {
        if (src[i] == '\n') {
            i += 1;
            continue;
        }
        if (src[i] == '\r' and i + 1 < src.len and src[i + 1] == '\n') {
            i += 2;
            continue;
        }
        break;
    }
    return i;
}

fn detectIndent(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}

fn appendNewline(out_buf: []u8, out_len: *usize) void {
    if (out_len.* > 0 and out_len.* < out_buf.len) {
        out_buf[out_len.*] = '\n';
        out_len.* += 1;
    }
}

fn appendCodeLine(out_buf: []u8, out_len: *usize, text: []const u8) void {
    if (out_len.* + text.len + 1 > out_buf.len) return;
    @memcpy(out_buf[out_len.* .. out_len.* + text.len], text);
    out_len.* += text.len;
    out_buf[out_len.*] = '\n';
    out_len.* += 1;
}

fn parseRstBlockBody(body_src: []const u8, out_buf: []u8) ?usize {
    const start_idx = skipDirectiveHeader(body_src);
    if (start_idx >= body_src.len) return null;

    var iter = std.mem.splitScalar(u8, body_src[start_idx..], '\n');
    var indent: usize = 0;
    var out_len: usize = 0;

    while (iter.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) {
            appendNewline(out_buf, &out_len);
            continue;
        }
        const line_indent = detectIndent(line);
        if (indent == 0 and line_indent == 0) break;
        if (indent == 0) indent = line_indent;
        if (line_indent < indent) break;
        appendCodeLine(out_buf, &out_len, line[indent..]);
    }
    while (out_len > 0 and out_buf[out_len - 1] == '\n') out_len -= 1;
    appendNewline(out_buf, &out_len);
    return if (out_len > 0) out_len else null;
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

test "client extract markdown code block" {
    const sample = "Directive:\n```macros\nsys_serial_write(\"OK\");\n```\nDone.";
    var code_buf: [64]u8 = undefined;
    const len = AiClient.extractCodeBlock(sample, &code_buf);
    try std.testing.expect(len != null);
    try std.testing.expectEqualStrings("sys_serial_write(\"OK\");\n", code_buf[0..len.?]);
}

test "client extract rst code block 3-space" {
    const sample =
        "Directive Narrative\n" ++
        "===================\n\n" ++
        ".. code-block:: macros\n\n" ++
        "   sys_fb_draw_string(20, 20, \"RST Online\", 65280, 0);\n" ++
        "   sys_serial_write(\"Active\\n\");\n\n" ++
        "Narrative continues outside code block.";
    var code_buf: [128]u8 = undefined;
    const len = AiClient.extractCodeBlock(sample, &code_buf);
    try std.testing.expect(len != null);
    const expected =
        "sys_fb_draw_string(20, 20, \"RST Online\", 65280, 0);\n" ++
        "sys_serial_write(\"Active\\n\");\n";
    try std.testing.expectEqualStrings(expected, code_buf[0..len.?]);
}

test "client extract rst code block 4-space" {
    const sample =
        ".. code-block:: mx\n\n" ++
        "    var x = 42;\n" ++
        "    print(x);\n\n" ++
        "End of block.";
    var code_buf: [128]u8 = undefined;
    const len = AiClient.extractCodeBlock(sample, &code_buf);
    try std.testing.expect(len != null);
    const expected = "var x = 42;\nprint(x);\n";
    try std.testing.expectEqualStrings(expected, code_buf[0..len.?]);
}

test "client extract exact gemini resident ai response" {
    const sample =
        "Writing boot banner and diagnostics to the linear GOP canvas and serial console:\n\n" ++
        ".. code-block:: macros\n\n" ++
        "   sys_serial_write(\"uOS: Operator link acknowledged. CSpace 0 verified.\\n\");\n" ++
        "   sys_fb_clear(0);\n" ++
        "   sys_fb_draw_rect(0, 0, 1280, 44, 1120295);\n" ++
        "   sys_fb_draw_string(24, 14, \"MicrOS (uOS) // Sovereign Root Intelligence [CSpace 0]\", 65280, 1120295);\n" ++
        "   sys_fb_draw_rect(0, 44, 1280, 2, 65280);\n" ++
        "   sys_fb_draw_string(24, 68, \"Substrate: Bare-metal x86_64 | Zero-libc ABI\", 16777215, 0);\n" ++
        "   sys_fb_draw_string(24, 92, \"Display Canvas: 1280x800 GOP linear buffer\", 16777215, 0);\n" ++
        "   sys_fb_draw_string(24, 116, \"IPC Model: SPSC Typed Rings | VirtIO Active\", 16777215, 0);\n" ++
        "   sys_fb_draw_string(24, 140, \"Awaiting directives...\", 8421504, 0);\n\n" ++
        "Kernel Directives\n" ++
        "-----------------\n\n" ++
        "State your operational requirements:\n" ++
        "* Subsystem memory mapping and page allocation\n";
    var code_buf: [2048]u8 = undefined;
    const len = AiClient.extractCodeBlock(sample, &code_buf);
    try std.testing.expect(len != null);
    try std.testing.expect(std.mem.indexOf(u8, code_buf[0..len.?], "Kernel Directives") == null);
    try std.testing.expect(std.mem.startsWith(u8, code_buf[0..len.?], "sys_serial_write"));
    try std.testing.expect(std.mem.endsWith(u8, code_buf[0..len.?], "sys_fb_draw_string(24, 140, \"Awaiting directives...\", 8421504, 0);\n"));
}
