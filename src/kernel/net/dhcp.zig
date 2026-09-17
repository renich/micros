// MicrOS (µOS) Dynamic Host Configuration Protocol (DHCP)
// RFC 2131 Client Engine for Autonomous Subnet & Gateway Discovery
// Independent of libc and host kernel services.

const std = @import("std");

pub const PORT_SERVER: u16 = 67;
pub const PORT_CLIENT: u16 = 68;
pub const MAGIC_COOKIE: [4]u8 = [_]u8{ 99, 130, 83, 99 };

pub const OP_BOOTREQUEST: u8 = 1;
pub const OP_BOOTREPLY: u8 = 2;
pub const HTYPE_ETHERNET: u8 = 1;
pub const HLEN_ETHERNET: u8 = 6;

pub const MSG_DISCOVER: u8 = 1;
pub const MSG_OFFER: u8 = 2;
pub const MSG_REQUEST: u8 = 3;
pub const MSG_ACK: u8 = 5;
pub const MSG_NAK: u8 = 6;

pub const OPT_SUBNET_MASK: u8 = 1;
pub const OPT_ROUTER: u8 = 3;
pub const OPT_DNS_SERVER: u8 = 6;
pub const OPT_REQUESTED_IP: u8 = 50;
pub const OPT_LEASE_TIME: u8 = 51;
pub const OPT_MSG_TYPE: u8 = 53;
pub const OPT_SERVER_ID: u8 = 54;
pub const OPT_PARAM_REQUEST: u8 = 55;
pub const OPT_END: u8 = 255;

pub const BOOTP_HEADER_LEN: usize = 236;
pub const BOOTP_WITH_COOKIE_LEN: usize = 240;

pub const DhcpConfig = struct {
    ip: [4]u8 = [_]u8{0} ** 4,
    subnet_mask: [4]u8 = [_]u8{0} ** 4,
    gateway: [4]u8 = [_]u8{0} ** 4,
    dns_server: [4]u8 = [_]u8{0} ** 4,
    server_id: [4]u8 = [_]u8{0} ** 4,
    lease_seconds: u32 = 0,
    bound: bool = false,
};

fn writeBootpHeader(out_buf: []u8, mac: [6]u8, xid: u32) void {
    @memset(out_buf[0..BOOTP_WITH_COOKIE_LEN], 0);
    out_buf[0] = OP_BOOTREQUEST;
    out_buf[1] = HTYPE_ETHERNET;
    out_buf[2] = HLEN_ETHERNET;
    out_buf[3] = 0; // Hops

    out_buf[4] = @intCast((xid >> 24) & 0xFF);
    out_buf[5] = @intCast((xid >> 16) & 0xFF);
    out_buf[6] = @intCast((xid >> 8) & 0xFF);
    out_buf[7] = @intCast(xid & 0xFF);

    out_buf[10] = 0x80; // Broadcast flag (0x8000)
    out_buf[11] = 0x00;

    @memcpy(out_buf[28..34], &mac);
    @memcpy(out_buf[236..240], &MAGIC_COOKIE);
}

pub fn buildDiscover(out_buf: []u8, mac: [6]u8, xid: u32) !usize {
    const required_len = BOOTP_WITH_COOKIE_LEN + 11; // 3 (type) + 5 (params) + 1 (end) + pad
    if (out_buf.len < required_len) return error.BufferTooSmall;

    writeBootpHeader(out_buf, mac, xid);
    var idx: usize = BOOTP_WITH_COOKIE_LEN;

    // Option 53: Message Type = Discover
    out_buf[idx] = OPT_MSG_TYPE;
    out_buf[idx + 1] = 1;
    out_buf[idx + 2] = MSG_DISCOVER;
    idx += 3;

    // Option 55: Parameter Request List (Subnet, Router, DNS)
    out_buf[idx] = OPT_PARAM_REQUEST;
    out_buf[idx + 1] = 3;
    out_buf[idx + 2] = OPT_SUBNET_MASK;
    out_buf[idx + 3] = OPT_ROUTER;
    out_buf[idx + 4] = OPT_DNS_SERVER;
    idx += 5;

    // Option 255: End
    out_buf[idx] = OPT_END;
    idx += 1;

    return idx;
}

pub fn buildRequest(
    out_buf: []u8,
    mac: [6]u8,
    xid: u32,
    req_ip: [4]u8,
    srv_id: [4]u8,
) !usize {
    const required_len = BOOTP_WITH_COOKIE_LEN + 21;
    if (out_buf.len < required_len) return error.BufferTooSmall;

    writeBootpHeader(out_buf, mac, xid);
    var idx: usize = BOOTP_WITH_COOKIE_LEN;

    // Option 53: Message Type = Request
    out_buf[idx] = OPT_MSG_TYPE;
    out_buf[idx + 1] = 1;
    out_buf[idx + 2] = MSG_REQUEST;
    idx += 3;

    // Option 50: Requested IP Address
    out_buf[idx] = OPT_REQUESTED_IP;
    out_buf[idx + 1] = 4;
    @memcpy(out_buf[idx + 2 .. idx + 6], &req_ip);
    idx += 6;

    // Option 54: Server Identifier
    out_buf[idx] = OPT_SERVER_ID;
    out_buf[idx + 1] = 4;
    @memcpy(out_buf[idx + 2 .. idx + 6], &srv_id);
    idx += 6;

    out_buf[idx] = OPT_END;
    idx += 1;

    return idx;
}

fn parseOption(tag: u8, val: []const u8, cfg: *DhcpConfig, msg_type: *?u8) void {
    switch (tag) {
        OPT_MSG_TYPE => if (val.len >= 1) {
            msg_type.* = val[0];
        },
        OPT_SUBNET_MASK => if (val.len >= 4) {
            @memcpy(&cfg.subnet_mask, val[0..4]);
        },
        OPT_ROUTER => if (val.len >= 4) {
            @memcpy(&cfg.gateway, val[0..4]);
        },
        OPT_DNS_SERVER => if (val.len >= 4) {
            @memcpy(&cfg.dns_server, val[0..4]);
        },
        OPT_SERVER_ID => if (val.len >= 4) {
            @memcpy(&cfg.server_id, val[0..4]);
        },
        OPT_LEASE_TIME => if (val.len >= 4) {
            cfg.lease_seconds = (@as(u32, val[0]) << 24) |
                (@as(u32, val[1]) << 16) |
                (@as(u32, val[2]) << 8) |
                @as(u32, val[3]);
        },
        else => {},
    }
}

pub fn parseResponse(payload: []const u8, expected_xid: u32, cfg: *DhcpConfig) ?u8 {
    if (payload.len < BOOTP_WITH_COOKIE_LEN) return null;
    if (payload[0] != OP_BOOTREPLY) return null;

    const xid = (@as(u32, payload[4]) << 24) |
        (@as(u32, payload[5]) << 16) |
        (@as(u32, payload[6]) << 8) |
        @as(u32, payload[7]);
    if (xid != expected_xid) return null;

    if (!std.mem.eql(u8, payload[236..240], &MAGIC_COOKIE)) return null;

    @memcpy(&cfg.ip, payload[16..20]); // yiaddr

    var msg_type: ?u8 = null;
    var idx: usize = BOOTP_WITH_COOKIE_LEN;

    while (idx < payload.len) {
        const tag = payload[idx];
        if (tag == OPT_END) break;
        if (tag == 0) { // OPT_PAD
            idx += 1;
            continue;
        }
        if (idx + 1 >= payload.len) break;
        const len = payload[idx + 1];
        if (idx + 2 + len > payload.len) break;

        parseOption(tag, payload[idx + 2 .. idx + 2 + len], cfg, &msg_type);
        idx += 2 + len;
    }

    return msg_type;
}

test "dhcp discover message format" {
    var buf: [512]u8 = undefined;
    const mac = [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    const xid = 0x4D494352;

    const len = try buildDiscover(&buf, mac, xid);
    try std.testing.expect(len >= BOOTP_WITH_COOKIE_LEN);
    try std.testing.expectEqual(OP_BOOTREQUEST, buf[0]);
    try std.testing.expectEqualSlices(u8, &MAGIC_COOKIE, buf[236..240]);
}

test "dhcp response parser" {
    var buf: [300]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = OP_BOOTREPLY;
    buf[4] = 0x11;
    buf[5] = 0x22;
    buf[6] = 0x33;
    buf[7] = 0x44;

    // yiaddr: 10.0.2.15
    buf[16] = 10;
    buf[17] = 0;
    buf[18] = 2;
    buf[19] = 15;

    @memcpy(buf[236..240], &MAGIC_COOKIE);

    // Option 53: Offer
    buf[240] = OPT_MSG_TYPE;
    buf[241] = 1;
    buf[242] = MSG_OFFER;

    // Option 3: Gateway 10.0.2.2
    buf[243] = OPT_ROUTER;
    buf[244] = 4;
    buf[245] = 10;
    buf[246] = 0;
    buf[247] = 2;
    buf[248] = 2;

    buf[249] = OPT_END;

    var cfg = DhcpConfig{};
    const msg = parseResponse(buf[0..250], 0x11223344, &cfg).?;
    try std.testing.expectEqual(MSG_OFFER, msg);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 2, 15 }, &cfg.ip);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 2, 2 }, &cfg.gateway);
}
