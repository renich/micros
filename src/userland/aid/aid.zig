// MicrOS (µOS) Sovereign AI & Security Daemon (aid)
// Isolated userland service actor executing TLS 1.3 encryption/decryption,
// HTTP/1.1 REST client framing, and LLM cognitive prompt synthesis.
// Controlled via CSpace capabilities and lock-free SPSC IPC ring buffers.
// Freestanding, zero libc.

const std = @import("std");
const cap_mod = @import("../../kernel/cap/capability.zig");
const ai_mod = @import("../../kernel/ai.zig");
const ai_provider = ai_mod.provider;
const ai_client = ai_mod.client;
const mock_mod = ai_mod.mock;
const gemini_mod = @import("../../kernel/ai/gemini.zig");
const openai_mod = @import("../../kernel/ai/openai.zig");
const netd_mod = @import("../netd/netd.zig");
const ring_mod = @import("../../kernel/ipc/ring.zig");
const SpscRingBuffer = ring_mod.SpscRingBuffer;
const tls_stream_mod = @import("../../kernel/net/tls_stream.zig");
const http_mod = @import("../../kernel/net/http.zig");
const serial = @import("../../kernel/serial.zig");

pub const FIXTURE_CALCULATOR_HTTP =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: application/json; charset=UTF-8\r\n" ++
    "Transfer-Encoding: chunked\r\n" ++
    "Date: Tue, 29 Sep 2026 08:00:00 GMT\r\n" ++
    "Server: scaffolding on HTTPServer2\r\n" ++
    "\r\n" ++
    "63\r\n" ++
    "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"```macros\\nfn calc(a, b) { return a + b; }\\n```\"}]}}]}\r\n" ++
    "0\r\n" ++
    "\r\n";

pub const AiDaemonState = enum(u8) {
    uninitialized = 0,
    idle = 1,
    ready = 2,
    processing = 3,
    faulted = 4,
};

pub const AiDaemon = struct {
    allocator: std.mem.Allocator,
    config: ai_provider.ProviderConfig,
    client: ai_client.AiClient,
    net_daemon: ?*netd_mod.NetDaemon,
    ipc_cap: cap_mod.Capability,
    client_rx_ring: ?*SpscRingBuffer,
    client_tx_ring: ?*SpscRingBuffer,
    tls_adapter: ?*tls_stream_mod.TcpStreamAdapter,
    state: AiDaemonState,
    request_count: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        config: ai_provider.ProviderConfig,
        net_daemon: ?*netd_mod.NetDaemon,
        ipc_cap: cap_mod.Capability,
    ) AiDaemon {
        return AiDaemon{
            .allocator = allocator,
            .config = config,
            .client = ai_client.AiClient.init(config),
            .net_daemon = net_daemon,
            .ipc_cap = ipc_cap,
            .client_rx_ring = null,
            .client_tx_ring = null,
            .tls_adapter = null,
            .state = .ready,
            .request_count = 0,
        };
    }

    pub fn setRings(
        self: *AiDaemon,
        rx_ring: *SpscRingBuffer,
        tx_ring: *SpscRingBuffer,
    ) void {
        self.client_rx_ring = rx_ring;
        self.client_tx_ring = tx_ring;
    }

    pub fn setTlsAdapter(
        self: *AiDaemon,
        adapter: *tls_stream_mod.TcpStreamAdapter,
    ) void {
        self.tls_adapter = adapter;
    }

    pub fn dispatchPrompt(
        self: *AiDaemon,
        prompt: []const u8,
        out_buf: []u8,
    ) usize {
        self.state = .processing;
        defer self.state = .ready;
        self.request_count +%= 1;

        if (self.config.provider_type == .recorded_fixture) {
            var decoded_buf: [1024]u8 = undefined;
            const body = extractResponseBody(FIXTURE_CALCULATOR_HTTP, &decoded_buf) orelse return 0;
            return AiDaemon.extractResponseText(self.config.provider_type, body, out_buf) orelse 0;
        }

        if (self.config.provider_type == .mock or self.net_daemon == null) {
            return mock_mod.generateResponse(prompt, out_buf) catch 0;
        }

        const online_res = self.dispatchOnline(prompt, out_buf);
        if (online_res > 0) return online_res;

        serial.writeString("[aid] Mock offline fallback: generic synthesis active\n");
        return mock_mod.generateResponse(prompt, out_buf) catch 0;
    }

    fn connectEndpoint(self: *AiDaemon) bool {
        const net_d = self.net_daemon orelse return false;
        const adapter = self.tls_adapter orelse return false;
        if (adapter.connected) return true;

        if (net_d.stack != null and !net_d.stack.?.dhcp_config.bound) {
            _ = net_d.startDhcp() catch false;
        }

        const ip = net_d.resolveDns(self.config.endpoint) catch |err| {
            serial.writeString("[aid] DNS failed for ");
            serial.writeString(self.config.endpoint);
            serial.writeString(": ");
            serial.writeString(@errorName(err));
            serial.writeString("\n");
            return false;
        };
        const connected = net_d.connectTcp(ip, self.config.port) catch |err| {
            serial.writeString("[aid] TCP connect failed: ");
            serial.writeString(@errorName(err));
            serial.writeString("\n");
            return false;
        };
        if (!connected) return false;

        adapter.handshake(self.config.endpoint) catch |err| {
            serial.writeString("[aid] TLS handshake failed: ");
            serial.writeString(@errorName(err));
            serial.writeString("\n");
            return false;
        };
        return true;
    }

    fn isResponseComplete(data: []const u8) bool {
        const resp = http_mod.parseResponseHeaders(data, data.len) catch return false;
        if (resp.content_length) |cl| {
            return data.len >= resp.body_offset + cl;
        }
        if (resp.is_chunked) {
            const body_slice = data[resp.body_offset..];
            return http_mod.isChunkedComplete(body_slice);
        }
        return false;
    }

    fn readFullResponse(adapter: *tls_stream_mod.TcpStreamAdapter, buf: []u8) usize {
        var total: usize = 0;
        while (total < buf.len) {
            const n = adapter.readSlice(buf[total..]) catch |err| {
                if (err != error.EndOfStream) {
                    serial.writeString("[aid] readSlice: ");
                    serial.writeString(@errorName(err));
                    serial.writeString("\n");
                }
                break;
            };
            if (n == 0) break;
            total += n;
            if (isResponseComplete(buf[0..total])) break;
        }
        return total;
    }

    fn extractResponseBody(raw_data: []const u8, decoded_buf: []u8) ?[]const u8 {
        const resp = http_mod.parseResponseHeaders(raw_data, raw_data.len) catch return null;
        if (resp.body_offset >= raw_data.len) return null;
        const raw_body = raw_data[resp.body_offset..];
        if (resp.is_chunked) {
            const dlen = http_mod.decodeChunkedBody(raw_body, decoded_buf) catch |err| {
                serial.writeString("[aid] Chunked decode error: ");
                serial.writeString(@errorName(err));
                serial.writeString("\n");
                return null;
            };
            return decoded_buf[0..dlen];
        }
        return raw_body;
    }

    fn dispatchOnline(
        self: *AiDaemon,
        prompt: []const u8,
        out_buf: []u8,
    ) usize {
        const adapter = self.tls_adapter orelse return 0;
        if (!self.connectEndpoint()) return 0;
        defer adapter.close();

        var req_buf: [16384]u8 = undefined;
        var body_buf: [16384]u8 = undefined;
        const req_len = self.client.formatPromptRequest(&req_buf, &body_buf, prompt) catch |err| {
            serial.writeString("[aid] formatPromptRequest error: ");
            serial.writeString(@errorName(err));
            serial.writeString("\n");
            return 0;
        };

        adapter.writeAll(req_buf[0..req_len]) catch |err| {
            serial.writeString("[aid] writeAll failed: ");
            serial.writeString(@errorName(err));
            serial.writeString("\n");
            return 0;
        };

        const resp_buf = self.allocator.alloc(u8, 65536) catch return 0;
        defer self.allocator.free(resp_buf);
        const chunk_buf = self.allocator.alloc(u8, 65536) catch return 0;
        defer self.allocator.free(chunk_buf);

        const read_bytes = readFullResponse(adapter, resp_buf);
        if (read_bytes == 0) return 0;

        const body = extractResponseBody(resp_buf[0..read_bytes], chunk_buf) orelse return 0;
        return AiDaemon.extractResponseText(self.config.provider_type, body, out_buf) orelse 0;
    }

    pub fn step(self: *AiDaemon) void {
        _ = self.processClientIpc();
    }

    pub fn processClientIpc(self: *AiDaemon) usize {
        const rx = self.client_rx_ring orelse return 0;
        const tx = self.client_tx_ring orelse return 0;
        if (rx.isEmpty()) return 0;

        var prompt_buf: [1024]u8 = undefined;
        var prompt_len: usize = 0;

        while (!rx.isEmpty()) {
            const b = rx.readByte() orelse break;
            if (b == 0) break;
            if (prompt_len < prompt_buf.len) {
                prompt_buf[prompt_len] = b;
                prompt_len += 1;
            }
        }

        var resp_buf: [2048]u8 = undefined;
        const resp_len = self.dispatchPrompt(prompt_buf[0..prompt_len], &resp_buf);

        for (resp_buf[0..resp_len]) |b| {
            if (!tx.writeByte(b)) break;
        }
        _ = tx.writeByte(0);
        return resp_len;
    }

    pub fn extractResponseText(provider_type: ai_provider.ProviderType, json_payload: []const u8, out_text: []u8) ?usize {
        const text_res = switch (provider_type) {
            .gemini, .recorded_fixture => gemini_mod.extractText(json_payload, out_text),
            .openai, .local_http, .anthropic => openai_mod.extractText(json_payload, out_text),
            .mock => mock_mod.generateResponse("status", out_text) catch null,
        };
        if (text_res) |len| return len;
        if (std.mem.indexOf(u8, json_payload, "\"functionCall\"") != null or
            std.mem.indexOf(u8, json_payload, "\"tool_calls\"") != null)
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

pub const extractResponseText = AiDaemon.extractResponseText;
pub const extractCodeBlock = AiDaemon.extractCodeBlock;

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

test "AiDaemon: mock offline prompt dispatch" {
    const null_cap = cap_mod.Capability.NULL_CAP;
    const cfg = ai_provider.ProviderConfig{
        .provider_type = .mock,
        .endpoint = "mock.local",
        .port = 443,
        .use_tls = false,
        .model = "mock-model",
    };

    var aid = AiDaemon.init(std.testing.allocator, cfg, null, null_cap);
    try std.testing.expectEqual(AiDaemonState.ready, aid.state);

    var out: [512]u8 = undefined;
    const n = aid.dispatchPrompt("hello", &out);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "MOCK-0001") != null);
}

test "AiDaemon: SPSC IPC request and response streaming" {
    const null_cap = cap_mod.Capability.NULL_CAP;
    const cfg = ai_provider.ProviderConfig{
        .provider_type = .mock,
        .endpoint = "mock.local",
        .port = 443,
        .use_tls = false,
        .model = "mock-model",
    };

    var aid = AiDaemon.init(std.testing.allocator, cfg, null, null_cap);
    var rx_ring = SpscRingBuffer.init();
    var tx_ring = SpscRingBuffer.init();
    aid.setRings(&rx_ring, &tx_ring);

    const test_prompt = "status";
    for (test_prompt) |b| _ = rx_ring.writeByte(b);
    _ = rx_ring.writeByte(0);

    const resp_len = aid.processClientIpc();
    try std.testing.expect(resp_len > 0);
    try std.testing.expect(!tx_ring.isEmpty());

    var out: [512]u8 = undefined;
    var out_len: usize = 0;
    while (!tx_ring.isEmpty() and out_len < out.len) : (out_len += 1) {
        const b = tx_ring.readByte().?;
        if (b == 0) break;
        out[out_len] = b;
    }
    try std.testing.expect(out_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, out[0..out_len], "MOCK-0001") != null);
}

test "AiDaemon: oversized prompt drains null terminator without desync" {
    const null_cap = cap_mod.Capability.NULL_CAP;
    const cfg = ai_provider.ProviderConfig{
        .provider_type = .mock,
        .endpoint = "mock.local",
        .port = 443,
        .use_tls = false,
        .model = "mock-model",
    };

    var aid = AiDaemon.init(std.testing.allocator, cfg, null, null_cap);
    var rx_ring = SpscRingBuffer.init();
    var tx_ring = SpscRingBuffer.init();
    aid.setRings(&rx_ring, &tx_ring);

    // Push oversized prompt (> 1024 bytes) terminated by 0
    for (0..1200) |_| _ = rx_ring.writeByte('A');
    _ = rx_ring.writeByte(0);

    // Push second normal prompt
    for ("second") |b| _ = rx_ring.writeByte(b);
    _ = rx_ring.writeByte(0);

    const first_len = aid.processClientIpc();
    try std.testing.expect(first_len > 0);

    const second_len = aid.processClientIpc();
    try std.testing.expect(second_len > 0);
}

test "live-synth: full http fixture parse to chunk" {
    var decoded_buf: [1024]u8 = undefined;
    const body = AiDaemon.extractResponseBody(FIXTURE_CALCULATOR_HTTP, &decoded_buf);
    try std.testing.expect(body != null);

    const cfg = ai_provider.ProviderConfig{
        .provider_type = .recorded_fixture,
        .endpoint = "generativelanguage.googleapis.com",
        .port = 443,
        .use_tls = true,
        .model = "gemini-2.5-flash",
    };
    var text_buf: [1024]u8 = undefined;
    const n = extractResponseText(cfg.provider_type, body.?, &text_buf);
    try std.testing.expect(n != null and n.? > 0);

    const full_text = text_buf[0..n.?];
    var code_buf: [512]u8 = undefined;
    const code_len = extractCodeBlock(full_text, &code_buf);
    try std.testing.expect(code_len != null and code_len.? > 0);

    const code = std.mem.trim(u8, code_buf[0..code_len.?], " \t\r\n");
    try std.testing.expectEqualStrings("fn calc(a, b) { return a + b; }", code);

    const parser_mod = @import("../../macros/parser.zig");
    var p = parser_mod.Parser.init(std.testing.allocator, code);
    const ast_node = try p.parseStatement();
    defer ast_node.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("calc", ast_node.function_decl.name);
}

test "live-synth: mock offline fallback label" {
    const null_cap = cap_mod.Capability.NULL_CAP;
    const cfg = ai_provider.ProviderConfig{
        .provider_type = .mock,
        .endpoint = "mock.local",
        .port = 443,
        .use_tls = false,
        .model = "mock-model",
    };

    var aid = AiDaemon.init(std.testing.allocator, cfg, null, null_cap);
    var out: [512]u8 = undefined;
    const n = aid.dispatchPrompt("calc", &out);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "MOCK-0001") != null);
}

test "aid extract markdown code block" {
    const sample = "Directive:\n```macros\nsys_serial_write(\"OK\");\n```\nDone.";
    var code_buf: [64]u8 = undefined;
    const len = extractCodeBlock(sample, &code_buf);
    try std.testing.expect(len != null);
    try std.testing.expectEqualStrings("sys_serial_write(\"OK\");\n", code_buf[0..len.?]);
}

test "aid extract rst code block 3-space" {
    const sample =
        "Directive Narrative\n" ++
        "===================\n\n" ++
        ".. code-block:: macros\n\n" ++
        "   sys_window_draw_string(1, 20, 20, \"RST Online\", 65280, 0);\n" ++
        "   sys_serial_write(\"Active\\n\");\n\n" ++
        "Narrative continues outside code block.";
    var code_buf: [128]u8 = undefined;
    const len = extractCodeBlock(sample, &code_buf);
    try std.testing.expect(len != null);
    const expected =
        "sys_window_draw_string(1, 20, 20, \"RST Online\", 65280, 0);\n" ++
        "sys_serial_write(\"Active\\n\");\n";
    try std.testing.expectEqualStrings(expected, code_buf[0..len.?]);
}

test "aid extract rst code block 4-space" {
    const sample =
        ".. code-block:: mx\n\n" ++
        "    var x = 42;\n" ++
        "    print(x);\n\n" ++
        "End of block.";
    var code_buf: [128]u8 = undefined;
    const len = extractCodeBlock(sample, &code_buf);
    try std.testing.expect(len != null);
    const expected = "var x = 42;\nprint(x);\n";
    try std.testing.expectEqualStrings(expected, code_buf[0..len.?]);
}

test "aid extract exact gemini resident ai response" {
    const sample =
        "Writing boot banner and diagnostics to the linear GOP canvas and serial console:\n\n" ++
        ".. code-block:: macros\n\n" ++
        "   sys_serial_write(\"uOS: Operator link acknowledged. CSpace 0 verified.\\n\");\n" ++
        "   sys_window_commit(0);\n" ++
        "   sys_yield();\n" ++
        "Kernel Directives\n" ++
        "-----------------\n\n" ++
        "State your operational requirements:\n" ++
        "* Subsystem memory mapping and page allocation\n";
    var code_buf: [2048]u8 = undefined;
    const len = extractCodeBlock(sample, &code_buf);
    try std.testing.expect(len != null);
    try std.testing.expect(std.mem.indexOf(u8, code_buf[0..len.?], "Kernel Directives") == null);
    try std.testing.expect(std.mem.startsWith(u8, code_buf[0..len.?], "sys_serial_write"));
    try std.testing.expect(std.mem.endsWith(u8, code_buf[0..len.?], "sys_yield();\n"));
}
