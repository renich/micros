// MicrOS (µOS) Address Resolution Protocol (ARP)
// RFC 826 In-Memory Resolution Cache & Packet Processing
// Independent of libc and host kernel services.

const std = @import("std");

pub const HARDWARE_ETHERNET: u16 = 0x0001;
pub const PROTOCOL_IPV4: u16 = 0x0800;
pub const HW_ADDR_LEN: u8 = 6;
pub const PROTO_ADDR_LEN: u8 = 4;
pub const OP_REQUEST: u16 = 1;
pub const OP_REPLY: u16 = 2;
pub const ARP_PACKET_LEN: usize = 28;
pub const ARP_TABLE_CAPACITY: usize = 16;

pub const ArpPacket = struct {
    htype: u16,
    ptype: u16,
    hlen: u8,
    plen: u8,
    opcode: u16,
    sender_mac: [6]u8,
    sender_ip: [4]u8,
    target_mac: [6]u8,
    target_ip: [4]u8,
};

pub const ArpEntry = struct {
    ip: [4]u8,
    mac: [6]u8,
    valid: bool,
};

pub const ArpTable = struct {
    entries: [ARP_TABLE_CAPACITY]ArpEntry = [_]ArpEntry{.{
        .ip = [_]u8{0} ** 4,
        .mac = [_]u8{0} ** 6,
        .valid = false,
    }} ** ARP_TABLE_CAPACITY,
    count: usize = 0,

    pub fn insert(self: *ArpTable, ip: [4]u8, mac: [6]u8) void {
        for (&self.entries) |*entry| {
            if (entry.valid and std.mem.eql(u8, &entry.ip, &ip)) {
                entry.mac = mac;
                return;
            }
        }
        for (&self.entries) |*entry| {
            if (!entry.valid) {
                entry.ip = ip;
                entry.mac = mac;
                entry.valid = true;
                self.count += 1;
                return;
            }
        }
        // Evict first slot on overflow
        self.entries[0] = ArpEntry{ .ip = ip, .mac = mac, .valid = true };
    }

    pub fn lookup(self: *const ArpTable, ip: [4]u8) ?[6]u8 {
        for (self.entries) |entry| {
            if (entry.valid and std.mem.eql(u8, &entry.ip, &ip)) {
                return entry.mac;
            }
        }
        return null;
    }
};

pub fn parseArp(data: []const u8) ?ArpPacket {
    if (data.len < ARP_PACKET_LEN) return null;

    const htype = (@as(u16, data[0]) << 8) | @as(u16, data[1]);
    const ptype = (@as(u16, data[2]) << 8) | @as(u16, data[3]);
    const hlen = data[4];
    const plen = data[5];
    const opcode = (@as(u16, data[6]) << 8) | @as(u16, data[7]);

    if (htype != HARDWARE_ETHERNET or ptype != PROTOCOL_IPV4) return null;
    if (hlen != HW_ADDR_LEN or plen != PROTO_ADDR_LEN) return null;

    var s_mac: [6]u8 = undefined;
    var s_ip: [4]u8 = undefined;
    var t_mac: [6]u8 = undefined;
    var t_ip: [4]u8 = undefined;

    @memcpy(&s_mac, data[8..14]);
    @memcpy(&s_ip, data[14..18]);
    @memcpy(&t_mac, data[18..24]);
    @memcpy(&t_ip, data[24..28]);

    return ArpPacket{
        .htype = htype,
        .ptype = ptype,
        .hlen = hlen,
        .plen = plen,
        .opcode = opcode,
        .sender_mac = s_mac,
        .sender_ip = s_ip,
        .target_mac = t_mac,
        .target_ip = t_ip,
    };
}

fn writeArpBody(
    out_buf: []u8,
    opcode: u16,
    sender_mac: [6]u8,
    sender_ip: [4]u8,
    target_mac: [6]u8,
    target_ip: [4]u8,
) !usize {
    if (out_buf.len < ARP_PACKET_LEN) return error.BufferTooSmall;

    out_buf[0] = @intCast((HARDWARE_ETHERNET >> 8) & 0xFF);
    out_buf[1] = @intCast(HARDWARE_ETHERNET & 0xFF);
    out_buf[2] = @intCast((PROTOCOL_IPV4 >> 8) & 0xFF);
    out_buf[3] = @intCast(PROTOCOL_IPV4 & 0xFF);
    out_buf[4] = HW_ADDR_LEN;
    out_buf[5] = PROTO_ADDR_LEN;
    out_buf[6] = @intCast((opcode >> 8) & 0xFF);
    out_buf[7] = @intCast(opcode & 0xFF);

    @memcpy(out_buf[8..14], &sender_mac);
    @memcpy(out_buf[14..18], &sender_ip);
    @memcpy(out_buf[18..24], &target_mac);
    @memcpy(out_buf[24..28], &target_ip);

    return ARP_PACKET_LEN;
}

pub fn buildArpRequest(out_buf: []u8, sender_mac: [6]u8, sender_ip: [4]u8, target_ip: [4]u8) !usize {
    const zero_mac = [_]u8{0} ** 6;
    return writeArpBody(out_buf, OP_REQUEST, sender_mac, sender_ip, zero_mac, target_ip);
}

pub fn buildArpReply(
    out_buf: []u8,
    sender_mac: [6]u8,
    sender_ip: [4]u8,
    target_mac: [6]u8,
    target_ip: [4]u8,
) !usize {
    return writeArpBody(out_buf, OP_REPLY, sender_mac, sender_ip, target_mac, target_ip);
}

test "arp table insert and lookup" {
    var table = ArpTable{};
    const ip = [_]u8{ 10, 0, 2, 2 };
    const mac = [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };

    try std.testing.expect(table.lookup(ip) == null);
    table.insert(ip, mac);
    const found = table.lookup(ip).?;
    try std.testing.expectEqualSlices(u8, &mac, &found);
}

test "arp packet parse and serialize" {
    var buf: [64]u8 = undefined;
    const s_mac = [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    const s_ip = [_]u8{ 10, 0, 2, 15 };
    const t_ip = [_]u8{ 10, 0, 2, 2 };

    const len = try buildArpRequest(&buf, s_mac, s_ip, t_ip);
    try std.testing.expectEqual(ARP_PACKET_LEN, len);

    const parsed = parseArp(buf[0..len]).?;
    try std.testing.expectEqual(OP_REQUEST, parsed.opcode);
    try std.testing.expectEqualSlices(u8, &s_mac, &parsed.sender_mac);
    try std.testing.expectEqualSlices(u8, &s_ip, &parsed.sender_ip);
    try std.testing.expectEqualSlices(u8, &t_ip, &parsed.target_ip);
}
