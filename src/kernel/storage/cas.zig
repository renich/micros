// MicrOS (µOS) Sovereign Content-Addressed Storage (CAS) Engine
// Manages Sector 0 Superblock, append-only BLAKE3 chunks, and cryptographic integrity.
// Zero libc, freestanding, bounded block cache operations.

const std = @import("std");
const block_cache = @import("block_cache.zig");
const chunk_mod = @import("chunk.zig");
const virtio_blk = @import("../drivers/virtio_blk.zig");

pub const CAS_SUPERBLOCK_MAGIC: u32 = 0x4D494352; // "MICR"
pub const CAS_SUPERBLOCK_VERSION: u32 = 1;
pub const SECTOR_SUPERBLOCK: u64 = 0;
pub const SECTOR_FIRST_CHUNK: u64 = 1;
pub const SECTOR_SIZE: usize = 512;
pub const FIRST_SECTOR_DATA_CAPACITY: usize = SECTOR_SIZE - chunk_mod.CHUNK_HEADER_SIZE; // 448
pub const MAX_CHUNK_PAYLOAD_SIZE: usize = 1024 * 1024; // 1 MiB

pub const CasSuperblock = extern struct {
    magic: u32,
    version: u32,
    generation: u64,
    root_hash: [chunk_mod.HASH_SIZE]u8,
    block_count: u64,
    next_free_sector: u64,
    checksum: [chunk_mod.HASH_SIZE]u8,
    padding: [416]u8 = [_]u8{0} ** 416,
};

pub const CasEngine = struct {
    cache: *block_cache.BlockCache,
    superblock: CasSuperblock,

    pub fn init(cache: *block_cache.BlockCache, dev: ?*virtio_blk.VirtioBlkDevice, total_sectors: u64) !CasEngine {
        var sec_buf: [SECTOR_SIZE]u8 align(@alignOf(CasSuperblock)) = undefined;
        try cache.readSector(SECTOR_SUPERBLOCK, &sec_buf, dev);

        const sb_ptr: *const CasSuperblock = @ptrCast(@alignCast(&sec_buf));
        if (sb_ptr.magic != CAS_SUPERBLOCK_MAGIC) {
            const formatted_sb = formatSuperblock(total_sectors);
            try writeSuperblock(cache, &formatted_sb, dev);
            return CasEngine{ .cache = cache, .superblock = formatted_sb };
        }

        const computed_csum = computeSbChecksum(sb_ptr);
        if (!std.mem.eql(u8, &computed_csum, &sb_ptr.checksum)) {
            return error.CorruptedSuperblock;
        }

        return CasEngine{ .cache = cache, .superblock = sb_ptr.* };
    }

    pub fn putChunk(
        self: *CasEngine,
        chunk_type: chunk_mod.ChunkType,
        payload: []const u8,
        dev: ?*virtio_blk.VirtioBlkDevice,
    ) ![chunk_mod.HASH_SIZE]u8 {
        if (payload.len > MAX_CHUNK_PAYLOAD_SIZE) return error.PayloadTooLarge;
        const hash = chunk_mod.computeBlake3Hash(payload);
        const sectors_needed = chunk_mod.calculateRequiredSectors(payload.len);
        if (self.superblock.next_free_sector + sectors_needed > self.superblock.block_count) {
            return error.StorageFull;
        }

        const start_sec = self.superblock.next_free_sector;
        try writeChunkData(self.cache, start_sec, hash, chunk_type, payload, dev);

        self.superblock.next_free_sector += sectors_needed;
        self.superblock.generation += 1;
        self.superblock.checksum = computeSbChecksum(&self.superblock);

        try writeSuperblock(self.cache, &self.superblock, dev);
        return hash;
    }

    pub fn getChunk(
        self: *CasEngine,
        hash: *const [chunk_mod.HASH_SIZE]u8,
        out_buf: []u8,
        dev: ?*virtio_blk.VirtioBlkDevice,
    ) !usize {
        var curr_sec = SECTOR_FIRST_CHUNK;
        while (curr_sec < self.superblock.next_free_sector) {
            var first_sec: [SECTOR_SIZE]u8 align(@alignOf(chunk_mod.CasChunkHeader)) = undefined;
            try self.cache.readSector(curr_sec, &first_sec, dev);

            const hdr: *const chunk_mod.CasChunkHeader = @ptrCast(@alignCast(&first_sec));
            if (hdr.length > MAX_CHUNK_PAYLOAD_SIZE) return error.CorruptedChunk;
            const sec_count = chunk_mod.calculateRequiredSectors(hdr.length);
            if (sec_count == 0) return error.CorruptedChunk;

            if (std.mem.eql(u8, &hdr.hash, hash)) {
                return try readAndVerifyChunk(self.cache, curr_sec, hdr, &first_sec, out_buf, dev);
            }
            curr_sec += sec_count;
        }
        return error.ChunkNotFound;
    }

    pub fn putManifest(
        self: *CasEngine,
        manifest: *const chunk_mod.SystemManifest,
        dev: ?*virtio_blk.VirtioBlkDevice,
    ) ![chunk_mod.HASH_SIZE]u8 {
        try manifest.validate();
        const raw_bytes: [*]const u8 = @ptrCast(manifest);
        return self.putChunk(.system_manifest, raw_bytes[0..chunk_mod.SYSTEM_MANIFEST_SIZE], dev);
    }

    pub fn getManifest(
        self: *CasEngine,
        hash: *const [chunk_mod.HASH_SIZE]u8,
        dev: ?*virtio_blk.VirtioBlkDevice,
    ) !chunk_mod.SystemManifest {
        var buf align(@alignOf(chunk_mod.SystemManifest)) = [_]u8{0} ** chunk_mod.SYSTEM_MANIFEST_SIZE;
        const read_len = try self.getChunk(hash, &buf, dev);
        if (read_len != chunk_mod.SYSTEM_MANIFEST_SIZE) return error.CorruptManifestSize;
        const manifest_ptr: *const chunk_mod.SystemManifest = @ptrCast(@alignCast(&buf));
        try manifest_ptr.validate();
        return manifest_ptr.*;
    }

    pub fn setRootHash(
        self: *CasEngine,
        root: *const [chunk_mod.HASH_SIZE]u8,
        dev: ?*virtio_blk.VirtioBlkDevice,
    ) !void {
        self.superblock.root_hash = root.*;
        self.superblock.generation += 1;
        self.superblock.checksum = computeSbChecksum(&self.superblock);
        try writeSuperblock(self.cache, &self.superblock, dev);
    }

    pub fn getRootHash(self: *const CasEngine) [chunk_mod.HASH_SIZE]u8 {
        return self.superblock.root_hash;
    }
};

fn formatSuperblock(total_sectors: u64) CasSuperblock {
    var sb = CasSuperblock{
        .magic = CAS_SUPERBLOCK_MAGIC,
        .version = CAS_SUPERBLOCK_VERSION,
        .generation = 0,
        .root_hash = [_]u8{0} ** chunk_mod.HASH_SIZE,
        .block_count = total_sectors,
        .next_free_sector = SECTOR_FIRST_CHUNK,
        .checksum = [_]u8{0} ** chunk_mod.HASH_SIZE,
    };
    sb.checksum = computeSbChecksum(&sb);
    return sb;
}

fn computeSbChecksum(sb: *const CasSuperblock) [chunk_mod.HASH_SIZE]u8 {
    const raw: [*]const u8 = @ptrCast(sb);
    const checksum_offset = @offsetOf(CasSuperblock, "checksum");
    return chunk_mod.computeBlake3Hash(raw[0..checksum_offset]);
}

fn writeSuperblock(cache: *block_cache.BlockCache, sb: *const CasSuperblock, dev: ?*virtio_blk.VirtioBlkDevice) !void {
    const raw: *const [SECTOR_SIZE]u8 = @ptrCast(@alignCast(sb));
    try cache.writeSector(SECTOR_SUPERBLOCK, raw, dev);
    try cache.flush(dev);
}

fn writeChunkData(
    cache: *block_cache.BlockCache,
    start_sec: u64,
    hash: [chunk_mod.HASH_SIZE]u8,
    chunk_type: chunk_mod.ChunkType,
    payload: []const u8,
    dev: ?*virtio_blk.VirtioBlkDevice,
) !void {
    var first_sec align(@alignOf(chunk_mod.CasChunkHeader)) = [_]u8{0} ** SECTOR_SIZE;
    const hdr: *chunk_mod.CasChunkHeader = @ptrCast(@alignCast(&first_sec));
    hdr.* = chunk_mod.CasChunkHeader{
        .hash = hash,
        .length = @intCast(payload.len),
        .chunk_type = chunk_type,
    };

    const first_copy_len = @min(payload.len, FIRST_SECTOR_DATA_CAPACITY);
    @memcpy(first_sec[chunk_mod.CHUNK_HEADER_SIZE .. chunk_mod.CHUNK_HEADER_SIZE + first_copy_len], payload[0..first_copy_len]);
    try cache.writeSector(start_sec, &first_sec, dev);

    var written: usize = first_copy_len;
    var sec_idx: u64 = 1;
    while (written < payload.len) {
        var sec_buf = [_]u8{0} ** SECTOR_SIZE;
        const copy_len = @min(payload.len - written, SECTOR_SIZE);
        @memcpy(sec_buf[0..copy_len], payload[written .. written + copy_len]);
        try cache.writeSector(start_sec + sec_idx, &sec_buf, dev);
        written += copy_len;
        sec_idx += 1;
    }
}

fn readAndVerifyChunk(
    cache: *block_cache.BlockCache,
    start_sec: u64,
    hdr: *const chunk_mod.CasChunkHeader,
    first_sec: *const [SECTOR_SIZE]u8,
    out_buf: []u8,
    dev: ?*virtio_blk.VirtioBlkDevice,
) !usize {
    const payload_len = @as(usize, hdr.length);
    if (out_buf.len < payload_len) return error.BufferTooSmall;

    const first_copy_len = @min(payload_len, FIRST_SECTOR_DATA_CAPACITY);
    @memcpy(out_buf[0..first_copy_len], first_sec[chunk_mod.CHUNK_HEADER_SIZE .. chunk_mod.CHUNK_HEADER_SIZE + first_copy_len]);

    var read_bytes: usize = first_copy_len;
    var sec_idx: u64 = 1;
    while (read_bytes < payload_len) {
        var sec_buf: [SECTOR_SIZE]u8 = undefined;
        try cache.readSector(start_sec + sec_idx, &sec_buf, dev);
        const copy_len = @min(payload_len - read_bytes, SECTOR_SIZE);
        @memcpy(out_buf[read_bytes .. read_bytes + copy_len], sec_buf[0..copy_len]);
        read_bytes += copy_len;
        sec_idx += 1;
    }

    const recomputed_hash = chunk_mod.computeBlake3Hash(out_buf[0..payload_len]);
    if (!std.mem.eql(u8, &hdr.hash, &recomputed_hash)) {
        return error.CorruptChunk;
    }
    return payload_len;
}

test "superblock size and formatting" {
    try std.testing.expectEqual(SECTOR_SIZE, @sizeOf(CasSuperblock));
    const sb = formatSuperblock(1024);
    try std.testing.expectEqual(CAS_SUPERBLOCK_MAGIC, sb.magic);
    try std.testing.expectEqual(@as(u64, 1024), sb.block_count);
}

test "cas engine put and get round trip" {
    var cache = try block_cache.BlockCache.init(std.testing.allocator);
    defer cache.deinit();

    var cas = try CasEngine.init(&cache, null, 1000);
    const test_payload = "sys_serial_write(\"Persistent Sovereign CAS Actor!\");";
    const hash = try cas.putChunk(.actor_source, test_payload, null);

    var read_buf: [512]u8 = undefined;
    const read_len = try cas.getChunk(&hash, &read_buf, null);

    try std.testing.expectEqual(test_payload.len, read_len);
    try std.testing.expectEqualStrings(test_payload, read_buf[0..read_len]);
}

test "cas engine put and get manifest round trip" {
    var cache = try block_cache.BlockCache.init(std.testing.allocator);
    defer cache.deinit();

    var cas = try CasEngine.init(&cache, null, 1000);
    var manifest = chunk_mod.SystemManifest{
        .required_capabilities = 0x1F,
        .entry_hash = [_]u8{0x11} ** chunk_mod.HASH_SIZE,
        .source_hash = [_]u8{0x22} ** chunk_mod.HASH_SIZE,
        .dependency_count = 1,
    };
    manifest.dependencies[0] = [_]u8{0x33} ** chunk_mod.HASH_SIZE;

    const hash = try cas.putManifest(&manifest, null);
    const retrieved = try cas.getManifest(&hash, null);

    try std.testing.expectEqual(manifest.magic, retrieved.magic);
    try std.testing.expectEqual(manifest.abi_version, retrieved.abi_version);
    try std.testing.expectEqual(manifest.required_capabilities, retrieved.required_capabilities);
    try std.testing.expectEqualSlices(u8, &manifest.entry_hash, &retrieved.entry_hash);
    try std.testing.expectEqualSlices(u8, &manifest.source_hash, &retrieved.source_hash);
    try std.testing.expectEqual(manifest.dependency_count, retrieved.dependency_count);
    try std.testing.expectEqualSlices(u8, &manifest.dependencies[0], &retrieved.dependencies[0]);
}
