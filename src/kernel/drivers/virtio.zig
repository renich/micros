// MicrOS (µOS) VirtIO 1.0 Substrate & Common Virtqueue Definitions
// Implements split virtqueue descriptor rings, avail/used rings, and legacy PCI registers.
// Zero libc, page-aligned DMA ring layouts adhering to the VirtIO 1.0 specification.

const std = @import("std");

pub const DEFAULT_QUEUE_SIZE: u16 = 256;
pub const PAUSE_SPIN_LIMIT: usize = 5_000_000;

// Legacy VirtIO PCI I/O register offsets
pub const REG_DEVICE_FEATURES: u16 = 0x00;
pub const REG_GUEST_FEATURES: u16 = 0x04;
pub const REG_QUEUE_ADDRESS: u16 = 0x08;
pub const REG_QUEUE_SIZE: u16 = 0x0C;
pub const REG_QUEUE_SELECT: u16 = 0x0E;
pub const REG_QUEUE_NOTIFY: u16 = 0x10;
pub const REG_DEVICE_STATUS: u16 = 0x12;
pub const REG_ISR_STATUS: u16 = 0x13;

// Device status flags
pub const STATUS_RESET: u8 = 0x00;
pub const STATUS_ACKNOWLEDGE: u8 = 0x01;
pub const STATUS_DRIVER: u8 = 0x02;
pub const STATUS_DRIVER_OK: u8 = 0x04;
pub const STATUS_FEATURES_OK: u8 = 0x08;
pub const STATUS_FAILED: u8 = 0x80;

// Split Virtqueue descriptor flags
pub const VRING_DESC_F_NEXT: u16 = 0x0001;
pub const VRING_DESC_F_WRITE: u16 = 0x0002;
pub const VRING_DESC_F_INDIRECT: u16 = 0x0004;

// Virtqueue event suppression flags
pub const VRING_AVAIL_F_NO_INTERRUPT: u16 = 0x0001;
pub const VRING_USED_F_NO_NOTIFY: u16 = 0x0001;

pub const VRingDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

pub fn VRingAvail(comptime size: u16) type {
    return extern struct {
        flags: u16,
        idx: u16,
        ring: [size]u16,
        used_event: u16,
    };
}

pub const VRingUsedElem = extern struct {
    id: u32,
    len: u32,
};

pub fn VRingUsed(comptime size: u16) type {
    return extern struct {
        flags: u16,
        idx: u16,
        ring: [size]VRingUsedElem,
        avail_event: u16,
    };
}

test "virtio split virtqueue descriptor layout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(VRingDesc));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(VRingUsedElem));
    try std.testing.expectEqual(@as(usize, 6 + 256 * 2), @sizeOf(VRingAvail(DEFAULT_QUEUE_SIZE)));
    try std.testing.expectEqual(@as(usize, 2056), @sizeOf(VRingUsed(DEFAULT_QUEUE_SIZE)));
}
