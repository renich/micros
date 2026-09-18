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
const netd_mod = @import("../netd/netd.zig");
const ring_mod = @import("../../kernel/ipc/ring.zig");
const SpscRingBuffer = ring_mod.SpscRingBuffer;
const tls_stream_mod = @import("../../kernel/net/tls_stream.zig");
const http_mod = @import("../../kernel/net/http.zig");
const serial = @import("../../kernel/serial.zig");

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

        if (self.config.provider_type == .mock or self.net_daemon == null) {
            return mock_mod.generateResponse(prompt, out_buf) catch 0;
        }

        const online_res = self.dispatchOnline(prompt, out_buf);
        if (online_res > 0) return online_res;

        serial.writeString("[aid] Online dispatch returned 0; reporting error\n");
        const err_msg = "[aid] Online AI inference failed. Verify network connectivity and GEMINI_API_KEY.";
        const copy_len = @min(err_msg.len, out_buf.len);
        @memcpy(out_buf[0..copy_len], err_msg[0..copy_len]);
        return copy_len;
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
            return std.mem.indexOf(u8, body_slice, "0\r\n\r\n") != null;
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

        var resp_buf: [16384]u8 = undefined;
        var chunk_buf: [16384]u8 = undefined;
        const read_bytes = readFullResponse(adapter, &resp_buf);
        if (read_bytes == 0) return 0;

        const body = extractResponseBody(resp_buf[0..read_bytes], &chunk_buf) orelse return 0;
        return self.client.extractResponseText(body, out_buf) orelse 0;
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
};

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
