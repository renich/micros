// MicrOS (µOS) Distributed Content-Addressed Storage (CAS) & Merkle Sync Engine
// SPEC-TECH-P2P-002: Decentralized CAS replication, Merkle tree difference exchange, and OCC reconciliation.
// Zero libc, freestanding, capability-safe, bounded execution.

const std = @import("std");

pub const HASH_SIZE: usize = 32;
pub const MAX_PATH_LEN: usize = 64;
pub const MAX_MERKLE_ENTRIES: usize = 128;
pub const CHUNK_RESP_HEADER_SIZE: usize = 40;

pub const ChunkType = enum(u32) {
    raw_blob = 1,
    actor_source = 2,
    bytecode_chunk = 3,
    merkle_node = 4,
    system_manifest = 5,
    workspace_manifest = 6,
};

pub const ChunkRequest = extern struct {
    hash: [HASH_SIZE]u8 align(1),

    pub fn serialize(self: *const ChunkRequest, out_buf: *[HASH_SIZE]u8) void {
        @memcpy(out_buf, &self.hash);
    }

    pub fn deserialize(in_buf: *const [HASH_SIZE]u8) ChunkRequest {
        var req: ChunkRequest = undefined;
        @memcpy(&req.hash, in_buf);
        return req;
    }
};

pub const ChunkEnvelope = extern struct {
    hash: [HASH_SIZE]u8 align(1),
    chunk_type: ChunkType align(1),
    payload_len: u32 align(1),

    pub fn serialize(self: *const ChunkEnvelope, payload: []const u8, out_buf: []u8) !usize {
        if (out_buf.len < CHUNK_RESP_HEADER_SIZE or payload.len > out_buf.len - CHUNK_RESP_HEADER_SIZE) return error.BufferTooSmall;
        const total = CHUNK_RESP_HEADER_SIZE + payload.len;

        const hdr_bytes: *const [CHUNK_RESP_HEADER_SIZE]u8 = @ptrCast(self);
        @memcpy(out_buf[0..CHUNK_RESP_HEADER_SIZE], hdr_bytes);
        @memcpy(out_buf[CHUNK_RESP_HEADER_SIZE..total], payload);
        return total;
    }

    pub fn deserialize(in_buf: []const u8) !struct { header: ChunkEnvelope, payload: []const u8 } {
        if (in_buf.len < CHUNK_RESP_HEADER_SIZE) return error.InvalidPayloadSize;
        const hdr_ptr: *const ChunkEnvelope = @ptrCast(in_buf.ptr);
        if (hdr_ptr.payload_len > in_buf.len - CHUNK_RESP_HEADER_SIZE) return error.IncompletePayload;
        const expected_total = CHUNK_RESP_HEADER_SIZE + hdr_ptr.payload_len;

        return .{
            .header = hdr_ptr.*,
            .payload = in_buf[CHUNK_RESP_HEADER_SIZE..expected_total],
        };
    }

    pub fn verifyIntegrity(self: *const ChunkEnvelope, payload: []const u8) bool {
        if (payload.len != self.payload_len) return false;
        var computed: [HASH_SIZE]u8 = undefined;
        std.crypto.hash.Blake3.hash(payload, &computed, .{});
        return std.mem.eql(u8, &self.hash, &computed);
    }
};

pub const MerkleEntry = extern struct {
    path_len: u16 align(1),
    path: [MAX_PATH_LEN]u8 align(1),
    size: u64 align(1),
    hash: [HASH_SIZE]u8 align(1),

    pub fn init(path_str: []const u8, size: u64, hash: *const [HASH_SIZE]u8) !MerkleEntry {
        if (path_str.len > MAX_PATH_LEN) return error.PathTooLong;
        var entry = MerkleEntry{
            .path_len = @intCast(path_str.len),
            .path = [_]u8{0} ** MAX_PATH_LEN,
            .size = size,
            .hash = hash.*,
        };
        @memcpy(entry.path[0..path_str.len], path_str);
        return entry;
    }

    pub fn getPath(self: *const MerkleEntry) []const u8 {
        const len = @min(@as(usize, self.path_len), MAX_PATH_LEN);
        return self.path[0..len];
    }
};

pub const MerkleTree = struct {
    generation: u64,
    root_hash: [HASH_SIZE]u8,
    entry_count: usize,
    entries: [MAX_MERKLE_ENTRIES]MerkleEntry,

    pub fn init(generation: u64) MerkleTree {
        return MerkleTree{
            .generation = generation,
            .root_hash = [_]u8{0} ** HASH_SIZE,
            .entry_count = 0,
            .entries = undefined,
        };
    }

    pub fn addEntry(self: *MerkleTree, entry: MerkleEntry) !void {
        if (self.entry_count >= MAX_MERKLE_ENTRIES) return error.TreeFull;
        self.entries[self.entry_count] = entry;
        self.entry_count += 1;
        self.sortEntries();
        self.recomputeRoot();
    }

    pub fn findEntry(self: *const MerkleTree, path_str: []const u8) ?*const MerkleEntry {
        for (self.entries[0..self.entry_count]) |*e| {
            if (std.mem.eql(u8, e.getPath(), path_str)) return e;
        }
        return null;
    }

    fn sortEntries(self: *MerkleTree) void {
        if (self.entry_count <= 1) return;
        var i: usize = 1;
        while (i < self.entry_count) : (i += 1) {
            var j = i;
            while (j > 0 and std.mem.order(u8, self.entries[j - 1].getPath(), self.entries[j].getPath()) == .gt) : (j -= 1) {
                const tmp = self.entries[j - 1];
                self.entries[j - 1] = self.entries[j];
                self.entries[j] = tmp;
            }
        }
    }

    pub fn recomputeRoot(self: *MerkleTree) void {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(std.mem.asBytes(&self.generation));
        for (self.entries[0..self.entry_count]) |*e| {
            hasher.update(e.getPath());
            hasher.update(std.mem.asBytes(&e.size));
            hasher.update(&e.hash);
        }
        hasher.final(&self.root_hash);
    }
};

pub const MerkleDifference = struct {
    pub fn computeMissingHashes(
        local: *const MerkleTree,
        remote: *const MerkleTree,
        out_hashes: *[MAX_MERKLE_ENTRIES][HASH_SIZE]u8,
    ) usize {
        var count: usize = 0;
        for (remote.entries[0..remote.entry_count]) |*re| {
            const local_match = local.findEntry(re.getPath());
            if (local_match == null or !std.mem.eql(u8, &local_match.?.hash, &re.hash)) {
                if (count < MAX_MERKLE_ENTRIES) {
                    out_hashes[count] = re.hash;
                    count += 1;
                }
            }
        }
        return count;
    }
};

pub const OccReconciler = struct {
    pub fn reconcile(local: *MerkleTree, remote: *const MerkleTree) !void {
        for (remote.entries[0..remote.entry_count]) |*re| {
            const local_match = local.findEntry(re.getPath());
            if (local_match == null) {
                try local.addEntry(re.*);
            } else if (!std.mem.eql(u8, &local_match.?.hash, &re.hash)) {
                try resolveEntryConflict(local, local_match.?, re);
            }
        }
        local.generation = @max(local.generation, remote.generation) + 1;
        local.sortEntries();
        local.recomputeRoot();
    }

    fn resolveEntryConflict(local: *MerkleTree, local_entry: *const MerkleEntry, remote_entry: *const MerkleEntry) !void {
        // Deterministic lexicographical tie-break for canonical path
        if (std.mem.order(u8, &remote_entry.hash, &local_entry.hash) == .gt) {
            // Overwrite existing local entry with higher-hash remote entry
            for (local.entries[0..local.entry_count]) |*e| {
                if (std.mem.eql(u8, e.getPath(), local_entry.getPath())) {
                    e.hash = remote_entry.hash;
                    e.size = remote_entry.size;
                    break;
                }
            }
        }
    }
};

test "ChunkRequest serialization and deserialization" {
    const hash = [_]u8{0xAB} ** HASH_SIZE;
    const req = ChunkRequest{ .hash = hash };

    var buf: [HASH_SIZE]u8 = undefined;
    req.serialize(&buf);

    const parsed = ChunkRequest.deserialize(&buf);
    try std.testing.expectEqualStrings(&hash, &parsed.hash);
}

test "ChunkEnvelope serialization, integrity verification, and tamper rejection" {
    const payload = "MicrOS Content-Addressed Storage Payload";
    var expected_hash: [HASH_SIZE]u8 = undefined;
    std.crypto.hash.Blake3.hash(payload, &expected_hash, .{});

    const env = ChunkEnvelope{
        .hash = expected_hash,
        .chunk_type = .actor_source,
        .payload_len = @intCast(payload.len),
    };

    var buf: [128]u8 = undefined;
    const written = try env.serialize(payload, &buf);
    try std.testing.expectEqual(CHUNK_RESP_HEADER_SIZE + payload.len, written);

    const parsed = try ChunkEnvelope.deserialize(buf[0..written]);
    try std.testing.expectEqual(ChunkType.actor_source, parsed.header.chunk_type);
    try std.testing.expectEqualStrings(payload, parsed.payload);
    try std.testing.expect(parsed.header.verifyIntegrity(parsed.payload));

    // Tampered payload fails verification
    var tampered_buf: [128]u8 = undefined;
    @memcpy(tampered_buf[0..written], buf[0..written]);
    tampered_buf[written - 1] ^= 0xFF;
    const tampered = try ChunkEnvelope.deserialize(tampered_buf[0..written]);
    try std.testing.expect(!tampered.header.verifyIntegrity(tampered.payload));
}

test "MerkleTree entry addition, path sorting, and deterministic root hashing" {
    var tree1 = MerkleTree.init(1);
    const hash_a = [_]u8{0x11} ** HASH_SIZE;
    const hash_b = [_]u8{0x22} ** HASH_SIZE;

    const entry_b = try MerkleEntry.init("src/kernel/sys.zig", 1024, &hash_b);
    const entry_a = try MerkleEntry.init("lib/macros/init.mx", 512, &hash_a);

    // Add out of alphabetical order
    try tree1.addEntry(entry_b);
    try tree1.addEntry(entry_a);

    // Sorting ensures lib/macros/init.mx is index 0
    try std.testing.expectEqualStrings("lib/macros/init.mx", tree1.entries[0].getPath());
    try std.testing.expectEqualStrings("src/kernel/sys.zig", tree1.entries[1].getPath());

    // Identical tree built in reverse order must produce identical root_hash
    var tree2 = MerkleTree.init(1);
    try tree2.addEntry(entry_a);
    try tree2.addEntry(entry_b);
    try std.testing.expectEqualStrings(&tree1.root_hash, &tree2.root_hash);
}

test "MerkleDifference missing hash computation" {
    var local = MerkleTree.init(1);
    var remote = MerkleTree.init(2);

    const hash1 = [_]u8{0x01} ** HASH_SIZE;
    const hash2 = [_]u8{0x02} ** HASH_SIZE;
    const hash3 = [_]u8{0x03} ** HASH_SIZE;

    try local.addEntry(try MerkleEntry.init("shared.mx", 100, &hash1));

    try remote.addEntry(try MerkleEntry.init("shared.mx", 100, &hash1));
    try remote.addEntry(try MerkleEntry.init("remote_only.mx", 200, &hash2));
    try remote.addEntry(try MerkleEntry.init("modified.mx", 300, &hash3));

    var missing_hashes: [MAX_MERKLE_ENTRIES][HASH_SIZE]u8 = undefined;
    const count = MerkleDifference.computeMissingHashes(&local, &remote, &missing_hashes);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings(&hash3, &missing_hashes[0]); // modified.mx
    try std.testing.expectEqualStrings(&hash2, &missing_hashes[1]); // remote_only.mx
}

test "OccReconciler offline-first reconciliation and monotonic generation advance" {
    var local = MerkleTree.init(10);
    var remote = MerkleTree.init(12);

    const hash_old = [_]u8{0x10} ** HASH_SIZE;
    const hash_new = [_]u8{0x20} ** HASH_SIZE;
    const hash_extra = [_]u8{0x30} ** HASH_SIZE;

    try local.addEntry(try MerkleEntry.init("main.mx", 500, &hash_old));

    try remote.addEntry(try MerkleEntry.init("main.mx", 520, &hash_new));
    try remote.addEntry(try MerkleEntry.init("extra.mx", 100, &hash_extra));

    try OccReconciler.reconcile(&local, &remote);

    // Monotonic generation advances to max(10, 12) + 1 = 13
    try std.testing.expectEqual(@as(u64, 13), local.generation);
    try std.testing.expectEqual(@as(usize, 2), local.entry_count);

    // main.mx conflict resolved to hash_new (0x20 > 0x10)
    const main_entry = local.findEntry("main.mx");
    try std.testing.expect(main_entry != null);
    try std.testing.expectEqualStrings(&hash_new, &main_entry.?.hash);

    // extra.mx incorporated
    const extra_entry = local.findEntry("extra.mx");
    try std.testing.expect(extra_entry != null);
    try std.testing.expectEqualStrings(&hash_extra, &extra_entry.?.hash);
}
