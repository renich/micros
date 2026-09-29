// MicrOS (µOS) Sovereign TLS 1.3 Transport Stream Adapter
// Bridges std.crypto.tls.Client with the raw freestanding NetworkStack and TCP client.
// Zero libc, freestanding, capability-compatible.

const std = @import("std");
const stack_mod = @import("stack.zig");
const serial = @import("../serial.zig");
const io = @import("../arch/x86_64/io.zig");
const fiber_mod = @import("../../macros/fiber.zig");

const builtin = @import("builtin");
const is_uefi = builtin.os.tag == .uefi;

const spki = @import("spki.zig");
pub const BUFFER_SIZE_READER: usize = 65536;
pub const BUFFER_SIZE_WRITER: usize = 32768;
pub const BUFFER_SIZE_TLS_READ: usize = 65536;
pub const BUFFER_SIZE_TLS_WRITE: usize = 32768;
pub const ENTROPY_LEN: usize = std.crypto.tls.Client.Options.entropy_len;
pub const DEFAULT_TIMESTAMP_SEC: i64 = 1789624912;
const DRAIN_TIMEOUT_ITERS: usize = 20_000_000;

pub const TlsClientType = @import("tls_client.zig");
pub const TLS_VERIFICATION_STATUS: []const u8 = "SPKI_PINNED (RFC 7469 Subject Public Key Info pinning active)";

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
    tls_client: ?TlsClientType = null,
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

    fn fillEntropy(self: *TcpStreamAdapter) void {
        var i: usize = 0;
        while (i < ENTROPY_LEN) {
            const val = io.getEntropy64(0x5A5AA5A512345678 +% @as(u64, @intCast(i)));
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

        var status_buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&status_buf, "TLS 1.3 SPKI pinning active for {s}", .{hostname})) |msg| {
            serial.writeStatusOk("tls ", msg);
        } else |_| {
            serial.writeStatusOk("tls ", "TLS 1.3 SPKI pinning active");
        }

        self.tls_client = try TlsClientType.init(
            &self.reader_interface,
            &self.writer_interface,
            .{
                .host = .{ .explicit = hostname },
                .ca = .no_verification,
                .spki_pin_verifier = spki.verifySpkiPin,
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
        const client = if (self.tls_client) |*c| c else return error.NotConnected;
        try client.writer.writeAll(data);
        try client.writer.flush();
        try self.writer_interface.flush();
    }

    pub fn readSlice(self: *TcpStreamAdapter, dest: []u8) !usize {
        const client = if (self.tls_client) |*c| c else return error.NotConnected;
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
        _ = adapter.stack.poll();
        io.ioWait();
        if ((iters & 0x3F) == 0) fiber_mod.yield();
        if (isTcpEof(adapter)) break;
    }
    if (adapter.stack.tcp_rx_len == 0) {
        if (isTcpEof(adapter)) {
            return error.EndOfStream;
        }
        serial.writeString("[tls] streamFn: TIMEOUT waiting for RX!\n");
        return error.ReadFailed;
    }
}

fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const adapter: *TcpStreamAdapter = @alignCast(@fieldParentPtr("reader_interface", r));
    const max_to_write = @intFromEnum(limit);
    if (max_to_write == 0) return 0;

    try waitForRx(adapter);

    const dest = limit.slice(w.writableSliceGreedy(1) catch return error.WriteFailed);
    const read_len = adapter.stack.readTcpData(dest);
    if (read_len == 0) return error.EndOfStream;
    w.advance(read_len);
    return read_len;
}

test "tls stream adapter type verification" {
    if (is_uefi) return;
    try std.testing.expect(BUFFER_SIZE_READER >= std.crypto.tls.Client.min_buffer_len);
    try std.testing.expect(BUFFER_SIZE_WRITER >= std.crypto.tls.Client.min_buffer_len);
    try std.testing.expectEqual(@as(usize, 240), ENTROPY_LEN);
}

pub fn extractSpkiSha256(cert_der: []const u8) ![32]u8 {
    const cert: std.crypto.Certificate = .{
        .buffer = cert_der,
        .index = 0,
    };
    const parsed = try cert.parse();
    const spki_start = parsed.subject_slice.end;
    const spki_elem = try std.crypto.Certificate.der.Element.parse(cert_der, spki_start);
    const spki_bytes = cert_der[spki_start..spki_elem.slice.end];

    var pin: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(spki_bytes, &pin, .{});
    return pin;
}

const FIXTURE_CERT_PRIMARY_HEX = "3082018c30820133a0030201020214323fe5671b8cba67163505da05e9ace510d5ca05300a06082a8648ce3d040302301c311a301806035504030c11746573742e6d6963726f732e6c6f63616c301e170d3236303932393038323931375a170d3236303933303038323931375a301c311a301806035504030c11746573742e6d6963726f732e6c6f63616c3059301306072a8648ce3d020106082a8648ce3d03010703420004faa75102986ea0dbc6aeceb69d1fa609751f938eb2891f1b3065b1a526f94007f426b5b671f2b1e550f519770105186b25ba6bce2e72f375bc1be1b9a118eb22a3533051301d0603551d0e041604142502f24732a3ab5dc78a5ff4b10299bc6f3ba527301f0603551d230418301680142502f24732a3ab5dc78a5ff4b10299bc6f3ba527300f0603551d130101ff040530030101ff300a06082a8648ce3d040302034700304402206c8e2409962c8632739bdf2c8443d7577f4b59b50c273704e594e0817b5bc74a0220751968ad938a3a8fccb702b792856b80b954a51a6ececb07c989526d4373afcd";

const FIXTURE_CERT_BACKUP_HEX = "3082013b3081e2a00302010202140e3271f2c5801fe0baf232322d8d6173f339cc95300a06082a8648ce3d040302301e311c301a06035504030c136261636b75702e6d6963726f732e6c6f63616c301e170d3236303932393038343531355a170d3236303933303038343531355a301e311c301a06035504030c136261636b75702e6d6963726f732e6c6f63616c3059301306072a8648ce3d020106082a8648ce3d030107034200047b9d0d66421cac105b47653ff02a4e575029b596a7b50c5cf714c3196a0f17f4e4c8de248d4f38359213132744d313b85bda89b6255b082ff3a5409bed3847ee300a06082a8648ce3d0403020348003045022100f6cac6ea37976cad573e8173dffe2fb72a39a57dfb2453ff4a0bbdaf489c9cec022018339bc82b1348e7a5f2483aa89e3abe3794072d7d071a144c3f9e909f1b265e";

test "spki spike: parse fixture cert, extract SubjectPublicKeyInfo, and compute SHA-256 pin" {
    if (is_uefi) return;
    var cert_der: [FIXTURE_CERT_PRIMARY_HEX.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&cert_der, FIXTURE_CERT_PRIMARY_HEX);

    const pin = try extractSpkiSha256(&cert_der);
    const pin_hex = std.fmt.bytesToHex(pin, .lower);

    const expected_hex = "faf445c04c0e0e9e3dbfe7f629cf624400d6c3c5e84ef1cbdb157d6a83a40351";
    try std.testing.expectEqualStrings(expected_hex, &pin_hex);
    try std.testing.expect(std.crypto.timing_safe.eql([32]u8, pin, pin));
}

test "tls: SPKI primary pin match succeeds" {
    if (is_uefi) return;
    var cert_der: [FIXTURE_CERT_PRIMARY_HEX.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&cert_der, FIXTURE_CERT_PRIMARY_HEX);

    try spki.verifySpkiPin("test.micros.local", &cert_der);
}

test "tls: SPKI backup pin match succeeds" {
    if (is_uefi) return;
    var cert_der: [FIXTURE_CERT_BACKUP_HEX.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&cert_der, FIXTURE_CERT_BACKUP_HEX);

    try spki.verifySpkiPin("test.micros.local", &cert_der);
}

test "tls: SPKI mismatch fails closed with error.CertificatePinMismatch" {
    if (is_uefi) return;
    var cert_der_backup: [FIXTURE_CERT_BACKUP_HEX.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&cert_der_backup, FIXTURE_CERT_BACKUP_HEX);

    // Valid X.509 cert whose SPKI hash does not match generativelanguage.googleapis.com
    try std.testing.expectError(error.CertificatePinMismatch, spki.verifySpkiPin("generativelanguage.googleapis.com", &cert_der_backup));

    // Tampered / corrupted certificate also fails closed with CertificatePinMismatch
    var cert_der_primary: [FIXTURE_CERT_PRIMARY_HEX.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&cert_der_primary, FIXTURE_CERT_PRIMARY_HEX);
    cert_der_primary[115] ^= 0xFF;
    try std.testing.expectError(error.CertificatePinMismatch, spki.verifySpkiPin("test.micros.local", &cert_der_primary));
}

test "tls: unpinned downgrade rejected fail-closed by default" {
    if (is_uefi) return;
    var cert_der: [FIXTURE_CERT_PRIMARY_HEX.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&cert_der, FIXTURE_CERT_PRIMARY_HEX);

    // Default: allow_unpinned = false. Unknown endpoint fails closed.
    spki.allow_unpinned = false;
    try std.testing.expectError(error.CertificatePinMismatch, spki.verifySpkiPin("rogue.unpinned.net", &cert_der));

    // Explicit override allowed for dev
    spki.allow_unpinned = true;
    defer spki.allow_unpinned = false;
    try spki.verifySpkiPin("rogue.unpinned.net", &cert_der);
}

test "tls: exercises std.crypto.timing_safe.eql comparison path" {
    if (is_uefi) return;
    const pin_a: [32]u8 = [_]u8{0xAA} ** 32;
    var pin_b: [32]u8 = [_]u8{0xAA} ** 32;

    try std.testing.expect(std.crypto.timing_safe.eql([32]u8, pin_a, pin_b));

    pin_b[31] ^= 0x01;
    try std.testing.expect(!std.crypto.timing_safe.eql([32]u8, pin_a, pin_b));
}
