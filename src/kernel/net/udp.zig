// MicrOS (µOS) User Datagram Protocol (UDP)
// RFC 768 Datagram Processing Engine
// Independent of libc and host kernel services.

const std = @import("std");

pub const UDP_HEADER_LEN: usize = 8;
pub const PROTO_UDP: u8 = 17;

pub const UdpHeader = struct {
    src_port: u16,
    dst_port: u16,
    length: u16,
    checksum: u16,
};

pub fn parseHeader(data: []const u8) ?UdpHeader {
    if (data.len < UDP_HEADER_LEN) return null;

    const length = (@as(u16, data[4]) << 8) | @as(u16, data[5]);
    if (data.len < length) return null;

    return UdpHeader{
        .src_port = (@as(u16, data[0]) << 8) | @as(u16, data[1]),
        .dst_port = (@as(u16, data[2]) << 8) | @as(u16, data[3]),
        .length = length,
        .checksum = (@as(u16, data[6]) << 8) | @as(u16, data[7]),
    };
}

pub fn writeHeader(
    out_buf: []u8,
    src_port: u16,
    dst_port: u16,
    payload_len: u16,
) !usize {
    const total_len = UDP_HEADER_LEN + payload_len;
    if (out_buf.len < total_len) return error.BufferTooSmall;

    out_buf[0] = @intCast((src_port >> 8) & 0xFF);
    out_buf[1] = @intCast(src_port & 0xFF);
    out_buf[2] = @intCast((dst_port >> 8) & 0xFF);
    out_buf[3] = @intCast(dst_port & 0xFF);
    out_buf[4] = @intCast((total_len >> 8) & 0xFF);
    out_buf[5] = @intCast(total_len & 0xFF);
    out_buf[6] = 0x00; // Checksum (0 = omitted in IPv4 UDP)
    out_buf[7] = 0x00;

    return UDP_HEADER_LEN;
}

pub fn calculateChecksum(src_ip: [4]u8, dst_ip: [4]u8, udp_packet: []const u8) u16 {
    var sum: u32 = 0;
    // Pseudo-header: src_ip (4) + dst_ip (4) + zero (1) + proto (1) + udp_len (2)
    sum += ((@as(u32, src_ip[0]) << 8) | src_ip[1]);
    sum += ((@as(u32, src_ip[2]) << 8) | src_ip[3]);
    sum += ((@as(u32, dst_ip[0]) << 8) | dst_ip[1]);
    sum += ((@as(u32, dst_ip[2]) << 8) | dst_ip[3]);
    sum += PROTO_UDP;
    sum += @as(u32, @intCast(udp_packet.len));

    var i: usize = 0;
    while (i + 1 < udp_packet.len) : (i += 2) {
        const word = (@as(u32, udp_packet[i]) << 8) | @as(u32, udp_packet[i + 1]);
        sum += word;
    }
    if (i < udp_packet.len) {
        sum += @as(u32, udp_packet[i]) << 8;
    }

    while ((sum >> 16) != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    const csum = @as(u16, @intCast(~sum & 0xFFFF));
    return if (csum == 0) 0xFFFF else csum;
}

test "udp header parse and serialize" {
    var buf: [32]u8 = undefined;
    const hdr_len = try writeHeader(&buf, 68, 67, 10);
    try std.testing.expectEqual(UDP_HEADER_LEN, hdr_len);

    const parsed = parseHeader(buf[0 .. UDP_HEADER_LEN + 10]).?;
    try std.testing.expectEqual(@as(u16, 68), parsed.src_port);
    try std.testing.expectEqual(@as(u16, 67), parsed.dst_port);
    try std.testing.expectEqual(@as(u16, 18), parsed.length);
}
