// MicrOS (µOS) Freestanding Git Packfile Parser & Object Extractor
// Decompresses Git packfile streams into BLAKE3 CAS objects and Git Trees.
// Zero libc, freestanding.

const std = @import("std");
const flate = std.compress.flate;

pub const PACK_MAGIC: u32 = 0x5041434B; // "PACK" in big-endian
pub const PACK_VERSION_2: u32 = 2;
pub const PACK_HEADER_SIZE: usize = 12;
pub const OID_SIZE_SHA1: usize = 20;
pub const HEX_OID_SIZE_SHA1: usize = 40;

pub const GitObjectType = enum(u8) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,
};

pub const PackHeader = struct {
    magic: u32,
    version: u32,
    object_count: u32,
};

pub const ObjectHeader = struct {
    obj_type: GitObjectType,
    uncompressed_size: usize,
    header_bytes: usize,
};

pub const TreeEntry = struct {
    mode: []const u8,
    name: []const u8,
    oid: [OID_SIZE_SHA1]u8,
};

pub fn parsePackHeader(data: []const u8) ?PackHeader {
    if (data.len < PACK_HEADER_SIZE) return null;
    const magic = std.mem.readInt(u32, data[0..4], .big);
    if (magic != PACK_MAGIC) return null;
    const version = std.mem.readInt(u32, data[4..8], .big);
    if (version != PACK_VERSION_2) return null;
    const object_count = std.mem.readInt(u32, data[8..12], .big);

    return PackHeader{
        .magic = magic,
        .version = version,
        .object_count = object_count,
    };
}

pub fn parseObjectHeader(data: []const u8) ?ObjectHeader {
    if (data.len == 0) return null;
    const first = data[0];
    const raw_type: u8 = (first >> 4) & 0x07;
    const obj_type: GitObjectType = switch (raw_type) {
        1 => .commit,
        2 => .tree,
        3 => .blob,
        4 => .tag,
        6 => .ofs_delta,
        7 => .ref_delta,
        else => return null,
    };

    var size: usize = first & 0x0F;
    var shift: usize = 4;
    var idx: usize = 1;
    var b = first;

    while ((b & 0x80) != 0) {
        if (idx >= data.len) return null;
        b = data[idx];
        const val: usize = b & 0x7F;
        size |= (val << @intCast(shift));
        shift += 7;
        idx += 1;
    }

    return ObjectHeader{
        .obj_type = obj_type,
        .uncompressed_size = size,
        .header_bytes = idx,
    };
}

pub fn decompressObject(
    allocator: std.mem.Allocator,
    input_slice: []const u8,
    uncompressed_size: usize,
) !struct { data: []u8, consumed_bytes: usize } {
    var in_reader: std.Io.Reader = .fixed(input_slice);
    const out = try allocator.alloc(u8, uncompressed_size);
    errdefer allocator.free(out);

    const window_buf = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window_buf);

    var decompress = flate.Decompress.init(&in_reader, .zlib, window_buf);
    var total_read: usize = 0;
    while (total_read < uncompressed_size) {
        const read_bytes = try decompress.reader.readSliceShort(out[total_read..]);
        if (read_bytes == 0) break;
        total_read += read_bytes;
    }
    if (total_read != uncompressed_size) {
        return error.TruncatedObject;
    }
    const consumed = in_reader.seek;
    return .{ .data = out, .consumed_bytes = consumed };
}

pub fn parseCommitTreeSha(commit_payload: []const u8) ?[HEX_OID_SIZE_SHA1]u8 {
    if (!std.mem.startsWith(u8, commit_payload, "tree ")) return null;
    if (commit_payload.len < 45) return null;
    var sha: [HEX_OID_SIZE_SHA1]u8 = undefined;
    @memcpy(&sha, commit_payload[5..45]);
    return sha;
}

pub fn parseTreeEntry(data: []const u8) ?struct { entry: TreeEntry, consumed: usize } {
    const space_idx = std.mem.indexOfScalar(u8, data, ' ') orelse return null;
    const mode = data[0..space_idx];
    const after_space = data[space_idx + 1 ..];
    const nul_idx = std.mem.indexOfScalar(u8, after_space, 0) orelse return null;
    const name = after_space[0..nul_idx];
    const after_nul = after_space[nul_idx + 1 ..];
    if (after_nul.len < OID_SIZE_SHA1) return null;

    var oid: [OID_SIZE_SHA1]u8 = undefined;
    @memcpy(&oid, after_nul[0..OID_SIZE_SHA1]);
    const total_consumed = space_idx + 1 + nul_idx + 1 + OID_SIZE_SHA1;

    return .{
        .entry = TreeEntry{
            .mode = mode,
            .name = name,
            .oid = oid,
        },
        .consumed = total_consumed,
    };
}

pub fn formatHexOid(bin: *const [OID_SIZE_SHA1]u8, out_hex: *[HEX_OID_SIZE_SHA1]u8) void {
    const hex_chars = "0123456789abcdef";
    for (bin, 0..) |b, i| {
        out_hex[i * 2] = hex_chars[(b >> 4) & 0xF];
        out_hex[i * 2 + 1] = hex_chars[b & 0xF];
    }
}

// === Colocated Unit Tests ===

test "packfile header parsing" {
    var hdr_bytes: [12]u8 = undefined;
    std.mem.writeInt(u32, hdr_bytes[0..4], PACK_MAGIC, .big);
    std.mem.writeInt(u32, hdr_bytes[4..8], PACK_VERSION_2, .big);
    std.mem.writeInt(u32, hdr_bytes[8..12], 3, .big);

    const hdr = parsePackHeader(&hdr_bytes).?;
    try std.testing.expectEqual(PACK_MAGIC, hdr.magic);
    try std.testing.expectEqual(@as(u32, 2), hdr.version);
    try std.testing.expectEqual(@as(u32, 3), hdr.object_count);

    hdr_bytes[0] = 'X';
    try std.testing.expect(parsePackHeader(&hdr_bytes) == null);
}

test "packfile object header variable length decoding" {
    // OBJ_BLOB (3) with size 15 (fits in first byte): 0b0_011_1111 = 0x3F
    const one_byte = [_]u8{0x3F};
    const hdr1 = parseObjectHeader(&one_byte).?;
    try std.testing.expectEqual(GitObjectType.blob, hdr1.obj_type);
    try std.testing.expectEqual(@as(usize, 15), hdr1.uncompressed_size);
    try std.testing.expectEqual(@as(usize, 1), hdr1.header_bytes);

    // OBJ_COMMIT (1) with size 256:
    // First byte: MSB=1, type=1, size lower 4 bits = 0x0 -> 0b1_001_0000 = 0x90
    // Second byte: MSB=0, size next 7 bits = (256 >> 4) = 16 -> 0x10
    const two_bytes = [_]u8{ 0x90, 0x10 };
    const hdr2 = parseObjectHeader(&two_bytes).?;
    try std.testing.expectEqual(GitObjectType.commit, hdr2.obj_type);
    try std.testing.expectEqual(@as(usize, 256), hdr2.uncompressed_size);
    try std.testing.expectEqual(@as(usize, 2), hdr2.header_bytes);
}

test "packfile commit tree sha extraction" {
    const commit_data = "tree 7b01850125fb080005781a7b4f74d081f2b62191\nauthor Alice <a@b.c> 1234567890 +0000\n\nInitial\n";
    const tree_sha = parseCommitTreeSha(commit_data).?;
    try std.testing.expectEqualStrings("7b01850125fb080005781a7b4f74d081f2b62191", &tree_sha);
}

test "packfile tree entry parsing" {
    var raw_entry: [64]u8 = undefined;
    const prefix = "100644 index.html\x00";
    @memcpy(raw_entry[0..prefix.len], prefix);
    var dummy_oid: [20]u8 = [_]u8{0xAA} ** 20;
    @memcpy(raw_entry[prefix.len .. prefix.len + 20], &dummy_oid);

    const parsed = parseTreeEntry(raw_entry[0 .. prefix.len + 20]).?;
    try std.testing.expectEqualStrings("100644", parsed.entry.mode);
    try std.testing.expectEqualStrings("index.html", parsed.entry.name);
    try std.testing.expectEqual(dummy_oid, parsed.entry.oid);
    try std.testing.expectEqual(prefix.len + 20, parsed.consumed);
}

test "packfile zlib object decompression" {
    const allocator = std.testing.allocator;
    const zlib_data = [_]u8{
        0x78, 0x9c, 0x73, 0xce, 0x2f, 0xa8, 0x2c, 0xca, 0x4c, 0xcf, 0x28, 0x51, 0x08, 0xcf, 0xcc, 0xc9,
        0x49, 0xcd, 0x55, 0x28, 0x4b, 0xcc, 0x53, 0x08, 0x4e, 0xce, 0x48, 0xcc, 0xcc, 0xd6, 0x51, 0x08,
        0xce, 0xcc, 0x4b, 0x4f, 0x2c, 0xc8, 0x2f, 0x4a, 0x55, 0x30, 0xb4, 0xb4, 0x34, 0xd5, 0xb5, 0x34,
        0x03, 0x00, 0x8b, 0x61, 0x0f, 0xa4,
    };
    const expected = "Copyright Willem van Schaik, Singapore 1995-96";
    const res = try decompressObject(allocator, &zlib_data, expected.len);
    defer allocator.free(res.data);

    try std.testing.expectEqualStrings(expected, res.data);
    try std.testing.expect(res.consumed_bytes >= zlib_data.len - 4);
}
