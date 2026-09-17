// MicrOS (µOS) Content-Addressed Storage Chunk Envelope & Hashing
// Implements 64-byte chunk headers, BLAKE3 verification, and hex string conversions.
// Zero libc, freestanding cryptographic integrity.

const std = @import("std");

pub const HASH_SIZE: usize = 32;
pub const HEX_HASH_SIZE: usize = 64;
pub const CHUNK_HEADER_SIZE: usize = 64;
pub const SECTOR_SIZE: usize = 512;

pub const ChunkType = enum(u32) {
    raw_blob = 1,
    actor_source = 2,
    bytecode_chunk = 3,
    merkle_node = 4,
    system_manifest = 5,
};

pub const CasChunkHeader = extern struct {
    hash: [HASH_SIZE]u8,
    length: u32,
    chunk_type: ChunkType,
    padding: [24]u8 = [_]u8{0} ** 24,
};

pub fn computeBlake3Hash(payload: []const u8) [HASH_SIZE]u8 {
    var out_hash: [HASH_SIZE]u8 = undefined;
    std.crypto.hash.Blake3.hash(payload, &out_hash, .{});
    return out_hash;
}

pub fn formatHexHash(hash: *const [HASH_SIZE]u8, out_hex: *[HEX_HASH_SIZE]u8) void {
    const hex_chars = "0123456789abcdef";
    for (hash, 0..) |b, i| {
        out_hex[i * 2] = hex_chars[(b >> 4) & 0x0F];
        out_hex[i * 2 + 1] = hex_chars[b & 0x0F];
    }
}

pub fn parseHexHash(hex_str: []const u8, out_hash: *[HASH_SIZE]u8) !void {
    if (hex_str.len != HEX_HASH_SIZE) return error.InvalidHexHashLength;
    for (0..HASH_SIZE) |i| {
        const h1 = try parseHexNibble(hex_str[i * 2]);
        const h2 = try parseHexNibble(hex_str[i * 2 + 1]);
        out_hash[i] = (h1 << 4) | h2;
    }
}

fn parseHexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHexChar,
    };
}

pub fn calculateRequiredSectors(payload_len: usize) u64 {
    const total_bytes = CHUNK_HEADER_SIZE + payload_len;
    return @as(u64, @intCast((total_bytes + (SECTOR_SIZE - 1)) / SECTOR_SIZE));
}

pub const SYSTEM_MANIFEST_MAGIC: u32 = 0x4D49434D; // "MICM"
pub const SYSTEM_MANIFEST_ABI_VERSION: u32 = 1;
pub const MAX_MANIFEST_DEPENDENCIES: usize = 8;
pub const SYSTEM_MANIFEST_SIZE: usize = 448;

pub const SystemManifest = extern struct {
    magic: u32 = SYSTEM_MANIFEST_MAGIC,
    abi_version: u32 = SYSTEM_MANIFEST_ABI_VERSION,
    required_capabilities: u64,
    entry_hash: [HASH_SIZE]u8,
    source_hash: [HASH_SIZE]u8,
    dependency_count: u32,
    reserved: u32 = 0,
    dependencies: [MAX_MANIFEST_DEPENDENCIES][HASH_SIZE]u8 = [_][HASH_SIZE]u8{[_]u8{0} ** HASH_SIZE} ** MAX_MANIFEST_DEPENDENCIES,
    padding: [104]u8 = [_]u8{0} ** 104,

    pub fn validate(self: *const SystemManifest) !void {
        if (self.magic != SYSTEM_MANIFEST_MAGIC) return error.InvalidManifestMagic;
        if (self.abi_version != SYSTEM_MANIFEST_ABI_VERSION) return error.UnsupportedManifestAbiVersion;
        if (self.dependency_count > MAX_MANIFEST_DEPENDENCIES) return error.ExcessiveDependencies;
    }
};

test "chunk header size invariant" {
    try std.testing.expectEqual(CHUNK_HEADER_SIZE, @sizeOf(CasChunkHeader));
}

test "system manifest size and sector invariant" {
    try std.testing.expectEqual(SYSTEM_MANIFEST_SIZE, @sizeOf(SystemManifest));
    try std.testing.expectEqual(SECTOR_SIZE, CHUNK_HEADER_SIZE + SYSTEM_MANIFEST_SIZE);
    try std.testing.expectEqual(@as(u64, 1), calculateRequiredSectors(SYSTEM_MANIFEST_SIZE));
}

test "system manifest validation" {
    var manifest = SystemManifest{
        .required_capabilities = 0x7,
        .entry_hash = [_]u8{0xAA} ** HASH_SIZE,
        .source_hash = [_]u8{0xBB} ** HASH_SIZE,
        .dependency_count = 2,
    };
    try manifest.validate();

    manifest.magic = 0xDEADBEEF;
    try std.testing.expectError(error.InvalidManifestMagic, manifest.validate());

    manifest.magic = SYSTEM_MANIFEST_MAGIC;
    manifest.abi_version = 99;
    try std.testing.expectError(error.UnsupportedManifestAbiVersion, manifest.validate());

    manifest.abi_version = SYSTEM_MANIFEST_ABI_VERSION;
    manifest.dependency_count = 10;
    try std.testing.expectError(error.ExcessiveDependencies, manifest.validate());
}

test "blake3 hash calculation and hex round-trip" {
    const test_data = "MicrOS sovereign content addressed storage";
    const hash = computeBlake3Hash(test_data);
    var hex_buf: [HEX_HASH_SIZE]u8 = undefined;
    formatHexHash(&hash, &hex_buf);

    var round_trip_hash: [HASH_SIZE]u8 = undefined;
    try parseHexHash(&hex_buf, &round_trip_hash);
    try std.testing.expectEqualSlices(u8, &hash, &round_trip_hash);
}
