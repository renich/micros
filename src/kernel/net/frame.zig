// MicrOS (µOS) Ethernet II Frame Serialization & Parsing
// Freestanding L2 Layer implementation compliant with IEEE 802.3.
// Independent of libc and host kernel services.

const std = @import("std");

pub const ETHERTYPE_IPV4: u16 = 0x0800;
pub const ETHERTYPE_ARP: u16 = 0x0806;
pub const ETHERTYPE_IPV6: u16 = 0x86DD;

pub const ETHERNET_HEADER_LEN: usize = 14;
pub const MAX_ETHERNET_FRAME: usize = 1514;
pub const MIN_ETHERNET_FRAME: usize = 60;

pub const BROADCAST_MAC: [6]u8 = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
pub const ZERO_MAC: [6]u8 = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

pub const EthernetHeader = struct {
    dst_mac: [6]u8,
    src_mac: [6]u8,
    ethertype: u16,

    pub fn isBroadcast(self: EthernetHeader) bool {
        return std.mem.eql(u8, &self.dst_mac, &BROADCAST_MAC);
    }
};

pub fn parseHeader(frame: []const u8) ?EthernetHeader {
    if (frame.len < ETHERNET_HEADER_LEN) return null;

    var dst: [6]u8 = undefined;
    var src: [6]u8 = undefined;
    @memcpy(&dst, frame[0..6]);
    @memcpy(&src, frame[6..12]);

    const ethertype = (@as(u16, frame[12]) << 8) | @as(u16, frame[13]);

    return EthernetHeader{
        .dst_mac = dst,
        .src_mac = src,
        .ethertype = ethertype,
    };
}

pub fn getPayload(frame: []const u8) []const u8 {
    if (frame.len < ETHERNET_HEADER_LEN) return frame[0..0];
    return frame[ETHERNET_HEADER_LEN..];
}

pub fn writeHeader(out_buf: []u8, dst_mac: [6]u8, src_mac: [6]u8, ethertype: u16) !void {
    if (out_buf.len < ETHERNET_HEADER_LEN) return error.BufferTooSmall;

    @memcpy(out_buf[0..6], &dst_mac);
    @memcpy(out_buf[6..12], &src_mac);
    out_buf[12] = @intCast((ethertype >> 8) & 0xFF);
    out_buf[13] = @intCast(ethertype & 0xFF);
}

test "ethernet header parse and serialize" {
    var buf: [MAX_ETHERNET_FRAME]u8 = undefined;
    const src = [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    const dst = BROADCAST_MAC;

    try writeHeader(&buf, dst, src, ETHERTYPE_IPV4);
    const parsed = parseHeader(buf[0..ETHERNET_HEADER_LEN]).?;

    try std.testing.expectEqualSlices(u8, &dst, &parsed.dst_mac);
    try std.testing.expectEqualSlices(u8, &src, &parsed.src_mac);
    try std.testing.expectEqual(ETHERTYPE_IPV4, parsed.ethertype);
    try std.testing.expect(parsed.isBroadcast());
}

test "ethernet buffer bounds checking" {
    var tiny_buf: [10]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, writeHeader(&tiny_buf, ZERO_MAC, ZERO_MAC, ETHERTYPE_ARP));
    try std.testing.expect(parseHeader(&tiny_buf) == null);
}
