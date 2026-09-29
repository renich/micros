// MicrOS (µOS) Sovereign A/B Boot Slot Substrate
// Governs sector-aligned BootSlotDescriptor, CAS slot persistence,
// monotonic generation counting, and fail-safe trial-boot rollback.
// Zero libc, freestanding, exactly 512 bytes.

const std = @import("std");
const cas_mod = @import("cas.zig");
const chunk_mod = @import("chunk.zig");
const block = @import("../drivers/block.zig");
const fat32 = @import("fat32.zig");

pub const SLOT_DESCRIPTOR_MAGIC: u32 = 0x534C4F54; // 'SLOT'
pub const SLOT_DESCRIPTOR_VERSION: u16 = 1;

pub const BootSlot = enum(u8) {
    slot_a = 'A',
    slot_b = 'B',

    pub fn alternate(self: BootSlot) BootSlot {
        return switch (self) {
            .slot_a => .slot_b,
            .slot_b => .slot_a,
        };
    }
};

pub const BootSlotFlags = packed struct(u8) {
    trial_canary: bool = false,
    trial_failed: bool = false,
    dirty: bool = false,
    reserved: u5 = 0,
};

pub const BootSlotDescriptor = extern struct {
    // Header (8 bytes)
    magic: u32 align(1) = SLOT_DESCRIPTOR_MAGIC,
    version: u16 align(1) = SLOT_DESCRIPTOR_VERSION,
    active_slot: BootSlot align(1) = .slot_a,
    flags: BootSlotFlags align(1) = .{},

    // Monotonic Generation & Epoch (16 bytes)
    generation: u64 align(1) = 1,
    timestamp: u64 align(1) = 0,

    // Cryptographic Hashes (32 bytes each = 96 bytes)
    active_kernel_hash: [32]u8 align(1) = [_]u8{0} ** 32,
    inactive_kernel_hash: [32]u8 align(1) = [_]u8{0} ** 32,
    system_manifest_hash: [32]u8 align(1) = [_]u8{0} ** 32,

    // Trial Boot Diagnostics & Sentinels (64 bytes)
    trial_deadline_ms: u32 align(1) = 20000,
    trial_boot_count: u32 align(1) = 0,
    last_fault_vec: u16 align(1) = 0,
    last_fault_rip: u64 align(1) = 0,
    reserved_diag: [46]u8 align(1) = [_]u8{0} ** 46,

    // Ed25519 Provenance Signature (64 bytes)
    signature: [64]u8 align(1) = [_]u8{0} ** 64,

    // Padding to exactly 512 bytes (264 bytes)
    reserved_padding: [264]u8 align(1) = [_]u8{0} ** 264,

    pub fn validate(self: *const BootSlotDescriptor) !void {
        if (self.magic != SLOT_DESCRIPTOR_MAGIC) return error.InvalidSlotMagic;
        if (self.version != SLOT_DESCRIPTOR_VERSION) return error.UnsupportedSlotVersion;
        if (self.active_slot != .slot_a and self.active_slot != .slot_b) return error.CorruptActiveSlot;
        if (self.generation == 0) return error.ZeroGeneration;
    }

    pub fn isTrial(self: *const BootSlotDescriptor) bool {
        return self.flags.trial_canary;
    }
};

comptime {
    // Commandment 9 and P4-C2: BootSlotDescriptor must mathematically fit in a single 512-byte sector
    std.debug.assert(@sizeOf(BootSlotDescriptor) == 512);
}

pub const SlotManager = struct {
    desc: BootSlotDescriptor,
    cas: ?*cas_mod.CasEngine,
    esp_dev: ?*block.BlockDevice,
    storage_dev: ?*block.BlockDevice,

    pub fn init(
        cas: ?*cas_mod.CasEngine,
        esp_dev: ?*block.BlockDevice,
        storage_dev: ?*block.BlockDevice,
    ) SlotManager {
        return .{
            .desc = BootSlotDescriptor{},
            .cas = cas,
            .esp_dev = esp_dev,
            .storage_dev = storage_dev,
        };
    }

    pub fn getActiveSlot(self: *const SlotManager) BootSlot {
        return self.desc.active_slot;
    }

    pub fn getGeneration(self: *const SlotManager) u64 {
        return self.desc.generation;
    }

    pub fn stageTrial(
        self: *SlotManager,
        new_kernel_hash: *const [32]u8,
        manifest_hash: *const [32]u8,
        timestamp: u64,
        deadline_ms: u32,
    ) !BootSlot {
        try self.desc.validate();

        const target_slot = self.desc.active_slot.alternate();
        self.desc.generation += 1;
        self.desc.timestamp = timestamp;
        self.desc.inactive_kernel_hash = new_kernel_hash.*;
        self.desc.system_manifest_hash = manifest_hash.*;
        self.desc.trial_deadline_ms = deadline_ms;
        self.desc.trial_boot_count = 0;
        self.desc.flags.trial_canary = true;
        self.desc.flags.trial_failed = false;

        try self.persist();
        return target_slot;
    }

    pub fn confirmBoot(self: *SlotManager) !bool {
        try self.desc.validate();
        if (!self.desc.flags.trial_canary) return false;

        self.desc.flags.trial_canary = false;
        self.desc.flags.trial_failed = false;
        self.desc.active_slot = self.desc.active_slot.alternate();
        self.desc.active_kernel_hash = self.desc.inactive_kernel_hash;

        try self.persist();
        return true;
    }

    pub fn rollbackToPrevious(self: *SlotManager, fault_vec: u16, fault_rip: u64) !void {
        try self.desc.validate();

        // Forward-monotonic rollback: advances generation to invalidate trial attempts
        self.desc.generation += 1;
        self.desc.flags.trial_canary = false;
        self.desc.flags.trial_failed = true;
        self.desc.last_fault_vec = fault_vec;
        self.desc.last_fault_rip = fault_rip;

        try self.persist();
    }

    pub fn persist(self: *SlotManager) !void {
        // P4-C2: Persist via CAS + FAT32 projection (raw-sector writes forbidden)
        if (self.cas) |cas| {
            const raw_desc: [*]const u8 = @ptrCast(&self.desc);
            _ = try cas.putChunk(.raw_blob, raw_desc[0..512], self.storage_dev);
        }

        if (self.esp_dev) |edev| {
            const state_byte: u8 = if (self.desc.flags.trial_canary)
                @intFromEnum(self.desc.active_slot.alternate())
            else
                @intFromEnum(self.desc.active_slot);

            const state_data = [_]u8{ state_byte, '\n' };
            try fat32.writeFile(edev, "/EFI/BOOT/BOOTSTATE.DAT", &state_data);

            const trial_byte: u8 = if (self.desc.flags.trial_canary) '1' else '0';
            const trial_data = [_]u8{ trial_byte, '\n' };
            try fat32.writeFile(edev, "/EFI/BOOT/TRIAL.DAT", &trial_data);
        }
    }

    pub fn syncFromEsp(self: *SlotManager, allocator: std.mem.Allocator) !void {
        const edev = self.esp_dev orelse return;

        if (fat32.readFile(edev, "/EFI/BOOT/BOOTSTATE.DAT", allocator)) |state| {
            defer allocator.free(state);
            if (state.len > 0) {
                if (state[0] == 'A') self.desc.active_slot = .slot_a;
                if (state[0] == 'B') self.desc.active_slot = .slot_b;
            }
        } else |_| {}

        if (fat32.readFile(edev, "/EFI/BOOT/TRIAL.DAT", allocator)) |trial| {
            defer allocator.free(trial);
            if (trial.len > 0 and trial[0] == '1') {
                self.desc.flags.trial_canary = true;
            } else {
                self.desc.flags.trial_canary = false;
            }
        } else |_| {}
    }
};

// ============================================================================
// Colocated Unit Tests
// ============================================================================

test "BootSlotDescriptor binary layout is exactly 512 bytes" {
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(BootSlotDescriptor));
}

test "slot manager stage, confirm, and monotonic generation advance" {
    var sm = SlotManager.init(null, null, null);
    try std.testing.expectEqual(BootSlot.slot_a, sm.getActiveSlot());
    try std.testing.expectEqual(@as(u64, 1), sm.getGeneration());
    try std.testing.expect(!sm.desc.isTrial());

    const k_hash = [_]u8{0xAA} ** 32;
    const m_hash = [_]u8{0xBB} ** 32;

    const target = try sm.stageTrial(&k_hash, &m_hash, 1000, 15000);
    try std.testing.expectEqual(BootSlot.slot_b, target);
    try std.testing.expectEqual(BootSlot.slot_a, sm.getActiveSlot()); // Still slot A until confirmed!
    try std.testing.expectEqual(@as(u64, 2), sm.getGeneration());
    try std.testing.expect(sm.desc.isTrial());
    try std.testing.expectEqual(@as(u32, 15000), sm.desc.trial_deadline_ms);

    const confirmed = try sm.confirmBoot();
    try std.testing.expect(confirmed);
    try std.testing.expect(!sm.desc.isTrial());
    try std.testing.expectEqual(BootSlot.slot_b, sm.getActiveSlot()); // Flipped to B!
    try std.testing.expectEqual(k_hash, sm.desc.active_kernel_hash);
}

test "slot manager trial failure and forward-rollback commit" {
    var sm = SlotManager.init(null, null, null);
    try std.testing.expectEqual(BootSlot.slot_a, sm.getActiveSlot());

    const k_hash = [_]u8{0x11} ** 32;
    const m_hash = [_]u8{0x22} ** 32;

    _ = try sm.stageTrial(&k_hash, &m_hash, 2000, 10000);
    try std.testing.expectEqual(@as(u64, 2), sm.getGeneration());

    // Induce trial failure (e.g. vector 14 at rip 0xDEADBEEF)
    try sm.rollbackToPrevious(14, 0xDEADBEEF);
    try std.testing.expect(!sm.desc.isTrial());
    try std.testing.expect(sm.desc.flags.trial_failed);
    try std.testing.expectEqual(BootSlot.slot_a, sm.getActiveSlot()); // Preserved active slot A!
    try std.testing.expectEqual(@as(u64, 3), sm.getGeneration()); // Monotonic advance forward!
    try std.testing.expectEqual(@as(u16, 14), sm.desc.last_fault_vec);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), sm.desc.last_fault_rip);
}

test "slot manager corrupt descriptor validation fail-closed" {
    var desc = BootSlotDescriptor{
        .magic = 0xBAD0BEEF, // Corrupt magic
    };
    try std.testing.expectError(error.InvalidSlotMagic, desc.validate());

    var desc2 = BootSlotDescriptor{
        .version = 999, // Unsupported version
    };
    try std.testing.expectError(error.UnsupportedSlotVersion, desc2.validate());

    var desc3 = BootSlotDescriptor{
        .generation = 0, // Invalid generation
    };
    try std.testing.expectError(error.ZeroGeneration, desc3.validate());
}
