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
