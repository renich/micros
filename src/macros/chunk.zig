const std = @import("std");
const eval = @import("eval.zig");
const Value = eval.Value;

pub const OpCode = enum(u8) {
    constant,
    add,
    sub,
    print,
    return_op,
    get_global,
    set_global,
    get_local,
    set_local,
    pop,
    call,
    jump,
    jump_if_false,
    loop,
    build_array,
    index_get,
    index_set,
    build_dict,
    get_property,
    set_property,
    equal,
    not_equal,
    less,
    greater,
    less_equal,
    greater_equal,
    closure,
    get_upvalue,
    set_upvalue,
    close_upvalue,
};

pub const Chunk = struct {
    code: std.ArrayList(u8),
    constants: std.ArrayList(Value),

    pub fn init() Chunk {
        return Chunk{
            .code = .empty,
            .constants = .empty,
        };
    }

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        self.code.deinit(allocator);
        self.constants.deinit(allocator);
    }

    pub fn writeChunk(self: *Chunk, allocator: std.mem.Allocator, byte: u8) !void {
        try self.code.append(allocator, byte);
    }

    pub fn addConstant(self: *Chunk, allocator: std.mem.Allocator, value: Value) !u16 {
        try self.constants.append(allocator, value);
        return @intCast(self.constants.items.len - 1);
    }
};

test "chunk basic" {
    var chunk = Chunk.init();
    defer chunk.deinit(std.testing.allocator);

    const idx = try chunk.addConstant(std.testing.allocator, Value{ .integer = 42 });
    try std.testing.expectEqual(0, idx);

    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.constant));
    try chunk.writeChunk(std.testing.allocator, @intCast(idx & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.return_op));

    try std.testing.expectEqual(3, chunk.code.items.len);
}
