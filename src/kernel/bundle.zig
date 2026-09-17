// MicrOS (µOS) Immutable Capability Bundle (MCB)
// Pure content-addressed, zero-copy payload reader.
// Replaces legacy Unix CPIO archives with 64-byte aligned manifest entries.

const std = @import("std");

pub const MCB_MAGIC: u64 = 0x4D494352_4F534D43; // "MICROSMC"
pub const MCB_VERSION: u32 = 1;

pub const BundleHeader = extern struct {
    magic: u64,
    version: u32,
    entry_count: u32,
    total_size_bytes: u64,
    reserved: u64,
};

pub const BundleEntry = extern struct {
    tag: [32]u8,
    offset: u64,
    size_bytes: u64,
    content_hash: [32]u8,

    pub fn getTag(self: *const BundleEntry) []const u8 {
        var len: usize = 0;
        while (len < 32 and self.tag[len] != 0) : (len += 1) {}
        return self.tag[0..len];
    }
};

comptime {
    std.debug.assert(@sizeOf(BundleHeader) == 32);
    std.debug.assert(@sizeOf(BundleEntry) == 80);
}

pub const BundleError = error{
    InvalidMagic,
    UnsupportedVersion,
    BundleTruncated,
    EntryNotFound,
};

pub const BundleReader = struct {
    data: []const u8,
    header: BundleHeader,

    pub fn init(data: []const u8) BundleError!BundleReader {
        if (data.len < @sizeOf(BundleHeader)) return BundleError.BundleTruncated;
        const header = @as(*align(1) const BundleHeader, @ptrCast(data.ptr)).*;

        if (header.magic != MCB_MAGIC) return BundleError.InvalidMagic;
        if (header.version != MCB_VERSION) return BundleError.UnsupportedVersion;
        if (data.len < header.total_size_bytes) return BundleError.BundleTruncated;

        const manifest_bytes = std.math.mul(usize, header.entry_count, @sizeOf(BundleEntry)) catch return BundleError.BundleTruncated;
        const manifest_end = std.math.add(usize, @sizeOf(BundleHeader), manifest_bytes) catch return BundleError.BundleTruncated;
        if (data.len < manifest_end) return BundleError.BundleTruncated;
        if (header.total_size_bytes < manifest_end) return BundleError.BundleTruncated;

        return BundleReader{
            .data = data,
            .header = header,
        };
    }

    pub fn getEntry(self: *const BundleReader, index: usize) ?BundleEntry {
        if (index >= self.header.entry_count) return null;
        const entry_offset = std.math.mul(usize, index, @sizeOf(BundleEntry)) catch return null;
        const offset = std.math.add(usize, @sizeOf(BundleHeader), entry_offset) catch return null;
        if (offset + @sizeOf(BundleEntry) > self.data.len) return null;

        return @as(*align(1) const BundleEntry, @ptrCast(self.data.ptr + offset)).*;
    }

    pub fn findData(self: *const BundleReader, tag: []const u8) ?[]const u8 {
        const manifest_bytes = std.math.mul(usize, self.header.entry_count, @sizeOf(BundleEntry)) catch return null;
        const manifest_end = std.math.add(usize, @sizeOf(BundleHeader), manifest_bytes) catch return null;

        var i: usize = 0;
        while (i < self.header.entry_count) : (i += 1) {
            const entry = self.getEntry(i) orelse break;
            if (std.mem.eql(u8, entry.getTag(), tag)) {
                if (entry.offset < manifest_end) return null;
                if (entry.offset > self.data.len) return null;
                if (entry.size_bytes > self.data.len - entry.offset) return null;
                const start: usize = @intCast(entry.offset);
                const end: usize = start + @as(usize, @intCast(entry.size_bytes));
                return self.data[start..end];
            }
        }
        return null;
    }
};

test "BundleReader parses MCB header and extracts entry data without copying" {
    // Construct a synthetic bundle in memory
    var bundle_buf: [256]u8 align(@alignOf(BundleHeader)) = [_]u8{0} ** 256;
    const header = BundleHeader{
        .magic = MCB_MAGIC,
        .version = MCB_VERSION,
        .entry_count = 1,
        .total_size_bytes = 256,
        .reserved = 0,
    };
    @memcpy(bundle_buf[0..@sizeOf(BundleHeader)], std.mem.asBytes(&header));

    const payload = "val answer = 42";
    var entry = BundleEntry{
        .tag = [_]u8{0} ** 32,
        .offset = 128,
        .size_bytes = payload.len,
        .content_hash = [_]u8{0} ** 32,
    };
    @memcpy(entry.tag[0..7], "init.mx");
    const entry_offset = @sizeOf(BundleHeader);
    @memcpy(bundle_buf[entry_offset .. entry_offset + @sizeOf(BundleEntry)], std.mem.asBytes(&entry));

    @memcpy(bundle_buf[128 .. 128 + payload.len], payload);

    const reader = try BundleReader.init(&bundle_buf);
    try std.testing.expectEqual(@as(u32, 1), reader.header.entry_count);

    const retrieved_entry = reader.getEntry(0).?;
    try std.testing.expectEqualStrings("init.mx", retrieved_entry.getTag());

    const retrieved_data = reader.findData("init.mx").?;
    try std.testing.expectEqualStrings(payload, retrieved_data);
    try std.testing.expect(reader.findData("nonexistent.mx") == null);
}

test "BundleReader rejects integer overflow in entry offset and size" {
    var bundle_buf: [256]u8 align(@alignOf(BundleHeader)) = [_]u8{0} ** 256;
    const header = BundleHeader{
        .magic = MCB_MAGIC,
        .version = MCB_VERSION,
        .entry_count = 1,
        .total_size_bytes = 256,
        .reserved = 0,
    };
    @memcpy(bundle_buf[0..@sizeOf(BundleHeader)], std.mem.asBytes(&header));

    var entry = BundleEntry{
        .tag = [_]u8{0} ** 32,
        .offset = std.math.maxInt(u64) - 10,
        .size_bytes = 20,
        .content_hash = [_]u8{0} ** 32,
    };
    @memcpy(entry.tag[0..6], "bad.mx");
    const entry_offset = @sizeOf(BundleHeader);
    @memcpy(bundle_buf[entry_offset .. entry_offset + @sizeOf(BundleEntry)], std.mem.asBytes(&entry));

    const reader = try BundleReader.init(&bundle_buf);
    try std.testing.expect(reader.findData("bad.mx") == null);
}

test "BundleReader rejects payload offset overlapping bundle header or manifest" {
    var bundle_buf: [256]u8 align(@alignOf(BundleHeader)) = [_]u8{0} ** 256;
    const header = BundleHeader{
        .magic = MCB_MAGIC,
        .version = MCB_VERSION,
        .entry_count = 1,
        .total_size_bytes = 256,
        .reserved = 0,
    };
    @memcpy(bundle_buf[0..@sizeOf(BundleHeader)], std.mem.asBytes(&header));

    var entry = BundleEntry{
        .tag = [_]u8{0} ** 32,
        .offset = 16,
        .size_bytes = 8,
        .content_hash = [_]u8{0} ** 32,
    };
    @memcpy(entry.tag[0..7], "hack.mx");
    const entry_offset = @sizeOf(BundleHeader);
    @memcpy(bundle_buf[entry_offset .. entry_offset + @sizeOf(BundleEntry)], std.mem.asBytes(&entry));

    const reader = try BundleReader.init(&bundle_buf);
    try std.testing.expect(reader.findData("hack.mx") == null);
}
