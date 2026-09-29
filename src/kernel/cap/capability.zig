// MicrOS (µOS) Object-Capability Definitions
// Freestanding, libc-free capability representation for domain isolation.

const std = @import("std");

pub const CapType = enum(u16) {
    null_cap = 0x0000,
    memory_extent = 0x0001,
    ipc_ring = 0x0002,
    irq_endpoint = 0x0003,
    framebuffer = 0x0004,
    actor_control = 0x0005,
    network_device = 0x0006,
    storage_device = 0x0007,
    /// Dedicated hardware MMIO/BAR window capability for device drivers.
    /// Replaces overloaded memory_extent with strict device-bound semantics (P0-C1).
    hardware_device = 0x0008,
    /// Designated page-aligned DMA bounce buffer capability.
    /// Exclusively authorized for sys_dma_bounce_copy transfers (P0-C1).
    dma_buffer = 0x0009,
    /// Dedicated in-system self-rewrite and kernel staging authority token.
    /// Assigned 0x000A to prevent collision with storage_device (0x0007) per P4-C6.
    rebuild_control = 0x000A,
};

pub const Rights = struct {
    pub const NONE: u16 = 0x0000;
    pub const READ: u16 = 0x0001;
    pub const WRITE: u16 = 0x0002;
    pub const GRANT: u16 = 0x0004;
    pub const REVOKE: u16 = 0x0008;
    pub const EXECUTE: u16 = 0x0010;
    pub const ALL: u16 = 0x001F;
};

pub const Capability = extern struct {
    cap_type: CapType,
    rights: u16,
    object_id: u32,
    data_addr: u64,
    data_size: u64,

    pub const NULL_CAP = Capability{
        .cap_type = .null_cap,
        .rights = Rights.NONE,
        .object_id = 0,
        .data_addr = 0,
        .data_size = 0,
    };

    pub fn isValid(self: Capability) bool {
        if (self.cap_type == .null_cap) return false;
        if (self.rights == Rights.NONE) return false;
        if (self.data_size > std.math.maxInt(u64) - self.data_addr) return false;
        return true;
    }

    pub fn hasRight(self: Capability, required_right: u16) bool {
        return (self.rights & required_right) == required_right;
    }

    pub fn canGrant(self: Capability) bool {
        return self.hasRight(Rights.GRANT);
    }
};

test "Capability initialization and rights verification" {
    const mem_cap = Capability{
        .cap_type = .memory_extent,
        .rights = Rights.READ | Rights.WRITE | Rights.GRANT,
        .object_id = 1,
        .data_addr = 0x1000,
        .data_size = 4096,
    };

    try std.testing.expect(mem_cap.isValid());
    try std.testing.expect(mem_cap.hasRight(Rights.READ));
    try std.testing.expect(mem_cap.hasRight(Rights.WRITE));
    try std.testing.expect(mem_cap.canGrant());
    try std.testing.expect(!mem_cap.hasRight(Rights.EXECUTE));

    const null_cap = Capability.NULL_CAP;
    try std.testing.expect(!null_cap.isValid());
    try std.testing.expect(!null_cap.hasRight(Rights.READ));

    // Capability with zero rights is invalid
    var zero_rights_cap = mem_cap;
    zero_rights_cap.rights = Rights.NONE;
    try std.testing.expect(!zero_rights_cap.isValid());

    // Capability with address overflow is invalid
    var overflow_cap = mem_cap;
    overflow_cap.data_addr = std.math.maxInt(u64) - 100;
    overflow_cap.data_size = 200;
    try std.testing.expect(!overflow_cap.isValid());
}

test "P0-C1: hardware_device and dma_buffer typing, rights, and attenuation" {
    const hw_cap = Capability{
        .cap_type = .hardware_device,
        .rights = Rights.READ | Rights.WRITE | Rights.REVOKE,
        .object_id = 0x1AF4,
        .data_addr = 0xFEB0_0000,
        .data_size = 0x1000,
    };

    try std.testing.expect(hw_cap.isValid());
    try std.testing.expectEqual(CapType.hardware_device, hw_cap.cap_type);
    try std.testing.expect(hw_cap.hasRight(Rights.READ));
    try std.testing.expect(hw_cap.hasRight(Rights.WRITE));
    try std.testing.expect(hw_cap.hasRight(Rights.REVOKE));
    try std.testing.expect(!hw_cap.hasRight(Rights.GRANT));
    try std.testing.expect(!hw_cap.hasRight(Rights.EXECUTE));

    const dma_cap = Capability{
        .cap_type = .dma_buffer,
        .rights = Rights.READ | Rights.WRITE | Rights.GRANT,
        .object_id = 42,
        .data_addr = 0x0020_0000,
        .data_size = 65536,
    };

    try std.testing.expect(dma_cap.isValid());
    try std.testing.expectEqual(CapType.dma_buffer, dma_cap.cap_type);
    try std.testing.expect(dma_cap.hasRight(Rights.READ));
    try std.testing.expect(dma_cap.hasRight(Rights.WRITE));
    try std.testing.expect(dma_cap.canGrant());
    try std.testing.expect(!dma_cap.hasRight(Rights.EXECUTE));
    try std.testing.expect(!dma_cap.hasRight(Rights.REVOKE));

    // Attenuation: READ-only hardware probe token (STG_3_AUDIT_RO)
    var ro_hw = hw_cap;
    ro_hw.rights = hw_cap.rights & Rights.READ;
    try std.testing.expect(ro_hw.isValid());
    try std.testing.expect(ro_hw.hasRight(Rights.READ));
    try std.testing.expect(!ro_hw.hasRight(Rights.WRITE));
    try std.testing.expect(!ro_hw.hasRight(Rights.REVOKE));

    // Phase 4 / P4-C6: rebuild_control capability (0x000A)
    const rebuild_cap = Capability{
        .cap_type = .rebuild_control,
        .rights = Rights.WRITE | Rights.EXECUTE,
        .object_id = 99,
        .data_addr = 0,
        .data_size = 0,
    };
    try std.testing.expect(rebuild_cap.isValid());
    try std.testing.expectEqual(CapType.rebuild_control, rebuild_cap.cap_type);
    try std.testing.expect(rebuild_cap.hasRight(Rights.WRITE));
    try std.testing.expect(rebuild_cap.hasRight(Rights.EXECUTE));
    try std.testing.expect(!rebuild_cap.hasRight(Rights.GRANT));
}
