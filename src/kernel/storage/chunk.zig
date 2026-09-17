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

test "chunk header size invariant" {
    try std.testing.expectEqual(CHUNK_HEADER_SIZE, @sizeOf(CasChunkHeader));
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
