// MicrOS (µOS) Sovereign TLS 1.3 Transport Stream Adapter
// Bridges std.crypto.tls.Client with the raw freestanding NetworkStack and TCP client.
// Zero libc, freestanding, capability-compatible.

const std = @import("std");
const stack_mod = @import("stack.zig");
const serial = @import("../serial.zig");
const io = @import("../arch/x86_64/io.zig");

pub const BUFFER_SIZE_READER: usize = 65536;
pub const BUFFER_SIZE_WRITER: usize = 32768;
pub const BUFFER_SIZE_TLS_READ: usize = 65536;
pub const BUFFER_SIZE_TLS_WRITE: usize = 32768;
pub const ENTROPY_LEN: usize = std.crypto.tls.Client.Options.entropy_len;
pub const DEFAULT_TIMESTAMP_SEC: i64 = 1789624912;
const DRAIN_TIMEOUT_ITERS: usize = 20_000_000;

const writer_vtable: std.Io.Writer.VTable = .{
    .drain = drainFn,
};

const reader_vtable: std.Io.Reader.VTable = .{
    .stream = streamFn,
};

pub const TcpStreamAdapter = struct {
    stack: *stack_mod.NetworkStack,
    reader_buf: [BUFFER_SIZE_READER]u8 = undefined,
    writer_buf: [BUFFER_SIZE_WRITER]u8 = undefined,
    tls_read_buf: [BUFFER_SIZE_TLS_READ]u8 = undefined,
    tls_write_buf: [BUFFER_SIZE_TLS_WRITE]u8 = undefined,
    reader_interface: std.Io.Reader = undefined,
    writer_interface: std.Io.Writer = undefined,
    tls_client: ?std.crypto.tls.Client = null,
    entropy: [ENTROPY_LEN]u8 = undefined,
    connected: bool = false,

    pub fn init(self: *TcpStreamAdapter, stack: *stack_mod.NetworkStack) void {
        self.stack = stack;
        self.tls_client = null;
        self.connected = false;
        self.reader_interface = .{
            .vtable = &reader_vtable,
            .buffer = &self.reader_buf,
            .seek = 0,
            .end = 0,
        };
        self.writer_interface = .{
            .vtable = &writer_vtable,
            .buffer = &self.writer_buf,
            .end = 0,
        };
    }

    pub fn fillEntropy(self: *TcpStreamAdapter) void {
        var i: usize = 0;
        while (i < ENTROPY_LEN) {
            var rax_val: u64 = undefined;
            var rdx_val: u64 = undefined;
            asm volatile (
                \\rdtsc
                : [rax_val] "={rax}" (rax_val),
                  [rdx_val] "={rdx}" (rdx_val),
            );
            var val: u64 = (rdx_val << 32) | rax_val;

            var rdrand_val: u64 = 0;
            var success: u8 = 0;
            asm volatile (
                \\rdrand %[rdrand_val]
                \\setc %[success]
                : [rdrand_val] "=r" (rdrand_val),
                  [success] "=r" (success),
            );
            if (success != 0 and rdrand_val != 0) {
                val ^= rdrand_val;
            }

            if (val == 0) val = 0x5A5AA5A512345678 +% @as(u64, @intCast(i));
            const bytes: [8]u8 = @bitCast(val);
            const chunk = @min(8, ENTROPY_LEN - i);
            @memcpy(self.entropy[i .. i + chunk], bytes[0..chunk]);
            i += chunk;
        }
    }

    pub fn handshake(self: *TcpStreamAdapter, hostname: []const u8) !void {
        self.fillEntropy();
        const now_ts = std.Io.Timestamp{
            .nanoseconds = DEFAULT_TIMESTAMP_SEC * std.time.ns_per_s,
        };

        self.tls_client = try std.crypto.tls.Client.init(
            &self.reader_interface,
            &self.writer_interface,
            .{
                .host = .{ .explicit = hostname },
                .ca = .no_verification,
                .read_buffer = &self.tls_read_buf,
                .write_buffer = &self.tls_write_buf,
                .entropy = &self.entropy,
                .realtime_now = now_ts,
                .allow_truncation_attacks = true,
            },
        );
        self.connected = true;
    }

    pub fn writeAll(self: *TcpStreamAdapter, data: []const u8) !void {
        const client = &(self.tls_client orelse return error.NotConnected);
        try client.writer.writeAll(data);
        try client.writer.flush();
        try self.writer_interface.flush();
    }

    pub fn readSlice(self: *TcpStreamAdapter, dest: []u8) !usize {
        const client = &(self.tls_client orelse return error.NotConnected);
        return try client.reader.readSliceShort(dest);
    }

    pub fn close(self: *TcpStreamAdapter) void {
        self.connected = false;
        self.tls_client = null;
        self.stack.closeTcp() catch {};
    }
};

fn drainFn(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const adapter: *TcpStreamAdapter = @alignCast(@fieldParentPtr("writer_interface", w));
    serial.writeString("[tls] drainFn: buffered=");
    serial.writeHex(@intCast(w.buffered().len));
    serial.writeString(" data.len=");
    serial.writeHex(@intCast(data.len));
    serial.writeString("\n");
    if (w.buffered().len > 0) {
        adapter.stack.sendTcpData(w.buffered()) catch return error.WriteFailed;
        w.end = 0;
    }
    var n: usize = 0;
    if (data.len > 0) {
        for (data[0 .. data.len - 1]) |slice| {
            adapter.stack.sendTcpData(slice) catch return error.WriteFailed;
            n += slice.len;
        }
        for (0..splat) |_| {
            adapter.stack.sendTcpData(data[data.len - 1]) catch return error.WriteFailed;
        }
        n += splat * data[data.len - 1].len;
    }
    return n;
}

fn isTcpEof(adapter: *const TcpStreamAdapter) bool {
    if (adapter.stack.tcp_rx_len > 0) return false;
    const client = adapter.stack.tcp_client orelse return false;
    return client.state == .closed or client.state == .time_wait;
}

fn waitForRx(adapter: *TcpStreamAdapter) std.Io.Reader.StreamError!void {
    var iters: usize = 0;
    while (adapter.stack.tcp_rx_len == 0 and iters < DRAIN_TIMEOUT_ITERS) : (iters += 1) {
        adapter.stack.poll();
        io.ioWait();
        if (isTcpEof(adapter)) break;
    }
    if (adapter.stack.tcp_rx_len == 0) {
        if (isTcpEof(adapter)) {
            serial.writeString("[tls] streamFn: EOF (remote closed connection)\n");
            return error.EndOfStream;
        }
        serial.writeString("[tls] streamFn: TIMEOUT waiting for RX!\n");
        return error.ReadFailed;
    }
}

fn logTlsRecords(dest: []const u8, read_len: usize) void {
    var off: usize = 0;
    while (off + 5 <= read_len) {
        const ct = dest[off];
        const v = (@as(u16, dest[off + 1]) << 8) | dest[off + 2];
        const rlen = (@as(u16, dest[off + 3]) << 8) | dest[off + 4];
        serial.writeString("[tls] Record @");
        serial.writeHex(@intCast(off));
        serial.writeString(" ct=0x");
        serial.writeHex(ct);
        serial.writeString(" ver=0x");
        serial.writeHex(v);
        serial.writeString(" len=0x");
        serial.writeHex(rlen);
        serial.writeString("\n");
        off += 5 + rlen;
    }
    if (off < read_len) {
        serial.writeString("[tls] Incomplete trailing record bytes=");
        serial.writeHex(@intCast(read_len - off));
        serial.writeString("\n");
    }
}

fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const adapter: *TcpStreamAdapter = @alignCast(@fieldParentPtr("reader_interface", r));
    const max_to_write = @intFromEnum(limit);
    if (max_to_write == 0) return 0;

    serial.writeString("[tls] streamFn: waiting for RX...\n");
    try waitForRx(adapter);

    serial.writeString("[tls] streamFn: got RX data! len=");
    serial.writeHex(@intCast(adapter.stack.tcp_rx_len));
    serial.writeString("\n");

    const dest = limit.slice(w.writableSliceGreedy(1) catch return error.WriteFailed);
    const read_len = adapter.stack.readTcpData(dest);
    if (read_len == 0) return error.EndOfStream;
    w.advance(read_len);

    logTlsRecords(dest, read_len);
    return read_len;
}

test "tls stream adapter type verification" {
    try std.testing.expect(BUFFER_SIZE_READER >= std.crypto.tls.Client.min_buffer_len);
    try std.testing.expect(BUFFER_SIZE_WRITER >= std.crypto.tls.Client.min_buffer_len);
    try std.testing.expectEqual(@as(usize, 240), ENTROPY_LEN);
}
