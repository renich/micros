// micros-bundle: MicrOS Capability Bundle (MCB) Packager
// Packs sovereign application modules and bytecode into an immutable MCB binary.

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
};

const FileSpec = struct {
    tag: []const u8,
    path: []const u8,
    data: []const u8,
    hash: [32]u8,
};

fn parseTagAndPath(arg: []const u8) ?struct { tag: []const u8, path: []const u8 } {
    var iter = std.mem.splitScalar(u8, arg, '=');
    const tag = iter.next() orelse return null;
    const path = iter.next() orelse return null;
    return .{ .tag = tag, .path = path };
}

fn computeHash(data: []const u8) [32]u8 {
    var out_hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(data, &out_hash, .{});
    return out_hash;
}

fn align64(val: u64) u64 {
    return std.mem.alignForward(u64, val, 64);
}

fn computeTotalSize(specs: []const FileSpec) u64 {
    var offset: u64 = align64(@sizeOf(BundleHeader) + specs.len * @sizeOf(BundleEntry));
    for (specs) |spec| {
        offset = align64(offset + spec.data.len);
    }
    return offset;
}

fn writeEntries(io: std.Io, file: *std.Io.File, specs: []const FileSpec) !void {
    var offset: u64 = align64(@sizeOf(BundleHeader) + specs.len * @sizeOf(BundleEntry));
    for (specs) |spec| {
        var entry = BundleEntry{
            .tag = [_]u8{0} ** 32,
            .offset = offset,
            .size_bytes = spec.data.len,
            .content_hash = spec.hash,
        };
        const copy_len = @min(spec.tag.len, 31);
        @memcpy(entry.tag[0..copy_len], spec.tag[0..copy_len]);
        try file.writeStreamingAll(io, std.mem.asBytes(&entry));
        offset = align64(offset + spec.data.len);
    }
}

fn writePadding(io: std.Io, file: *std.Io.File, count: usize) !void {
    if (count == 0) return;
    const zeroes = [_]u8{0} ** 64;
    var remaining = count;
    while (remaining > 0) {
        const chunk = @min(remaining, 64);
        try file.writeStreamingAll(io, zeroes[0..chunk]);
        remaining -= chunk;
    }
}

fn writePayloads(io: std.Io, file: *std.Io.File, specs: []const FileSpec) !void {
    var cur_pos: u64 = @sizeOf(BundleHeader) + specs.len * @sizeOf(BundleEntry);
    for (specs) |spec| {
        const target_offset = align64(cur_pos);
        if (target_offset > cur_pos) {
            try writePadding(io, file, @intCast(target_offset - cur_pos));
            cur_pos = target_offset;
        }
        try file.writeStreamingAll(io, spec.data);
        cur_pos += spec.data.len;
    }
    const final_aligned = align64(cur_pos);
    if (final_aligned > cur_pos) {
        try writePadding(io, file, @intCast(final_aligned - cur_pos));
    }
}

fn buildBundle(
    io: std.Io,
    out_path: []const u8,
    specs: []const FileSpec,
) !void {
    const cwd = std.Io.Dir.cwd();
    const out_file = try cwd.createFile(io, out_path, .{});
    var f = out_file;
    defer f.close(io);

    const total_size = computeTotalSize(specs);
    const header = BundleHeader{
        .magic = MCB_MAGIC,
        .version = MCB_VERSION,
        .entry_count = @intCast(specs.len),
        .total_size_bytes = total_size,
        .reserved = 0,
    };
    try f.writeStreamingAll(io, std.mem.asBytes(&header));
    try writeEntries(io, &f, specs);
    try writePayloads(io, &f, specs);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = init.minimal.args.iterate();
    _ = args.skip(); // skip binary name

    const out_path = args.next() orelse {
        std.debug.print("Usage: micros-bundle <output.mcb> <tag=path> [tag=path...]\n", .{});
        std.process.exit(1);
    };

    var specs: std.ArrayList(FileSpec) = .empty;
    defer specs.deinit(allocator);

    while (args.next()) |arg| {
        const parsed = parseTagAndPath(arg) orelse continue;
        const data = try std.Io.Dir.cwd().readFileAllocOptions(
            init.io,
            parsed.path,
            allocator,
            .limited(16 * 1024 * 1024),
            .of(u8),
            0,
        );
        const hash = computeHash(data);
        try specs.append(allocator, .{
            .tag = parsed.tag,
            .path = parsed.path,
            .data = data,
            .hash = hash,
        });
    }

    try buildBundle(init.io, out_path, specs.items);
    std.debug.print("[micros-bundle] Successfully packed {d} entries into {s}\n", .{ specs.items.len, out_path });
}
