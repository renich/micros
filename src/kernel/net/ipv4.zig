// MicrOS (µOS) IPv4 Packet Processing & RFC 791 Protocol Engine
// Freestanding L3 Layer implementation.
// Independent of libc and host kernel services.

const std = @import("std");

pub const PROTO_ICMP: u8 = 1;
pub const PROTO_TCP: u8 = 6;
pub const PROTO_UDP: u8 = 17;

pub const IPV4_MIN_HEADER_LEN: usize = 20;
pub const DEFAULT_TTL: u8 = 64;
pub const FLAG_DONT_FRAGMENT: u16 = 0x4000;

pub const Ipv4Header = struct {
    version: u4,
    ihl: u4,
    tos: u8,
    total_len: u16,
    id: u16,
    flags_frag: u16,
    ttl: u8,
    protocol: u8,
    checksum: u16,
    src_ip: [4]u8,
    dst_ip: [4]u8,
};

pub fn calculateChecksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        const word = (@as(u32, bytes[i]) << 8) | @as(u32, bytes[i + 1]);
        sum += word;
    }
    if (i < bytes.len) {
        sum += @as(u32, bytes[i]) << 8;
    }
    while ((sum >> 16) != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @intCast(~sum & 0xFFFF);
}

pub fn parseHeader(packet: []const u8) ?Ipv4Header {
    if (packet.len < IPV4_MIN_HEADER_LEN) return null;

    const ver_ihl = packet[0];
    const version: u4 = @truncate(ver_ihl >> 4);
    const ihl: u4 = @truncate(ver_ihl & 0x0F);
    if (version != 4 or ihl < 5) return null;

    const header_len = @as(usize, ihl) * 4;
    if (packet.len < header_len) return null;

    var src: [4]u8 = undefined;
    var dst: [4]u8 = undefined;
    @memcpy(&src, packet[12..16]);
    @memcpy(&dst, packet[16..20]);

    return Ipv4Header{
        .version = version,
        .ihl = ihl,
        .tos = packet[1],
        .total_len = (@as(u16, packet[2]) << 8) | @as(u16, packet[3]),
        .id = (@as(u16, packet[4]) << 8) | @as(u16, packet[5]),
        .flags_frag = (@as(u16, packet[6]) << 8) | @as(u16, packet[7]),
        .ttl = packet[8],
        .protocol = packet[9],
        .checksum = (@as(u16, packet[10]) << 8) | @as(u16, packet[11]),
        .src_ip = src,
        .dst_ip = dst,
    };
}

pub fn writeHeader(
    out_buf: []u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    protocol: u8,
    payload_len: u16,
    id: u16,
) !usize {
    if (out_buf.len < IPV4_MIN_HEADER_LEN) return error.BufferTooSmall;

    const total_len: u16 = @intCast(IPV4_MIN_HEADER_LEN + payload_len);
    out_buf[0] = 0x45; // Version 4, IHL 5 (20 bytes)
    out_buf[1] = 0x00; // DSCP/ECN
    out_buf[2] = @intCast((total_len >> 8) & 0xFF);
    out_buf[3] = @intCast(total_len & 0xFF);
    out_buf[4] = @intCast((id >> 8) & 0xFF);
    out_buf[5] = @intCast(id & 0xFF);
    out_buf[6] = @intCast((FLAG_DONT_FRAGMENT >> 8) & 0xFF);
    out_buf[7] = @intCast(FLAG_DONT_FRAGMENT & 0xFF);
    out_buf[8] = DEFAULT_TTL;
    out_buf[9] = protocol;
    out_buf[10] = 0x00; // Zero checksum for calculation
    out_buf[11] = 0x00;
    @memcpy(out_buf[12..16], &src_ip);
    @memcpy(out_buf[16..20], &dst_ip);

    const csum = calculateChecksum(out_buf[0..IPV4_MIN_HEADER_LEN]);
    out_buf[10] = @intCast((csum >> 8) & 0xFF);
    out_buf[11] = @intCast(csum & 0xFF);

    return IPV4_MIN_HEADER_LEN;
}

test "ipv4 checksum calculation and validation" {
    const hdr = [_]u8{
        0x45, 0x00, 0x00, 0x3C, 0x1C, 0x46, 0x40, 0x00,
        0x40, 0x06, 0x00, 0x00, 0xAC, 0x10, 0x0A, 0x63,
        0xAC, 0x10, 0x0A, 0x0C,
    };
    const csum = calculateChecksum(&hdr);
    try std.testing.expectEqual(@as(u16, 0xB1E6), csum);
}

test "ipv4 write and parse header roundtrip" {
    var buf: [64]u8 = undefined;
    const src = [_]u8{ 10, 0, 2, 15 };
    const dst = [_]u8{ 10, 0, 2, 2 };

    const hdr_len = try writeHeader(&buf, src, dst, PROTO_ICMP, 32, 0x1234);
    try std.testing.expectEqual(IPV4_MIN_HEADER_LEN, hdr_len);

    // Verify written header checksum verifies to 0
    try std.testing.expectEqual(@as(u16, 0), calculateChecksum(buf[0..hdr_len]));

    const parsed = parseHeader(buf[0..hdr_len]).?;
    try std.testing.expectEqual(@as(u4, 4), parsed.version);
    try std.testing.expectEqual(@as(u4, 5), parsed.ihl);
    try std.testing.expectEqual(@as(u16, 52), parsed.total_len);
    try std.testing.expectEqual(PROTO_ICMP, parsed.protocol);
    try std.testing.expectEqualSlices(u8, &src, &parsed.src_ip);
    try std.testing.expectEqualSlices(u8, &dst, &parsed.dst_ip);
}
