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
pub const MAX_LISTENERS: usize = 4;
pub const MAX_SERVER_CONNECTIONS: usize = 8;
pub const TCP_RX_BUFFER_SIZE: usize = 16384;
pub const TCP_TX_BUFFER_SIZE: usize = 16384;
pub const TCP_MAX_SEGMENT_SIZE: usize = 1460;
pub const TCP_RTO_TICKS: u64 = 100;
pub const TCP_MAX_RETRIES: u8 = 3;

pub const TcpState = enum {
    closed,
    syn_sent,
    established,
    fin_wait,
    time_wait,
};

pub const ServerState = enum(u8) {
    closed = 0,
    listen = 1,
    syn_received = 2,
    established = 3,
    fin_wait_1 = 4,
    fin_wait_2 = 5,
    close_wait = 6,
    closing = 7,
    last_ack = 8,
    time_wait = 9,
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

fn writeTcpHeaderFields(
    out_buf: []u8,
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: u9,
) void {
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

    const offset_flags: u16 = (@as(u16, 5) << 12) | @as(u16, flags);
    out_buf[12] = @intCast((offset_flags >> 8) & 0xFF);
    out_buf[13] = @intCast(offset_flags & 0xFF);

    out_buf[14] = @intCast((DEFAULT_WINDOW >> 8) & 0xFF);
    out_buf[15] = @intCast(DEFAULT_WINDOW & 0xFF);
    out_buf[16] = 0x00; // Checksum
    out_buf[17] = 0x00;
    out_buf[18] = 0x00; // Urgent pointer
    out_buf[19] = 0x00;
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

    writeTcpHeaderFields(out_buf, src_port, dst_port, seq, ack, flags);
    @memcpy(out_buf[TCP_HEADER_MIN_LEN..total_len], payload);

    const csum = calculateChecksum(src_ip, dst_ip, out_buf[0..total_len]);
    out_buf[16] = @intCast((csum >> 8) & 0xFF);
    out_buf[17] = @intCast(csum & 0xFF);

    return total_len;
}

pub fn isSeqGe(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) >= 0;
}

pub fn computeSynCookie(
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
    client_isn: u32,
    secret_nonce: u64,
) u32 {
    var input: [24]u8 = undefined;
    @memcpy(input[0..4], &src_ip);
    @memcpy(input[4..8], &dst_ip);
    input[8] = @intCast((src_port >> 8) & 0xFF);
    input[9] = @intCast(src_port & 0xFF);
    input[10] = @intCast((dst_port >> 8) & 0xFF);
    input[11] = @intCast(dst_port & 0xFF);
    input[12] = @intCast((client_isn >> 24) & 0xFF);
    input[13] = @intCast((client_isn >> 16) & 0xFF);
    input[14] = @intCast((client_isn >> 8) & 0xFF);
    input[15] = @intCast(client_isn & 0xFF);
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        input[16 + i] = @truncate(secret_nonce >> @intCast(i * 8));
    }
    var out_hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(&input, &out_hash, .{});
    return (@as(u32, out_hash[0]) << 24) |
        (@as(u32, out_hash[1]) << 16) |
        (@as(u32, out_hash[2]) << 8) |
        @as(u32, out_hash[3]);
}

pub fn verifySynCookie(
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
    client_isn: u32,
    secret_nonce: u64,
    cookie: u32,
) bool {
    return computeSynCookie(src_ip, dst_ip, src_port, dst_port, client_isn, secret_nonce) == cookie;
}

pub fn writeSynAckPacket(
    out_buf: []u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
) !usize {
    return writePacket(
        out_buf,
        src_ip,
        dst_ip,
        src_port,
        dst_port,
        seq,
        ack,
        FLAG_SYN | FLAG_ACK,
        &[_]u8{},
    );
}

pub fn writeRstPacket(
    out_buf: []u8,
    src_ip: [4]u8,
    dst_ip: [4]u8,
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
) !usize {
    return writePacket(
        out_buf,
        src_ip,
        dst_ip,
        src_port,
        dst_port,
        seq,
        ack,
        FLAG_RST | FLAG_ACK,
        &[_]u8{},
    );
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

pub const TcpListener = struct {
    id: u32,
    port: u16,
    owner_actor: u32,
    active: bool = false,

    pub fn init(id: u32, port: u16, owner: u32) TcpListener {
        return TcpListener{
            .id = id,
            .port = port,
            .owner_actor = owner,
            .active = true,
        };
    }
};

pub const TcpServerConn = struct {
    id: u32 = 0,
    state: ServerState = .closed,
    local_port: u16 = 0,
    remote_port: u16 = 0,
    remote_ip: [4]u8 = [_]u8{0} ** 4,
    remote_mac: [6]u8 = [_]u8{0} ** 6,
    local_seq: u32 = 0,
    remote_seq: u32 = 0,
    remote_ack: u32 = 0,
    unacked_seq: u32 = 0,
    last_activity_ticks: u64 = 0,
    retries: u8 = 0,
    rx_buf: [TCP_RX_BUFFER_SIZE]u8 = undefined,
    rx_head: usize = 0,
    rx_tail: usize = 0,
    tx_buf: [TCP_TX_BUFFER_SIZE]u8 = undefined,
    tx_len: usize = 0,
    tx_sent: usize = 0,
    owner_actor: u32 = 0,

    pub fn init(
        id: u32,
        local_port: u16,
        remote_port: u16,
        remote_ip: [4]u8,
        remote_mac: [6]u8,
        initial_seq: u32,
        client_isn: u32,
        owner_actor: u32,
    ) TcpServerConn {
        var conn = TcpServerConn{
            .id = id,
            .state = .established,
            .local_port = local_port,
            .remote_port = remote_port,
            .remote_ip = remote_ip,
            .remote_mac = remote_mac,
            .local_seq = initial_seq +% 1,
            .unacked_seq = initial_seq +% 1,
            .remote_seq = client_isn +% 1,
            .remote_ack = initial_seq +% 1,
            .owner_actor = owner_actor,
        };
        conn.rx_head = 0;
        conn.rx_tail = 0;
        conn.tx_len = 0;
        conn.tx_sent = 0;
        return conn;
    }

    pub fn availableRx(self: *const TcpServerConn) usize {
        return self.rx_head - self.rx_tail;
    }

    pub fn readRx(self: *TcpServerConn, out: []u8) usize {
        const avail = self.availableRx();
        const copy_len = @min(avail, out.len);
        var i: usize = 0;
        while (i < copy_len) : (i += 1) {
            out[i] = self.rx_buf[(self.rx_tail + i) % TCP_RX_BUFFER_SIZE];
        }
        self.rx_tail += copy_len;
        if (self.rx_tail == self.rx_head) {
            self.rx_head = 0;
            self.rx_tail = 0;
        }
        return copy_len;
    }

    pub fn queueTx(self: *TcpServerConn, data: []const u8) !usize {
        const avail = TCP_TX_BUFFER_SIZE - self.tx_len;
        const copy_len = @min(avail, data.len);
        if (copy_len == 0) return error.TxBufferFull;
        @memcpy(self.tx_buf[self.tx_len .. self.tx_len + copy_len], data[0..copy_len]);
        self.tx_len += copy_len;
        return copy_len;
    }

    pub fn buildAck(self: *const TcpServerConn, local_ip: [4]u8, out_buf: []u8) !usize {
        return writePacket(
            out_buf,
            local_ip,
            self.remote_ip,
            self.local_port,
            self.remote_port,
            self.local_seq,
            self.remote_seq,
            FLAG_ACK,
            &[_]u8{},
        );
    }

    pub fn buildData(self: *TcpServerConn, local_ip: [4]u8, out_buf: []u8) !usize {
        if (self.tx_sent >= self.tx_len) return 0;
        const remaining = self.tx_len - self.tx_sent;
        const send_len = @min(remaining, TCP_MAX_SEGMENT_SIZE);
        const payload = self.tx_buf[self.tx_sent .. self.tx_sent + send_len];
        const pkt_len = try writePacket(
            out_buf,
            local_ip,
            self.remote_ip,
            self.local_port,
            self.remote_port,
            self.local_seq,
            self.remote_seq,
            FLAG_ACK | FLAG_PSH,
            payload,
        );
        self.tx_sent += send_len;
        self.local_seq +%= @intCast(send_len);
        return pkt_len;
    }

    pub fn buildFin(self: *TcpServerConn, local_ip: [4]u8, out_buf: []u8) !usize {
        self.state = .last_ack;
        const pkt_len = try writePacket(
            out_buf,
            local_ip,
            self.remote_ip,
            self.local_port,
            self.remote_port,
            self.local_seq,
            self.remote_seq,
            FLAG_FIN | FLAG_ACK,
            &[_]u8{},
        );
        self.local_seq +%= 1;
        return pkt_len;
    }

    fn appendRxPayload(self: *TcpServerConn, payload: []const u8) void {
        const avail = TCP_RX_BUFFER_SIZE - (self.rx_head - self.rx_tail);
        if (payload.len > avail) return;
        var i: usize = 0;
        while (i < payload.len) : (i += 1) {
            self.rx_buf[(self.rx_head + i) % TCP_RX_BUFFER_SIZE] = payload[i];
        }
        self.rx_head += payload.len;
        self.remote_seq +%= @intCast(payload.len);
    }

    pub fn processSegment(self: *TcpServerConn, tcp_hdr: TcpHeader, payload: []const u8) bool {
        if ((tcp_hdr.flags & FLAG_RST) != 0) {
            self.state = .closed;
            return false;
        }

        if (self.state == .last_ack and (tcp_hdr.flags & FLAG_ACK) != 0) {
            self.state = .closed;
            return true;
        }

        if (self.state != .established and self.state != .close_wait) return false;

        if (payload.len > 0 or (tcp_hdr.flags & FLAG_FIN) != 0) {
            if (tcp_hdr.seq_num != self.remote_seq) {
                return false;
            }
        }

        if ((tcp_hdr.flags & FLAG_ACK) != 0) {
            self.remote_ack = tcp_hdr.ack_num;
            if (isSeqGe(tcp_hdr.ack_num, self.unacked_seq)) {
                self.unacked_seq = tcp_hdr.ack_num;
            }
        }

        if (payload.len > 0) {
            self.appendRxPayload(payload);
        }

        if ((tcp_hdr.flags & FLAG_FIN) != 0) {
            self.remote_seq +%= 1;
            self.state = .close_wait;
        }

        return true;
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

test "tcp syn cookie computation and validation" {
    const src_ip = [_]u8{ 10, 0, 2, 2 };
    const dst_ip = [_]u8{ 10, 0, 2, 15 };
    const src_port: u16 = 54321;
    const dst_port: u16 = 80;
    const client_isn: u32 = 0x1234_5678;
    const secret: u64 = 0xDEAD_BEEF_CAFE_BABE;

    const cookie = computeSynCookie(src_ip, dst_ip, src_port, dst_port, client_isn, secret);
    try std.testing.expect(cookie != 0);
    try std.testing.expect(verifySynCookie(src_ip, dst_ip, src_port, dst_port, client_isn, secret, cookie));

    const bad_ip = [_]u8{ 10, 0, 2, 3 };
    try std.testing.expect(!verifySynCookie(bad_ip, dst_ip, src_port, dst_port, client_isn, secret, cookie));
    try std.testing.expect(!verifySynCookie(src_ip, dst_ip, 54322, dst_port, client_isn, secret, cookie));
    try std.testing.expect(!verifySynCookie(src_ip, dst_ip, src_port, dst_port, client_isn + 1, secret, cookie));
}

test "tcp server connection lifecycle and buffer streaming" {
    const local_ip = [_]u8{ 10, 0, 2, 15 };
    const remote_ip = [_]u8{ 10, 0, 2, 2 };
    const remote_mac = [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    var conn = TcpServerConn.init(1, 80, 54321, remote_ip, remote_mac, 1000, 5000, 0);

    try std.testing.expectEqual(ServerState.established, conn.state);
    try std.testing.expectEqual(@as(u32, 1001), conn.local_seq);
    try std.testing.expectEqual(@as(u32, 5001), conn.remote_seq);

    const msg = "HTTP/1.1 200 OK\r\n\r\nHello MicrOS!";
    const queued = try conn.queueTx(msg);
    try std.testing.expectEqual(msg.len, queued);

    var pkt_buf: [256]u8 = undefined;
    const data_len = try conn.buildData(local_ip, &pkt_buf);
    try std.testing.expect(data_len > TCP_HEADER_MIN_LEN);

    const hdr = parseHeader(pkt_buf[0..data_len]).?;
    try std.testing.expectEqual(@as(u16, 80), hdr.src_port);
    try std.testing.expectEqual(@as(u16, 54321), hdr.dst_port);
    try std.testing.expectEqual(FLAG_ACK | FLAG_PSH, hdr.flags);

    const req_payload = "GET / HTTP/1.1\r\n";
    const req_hdr = TcpHeader{
        .src_port = 54321,
        .dst_port = 80,
        .seq_num = 5001,
        .ack_num = 1001 + @as(u32, @intCast(msg.len)),
        .data_offset = 5,
        .flags = FLAG_ACK | FLAG_PSH,
        .window_size = 65535,
        .checksum = 0,
        .urgent_ptr = 0,
    };
    const handled = conn.processSegment(req_hdr, req_payload);
    try std.testing.expect(handled);
    try std.testing.expectEqual(@as(u32, 5001 + req_payload.len), conn.remote_seq);
    try std.testing.expectEqual(req_payload.len, conn.availableRx());

    var rx_out: [64]u8 = undefined;
    const read_bytes = conn.readRx(&rx_out);
    try std.testing.expectEqual(req_payload.len, read_bytes);
    try std.testing.expectEqualStrings(req_payload, rx_out[0..read_bytes]);

    const bad_seq_hdr = TcpHeader{
        .src_port = 54321,
        .dst_port = 80,
        .seq_num = 9999,
        .ack_num = conn.local_seq,
        .data_offset = 5,
        .flags = FLAG_ACK,
        .window_size = 65535,
        .checksum = 0,
        .urgent_ptr = 0,
    };
    try std.testing.expect(!conn.processSegment(bad_seq_hdr, "Dropped"));

    const fin_hdr = TcpHeader{
        .src_port = 54321,
        .dst_port = 80,
        .seq_num = conn.remote_seq,
        .ack_num = conn.local_seq,
        .data_offset = 5,
        .flags = FLAG_FIN | FLAG_ACK,
        .window_size = 65535,
        .checksum = 0,
        .urgent_ptr = 0,
    };
    try std.testing.expect(conn.processSegment(fin_hdr, &[_]u8{}));
    try std.testing.expectEqual(ServerState.close_wait, conn.state);

    _ = try conn.buildFin(local_ip, &pkt_buf);
    try std.testing.expectEqual(ServerState.last_ack, conn.state);

    const ack_hdr = TcpHeader{
        .src_port = 54321,
        .dst_port = 80,
        .seq_num = conn.remote_seq,
        .ack_num = conn.local_seq,
        .data_offset = 5,
        .flags = FLAG_ACK,
        .window_size = 65535,
        .checksum = 0,
        .urgent_ptr = 0,
    };
    try std.testing.expect(conn.processSegment(ack_hdr, &[_]u8{}));
    try std.testing.expectEqual(ServerState.closed, conn.state);
}
