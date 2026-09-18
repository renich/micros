// MicrOS (µOS) Intel e1000e/igb Gigabit Ethernet Controller Driver (e1000.zig)
// SPEC-TECH-SILICON-002: Enterprise bare-metal NIC enablement, zero-copy ring buffers, and MMIO access.
// Zero libc, freestanding, 16-byte aligned DMA descriptor rings.

const std = @import("std");

pub const REG_CTRL: usize = 0x0000;
pub const REG_STATUS: usize = 0x0008;
pub const REG_EERD: usize = 0x0014;
pub const REG_ICR: usize = 0x00C0;
pub const REG_IMS: usize = 0x00D0;
pub const REG_RCTL: usize = 0x0100;
pub const REG_TCTL: usize = 0x0400;
pub const REG_RDBAL: usize = 0x2800;
pub const REG_RDBAH: usize = 0x2804;
pub const REG_RDLEN: usize = 0x2808;
pub const REG_RDH: usize = 0x2810;
pub const REG_RDT: usize = 0x2818;
pub const REG_TDBAL: usize = 0x3800;
pub const REG_TDBAH: usize = 0x3804;
pub const REG_TDLEN: usize = 0x3808;
pub const REG_TDH: usize = 0x3810;
pub const REG_TDT: usize = 0x3818;
pub const REG_RAL: usize = 0x5400;
pub const REG_RAH: usize = 0x5404;

pub const RCTL_EN: u32 = 1 << 1;
pub const RCTL_SBP: u32 = 1 << 2;
pub const RCTL_UPE: u32 = 1 << 3;
pub const RCTL_MPE: u32 = 1 << 4;
pub const RCTL_BAM: u32 = 1 << 15;
pub const RCTL_BSIZE_2048: u32 = 0 << 16;
pub const RCTL_SECRC: u32 = 1 << 26;

pub const TCTL_EN: u32 = 1 << 1;
pub const TCTL_PSP: u32 = 1 << 3;

pub const TXD_CMD_EOP: u8 = 1 << 0;
pub const TXD_CMD_IFCS: u8 = 1 << 1;
pub const TXD_CMD_RS: u8 = 1 << 3;
pub const TXD_STAT_DD: u8 = 1 << 0;

pub const RXD_STAT_DD: u8 = 1 << 0;
pub const RXD_STAT_EOP: u8 = 1 << 1;

pub const NUM_RX_DESCRIPTORS: usize = 32;
pub const NUM_TX_DESCRIPTORS: usize = 32;
pub const RX_BUFFER_SIZE: usize = 2048;

pub const RxDescriptor = extern struct {
    buffer_addr: u64 align(1),
    length: u16 align(1),
    checksum: u16 align(1),
    status: u8 align(1),
    errors: u8 align(1),
    special: u16 align(1),
};

pub const TxDescriptor = extern struct {
    buffer_addr: u64 align(1),
    length: u16 align(1),
    cso: u8 align(1),
    cmd: u8 align(1),
    status: u8 align(1),
    css: u8 align(1),
    special: u16 align(1),
};

pub const ReceivedPacket = struct {
    buffer_addr: u64,
    length: u16,
};

pub const E1000Device = struct {
    mmio_base: usize,
    mac_address: [6]u8,
    rx_ring: [NUM_RX_DESCRIPTORS]RxDescriptor align(16),
    tx_ring: [NUM_TX_DESCRIPTORS]TxDescriptor align(16),
    rx_cur: usize,
    tx_cur: usize,

    pub fn initMock(mmio_fake: usize, mac: [6]u8) E1000Device {
        var dev = E1000Device{
            .mmio_base = mmio_fake,
            .mac_address = mac,
            .rx_ring = std.mem.zeroes([NUM_RX_DESCRIPTORS]RxDescriptor),
            .tx_ring = std.mem.zeroes([NUM_TX_DESCRIPTORS]TxDescriptor),
            .rx_cur = 0,
            .tx_cur = 0,
        };
        dev.initRings();
        return dev;
    }

    fn initRings(self: *E1000Device) void {
        for (&self.rx_ring) |*desc| {
            desc.status = 0;
            desc.length = 0;
        }
        for (&self.tx_ring) |*desc| {
            desc.status = TXD_STAT_DD;
            desc.cmd = 0;
        }
    }

    pub fn transmitPacket(self: *E1000Device, packet_phys_addr: u64, len: u16) !void {
        const idx = self.tx_cur;
        const desc = &self.tx_ring[idx];

        if ((desc.status & TXD_STAT_DD) == 0) return error.TxRingFull;

        desc.buffer_addr = packet_phys_addr;
        desc.length = len;
        desc.cmd = TXD_CMD_EOP | TXD_CMD_IFCS | TXD_CMD_RS;
        desc.status = 0;

        self.tx_cur = (self.tx_cur + 1) % NUM_TX_DESCRIPTORS;
    }

    pub fn pollReceivePacket(self: *E1000Device) ?ReceivedPacket {
        const idx = self.rx_cur;
        const desc = &self.rx_ring[idx];

        if ((desc.status & RXD_STAT_DD) == 0) return null;

        const res = ReceivedPacket{
            .buffer_addr = desc.buffer_addr,
            .length = desc.length,
        };

        desc.status = 0; // Reset for reuse
        self.rx_cur = (self.rx_cur + 1) % NUM_RX_DESCRIPTORS;
        return res;
    }
};

test "Rx and Tx descriptor 16-byte alignment invariant" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(RxDescriptor));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(TxDescriptor));
}

test "E1000 device initialization and ring lifecycle" {
    const fake_mac = [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    var dev = E1000Device.initMock(0xFE000000, fake_mac);

    try std.testing.expectEqualStrings(&fake_mac, &dev.mac_address);
    try std.testing.expectEqual(@as(usize, 0), dev.rx_cur);
    try std.testing.expectEqual(@as(usize, 0), dev.tx_cur);
}

test "E1000 packet transmission and ring advance" {
    const fake_mac = [_]u8{ 0x00, 0x1B, 0x21, 0x33, 0x44, 0x55 };
    var dev = E1000Device.initMock(0xFE000000, fake_mac);

    try dev.transmitPacket(0x1000, 64);
    try std.testing.expectEqual(@as(usize, 1), dev.tx_cur);
    try std.testing.expectEqual(@as(u64, 0x1000), dev.tx_ring[0].buffer_addr);
    try std.testing.expectEqual(@as(u16, 64), dev.tx_ring[0].length);
}

test "E1000 packet reception poll and descriptor reset" {
    const fake_mac = [_]u8{ 0x00, 0x1B, 0x21, 0x33, 0x44, 0x55 };
    var dev = E1000Device.initMock(0xFE000000, fake_mac);

    // Simulate incoming packet
    dev.rx_ring[0].buffer_addr = 0x2000;
    dev.rx_ring[0].length = 128;
    dev.rx_ring[0].status = RXD_STAT_DD | RXD_STAT_EOP;

    const pkt = dev.pollReceivePacket();
    try std.testing.expect(pkt != null);
    try std.testing.expectEqual(@as(u64, 0x2000), pkt.?.buffer_addr);
    try std.testing.expectEqual(@as(u16, 128), pkt.?.length);
    try std.testing.expectEqual(@as(usize, 1), dev.rx_cur);
}
