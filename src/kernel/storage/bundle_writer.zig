// MicrOS (µOS) Freestanding Capability Bundle (MCB) Writer
// Synthesizes immutable, 64-byte aligned MCB binary bundles entirely in memory.
// Enforces lexicographical tag sorting and deterministic zero padding.
// Zero libc, freestanding, explicit allocator.

const std = @import("std");
const bundle = @import("../bundle.zig");

pub const EntryInput = struct {
    tag: []const u8,
    data: []const u8,
};

pub const BundleWriterError = error{
    TagTooLong,
    EmptyTag,
    DuplicateTag,
    AllocationFailed,
    BundleTooLarge,
};

fn align64(val: u64) u64 {
    return std.mem.alignForward(u64, val, 64);
}

fn entryLessThan(_: void, a: EntryInput, b: EntryInput) bool {
    return std.mem.order(u8, a.tag, b.tag) == .lt;
}

fn computeTotalSize(entries: []const EntryInput) u64 {
    const table_bytes = @sizeOf(bundle.BundleHeader) + (entries.len * @sizeOf(bundle.BundleEntry));
    var cur_pos: u64 = align64(table_bytes);
    for (entries) |e| {
        cur_pos = align64(cur_pos);
        cur_pos += e.data.len;
    }
    return align64(cur_pos);
}

fn validateEntries(entries: []const EntryInput) BundleWriterError!void {
    for (entries, 0..) |e, idx| {
        if (e.tag.len == 0) return BundleWriterError.EmptyTag;
        if (e.tag.len >= 32) return BundleWriterError.TagTooLong;
        if (idx > 0 and std.mem.eql(u8, entries[idx - 1].tag, e.tag)) {
            return BundleWriterError.DuplicateTag;
        }
    }
}

fn writeEntryTable(
    out_buf: []u8,
    entries: []const EntryInput,
    table_end_aligned: u64,
) void {
    var cur_payload_offset = table_end_aligned;
    for (entries, 0..) |e, idx| {
        cur_payload_offset = align64(cur_payload_offset);
        var entry = bundle.BundleEntry{
            .tag = [_]u8{0} ** 32,
            .offset = cur_payload_offset,
            .size_bytes = e.data.len,
            .content_hash = [_]u8{0} ** 32,
        };
        @memcpy(entry.tag[0..e.tag.len], e.tag);
        std.crypto.hash.Blake3.hash(e.data, &entry.content_hash, .{});

        const entry_dest = @sizeOf(bundle.BundleHeader) + (idx * @sizeOf(bundle.BundleEntry));
        const entry_slice = std.mem.asBytes(&entry);
        @memcpy(out_buf[entry_dest .. entry_dest + entry_slice.len], entry_slice);
        cur_payload_offset += e.data.len;
    }
}

fn writePayloads(out_buf: []u8, entries: []const EntryInput, table_end_aligned: u64) void {
    var cur_pos = table_end_aligned;
    for (entries) |e| {
        cur_pos = align64(cur_pos);
        const start: usize = @intCast(cur_pos);
        const end: usize = start + e.data.len;
        @memcpy(out_buf[start..end], e.data);
        cur_pos += e.data.len;
    }
}

pub fn packBundle(allocator: std.mem.Allocator, raw_entries: []const EntryInput) ![]u8 {
    const sorted = try allocator.alloc(EntryInput, raw_entries.len);
    defer allocator.free(sorted);
    @memcpy(sorted, raw_entries);
    std.mem.sort(EntryInput, sorted, {}, entryLessThan);

    try validateEntries(sorted);

    const total_size = computeTotalSize(sorted);
    if (total_size > std.math.maxInt(usize)) return BundleWriterError.BundleTooLarge;

    const out_buf = try allocator.alloc(u8, @intCast(total_size));
    @memset(out_buf, 0);

    const hdr = bundle.BundleHeader{
        .magic = bundle.MCB_MAGIC,
        .version = bundle.MCB_VERSION,
        .entry_count = @intCast(sorted.len),
        .total_size_bytes = total_size,
        .reserved = 0,
    };
    const hdr_bytes = std.mem.asBytes(&hdr);
    @memcpy(out_buf[0..hdr_bytes.len], hdr_bytes);

    const table_bytes = @sizeOf(bundle.BundleHeader) + (sorted.len * @sizeOf(bundle.BundleEntry));
    const table_aligned = align64(table_bytes);

    writeEntryTable(out_buf, sorted, table_aligned);
    writePayloads(out_buf, sorted, table_aligned);

    return out_buf;
}

test "bundle writer produces valid MCB parseable by BundleReader" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const test_entries = [_]EntryInput{
        .{ .tag = "b_script.mx", .data = "fn b() { return 2; }" },
        .{ .tag = "a_init.mx", .data = "fn main() { return 1; }" },
        .{ .tag = "c_util.mx", .data = "fn c() { return 3; }" },
    };

    const bundle_bytes = try packBundle(alloc, &test_entries);
    defer alloc.free(bundle_bytes);

    // Verify 64-byte alignment of the total size
    try testing.expectEqual(@as(usize, 0), bundle_bytes.len % 64);

    // Parse back with kernel BundleReader
    const reader = try bundle.BundleReader.init(bundle_bytes);
    try testing.expectEqual(@as(u32, 3), reader.header.entry_count);

    // Verify lexicographical order
    const e0 = reader.getEntry(0).?;
    const e1 = reader.getEntry(1).?;
    const e2 = reader.getEntry(2).?;

    try testing.expectEqualStrings("a_init.mx", e0.getTag());
    try testing.expectEqualStrings("b_script.mx", e1.getTag());
    try testing.expectEqualStrings("c_util.mx", e2.getTag());

    // Verify payload data matches
    const data_a = reader.findData("a_init.mx").?;
    const data_b = reader.findData("b_script.mx").?;
    const data_c = reader.findData("c_util.mx").?;

    try testing.expectEqualStrings("fn main() { return 1; }", data_a);
    try testing.expectEqualStrings("fn b() { return 2; }", data_b);
    try testing.expectEqualStrings("fn c() { return 3; }", data_c);
}

test "bundle writer rejects duplicate or invalid tags" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const dup_entries = [_]EntryInput{
        .{ .tag = "dup.mx", .data = "first" },
        .{ .tag = "dup.mx", .data = "second" },
    };
    try testing.expectError(BundleWriterError.DuplicateTag, packBundle(alloc, &dup_entries));

    const empty_entries = [_]EntryInput{
        .{ .tag = "", .data = "empty" },
    };
    try testing.expectError(BundleWriterError.EmptyTag, packBundle(alloc, &empty_entries));
}
