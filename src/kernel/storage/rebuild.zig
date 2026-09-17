// MicrOS (µOS) Autonomous Rebuild & Generational Rollback Engine
// Governs atomic SystemManifest updates, ESP kernel staging, and fail-safe rollback.
// Zero libc, freestanding, 448-byte SystemManifest in 512-byte CAS chunk.

const std = @import("std");
const cas_mod = @import("cas.zig");
const chunk_mod = @import("chunk.zig");
const block = @import("../drivers/block.zig");
const fat32 = @import("fat32.zig");

pub const SYSTEM_MANIFEST_MAGIC: u32 = 0x4D49434D; // "MICM"
pub const SYSTEM_MANIFEST_ABI_VERSION: u32 = 1;
pub const SYSTEM_MANIFEST_SIZE: usize = 448;

pub const MANIFEST_FLAG_STABLE: u32 = 0x0000_0001;
pub const MANIFEST_FLAG_TRIAL_CANARY: u32 = 0x0000_0002;
pub const MANIFEST_FLAG_ROLLBACK_REQ: u32 = 0x0000_0004;

pub const SystemManifest = extern struct {
    magic: u32 = SYSTEM_MANIFEST_MAGIC,
    abi_version: u32 = SYSTEM_MANIFEST_ABI_VERSION,
    generation: u64,
    timestamp: u64,
    flags: u32,
    reserved0: u32 = 0,

    kernel_hash: [32]u8,
    bundle_hash: [32]u8,
    config_hash: [32]u8,
    prev_manifest_hash: [32]u8,

    signature: [64]u8,
    padding: [224]u8 = [_]u8{0} ** 224,

    pub fn validate(self: *const SystemManifest) !void {
        if (self.magic != SYSTEM_MANIFEST_MAGIC) return error.InvalidManifestMagic;
        if (self.abi_version != SYSTEM_MANIFEST_ABI_VERSION) return error.UnsupportedManifestAbiVersion;
    }

    pub fn isTrial(self: *const SystemManifest) bool {
        return (self.flags & MANIFEST_FLAG_TRIAL_CANARY) != 0;
    }

    pub fn isStable(self: *const SystemManifest) bool {
        return (self.flags & MANIFEST_FLAG_STABLE) != 0;
    }
};

pub const RebuildEngine = struct {
    cas: *cas_mod.CasEngine,
    esp_dev: ?*block.BlockDevice,
    dev: ?*block.BlockDevice,

    pub fn init(
        cas: *cas_mod.CasEngine,
        esp_dev: ?*block.BlockDevice,
        dev: ?*block.BlockDevice,
    ) RebuildEngine {
        return .{
            .cas = cas,
            .esp_dev = esp_dev,
            .dev = dev,
        };
    }

    pub fn getActiveManifest(self: *RebuildEngine) !SystemManifest {
        const root = self.cas.getRootHash();
        const zero_hash = [_]u8{0} ** 32;
        if (std.mem.eql(u8, &root, &zero_hash)) return error.NoActiveManifest;

        var buf align(@alignOf(SystemManifest)) = [_]u8{0} ** SYSTEM_MANIFEST_SIZE;
        const len = try self.cas.getChunk(&root, &buf, self.dev);
        if (len != SYSTEM_MANIFEST_SIZE) return error.CorruptManifestSize;

        const manifest: *const SystemManifest = @ptrCast(@alignCast(&buf));
        try manifest.validate();
        return manifest.*;
    }

    fn stageEspKernel(dev: *block.BlockDevice, kernel_data: []const u8) !void {
        try fat32.writeFile(dev, "/EFI/BOOT/BOOTX64.EFI", kernel_data);
        var trial_marker = [_]u8{'1'};
        _ = fat32.writeFile(dev, "/EFI/BOOT/TRIAL.DAT", &trial_marker) catch {};
    }

    pub fn stageSystemUpdate(
        self: *RebuildEngine,
        kernel_data: []const u8,
        bundle_data: []const u8,
        config_data: []const u8,
        timestamp: u64,
    ) ![32]u8 {
        const k_hash = try self.cas.putChunk(.raw_blob, kernel_data, self.dev);
        const b_hash = try self.cas.putChunk(.raw_blob, bundle_data, self.dev);
        const c_hash = try self.cas.putChunk(.raw_blob, config_data, self.dev);

        var prev_gen: u64 = 0;
        var prev_hash = [_]u8{0} ** 32;
        if (self.getActiveManifest()) |manifest| {
            prev_gen = manifest.generation;
            prev_hash = self.cas.getRootHash();
        } else |_| {}

        var manifest = SystemManifest{
            .generation = prev_gen + 1,
            .timestamp = timestamp,
            .flags = MANIFEST_FLAG_TRIAL_CANARY,
            .kernel_hash = k_hash,
            .bundle_hash = b_hash,
            .config_hash = c_hash,
            .prev_manifest_hash = prev_hash,
            .signature = [_]u8{0} ** 64,
        };

        const raw_manifest: [*]const u8 = @ptrCast(&manifest);
        const manifest_hash = try self.cas.putChunk(
            .system_manifest,
            raw_manifest[0..SYSTEM_MANIFEST_SIZE],
            self.dev,
        );

        if (self.esp_dev) |edev| try stageEspKernel(edev, kernel_data);

        try self.cas.setRootHash(&manifest_hash, self.dev);
        return manifest_hash;
    }

    pub fn confirmBoot(self: *RebuildEngine) !void {
        var manifest = self.getActiveManifest() catch |err| switch (err) {
            error.NoActiveManifest => return,
            else => return err,
        };
        if (!manifest.isTrial()) return;

        manifest.flags = (manifest.flags & ~MANIFEST_FLAG_TRIAL_CANARY) | MANIFEST_FLAG_STABLE;
        const raw_manifest: [*]const u8 = @ptrCast(&manifest);
        const updated_hash = try self.cas.putChunk(
            .system_manifest,
            raw_manifest[0..SYSTEM_MANIFEST_SIZE],
            self.dev,
        );

        if (self.esp_dev) |edev| {
            var trial_marker = [_]u8{'0'};
            _ = fat32.writeFile(edev, "/EFI/BOOT/TRIAL.DAT", &trial_marker) catch {};
        }

        try self.cas.setRootHash(&updated_hash, self.dev);
    }

    pub fn rollbackToPrevious(self: *RebuildEngine, allocator: std.mem.Allocator) !void {
        const active = try self.getActiveManifest();
        const zero_hash = [_]u8{0} ** 32;
        if (std.mem.eql(u8, &active.prev_manifest_hash, &zero_hash)) {
            return error.NoPreviousGeneration;
        }

        var prev_buf align(@alignOf(SystemManifest)) = [_]u8{0} ** SYSTEM_MANIFEST_SIZE;
        const read_len = try self.cas.getChunk(&active.prev_manifest_hash, &prev_buf, self.dev);
        if (read_len != SYSTEM_MANIFEST_SIZE) return error.CorruptManifestSize;

        const prev_manifest: *const SystemManifest = @ptrCast(@alignCast(&prev_buf));
        try prev_manifest.validate();

        if (self.esp_dev) |edev| {
            const kernel_buf = try allocator.alloc(u8, cas_mod.MAX_CHUNK_PAYLOAD_SIZE);
            defer allocator.free(kernel_buf);
            const k_len = try self.cas.getChunk(&prev_manifest.kernel_hash, kernel_buf, self.dev);
            try fat32.writeFile(edev, "/EFI/BOOT/BOOTX64.EFI", kernel_buf[0..k_len]);
            var trial_marker = [_]u8{'0'};
            _ = fat32.writeFile(edev, "/EFI/BOOT/TRIAL.DAT", &trial_marker) catch {};
        }

        try self.cas.setRootHash(&active.prev_manifest_hash, self.dev);
    }
};

test "system manifest binary layout and sector fit" {
    try std.testing.expectEqual(448, @sizeOf(SystemManifest));
    try std.testing.expectEqual(64 + 448, chunk_mod.CHUNK_HEADER_SIZE + @sizeOf(SystemManifest));
    try std.testing.expectEqual(512, chunk_mod.CHUNK_HEADER_SIZE + @sizeOf(SystemManifest));
}

test "rebuild engine state machine lifecycle" {
    const allocator = std.testing.allocator;

    var cache = try @import("block_cache.zig").BlockCache.init(allocator);
    defer cache.deinit();

    var cas = try cas_mod.CasEngine.init(&cache, null, 1000);
    var engine = RebuildEngine.init(&cas, null, null);

    // Initial state: no active manifest
    try std.testing.expectError(error.NoActiveManifest, engine.getActiveManifest());

    // Stage Generation 1 update
    const mock_k1 = "KERNEL_GEN_1_IMAGE";
    const mock_b1 = "BUNDLE_GEN_1_MCB";
    const mock_c1 = "CONFIG_GEN_1_DATA";
    const m1_hash = try engine.stageSystemUpdate(mock_k1, mock_b1, mock_c1, 1000);

    // Check manifest properties
    const man1 = try engine.getActiveManifest();
    try std.testing.expectEqual(@as(u64, 1), man1.generation);
    try std.testing.expect(man1.isTrial());
    try std.testing.expect(!man1.isStable());

    // Confirm boot
    try engine.confirmBoot();
    const man1_confirmed = try engine.getActiveManifest();
    try std.testing.expectEqual(@as(u64, 1), man1_confirmed.generation);
    try std.testing.expect(!man1_confirmed.isTrial());
    try std.testing.expect(man1_confirmed.isStable());

    // Stage Generation 2 update
    const mock_k2 = "KERNEL_GEN_2_FAULTY_IMAGE";
    const mock_b2 = "BUNDLE_GEN_2_MCB";
    const mock_c2 = "CONFIG_GEN_2_DATA";
    _ = try engine.stageSystemUpdate(mock_k2, mock_b2, mock_c2, 2000);

    const man2 = try engine.getActiveManifest();
    try std.testing.expectEqual(@as(u64, 2), man2.generation);
    try std.testing.expect(man2.isTrial());

    // Rollback to Generation 1
    try engine.rollbackToPrevious(allocator);
    const rolled_back = try engine.getActiveManifest();
    try std.testing.expectEqual(@as(u64, 1), rolled_back.generation);
    try std.testing.expect(std.mem.eql(u8, &cas.getRootHash(), &m1_hash) or rolled_back.isStable());
}
