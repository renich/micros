// MicrOS (µOS) MCB Bundle Packer
// Deterministic writer for the immutable capability bundle format consumed by
// bundle.zig: 32-byte header, 80-byte manifest entries, 64-byte aligned payloads,
// BLAKE3 per-entry content hashes. Zero libc, freestanding, explicit allocator.

const std = @import("std");
const bundle = @import("../bundle.zig");
const chunk_mod = @import("chunk.zig");

pub const MCB_PAYLOAD_ALIGN: u64 = 64;
pub const MAX_BUNDLE_ENTRIES: usize = 256;
pub const MAX_BUNDLE_BYTES: u64 = 4 * 1024 * 1024;

pub const Entry = struct {
    tag: []const u8,
    content: []const u8,
};

pub const PackError = error{
    TooManyBundleEntries,
    BundleTooLarge,
    InvalidBundleEntry,
};

fn alignOffset(value: u64) u64 {
    return (value + (MCB_PAYLOAD_ALIGN - 1)) & ~@as(u64, MCB_PAYLOAD_ALIGN - 1);
}

fn manifestSize(entry_count: usize) u64 {
    return alignOffset(@sizeOf(bundle.BundleHeader) + entry_count * @sizeOf(bundle.BundleEntry));
}

/// Total on-disk size of the bundle: aligned manifest followed by aligned payloads.
pub fn totalSize(entries: []const Entry) PackError!u64 {
    if (entries.len > MAX_BUNDLE_ENTRIES) return error.TooManyBundleEntries;

    var total: u64 = manifestSize(entries.len);
    for (entries) |entry| {
        if (entry.tag.len == 0 or entry.tag.len > 32) return error.InvalidBundleEntry;
        total = alignOffset(total + entry.content.len);
    }
    if (total > MAX_BUNDLE_BYTES) return error.BundleTooLarge;
    return total;
}

/// Serialize `entries` into `buf`, which must be `totalSize(entries)` bytes.
pub fn write(buf: []u8, entries: []const Entry) PackError!void {
    if (buf.len < try totalSize(entries)) return error.BundleTooLarge;
    @memset(buf, 0);

    const header: *align(1) bundle.BundleHeader = @ptrCast(buf.ptr);
    header.* = .{
        .magic = bundle.MCB_MAGIC,
        .version = bundle.MCB_VERSION,
        .entry_count = @intCast(entries.len),
        .total_size_bytes = @intCast(buf.len),
        .reserved = 0,
    };

    var offset: u64 = manifestSize(entries.len);
    for (entries, 0..) |entry, i| {
        const entry_ptr = buf.ptr + @sizeOf(bundle.BundleHeader) + i * @sizeOf(bundle.BundleEntry);
        const slot: *align(1) bundle.BundleEntry = @ptrCast(entry_ptr);
        slot.* = .{
            .tag = [_]u8{0} ** 32,
            .offset = offset,
            .size_bytes = entry.content.len,
            .content_hash = chunk_mod.computeBlake3Hash(entry.content),
        };
        const copy_len = @min(entry.tag.len, 31);
        @memcpy(slot.tag[0..copy_len], entry.tag[0..copy_len]);
        @memcpy(buf[@intCast(offset)..][0..entry.content.len], entry.content);
        offset = alignOffset(offset + entry.content.len);
    }
}

/// Allocate and serialize a bundle image.
pub fn pack(allocator: std.mem.Allocator, entries: []const Entry) (PackError || std.mem.Allocator.Error)![]u8 {
    const total = try totalSize(entries);
    const buf = try allocator.alloc(u8, @intCast(total));
    errdefer allocator.free(buf);
    try write(buf, entries);
    return buf;
}

test "packed bundles round-trip through the MCB reader" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .tag = "init.mx", .content = "fn main() { return 0; }\nmain();" },
        .{ .tag = "ush.mx", .content = "print(\"shell\");" },
    };

    const bytes = try pack(allocator, &entries);
    defer allocator.free(bytes);

    var reader = try bundle.BundleReader.init(bytes);
    try std.testing.expectEqual(@as(u32, 2), reader.header.entry_count);
    try std.testing.expectEqual(@as(u64, bytes.len), reader.header.total_size_bytes);

    try std.testing.expectEqualStrings(entries[0].content, reader.findData("init.mx").?);
    try std.testing.expectEqualStrings(entries[1].content, reader.findData("ush.mx").?);
    try std.testing.expect(reader.findData("absent.mx") == null);

    // Payloads stay 64-byte aligned and content hashes are committed.
    const first = reader.getEntry(0).?;
    try std.testing.expectEqual(@as(u64, 0), first.offset % MCB_PAYLOAD_ALIGN);
    try std.testing.expectEqualSlices(u8, &chunk_mod.computeBlake3Hash(entries[0].content), &first.content_hash);
}

test "packer rejects oversized tag, entry count, and payload budgets" {
    const allocator = std.testing.allocator;
    var long_tag: [40]u8 = [_]u8{'x'} ** 40;
    try std.testing.expectError(error.InvalidBundleEntry, totalSize(&[_]Entry{.{ .tag = long_tag[0..], .content = "x" }}));
    try std.testing.expectError(error.InvalidBundleEntry, totalSize(&[_]Entry{.{ .tag = "", .content = "x" }}));

    var many: [MAX_BUNDLE_ENTRIES + 1]Entry = undefined;
    for (&many) |*entry| entry.* = .{ .tag = "a.mx", .content = "x" };
    try std.testing.expectError(error.TooManyBundleEntries, totalSize(&many));

    const big = try allocator.alloc(u8, MAX_BUNDLE_BYTES + 1);
    defer allocator.free(big);
    try std.testing.expectError(error.BundleTooLarge, totalSize(&[_]Entry{.{ .tag = "big.mx", .content = big }}));
}

test "empty bundle packs a valid header with no entries" {
    const allocator = std.testing.allocator;
    const bytes = try pack(allocator, &[_]Entry{});
    defer allocator.free(bytes);

    var reader = try bundle.BundleReader.init(bytes);
    try std.testing.expectEqual(@as(u32, 0), reader.header.entry_count);
    try std.testing.expect(reader.getEntry(0) == null);
}
