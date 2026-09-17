// Macros Deterministic Bytecode Chunk Serializer & Hasher
// Implements SPEC-TECH-LANG-002 section 2.3 for fixed-point verification.

const std = @import("std");
const eval = @import("eval.zig");
const chunk_mod = @import("chunk.zig");

const Value = eval.Value;
const Chunk = chunk_mod.Chunk;
const Allocator = std.mem.Allocator;

pub const MAGIC: [4]u8 = [_]u8{ 'M', 'C', 'R', '1' };
pub const VERSION: u16 = 1;
pub const HEADER_SIZE: u16 = 64;

pub const TAG_NIL: u8 = 0;
pub const TAG_BOOL_FALSE: u8 = 1;
pub const TAG_BOOL_TRUE: u8 = 2;
pub const TAG_INT64: u8 = 3;
pub const TAG_STRING: u8 = 4;
pub const TAG_FUNCTION: u8 = 5;

pub const Header = extern struct {
    magic: [4]u8,
    version: u16,
    header_size: u16,
    flags: u32,
    code_offset: u32,
    code_length: u32,
    constants_offset: u32,
    constants_count: u32,
    reserved: [36]u8,
};

pub const SerializerError = error{
    InvalidMagic,
    UnsupportedVersion,
    CorruptedHeader,
    TruncatedData,
    InvalidConstantTag,
    OutOfMemory,
};

fn serializeString(buf: *std.ArrayList(u8), allocator: Allocator, s: []const u8) !void {
    const len: u32 = @intCast(s.len);
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_bytes, len, .little);
    try buf.appendSlice(allocator, &len_bytes);
    try buf.appendSlice(allocator, s);
}

fn serializeFunction(buf: *std.ArrayList(u8), allocator: Allocator, f: eval.Function) !void {
    try serializeString(buf, allocator, f.name);
    var meta: [10]u8 = undefined;
    std.mem.writeInt(u16, meta[0..2], @intCast(f.arity), .little);
    std.mem.writeInt(u16, meta[2..4], @intCast(f.local_count), .little);
    std.mem.writeInt(u16, meta[4..6], @intCast(f.upvalue_count), .little);
    std.mem.writeInt(u32, meta[6..10], @intCast(f.ip_start), .little);
    try buf.appendSlice(allocator, &meta);
}

fn serializeConstant(buf: *std.ArrayList(u8), allocator: Allocator, val: Value) !void {
    switch (val) {
        .nil => try buf.append(allocator, TAG_NIL),
        .boolean => |b| {
            const tag = if (b) TAG_BOOL_TRUE else TAG_BOOL_FALSE;
            try buf.append(allocator, tag);
        },
        .integer => |i| {
            try buf.append(allocator, TAG_INT64);
            var b: [8]u8 = undefined;
            std.mem.writeInt(i64, &b, i, .little);
            try buf.appendSlice(allocator, &b);
        },
        .string => |s| {
            try buf.append(allocator, TAG_STRING);
            try serializeString(buf, allocator, s);
        },
        .function => |f| {
            try buf.append(allocator, TAG_FUNCTION);
            try serializeFunction(buf, allocator, f);
        },
        else => try buf.append(allocator, TAG_NIL),
    }
}

pub fn serializeChunk(allocator: Allocator, chunk: *const Chunk) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    var hdr: Header = undefined;
    hdr.magic = MAGIC;
    hdr.version = VERSION;
    hdr.header_size = HEADER_SIZE;
    hdr.flags = 0;
    hdr.code_offset = HEADER_SIZE;
    hdr.code_length = @intCast(chunk.code.items.len);
    hdr.constants_offset = HEADER_SIZE + hdr.code_length;
    hdr.constants_count = @intCast(chunk.constants.items.len);
    @memset(&hdr.reserved, 0);

    const hdr_bytes: [*]const u8 = @ptrCast(&hdr);
    try buf.appendSlice(allocator, hdr_bytes[0..HEADER_SIZE]);
    try buf.appendSlice(allocator, chunk.code.items);

    for (chunk.constants.items) |c| {
        try serializeConstant(&buf, allocator, c);
    }
    return buf.toOwnedSlice(allocator);
}

fn deserializeString(data: []const u8, pos: *usize, allocator: Allocator) ![]const u8 {
    if (pos.* + 4 > data.len) return SerializerError.TruncatedData;
    const len = std.mem.readInt(u32, data[pos.* .. pos.* + 4][0..4], .little);
    pos.* += 4;
    if (pos.* + len > data.len) return SerializerError.TruncatedData;
    const s = try allocator.dupe(u8, data[pos.* .. pos.* + len]);
    pos.* += len;
    return s;
}

fn deserializeFunction(data: []const u8, pos: *usize, allocator: Allocator) !eval.Function {
    const name = try deserializeString(data, pos, allocator);
    if (pos.* + 10 > data.len) return SerializerError.TruncatedData;
    const arity = std.mem.readInt(u16, data[pos.* .. pos.* + 2][0..2], .little);
    const local_count = std.mem.readInt(u16, data[pos.* + 2 .. pos.* + 4][0..2], .little);
    const upvalue_count = std.mem.readInt(u16, data[pos.* + 4 .. pos.* + 6][0..2], .little);
    const ip_start = std.mem.readInt(u32, data[pos.* + 6 .. pos.* + 10][0..4], .little);
    pos.* += 10;
    return eval.Function{
        .name = name,
        .arity = arity,
        .local_count = local_count,
        .upvalue_count = upvalue_count,
        .ip_start = ip_start,
    };
}

fn deserializeConstant(data: []const u8, pos: *usize, allocator: Allocator) !Value {
    if (pos.* >= data.len) return SerializerError.TruncatedData;
    const tag = data[pos.*];
    pos.* += 1;
    switch (tag) {
        TAG_NIL => return Value{ .nil = {} },
        TAG_BOOL_FALSE => return Value{ .boolean = false },
        TAG_BOOL_TRUE => return Value{ .boolean = true },
        TAG_INT64 => {
            if (pos.* + 8 > data.len) return SerializerError.TruncatedData;
            const val = std.mem.readInt(i64, data[pos.* .. pos.* + 8][0..8], .little);
            pos.* += 8;
            return Value{ .integer = val };
        },
        TAG_STRING => {
            const s = try deserializeString(data, pos, allocator);
            return Value{ .string = s };
        },
        TAG_FUNCTION => {
            const f = try deserializeFunction(data, pos, allocator);
            return Value{ .function = f };
        },
        else => return SerializerError.InvalidConstantTag,
    }
}

pub fn deserializeChunk(allocator: Allocator, data: []const u8) !Chunk {
    if (data.len < HEADER_SIZE) return SerializerError.TruncatedData;
    if (!std.mem.eql(u8, data[0..4], &MAGIC)) return SerializerError.InvalidMagic;
    const version = std.mem.readInt(u16, data[4..6], .little);
    if (version != VERSION) return SerializerError.UnsupportedVersion;

    const code_offset = std.mem.readInt(u32, data[12..16], .little);
    const code_len = std.mem.readInt(u32, data[16..20], .little);
    const consts_count = std.mem.readInt(u32, data[24..28], .little);

    if (code_offset + code_len > data.len) return SerializerError.TruncatedData;
    var ch = Chunk.init();
    errdefer ch.deinit(allocator);

    const code_slice = data[code_offset .. code_offset + code_len];
    try ch.code.appendSlice(allocator, code_slice);

    var pos: usize = code_offset + code_len;
    var i: u32 = 0;
    while (i < consts_count) : (i += 1) {
        const val = try deserializeConstant(data, &pos, allocator);
        if (val == .string) {
            _ = try ch.addAllocatedString(allocator, val.string);
        } else if (val == .function) {
            _ = try ch.addAllocatedString(allocator, val.function.name);
        }
        _ = try ch.addConstant(allocator, val);
    }
    return ch;
}

pub fn computeChunkHash(allocator: Allocator, chunk: *const Chunk) ![32]u8 {
    const serialized = try serializeChunk(allocator, chunk);
    defer allocator.free(serialized);
    var hash: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(serialized, &hash, .{});
    return hash;
}

test "serializer roundtrip and deterministic hashing" {
    const testing = std.testing;
    var ch = Chunk.init();
    defer ch.deinit(testing.allocator);

    const c1 = try ch.addConstant(testing.allocator, Value{ .integer = 42 });
    const c2 = try ch.addConstant(testing.allocator, Value{ .boolean = true });
    const s1 = try ch.addAllocatedString(testing.allocator, try testing.allocator.dupe(u8, "hello"));
    const c3 = try ch.addConstant(testing.allocator, Value{ .string = s1 });

    try ch.writeChunk(testing.allocator, 0); // op_constant
    try ch.writeChunk(testing.allocator, @intCast(c1 & 0xFF));
    try ch.writeChunk(testing.allocator, 0); // op_constant
    try ch.writeChunk(testing.allocator, @intCast(c2 & 0xFF));
    try ch.writeChunk(testing.allocator, 0); // op_constant
    try ch.writeChunk(testing.allocator, @intCast(c3 & 0xFF));
    try ch.writeChunk(testing.allocator, 4); // op_return

    const bytes = try serializeChunk(testing.allocator, &ch);
    defer testing.allocator.free(bytes);

    var deserialized = try deserializeChunk(testing.allocator, bytes);
    defer deserialized.deinit(testing.allocator);

    try testing.expectEqual(ch.code.items.len, deserialized.code.items.len);
    try testing.expectEqual(ch.constants.items.len, deserialized.constants.items.len);
    try testing.expectEqual(deserialized.constants.items[0].integer, 42);
    try testing.expectEqual(deserialized.constants.items[1].boolean, true);
    try testing.expectEqualStrings("hello", deserialized.constants.items[2].string);

    // Assert identical BLAKE3 hash on second serialization
    const hash1 = try computeChunkHash(testing.allocator, &ch);
    const hash2 = try computeChunkHash(testing.allocator, &deserialized);
    try testing.expectEqualSlices(u8, &hash1, &hash2);
}

test "Fixed-Point BLAKE3 verification across compiler runs" {
    const testing = std.testing;
    const parser_mod = @import("parser.zig");
    const compiler_mod = @import("compiler.zig");

    const source = "fn fib(n) { if (n <= 1) { return n; } return fib(n - 1) + fib(n - 2); } x = fib(10);";

    // Run 1 (Chunk 1)
    var ch1 = Chunk.init();
    defer ch1.deinit(testing.allocator);
    var p1 = parser_mod.Parser.init(testing.allocator, source);
    var c1 = compiler_mod.Compiler.init(testing.allocator, &ch1);
    while (p1.current_token.token_type != .eof) {
        const stmt = try p1.parseStatement();
        try c1.compile(stmt);
        stmt.deinit(testing.allocator);
    }
    const hash1 = try computeChunkHash(testing.allocator, &ch1);

    // Run 2 (Chunk 2)
    var ch2 = Chunk.init();
    defer ch2.deinit(testing.allocator);
    var p2 = parser_mod.Parser.init(testing.allocator, source);
    var c2 = compiler_mod.Compiler.init(testing.allocator, &ch2);
    while (p2.current_token.token_type != .eof) {
        const stmt = try p2.parseStatement();
        try c2.compile(stmt);
        stmt.deinit(testing.allocator);
    }
    const hash2 = try computeChunkHash(testing.allocator, &ch2);

    try testing.expectEqualSlices(u8, &hash1, &hash2);
}
