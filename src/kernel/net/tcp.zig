// MicrOS (µOS) Transmission Control Protocol (TCP)
// RFC 793 Client State Machine for Dedicated HTTPS/TLS Stream Transport
// Independent of libc and host kernel services.

const std = @import("std");

pub const TCP_HEADER_MIN_LEN: usize = 20;
pub const PROTO_TCP: u8 = 6;

pub const FLAG_FIN: u9 = 0x001;
pub const FLAG_SYN: u9 = 0x002;
pub const FLAG_RST: u9 = 0x004;
pub const FLAG_PSH: u9 = 0x008;
pub const FLAG_ACK: u9 = 0x010;
pub const FLAG_URG: u9 = 0x020;

pub const DEFAULT_WINDOW: u16 = 16384;

pub const TcpState = enum {
    closed,
    syn_sent,
    established,
    fin_wait,
    time_wait,
};

pub const TcpHeader = struct {
    src_port: u16,
    dst_port: u16,
    seq_num: u32,
    ack_num: u32,
    data_offset: u4,
    flags: u9,
    window_size: u16,
    checksum: u16,
    urgent_ptr: u16,
};

pub fn calculateChecksum(src_ip: [4]u8, dst_ip: [4]u8, tcp_packet: []const u8) u16 {
    var sum: u32 = 0;
    // Pseudo-header
    sum += ((@as(u32, src_ip[0]) << 8) | src_ip[1]);
    sum += ((@as(u32, src_ip[2]) << 8) | src_ip[3]);
    sum += ((@as(u32, dst_ip[0]) << 8) | dst_ip[1]);
    sum += ((@as(u32, dst_ip[2]) << 8) | dst_ip[3]);
    sum += PROTO_TCP;
    sum += @as(u32, @intCast(tcp_packet.len));

    var i: usize = 0;
    while (i + 1 < tcp_packet.len) : (i += 2) {
        sum += (@as(u32, tcp_packet[i]) << 8) | @as(u32, tcp_packet[i + 1]);
    }
    if (i < tcp_packet.len) {
        sum += @as(u32, tcp_packet[i]) << 8;
    }

    while ((sum >> 16) != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    const csum = @as(u16, @intCast(~sum & 0xFFFF));
    return if (csum == 0) 0xFFFF else csum;
}

pub fn parseHeader(data: []const u8) ?TcpHeader {
    if (data.len < TCP_HEADER_MIN_LEN) return null;

    const offset_flags = (@as(u16, data[12]) << 8) | @as(u16, data[13]);
    const data_offset: u4 = @truncate(offset_flags >> 12);
    const flags: u9 = @truncate(offset_flags & 0x1FF);

    if (data_offset < 5) return null;
    const header_len = @as(usize, data_offset) * 4;
    if (data.len < header_len) return null;

    return TcpHeader{
        .src_port = (@as(u16, data[0]) << 8) | @as(u16, data[1]),
        .dst_port = (@as(u16, data[2]) << 8) | @as(u16, data[3]),
        .seq_num = (@as(u32, data[4]) << 24) | (@as(u32, data[5]) << 16) | (@as(u32, data[6]) << 8) | @as(u32, data[7]),
        .ack_num = (@as(u32, data[8]) << 24) | (@as(u32, data[9]) << 16) | (@as(u32, data[10]) << 8) | @as(u32, data[11]),
        .data_offset = data_offset,
        .flags = flags,
        .window_size = (@as(u16, data[14]) << 8) | @as(u16, data[15]),
        .checksum = (@as(u16, data[16]) << 8) | @as(u16, data[17]),
        .urgent_ptr = (@as(u16, data[18]) << 8) | @as(u16, data[19]),
    };
}

pub fn writePacket(
    out_buf: []u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: u9,
    payload: []const u8,
) !usize {
    const total_len = TCP_HEADER_MIN_LEN + payload.len;
    if (out_buf.len < total_len) return error.BufferTooSmall;

    out_buf[0] = @intCast((src_port >> 8) & 0xFF);
    out_buf[1] = @intCast(src_port & 0xFF);
    out_buf[2] = @intCast((dst_port >> 8) & 0xFF);
    out_buf[3] = @intCast(dst_port & 0xFF);

    out_buf[4] = @intCast((seq >> 24) & 0xFF);
    out_buf[5] = @intCast((seq >> 16) & 0xFF);
    out_buf[6] = @intCast((seq >> 8) & 0xFF);
    out_buf[7] = @intCast(seq & 0xFF);

    out_buf[8] = @intCast((ack >> 24) & 0xFF);
    out_buf[9] = @intCast((ack >> 16) & 0xFF);
    out_buf[10] = @intCast((ack >> 8) & 0xFF);
    out_buf[11] = @intCast(ack & 0xFF);

    // Data offset = 5 (20 bytes), flags
    const offset_flags: u16 = (@as(u16, 5) << 12) | @as(u16, flags);
    out_buf[12] = @intCast((offset_flags >> 8) & 0xFF);
    out_buf[13] = @intCast(offset_flags & 0xFF);

    out_buf[14] = @intCast((DEFAULT_WINDOW >> 8) & 0xFF);
    out_buf[15] = @intCast(DEFAULT_WINDOW & 0xFF);
    out_buf[16] = 0x00; // Checksum
    out_buf[17] = 0x00;
    out_buf[18] = 0x00; // Urgent pointer
    out_buf[19] = 0x00;

    @memcpy(out_buf[TCP_HEADER_MIN_LEN..total_len], payload);

    const csum = calculateChecksum(src_ip, dst_ip, out_buf[0..total_len]);
    out_buf[16] = @intCast((csum >> 8) & 0xFF);
    out_buf[17] = @intCast(csum & 0xFF);

    return total_len;
}

pub fn isSeqGe(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) >= 0;
}

pub const TcpClient = struct {
    local_ip: [4]u8,
    remote_ip: [4]u8,
    local_port: u16,
    remote_port: u16,
    seq: u32,
    unacked_seq: u32,
    syn_seq: u32,
    ack: u32,
    state: TcpState = .closed,

    pub fn init(local_ip: [4]u8, remote_ip: [4]u8, local_port: u16, remote_port: u16, initial_seq: u32) TcpClient {
        return TcpClient{
            .local_ip = local_ip,
            .remote_ip = remote_ip,
            .local_port = local_port,
            .remote_port = remote_port,
            .seq = initial_seq,
            .unacked_seq = initial_seq,
            .syn_seq = initial_seq,
            .ack = 0,
            .state = .closed,
        };
    }

    pub fn buildSyn(self: *TcpClient, out_buf: []u8) !usize {
        self.state = .syn_sent;
        self.syn_seq = self.seq;
        self.unacked_seq = self.seq;
        const len = try writePacket(out_buf, self.local_ip, self.remote_ip, self.local_port, self.remote_port, self.syn_seq, 0, FLAG_SYN, &[_]u8{});
        self.seq = self.syn_seq +% 1;
        return len;
    }

    pub fn buildSynRetransmit(self: *const TcpClient, out_buf: []u8) !usize {
        return writePacket(out_buf, self.local_ip, self.remote_ip, self.local_port, self.remote_port, self.syn_seq, 0, FLAG_SYN, &[_]u8{});
    }

    pub fn buildAck(self: *const TcpClient, out_buf: []u8) !usize {
        return writePacket(out_buf, self.local_ip, self.remote_ip, self.local_port, self.remote_port, self.seq, self.ack, FLAG_ACK, &[_]u8{});
    }

    pub fn buildData(self: *TcpClient, out_buf: []u8, payload: []const u8) !usize {
        const len = try writePacket(out_buf, self.local_ip, self.remote_ip, self.local_port, self.remote_port, self.seq, self.ack, FLAG_ACK | FLAG_PSH, payload);
        self.seq +%= @intCast(payload.len);
        return len;
    }

    pub fn buildDataSegment(self: *const TcpClient, out_buf: []u8, seq_num: u32, payload: []const u8) !usize {
        return writePacket(out_buf, self.local_ip, self.remote_ip, self.local_port, self.remote_port, seq_num, self.ack, FLAG_ACK | FLAG_PSH, payload);
    }

    pub fn buildFin(self: *TcpClient, out_buf: []u8) !usize {
        self.state = .fin_wait;
        const len = try writePacket(out_buf, self.local_ip, self.remote_ip, self.local_port, self.remote_port, self.seq, self.ack, FLAG_FIN | FLAG_ACK, &[_]u8{});
        self.seq +%= 1;
        return len;
    }

    pub fn processSegment(self: *TcpClient, tcp_hdr: TcpHeader, payload: []const u8) bool {
        if ((tcp_hdr.flags & FLAG_RST) != 0) {
            self.state = .closed;
            return false;
        }

        if ((tcp_hdr.flags & FLAG_ACK) != 0) {
            if (isSeqGe(tcp_hdr.ack_num, self.unacked_seq)) {
                self.unacked_seq = tcp_hdr.ack_num;
            }
        }

        if (self.state == .syn_sent and (tcp_hdr.flags & (FLAG_SYN | FLAG_ACK)) == (FLAG_SYN | FLAG_ACK)) {
            self.ack = tcp_hdr.seq_num +% 1;
            self.state = .established;
            return true;
        }

        if (self.state == .established) {
            if (payload.len > 0) {
                self.ack = tcp_hdr.seq_num +% @as(u32, @intCast(payload.len));
            }
            if ((tcp_hdr.flags & FLAG_FIN) != 0) {
                self.ack +%= 1;
                self.state = .time_wait;
            }
            return true;
        }

        if (self.state == .time_wait) {
            return true;
        }

        return false;
    }
};

test "tcp packet generation and parse" {
    var buf: [128]u8 = undefined;
    const src_ip = [_]u8{ 10, 0, 2, 15 };
    const dst_ip = [_]u8{ 142, 250, 190, 46 };
    const payload = "GET / HTTP/1.1\r\n\r\n";

    const len = try writePacket(&buf, src_ip, dst_ip, 49152, 443, 1000, 2000, FLAG_ACK | FLAG_PSH, payload);
    try std.testing.expectEqual(TCP_HEADER_MIN_LEN + payload.len, len);

    const parsed = parseHeader(buf[0..len]).?;
    try std.testing.expectEqual(@as(u16, 49152), parsed.src_port);
    try std.testing.expectEqual(@as(u16, 443), parsed.dst_port);
    try std.testing.expectEqual(@as(u32, 1000), parsed.seq_num);
    try std.testing.expectEqual(@as(u32, 2000), parsed.ack_num);
    try std.testing.expectEqual(FLAG_ACK | FLAG_PSH, parsed.flags);
}

test "tcp client handshake state transitions" {
    const src_ip = [_]u8{ 10, 0, 2, 15 };
    const dst_ip = [_]u8{ 142, 250, 190, 46 };
    var client = TcpClient.init(src_ip, dst_ip, 50000, 443, 100);

    var syn_buf: [64]u8 = undefined;
    _ = try client.buildSyn(&syn_buf);
    try std.testing.expectEqual(TcpState.syn_sent, client.state);
    try std.testing.expectEqual(@as(u32, 101), client.seq);

    // Mock incoming SYN-ACK
    const syn_ack = TcpHeader{
        .src_port = 443,
        .dst_port = 50000,
        .seq_num = 500,
        .ack_num = 101,
        .data_offset = 5,
        .flags = FLAG_SYN | FLAG_ACK,
        .window_size = 65535,
        .checksum = 0,
        .urgent_ptr = 0,
    };
    const handled = client.processSegment(syn_ack, &[_]u8{});
    try std.testing.expect(handled);
    try std.testing.expectEqual(TcpState.established, client.state);
    try std.testing.expectEqual(@as(u32, 501), client.ack);
}

test "tcp client fin and time_wait transition" {
    const src_ip = [_]u8{ 10, 0, 2, 15 };
    const dst_ip = [_]u8{ 142, 250, 190, 46 };
    var client = TcpClient.init(src_ip, dst_ip, 50000, 443, 100);
    client.state = .established;
    client.seq = 101;
    client.ack = 501;

    const fin_hdr = TcpHeader{
        .src_port = 443,
        .dst_port = 50000,
        .seq_num = 501,
        .ack_num = 101,
        .data_offset = 5,
        .flags = FLAG_FIN | FLAG_ACK,
        .window_size = 65535,
        .checksum = 0,
        .urgent_ptr = 0,
    };
    const handled = client.processSegment(fin_hdr, &[_]u8{});
    try std.testing.expect(handled);
    try std.testing.expectEqual(TcpState.time_wait, client.state);
    try std.testing.expectEqual(@as(u32, 502), client.ack);

    // Retransmitted FIN in time_wait should also be handled
    const retrans_handled = client.processSegment(fin_hdr, &[_]u8{});
    try std.testing.expect(retrans_handled);
}

test "tcp sequence number comparison and retransmission" {
    try std.testing.expect(isSeqGe(100, 50));
    try std.testing.expect(isSeqGe(100, 100));
    try std.testing.expect(!isSeqGe(50, 100));
    // Modular wraparound
    try std.testing.expect(isSeqGe(10, 0xFFFF_FFF0));
    try std.testing.expect(!isSeqGe(0xFFFF_FFF0, 10));

    const src_ip = [_]u8{ 10, 0, 2, 15 };
    const dst_ip = [_]u8{ 142, 250, 190, 46 };
    var client = TcpClient.init(src_ip, dst_ip, 50000, 443, 1000);

    var buf: [128]u8 = undefined;
    const syn_len = try client.buildSyn(&buf);
    try std.testing.expectEqual(@as(u32, 1000), client.syn_seq);
    try std.testing.expectEqual(@as(u32, 1001), client.seq);
    try std.testing.expectEqual(@as(u32, 1000), client.unacked_seq);

    const retrans_len = try client.buildSynRetransmit(&buf);
    try std.testing.expectEqual(syn_len, retrans_len);
}
