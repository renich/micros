// MicrOS (µOS) G7 Provenance Substrate
// Cryptographic Ed25519 authorship, badge assignment, and bytecode integrity verification.
// Zero libc, freestanding, constant-time verification.

const std = @import("std");

pub const ProvenanceType = enum(u8) {
    genesis = 0,
    ai = 1,
    peer = 2,

    pub fn getBadgeText(self: ProvenanceType) []const u8 {
        return switch (self) {
            .genesis => "[gen]",
            .ai => "[ai]",
            .peer => "[peer]",
        };
    }
};

pub const Authorship = struct {
    origin: ProvenanceType,
    author_pubkey: [32]u8,
    signature: [64]u8,

    pub fn init(origin: ProvenanceType, key_pair: *const std.crypto.sign.Ed25519.KeyPair, code: []const u8) !Authorship {
        const sig = try key_pair.sign(code, null);
        return Authorship{
            .origin = origin,
            .author_pubkey = key_pair.public_key.toBytes(),
            .signature = sig.toBytes(),
        };
    }

    pub fn verify(self: *const Authorship, code: []const u8) bool {
        const pubkey = std.crypto.sign.Ed25519.PublicKey.fromBytes(self.author_pubkey) catch return false;
        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(self.signature);
        sig.verify(code, pubkey) catch return false;
        return true;
    }
};

pub fn signBytecode(key_pair: *const std.crypto.sign.Ed25519.KeyPair, code: []const u8) ![64]u8 {
    const sig = try key_pair.sign(code, null);
    return sig.toBytes();
}

pub fn verifyBytecode(pubkey_bytes: [32]u8, code: []const u8, sig_bytes: [64]u8) bool {
    const pubkey = std.crypto.sign.Ed25519.PublicKey.fromBytes(pubkey_bytes) catch return false;
    const sig = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes);
    sig.verify(code, pubkey) catch return false;
    return true;
}

test "G7: sign, verify valid Ed25519 authorship succeeds" {
    const seed = [_]u8{0x42} ** 32;
    const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    const bytecode = "sys_window_draw_rect(1, 10, 10, 50, 50, 0xFF00FF);";
    const auth = try Authorship.init(.ai, &key_pair, bytecode);

    try std.testing.expect(auth.verify(bytecode));
    try std.testing.expectEqualStrings("[ai]", auth.origin.getBadgeText());
}

test "G7: modified bytecode fails authorship check (tamper test)" {
    const seed = [_]u8{0x99} ** 32;
    const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    var bytecode = [_]u8{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80 };
    const sig = try signBytecode(&key_pair, &bytecode);
    const pubkey = key_pair.public_key.toBytes();

    // Verification succeeds on authentic bytecode
    try std.testing.expect(verifyBytecode(pubkey, &bytecode, sig));

    // Tamper with single byte
    bytecode[3] ^= 0xFF;

    // Authorship check mathematically fails
    try std.testing.expect(!verifyBytecode(pubkey, &bytecode, sig));
}

pub const PROVENANCE_SEAL_MAGIC: u32 = 0x50524F56; // 'PROV'
pub const PROVENANCE_SEAL_VERSION: u16 = 1;

pub const ArtifactProvenanceSeal = extern struct {
    // Header (8 bytes)
    magic: u32 align(1) = PROVENANCE_SEAL_MAGIC,
    version: u16 align(1) = PROVENANCE_SEAL_VERSION,
    origin_type: u8 align(1) = 0, // 0=genesis, 1=ai_synthesis, 2=peer_replicate
    flags: u8 align(1) = 0,

    // Emitter Metadata (24 bytes)
    emitter_id: [16]u8 align(1) = [_]u8{0} ** 16,
    timestamp: u64 align(1) = 0,

    // Cryptographic Input Lineage (96 bytes)
    input_bundle_hash: [32]u8 align(1) = [_]u8{0} ** 32,
    substrate_code_hash: [32]u8 align(1) = [_]u8{0} ** 32,
    config_hash: [32]u8 align(1) = [_]u8{0} ** 32,

    // Output Artifact Hash (32 bytes)
    emitted_artifact_hash: [32]u8 align(1) = [_]u8{0} ** 32,

    // Ed25519 Cryptographic Signature (96 bytes)
    author_pubkey: [32]u8 align(1) = [_]u8{0} ** 32,
    signature: [64]u8 align(1) = [_]u8{0} ** 64,

    pub fn initGenesis(
        key_pair: *const std.crypto.sign.Ed25519.KeyPair,
        bundle_data: []const u8,
        substrate_code: []const u8,
        config_data: []const u8,
        artifact_bytes: []const u8,
    ) !ArtifactProvenanceSeal {
        var seal = ArtifactProvenanceSeal{
            .magic = PROVENANCE_SEAL_MAGIC,
            .version = PROVENANCE_SEAL_VERSION,
            .origin_type = @intFromEnum(ProvenanceType.genesis),
            .flags = 0,
            .emitter_id = [_]u8{ 'm', 'i', 'c', 'r', 'o', 's', '-', 'g', 'e', 'n', 'e', 's', 'i', 's', 0, 0 },
            .timestamp = 0,
            .input_bundle_hash = undefined,
            .substrate_code_hash = undefined,
            .config_hash = undefined,
            .emitted_artifact_hash = undefined,
            .author_pubkey = key_pair.public_key.toBytes(),
            .signature = undefined,
        };

        std.crypto.hash.Blake3.hash(bundle_data, &seal.input_bundle_hash, .{});
        std.crypto.hash.Blake3.hash(substrate_code, &seal.substrate_code_hash, .{});
        std.crypto.hash.Blake3.hash(config_data, &seal.config_hash, .{});
        std.crypto.hash.Blake3.hash(artifact_bytes, &seal.emitted_artifact_hash, .{});

        const sig = try key_pair.sign(&seal.emitted_artifact_hash, null);
        seal.signature = sig.toBytes();
        return seal;
    }

    pub fn verify(self: *const ArtifactProvenanceSeal, artifact_bytes: []const u8) bool {
        if (self.magic != PROVENANCE_SEAL_MAGIC or self.version != PROVENANCE_SEAL_VERSION) {
            return false;
        }
        var expected_hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(artifact_bytes, &expected_hash, .{});
        if (!std.mem.eql(u8, &expected_hash, &self.emitted_artifact_hash)) {
            return false;
        }
        const pubkey = std.crypto.sign.Ed25519.PublicKey.fromBytes(self.author_pubkey) catch return false;
        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(self.signature);
        sig.verify(&self.emitted_artifact_hash, pubkey) catch return false;
        return true;
    }
};

comptime {
    std.debug.assert(@sizeOf(ArtifactProvenanceSeal) == 256);
}

test "G7: ArtifactProvenanceSeal 256-byte layout and verification" {
    try std.testing.expectEqual(@as(usize, 256), @sizeOf(ArtifactProvenanceSeal));

    const seed = [_]u8{0x55} ** 32;
    const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    const artifact_data = "MZ_MOCK_PE_KERNEL_IMAGE_BINARY_DATA";
    const seal = try ArtifactProvenanceSeal.initGenesis(
        &key_pair,
        "test_bundle_mcb",
        "substrate_code",
        "config_data",
        artifact_data,
    );

    try std.testing.expect(seal.verify(artifact_data));

    // Tampered artifact fails verification
    const tampered_data = "MZ_MOCK_PE_KERNEL_IMAGE_TAMPERED";
    try std.testing.expect(!seal.verify(tampered_data));
}
