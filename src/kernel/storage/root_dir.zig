// MicrOS (µOS) CAS Root Directory
// The CAS superblock root hash points at exactly one magic-tagged root object that
// names every persisted sub-tree. Independent subsystems (the system-manifest trial
// boot chain, the workspace catalog) therefore never contend for the superblock slot.
// A root slot holding anything else (an object written by an older build, or a
// foreign chunk) degrades to an empty directory instead of being misread.
// Zero libc, freestanding, explicit allocator.

const std = @import("std");
const cas_mod = @import("cas.zig");
const chunk_mod = @import("chunk.zig");
const block = @import("../drivers/block.zig");

pub const ROOT_DIRECTORY_MAGIC: u32 = 0x4D494344; // "MICD"
pub const ROOT_DIRECTORY_VERSION: u32 = 1;

pub const RootDirectory = extern struct {
    magic: u32 = ROOT_DIRECTORY_MAGIC,
    version: u32 = ROOT_DIRECTORY_VERSION,
    system_manifest_hash: [chunk_mod.HASH_SIZE]u8 = ZERO_HASH,
    catalog_manifest_hash: [chunk_mod.HASH_SIZE]u8 = ZERO_HASH,

    pub const ZERO_HASH = [_]u8{0} ** chunk_mod.HASH_SIZE;
    pub const SIZE: usize = @sizeOf(RootDirectory);

    pub fn isEmpty(self: *const RootDirectory) bool {
        return std.mem.eql(u8, &self.system_manifest_hash, &ZERO_HASH) and
            std.mem.eql(u8, &self.catalog_manifest_hash, &ZERO_HASH);
    }

    pub fn toBytes(self: *const RootDirectory) [SIZE]u8 {
        return @bitCast(self.*);
    }

    pub fn fromBytes(bytes: []const u8) !RootDirectory {
        if (bytes.len != SIZE) return error.CorruptRootDirectory;
        const dir: RootDirectory = @bitCast(bytes[0..SIZE].*);
        if (dir.magic != ROOT_DIRECTORY_MAGIC) return error.InvalidMagic;
        if (dir.version != ROOT_DIRECTORY_VERSION) return error.UnsupportedVersion;
        return dir;
    }

    pub fn withSystemManifest(self: RootDirectory, hash: *const [chunk_mod.HASH_SIZE]u8) RootDirectory {
        var next = self;
        next.system_manifest_hash = hash.*;
        return next;
    }

    pub fn withCatalogManifest(self: RootDirectory, hash: *const [chunk_mod.HASH_SIZE]u8) RootDirectory {
        var next = self;
        next.catalog_manifest_hash = hash.*;
        return next;
    }
};

pub fn load(cas: *cas_mod.CasEngine, dev: ?*block.BlockDevice) RootDirectory {
    const root = cas.getRootHash();
    if (std.mem.eql(u8, &root, &RootDirectory.ZERO_HASH)) return .{};

    var buf: [RootDirectory.SIZE]u8 = undefined;
    const len = cas.getChunk(&root, &buf, dev) catch return .{};
    return RootDirectory.fromBytes(buf[0..len]) catch .{};
}

pub fn store(cas: *cas_mod.CasEngine, dev: ?*block.BlockDevice, dir: *const RootDirectory) !void {
    const bytes = dir.toBytes();
    const hash = try cas.putChunk(.system_manifest, &bytes, dev);
    try cas.setRootHash(&hash, dev);
}

/// Read-modify-write of a single sub-root: sibling sub-roots are preserved and the
/// superblock slot only ever holds a root directory object.
pub fn setSystemManifestHash(cas: *cas_mod.CasEngine, dev: ?*block.BlockDevice, hash: *const [chunk_mod.HASH_SIZE]u8) !void {
    var dir = load(cas, dev).withSystemManifest(hash);
    try store(cas, dev, &dir);
}

pub fn setCatalogManifestHash(cas: *cas_mod.CasEngine, dev: ?*block.BlockDevice, hash: *const [chunk_mod.HASH_SIZE]u8) !void {
    var dir = load(cas, dev).withCatalogManifest(hash);
    try store(cas, dev, &dir);
}

test "root directory round trip preserves both sub-roots" {
    const system_hash = [_]u8{0xAA} ** chunk_mod.HASH_SIZE;
    const catalog_hash = [_]u8{0xBB} ** chunk_mod.HASH_SIZE;

    const dir = (RootDirectory{}).withSystemManifest(&system_hash).withCatalogManifest(&catalog_hash);
    try std.testing.expect(!dir.isEmpty());

    const decoded = try RootDirectory.fromBytes(&dir.toBytes());
    try std.testing.expectEqual(ROOT_DIRECTORY_MAGIC, decoded.magic);
    try std.testing.expectEqual(ROOT_DIRECTORY_VERSION, decoded.version);
    try std.testing.expectEqualSlices(u8, &system_hash, &decoded.system_manifest_hash);
    try std.testing.expectEqualSlices(u8, &catalog_hash, &decoded.catalog_manifest_hash);
}

test "root directory rejects foreign objects, truncation, and bad versions" {
    const good = (RootDirectory{}).toBytes();

    var foreign = good;
    foreign[0] = 0x00;
    try std.testing.expectError(error.InvalidMagic, RootDirectory.fromBytes(&foreign));

    var wrong_version = good;
    wrong_version[4] = 0x02;
    try std.testing.expectError(error.UnsupportedVersion, RootDirectory.fromBytes(&wrong_version));

    try std.testing.expectError(error.CorruptRootDirectory, RootDirectory.fromBytes(good[0 .. RootDirectory.SIZE - 1]));
}

test "root directory mutators preserve sibling sub-roots" {
    const system_hash = [_]u8{0x11} ** chunk_mod.HASH_SIZE;
    const catalog_hash = [_]u8{0x22} ** chunk_mod.HASH_SIZE;

    const only_system = (RootDirectory{}).withSystemManifest(&system_hash);
    const both = only_system.withCatalogManifest(&catalog_hash);
    try std.testing.expectEqualSlices(u8, &system_hash, &both.system_manifest_hash);
    try std.testing.expectEqualSlices(u8, &catalog_hash, &both.catalog_manifest_hash);

    const only_catalog = (RootDirectory{}).withCatalogManifest(&catalog_hash);
    try std.testing.expectEqualSlices(u8, &RootDirectory.ZERO_HASH, &only_catalog.system_manifest_hash);
    try std.testing.expect(!only_catalog.isEmpty());
    try std.testing.expect((RootDirectory{}).isEmpty());
}
