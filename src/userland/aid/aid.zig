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

        return mock_mod.generateResponse(prompt, out_buf) catch 0;
    }

    fn dispatchOnline(
        self: *AiDaemon,
        prompt: []const u8,
        out_buf: []u8,
    ) usize {
        const net_d = self.net_daemon orelse return 0;
        const adapter = self.tls_adapter orelse return 0;

        var req_buf: [4096]u8 = undefined;
        var body_buf: [4096]u8 = undefined;
        const req_len = self.client.formatPromptRequest(&req_buf, &body_buf, prompt) catch return 0;

        if (!adapter.connected) {
            const ip = net_d.resolveDns(self.config.endpoint) catch return 0;
            const connected = net_d.connectTcp(ip, self.config.port) catch false;
            if (!connected) return 0;
            adapter.handshake(self.config.endpoint) catch return 0;
        }

        adapter.writeAll(req_buf[0..req_len]) catch return 0;

        var resp_buf: [8192]u8 = undefined;
        const read_bytes = adapter.readSlice(&resp_buf) catch return 0;
        if (read_bytes == 0) return 0;

        const resp = http_mod.parseResponseHeaders(&resp_buf, read_bytes) catch return 0;
        if (resp.body_offset >= read_bytes) return 0;
        const body = resp_buf[resp.body_offset..read_bytes];
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

        while (!rx.isEmpty() and prompt_len < prompt_buf.len) : (prompt_len += 1) {
            const b = rx.readByte() orelse break;
            if (b == 0) break;
            prompt_buf[prompt_len] = b;
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
