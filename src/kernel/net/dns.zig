// MicrOS (µOS) Domain Name System (DNS) Resolver
// RFC 1035 Pure Freestanding Client for A-Record Resolution
// Independent of libc and host kernel services.

const std = @import("std");

pub const PORT_DNS: u16 = 53;
pub const DNS_HEADER_LEN: usize = 12;
pub const TYPE_A: u16 = 1;
pub const CLASS_IN: u16 = 1;
pub const FLAGS_STANDARD_QUERY: u16 = 0x0100;

pub const DnsHeader = struct {
    id: u16,
    flags: u16,
    qdcount: u16,
    ancount: u16,
    nscount: u16,
    arcount: u16,
};

pub fn buildQuery(out_buf: []u8, hostname: []const u8, query_id: u16) !usize {
    if (out_buf.len < DNS_HEADER_LEN + hostname.len + 6) return error.BufferTooSmall;

    // Header
    out_buf[0] = @intCast((query_id >> 8) & 0xFF);
    out_buf[1] = @intCast(query_id & 0xFF);
    out_buf[2] = @intCast((FLAGS_STANDARD_QUERY >> 8) & 0xFF);
    out_buf[3] = @intCast(FLAGS_STANDARD_QUERY & 0xFF);
    out_buf[4] = 0x00; // QDCOUNT = 1
    out_buf[5] = 0x01;
    out_buf[6] = 0x00; // ANCOUNT = 0
    out_buf[7] = 0x00;
    out_buf[8] = 0x00; // NSCOUNT = 0
    out_buf[9] = 0x00;
    out_buf[10] = 0x00; // ARCOUNT = 0
    out_buf[11] = 0x00;

    var idx: usize = DNS_HEADER_LEN;
    var label_start: usize = 0;
    for (hostname, 0..) |c, i| {
        if (c == '.') {
            const label_len: u8 = @intCast(i - label_start);
            out_buf[idx] = label_len;
            idx += 1;
            @memcpy(out_buf[idx .. idx + label_len], hostname[label_start..i]);
            idx += label_len;
            label_start = i + 1;
        }
    }
    if (label_start < hostname.len) {
        const label_len: u8 = @intCast(hostname.len - label_start);
        out_buf[idx] = label_len;
        idx += 1;
        @memcpy(out_buf[idx .. idx + label_len], hostname[label_start..]);
        idx += label_len;
    }
    out_buf[idx] = 0x00; // End of QNAME
    idx += 1;

    // QTYPE = A (1)
    out_buf[idx] = @intCast((TYPE_A >> 8) & 0xFF);
    out_buf[idx + 1] = @intCast(TYPE_A & 0xFF);
    // QCLASS = IN (1)
    out_buf[idx + 2] = @intCast((CLASS_IN >> 8) & 0xFF);
    out_buf[idx + 3] = @intCast(CLASS_IN & 0xFF);
    idx += 4;

    return idx;
}

fn skipName(data: []const u8, start_offset: usize) ?usize {
    var idx = start_offset;
    while (idx < data.len) {
        const len = data[idx];
        if (len == 0) return idx + 1;
        if ((len & 0xC0) == 0xC0) {
            return idx + 2; // Pointer
        }
        idx += 1 + @as(usize, len);
    }
    return null;
}

pub fn parseResponse(payload: []const u8, expected_id: u16) ?[4]u8 {
    if (payload.len < DNS_HEADER_LEN) return null;

    const id = (@as(u16, payload[0]) << 8) | @as(u16, payload[1]);
    const flags = (@as(u16, payload[2]) << 8) | @as(u16, payload[3]);
    const ancount = (@as(u16, payload[6]) << 8) | @as(u16, payload[7]);

    if (id != expected_id or (flags & 0x8000) == 0 or ancount == 0) return null;

    // Skip question section
    var idx = skipName(payload, DNS_HEADER_LEN) orelse return null;
    idx += 4; // Skip QTYPE and QCLASS

    // Parse answers
    var a: u16 = 0;
    while (a < ancount and idx < payload.len) : (a += 1) {
        idx = skipName(payload, idx) orelse return null;
        if (idx + 10 > payload.len) return null;

        const atype = (@as(u16, payload[idx]) << 8) | @as(u16, payload[idx + 1]);
        const aclass = (@as(u16, payload[idx + 2]) << 8) | @as(u16, payload[idx + 3]);
        const rdlength = (@as(u16, payload[idx + 8]) << 8) | @as(u16, payload[idx + 9]);
        idx += 10;

        if (atype == TYPE_A and aclass == CLASS_IN and rdlength == 4) {
            if (idx + 4 > payload.len) return null;
            var ip: [4]u8 = undefined;
            @memcpy(&ip, payload[idx .. idx + 4]);
            return ip;
        }
        idx += rdlength;
    }

    return null;
}

test "dns query format generation" {
    var buf: [256]u8 = undefined;
    const len = try buildQuery(&buf, "google.com", 0x1234);
    try std.testing.expect(len > DNS_HEADER_LEN);
    try std.testing.expectEqual(@as(u16, 0x1234), (@as(u16, buf[0]) << 8) | buf[1]);
    try std.testing.expectEqual(@as(u8, 6), buf[12]); // "google" length
    try std.testing.expectEqualStrings("google", buf[13..19]);
    try std.testing.expectEqual(@as(u8, 3), buf[19]); // "com" length
    try std.testing.expectEqualStrings("com", buf[20..23]);
    try std.testing.expectEqual(@as(u8, 0), buf[23]);
}

test "dns answer parse" {
    var query_buf: [128]u8 = undefined;
    const qlen = try buildQuery(&query_buf, "micros.org", 0xABCD);

    // Build mock response by appending an answer
    var resp_buf: [256]u8 = undefined;
    @memcpy(resp_buf[0..qlen], query_buf[0..qlen]);
    resp_buf[2] = 0x81; // Standard response, No error
    resp_buf[3] = 0x80;
    resp_buf[6] = 0x00; // ANCOUNT = 1
    resp_buf[7] = 0x01;

    var idx = qlen;
    // Pointer to name at offset 12 (0xC00C)
    resp_buf[idx] = 0xC0;
    resp_buf[idx + 1] = 0x0C;
    idx += 2;

    // Type A, Class IN, TTL 60
    resp_buf[idx] = 0x00;
    resp_buf[idx + 1] = 0x01;
    resp_buf[idx + 2] = 0x00;
    resp_buf[idx + 3] = 0x01;
    resp_buf[idx + 4] = 0x00;
    resp_buf[idx + 5] = 0x00;
    resp_buf[idx + 6] = 0x00;
    resp_buf[idx + 7] = 0x3C;
    // RDLENGTH = 4
    resp_buf[idx + 8] = 0x00;
    resp_buf[idx + 9] = 0x04;
    // IP 142.250.190.46
    resp_buf[idx + 10] = 142;
    resp_buf[idx + 11] = 250;
    resp_buf[idx + 12] = 190;
    resp_buf[idx + 13] = 46;
    idx += 14;

    const ip = parseResponse(resp_buf[0..idx], 0xABCD).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 142, 250, 190, 46 }, &ip);
}
