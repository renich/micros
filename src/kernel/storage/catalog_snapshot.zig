// MicrOS (µOS) Catalog Generation Snapshot Ring
// Bounded in-memory window of workspace manifest generations used for OCC undo and
// @gen-pinned reads. The ring is deliberately RAM-only: durability lives in the CAS
// root directory (see root_dir.zig and catalog_root.zig).
// Zero libc, freestanding, explicit allocator.

const std = @import("std");
const chunk_mod = @import("chunk.zig");
const manifest_mod = @import("manifest.zig");
const WorkspaceManifest = manifest_mod.WorkspaceManifest;

pub const MAX_SNAPSHOT_GENERATIONS: usize = 16;

pub const GenerationSnapshot = struct {
    generation: u64 = 0,
    manifest_cas_hash: [chunk_mod.HASH_SIZE]u8 = [_]u8{0} ** chunk_mod.HASH_SIZE,
    manifest: WorkspaceManifest = .{},
    valid: bool = false,
};

pub const SnapshotRing = struct {
    snapshots: [MAX_SNAPSHOT_GENERATIONS]GenerationSnapshot = [_]GenerationSnapshot{.{}} ** MAX_SNAPSHOT_GENERATIONS,
    head: usize = 0,
    count: usize = 0,

    pub fn push(self: *SnapshotRing, manifest: *const WorkspaceManifest, cas_hash: *const [chunk_mod.HASH_SIZE]u8) void {
        const slot = self.head;
        self.snapshots[slot] = .{
            .generation = manifest.header.generation,
            .manifest_cas_hash = cas_hash.*,
            .manifest = manifest.*,
            .valid = true,
        };
        self.head = (self.head + 1) % MAX_SNAPSHOT_GENERATIONS;
        if (self.count < MAX_SNAPSHOT_GENERATIONS) {
            self.count += 1;
        }
    }

    pub fn getOldestLiveGeneration(self: *const SnapshotRing) u64 {
        if (self.count == 0) return 1;
        if (self.count < MAX_SNAPSHOT_GENERATIONS) {
            return self.snapshots[0].generation;
        }
        return self.snapshots[self.head].generation;
    }

    pub fn findSnapshot(self: *const SnapshotRing, gen: u64) ?*const GenerationSnapshot {
        if (self.count == 0) return null;
        for (0..self.count) |i| {
            const idx = if (self.count < MAX_SNAPSHOT_GENERATIONS)
                i
            else
                (self.head + i) % MAX_SNAPSHOT_GENERATIONS;
            if (self.snapshots[idx].valid and self.snapshots[idx].generation == gen) {
                return &self.snapshots[idx];
            }
        }
        return null;
    }

    pub fn getPreviousSnapshot(self: *const SnapshotRing) ?*const GenerationSnapshot {
        if (self.count <= 1) return null;
        const prev_idx = (self.head + MAX_SNAPSHOT_GENERATIONS - 2) % MAX_SNAPSHOT_GENERATIONS;
        if (self.snapshots[prev_idx].valid) {
            return &self.snapshots[prev_idx];
        }
        return null;
    }
};

test "snapshot ring evicts the oldest generation once full" {
    var ring = SnapshotRing{};
    var hash = [_]u8{0} ** chunk_mod.HASH_SIZE;

    var gen: u64 = 1;
    while (gen <= MAX_SNAPSHOT_GENERATIONS + 1) : (gen += 1) {
        hash[0] = @intCast(gen % 256);
        const manifest = WorkspaceManifest.init(gen, &hash);
        ring.push(&manifest, &hash);
    }

    try std.testing.expectEqual(MAX_SNAPSHOT_GENERATIONS, ring.count);
    try std.testing.expectEqual(@as(u64, 2), ring.getOldestLiveGeneration());
    try std.testing.expect(ring.findSnapshot(1) == null);
    try std.testing.expect(ring.findSnapshot(2) != null);
}

test "snapshot ring reports no previous generation until two exist" {
    var ring = SnapshotRing{};
    const hash = [_]u8{0xAB} ** chunk_mod.HASH_SIZE;
    const first = WorkspaceManifest.init(1, &hash);

    try std.testing.expect(ring.getPreviousSnapshot() == null);
    ring.push(&first, &hash);
    try std.testing.expect(ring.getPreviousSnapshot() == null);

    const second = WorkspaceManifest.init(2, &hash);
    ring.push(&second, &hash);
    const prev = ring.getPreviousSnapshot() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 1), prev.generation);
}
