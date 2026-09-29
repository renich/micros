// MicrOS (µOS) P2P Artifact Replication & Tombstone Protocol
// SPEC-TECH-P2P-002: Decentralized CAS artifact publish, pull, and signed tombstones.
// Zero libc, freestanding, capability-safe, bounded execution.

const std = @import("std");

pub const HASH_SIZE: usize = 32;
pub const MAX_NAME_LEN: usize = 48;
pub const MAX_PUBLISHED: usize = 32;
pub const MAX_TOMBSTONES: usize = 32;
pub const PUBKEY_SIZE: usize = 32;
pub const SIGNATURE_SIZE: usize = 64;

pub const Tombstone = extern struct {
    artifact_hash: [HASH_SIZE]u8 align(1),
    timestamp: u64 align(1),
    signer_pubkey: [PUBKEY_SIZE]u8 align(1),
    signature: [SIGNATURE_SIZE]u8 align(1),

    pub fn init(
        artifact_hash: *const [HASH_SIZE]u8,
        timestamp: u64,
        key_pair: *const std.crypto.sign.Ed25519.KeyPair,
    ) !Tombstone {
        var t = Tombstone{
            .artifact_hash = artifact_hash.*,
            .timestamp = timestamp,
            .signer_pubkey = key_pair.public_key.toBytes(),
            .signature = undefined,
        };
        var sign_data: [HASH_SIZE + 8 + PUBKEY_SIZE]u8 = undefined;
        @memcpy(sign_data[0..HASH_SIZE], &t.artifact_hash);
        @memcpy(sign_data[HASH_SIZE .. HASH_SIZE + 8], std.mem.asBytes(&t.timestamp));
        @memcpy(sign_data[HASH_SIZE + 8 .. HASH_SIZE + 8 + PUBKEY_SIZE], &t.signer_pubkey);

        const sig = try key_pair.sign(&sign_data, null);
        t.signature = sig.toBytes();
        return t;
    }

    pub fn verify(self: *const Tombstone) bool {
        const pubkey = std.crypto.sign.Ed25519.PublicKey.fromBytes(self.signer_pubkey) catch return false;
        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(self.signature);
        var sign_data: [HASH_SIZE + 8 + PUBKEY_SIZE]u8 = undefined;
        @memcpy(sign_data[0..HASH_SIZE], &self.artifact_hash);
        @memcpy(sign_data[HASH_SIZE .. HASH_SIZE + 8], std.mem.asBytes(&self.timestamp));
        @memcpy(sign_data[HASH_SIZE + 8 .. HASH_SIZE + 8 + PUBKEY_SIZE], &self.signer_pubkey);

        sig.verify(&sign_data, pubkey) catch return false;
        return true;
    }
};

pub const PublishedArtifact = struct {
    hash: [HASH_SIZE]u8,
    name: [MAX_NAME_LEN]u8,
    name_len: usize,
    author_pubkey: [PUBKEY_SIZE]u8,
    size: u64,

    pub fn getName(self: *const PublishedArtifact) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const ReplicationManager = struct {
    published: [MAX_PUBLISHED]?PublishedArtifact = [_]?PublishedArtifact{null} ** MAX_PUBLISHED,
    published_count: usize = 0,
    tombstones: [MAX_TOMBSTONES]?Tombstone = [_]?Tombstone{null} ** MAX_TOMBSTONES,
    tombstone_count: usize = 0,

    pub fn init() ReplicationManager {
        return ReplicationManager{};
    }

    pub fn isTombstoned(self: *const ReplicationManager, hash: *const [HASH_SIZE]u8) bool {
        for (self.tombstones[0..self.tombstone_count]) |opt_t| {
            if (opt_t) |t| {
                if (std.mem.eql(u8, &t.artifact_hash, hash)) return true;
            }
        }
        return false;
    }

    pub fn publish(
        self: *ReplicationManager,
        hash: *const [HASH_SIZE]u8,
        name: []const u8,
        author_pubkey: *const [PUBKEY_SIZE]u8,
        size: u64,
    ) !void {
        if (self.isTombstoned(hash)) return error.ArtifactTombstoned;
        if (name.len > MAX_NAME_LEN) return error.NameTooLong;

        for (0..self.published_count) |i| {
            if (self.published[i]) |*p| {
                if (std.mem.eql(u8, &p.hash, hash)) {
                    p.size = size;
                    return;
                }
            }
        }

        if (self.published_count >= MAX_PUBLISHED) return error.CatalogFull;

        var name_buf = [_]u8{0} ** MAX_NAME_LEN;
        @memcpy(name_buf[0..name.len], name);

        self.published[self.published_count] = PublishedArtifact{
            .hash = hash.*,
            .name = name_buf,
            .name_len = name.len,
            .author_pubkey = author_pubkey.*,
            .size = size,
        };
        self.published_count += 1;
    }

    pub fn findPublished(self: *const ReplicationManager, hash: *const [HASH_SIZE]u8) ?*const PublishedArtifact {
        if (self.isTombstoned(hash)) return null;
        for (self.published[0..self.published_count]) |*opt_p| {
            if (opt_p.*) |*p| {
                if (std.mem.eql(u8, &p.hash, hash)) return p;
            }
        }
        return null;
    }

    pub fn unpublish(
        self: *ReplicationManager,
        hash: *const [HASH_SIZE]u8,
        timestamp: u64,
        key_pair: *const std.crypto.sign.Ed25519.KeyPair,
    ) !Tombstone {
        const tombstone = try Tombstone.init(hash, timestamp, key_pair);
        try self.recordTombstone(tombstone);
        return tombstone;
    }

    pub fn receiveTombstone(self: *ReplicationManager, tombstone: *const Tombstone) !void {
        if (!tombstone.verify()) return error.InvalidTombstoneSignature;
        try self.recordTombstone(tombstone.*);
    }

    fn recordTombstone(self: *ReplicationManager, tombstone: Tombstone) !void {
        if (self.isTombstoned(&tombstone.artifact_hash)) return;

        if (self.tombstone_count >= MAX_TOMBSTONES) return error.TombstoneLimitReached;
        self.tombstones[self.tombstone_count] = tombstone;
        self.tombstone_count += 1;

        self.deindexPublished(&tombstone.artifact_hash);
    }

    fn removePublishedIndex(self: *ReplicationManager, idx: usize) void {
        var j = idx;
        while (j + 1 < self.published_count) : (j += 1) {
            self.published[j] = self.published[j + 1];
        }
        self.published[self.published_count - 1] = null;
        self.published_count -= 1;
    }

    fn deindexPublished(self: *ReplicationManager, hash: *const [HASH_SIZE]u8) void {
        var i: usize = 0;
        while (i < self.published_count) {
            const entry = self.published[i] orelse {
                i += 1;
                continue;
            };
            if (std.mem.eql(u8, &entry.hash, hash)) {
                self.removePublishedIndex(i);
                continue;
            }
            i += 1;
        }
    }
};

// === Colocated Unit Tests ===

test "ReplicationManager publish and lookup" {
    var mgr = ReplicationManager.init();
    const hash = [_]u8{0x55} ** HASH_SIZE;
    const author = [_]u8{0x11} ** PUBKEY_SIZE;

    try mgr.publish(&hash, "editor.app", &author, 1024);
    try std.testing.expectEqual(@as(usize, 1), mgr.published_count);

    const found = mgr.findPublished(&hash);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("editor.app", found.?.getName());
    try std.testing.expectEqual(@as(u64, 1024), found.?.size);
}

test "ReplicationManager signed tombstone generation and verification" {
    const seed = [_]u8{0x33} ** 32;
    const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    const hash = [_]u8{0x77} ** HASH_SIZE;
    const tombstone = try Tombstone.init(&hash, 1000, &key_pair);

    try std.testing.expect(tombstone.verify());
    try std.testing.expectEqualStrings(&hash, &tombstone.artifact_hash);
    try std.testing.expectEqual(@as(u64, 1000), tombstone.timestamp);

    // Tampered tombstone fails verification
    var tampered = tombstone;
    tampered.timestamp = 2000;
    try std.testing.expect(!tampered.verify());
}

test "ReplicationManager tombstone de-indexes artifact and rejects pull" {
    const seed = [_]u8{0x44} ** 32;
    const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    var mgr = ReplicationManager.init();
    const hash = [_]u8{0x88} ** HASH_SIZE;
    const author = key_pair.public_key.toBytes();

    try mgr.publish(&hash, "shell.mx", &author, 2048);
    try std.testing.expect(mgr.findPublished(&hash) != null);

    // Unpublish emits signed tombstone
    const tombstone = try mgr.unpublish(&hash, 500, &key_pair);
    try std.testing.expect(tombstone.verify());

    // Artifact is de-indexed
    try std.testing.expectEqual(@as(usize, 0), mgr.published_count);
    try std.testing.expect(mgr.findPublished(&hash) == null);
    try std.testing.expect(mgr.isTombstoned(&hash));

    // Subsequent publish of tombstoned artifact is rejected
    const rep_err = mgr.publish(&hash, "shell.mx", &author, 2048);
    try std.testing.expectError(error.ArtifactTombstoned, rep_err);
}

test "ReplicationManager forged tombstone signature fails verification" {
    var mgr = ReplicationManager.init();
    const hash = [_]u8{0x99} ** HASH_SIZE;

    // Forged tombstone with invalid signature bytes
    const forged = Tombstone{
        .artifact_hash = hash,
        .timestamp = 100,
        .signer_pubkey = [_]u8{0xAA} ** PUBKEY_SIZE,
        .signature = [_]u8{0xBB} ** SIGNATURE_SIZE,
    };

    const err = mgr.receiveTombstone(&forged);
    try std.testing.expectError(error.InvalidTombstoneSignature, err);
}

test "ReplicationManager round-trip wire publish -> pull -> run simulation" {
    const seed_a = [_]u8{0x01} ** 32;
    const key_a = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed_a);
    const pubkey_a = key_a.public_key.toBytes();

    const seed_b = [_]u8{0x02} ** 32;
    const key_b = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed_b);

    var node_a_mgr = ReplicationManager.init();
    var node_b_mgr = ReplicationManager.init();

    // 1. Node A publishes an actor artifact
    const bytecode = "print(\"peer actor online\");";
    var hash: [HASH_SIZE]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytecode, &hash, .{});

    try node_a_mgr.publish(&hash, "peer_task", &pubkey_a, bytecode.len);
    try std.testing.expect(node_a_mgr.findPublished(&hash) != null);

    // 2. Node B pulls the artifact across simulated wire
    const pulled = node_a_mgr.findPublished(&hash);
    try std.testing.expect(pulled != null);

    // Node B verifies BLAKE3 hash
    var computed_hash: [HASH_SIZE]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytecode, &computed_hash, .{});
    try std.testing.expectEqualStrings(&hash, &computed_hash);

    // Node B records published locally
    try node_b_mgr.publish(&hash, pulled.?.getName(), &pulled.?.author_pubkey, pulled.?.size);
    try std.testing.expect(node_b_mgr.findPublished(&hash) != null);

    // 3. Node A unpublishes and emits signed tombstone
    const tombstone = try node_a_mgr.unpublish(&hash, 100, &key_a);
    try std.testing.expect(tombstone.verify());

    // 4. Wire propagates tombstone to Node B
    try node_b_mgr.receiveTombstone(&tombstone);

    // 5. Node B de-indexes and marks tombstoned
    try std.testing.expect(node_b_mgr.isTombstoned(&hash));
    try std.testing.expect(node_b_mgr.findPublished(&hash) == null);

    _ = key_b;
}
