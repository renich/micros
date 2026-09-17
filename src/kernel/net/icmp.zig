// MicrOS (µOS) Internet Control Message Protocol (ICMP)
// RFC 792 Echo Request/Reply Diagnostic Engine
// Independent of libc and host kernel services.

const std = @import("std");

pub const ICMP_TYPE_ECHO_REPLY: u8 = 0;
pub const ICMP_TYPE_ECHO_REQUEST: u8 = 8;
pub const ICMP_HEADER_LEN: usize = 8;

pub const IcmpEcho = struct {
    icmp_type: u8,
    code: u8,
    checksum: u16,
    id: u16,
    sequence: u16,
    payload: []const u8,
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

pub fn parseEcho(data: []const u8) ?IcmpEcho {
    if (data.len < ICMP_HEADER_LEN) return null;

    const icmp_type = data[0];
    if (icmp_type != ICMP_TYPE_ECHO_REQUEST and icmp_type != ICMP_TYPE_ECHO_REPLY) {
        return null;
    }

    return IcmpEcho{
        .icmp_type = icmp_type,
        .code = data[1],
        .checksum = (@as(u16, data[2]) << 8) | @as(u16, data[3]),
        .id = (@as(u16, data[4]) << 8) | @as(u16, data[5]),
        .sequence = (@as(u16, data[6]) << 8) | @as(u16, data[7]),
        .payload = data[ICMP_HEADER_LEN..],
    };
}

fn writeEchoBody(
    out_buf: []u8,
    icmp_type: u8,
    id: u16,
    seq: u16,
    payload: []const u8,
) !usize {
    const total_len = ICMP_HEADER_LEN + payload.len;
    if (out_buf.len < total_len) return error.BufferTooSmall;

    out_buf[0] = icmp_type;
    out_buf[1] = 0x00; // Code 0
    out_buf[2] = 0x00; // Zero checksum for calculation
    out_buf[3] = 0x00;
    out_buf[4] = @intCast((id >> 8) & 0xFF);
    out_buf[5] = @intCast(id & 0xFF);
    out_buf[6] = @intCast((seq >> 8) & 0xFF);
    out_buf[7] = @intCast(seq & 0xFF);
    @memcpy(out_buf[ICMP_HEADER_LEN..total_len], payload);

    const csum = calculateChecksum(out_buf[0..total_len]);
    out_buf[2] = @intCast((csum >> 8) & 0xFF);
    out_buf[3] = @intCast(csum & 0xFF);

    return total_len;
}

pub fn buildEchoReply(out_buf: []u8, req: IcmpEcho) !usize {
    return writeEchoBody(out_buf, ICMP_TYPE_ECHO_REPLY, req.id, req.sequence, req.payload);
}

pub fn buildEchoRequest(out_buf: []u8, id: u16, seq: u16, payload: []const u8) !usize {
    return writeEchoBody(out_buf, ICMP_TYPE_ECHO_REQUEST, id, seq, payload);
}

test "icmp echo parse and reply generation" {
    var req_buf: [32]u8 = undefined;
    var rep_buf: [32]u8 = undefined;
    const test_payload = "ping_micros";

    const req_len = try buildEchoRequest(&req_buf, 0x1234, 1, test_payload);
    try std.testing.expectEqual(ICMP_HEADER_LEN + test_payload.len, req_len);

    const parsed_req = parseEcho(req_buf[0..req_len]).?;
    try std.testing.expectEqual(ICMP_TYPE_ECHO_REQUEST, parsed_req.icmp_type);
    try std.testing.expectEqual(@as(u16, 0x1234), parsed_req.id);
    try std.testing.expectEqual(@as(u16, 1), parsed_req.sequence);
    try std.testing.expectEqualStrings(test_payload, parsed_req.payload);

    const rep_len = try buildEchoReply(&rep_buf, parsed_req);
    try std.testing.expectEqual(req_len, rep_len);

    const parsed_rep = parseEcho(rep_buf[0..rep_len]).?;
    try std.testing.expectEqual(ICMP_TYPE_ECHO_REPLY, parsed_rep.icmp_type);
    try std.testing.expectEqual(@as(u16, 0x1234), parsed_rep.id);
    try std.testing.expectEqual(@as(u16, 1), parsed_rep.sequence);
    try std.testing.expectEqualStrings(test_payload, parsed_rep.payload);
}
