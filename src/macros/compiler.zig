const std = @import("std");
const ast = @import("ast.zig");
const chunk = @import("chunk.zig");
const eval = @import("eval.zig");
const OpCode = chunk.OpCode;

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    chunk: *chunk.Chunk,
    locals: [256][]const u8,
    local_count: usize,
    scope_depth: usize,

    pub fn init(allocator: std.mem.Allocator, ch: *chunk.Chunk) Compiler {
        return Compiler{
            .allocator = allocator,
            .chunk = ch,
            .locals = undefined,
            .local_count = 0,
            .scope_depth = 0,
        };
    }

    pub fn resolveLocal(self: *Compiler, name: []const u8) ?u8 {
        var i: usize = self.local_count;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.locals[i], name)) return @intCast(i);
        }
        return null;
    }

    pub fn emitJump(self: *Compiler, instruction: u8) !usize {
        try self.chunk.writeChunk(self.allocator, instruction);
        try self.chunk.writeChunk(self.allocator, 0xff);
        try self.chunk.writeChunk(self.allocator, 0xff);
        return self.chunk.code.items.len - 2;
    }

    pub fn patchJump(self: *Compiler, offset: usize) !void {
        const jump = self.chunk.code.items.len - offset - 2;
        if (jump > std.math.maxInt(u16)) return error.TooMuchCodeToJump;
        self.chunk.code.items[offset] = @intCast((jump >> 8) & 0xff);
        self.chunk.code.items[offset + 1] = @intCast(jump & 0xff);
    }

    pub fn emitLoop(self: *Compiler, loop_start: usize) !void {
        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.loop));
        const offset = self.chunk.code.items.len - loop_start + 2;
        if (offset > std.math.maxInt(u16)) return error.TooMuchCodeToJump;
        try self.chunk.writeChunk(self.allocator, @intCast((offset >> 8) & 0xff));
        try self.chunk.writeChunk(self.allocator, @intCast(offset & 0xff));
    }

    pub fn compile(self: *Compiler, node: *const ast.Node) !void {
        switch (node.*) {
            .number_literal => |lit| {
                const num = std.fmt.parseInt(i64, lit.value, 10) catch return error.InvalidNumber;
                const idx = try self.chunk.addConstant(self.allocator, eval.Value{ .integer = num });
                try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
                try self.chunk.writeChunk(self.allocator, @intCast((idx >> 8) & 0xFF));
                try self.chunk.writeChunk(self.allocator, @intCast(idx & 0xFF));
            },
            .string_literal => |lit| {
                const idx = try self.chunk.addConstant(self.allocator, eval.Value{ .string = lit.value });
                try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
                try self.chunk.writeChunk(self.allocator, @intCast((idx >> 8) & 0xFF));
                try self.chunk.writeChunk(self.allocator, @intCast(idx & 0xFF));
            },
            .boolean_literal => |lit| {
                const idx = try self.chunk.addConstant(self.allocator, eval.Value{ .boolean = lit.value });
                try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
                try self.chunk.writeChunk(self.allocator, @intCast((idx >> 8) & 0xFF));
                try self.chunk.writeChunk(self.allocator, @intCast(idx & 0xFF));
            },
            .binary_expr => |bin| {
                try self.compile(bin.left);
                try self.compile(bin.right);
                if (bin.operator == .plus) {
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.add));
                } else if (bin.operator == .minus) {
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.sub));
                } else if (bin.operator == .equal_equal) {
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.equal));
                } else if (bin.operator == .not_equal) {
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.not_equal));
                } else if (bin.operator == .less_than) {
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.less));
                } else if (bin.operator == .greater_than) {
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.greater));
                } else if (bin.operator == .less_equal) {
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.less_equal));
                } else if (bin.operator == .greater_equal) {
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.greater_equal));
                } else return error.UnsupportedOperator;
            },
            .identifier => |ident| {
                if (self.resolveLocal(ident.name)) |slot| {
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.get_local));
                    try self.chunk.writeChunk(self.allocator, slot);
                } else {
                    const idx = try self.chunk.addConstant(self.allocator, eval.Value{ .string = ident.name });
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.get_global));
                    try self.chunk.writeChunk(self.allocator, @intCast((idx >> 8) & 0xFF));
                try self.chunk.writeChunk(self.allocator, @intCast(idx & 0xFF));
                }
            },
            .assignment => |assign| {
                try self.compile(assign.value);
                if (self.scope_depth > 0) {
                    var slot: u8 = 0;
                    if (self.resolveLocal(assign.target.name)) |existing_slot| {
                        slot = existing_slot;
                    } else {
                        slot = @intCast(self.local_count);
                        self.locals[self.local_count] = assign.target.name;
                        self.local_count += 1;
                    }
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.set_local));
                    try self.chunk.writeChunk(self.allocator, slot);
                } else {
                    const idx = try self.chunk.addConstant(self.allocator, eval.Value{ .string = assign.target.name });
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.set_global));
                    try self.chunk.writeChunk(self.allocator, @intCast((idx >> 8) & 0xFF));
                try self.chunk.writeChunk(self.allocator, @intCast(idx & 0xFF));
                }
            },
            .call_expr => |call| {
                if ((std.mem.eql(u8, call.callee, "print") or std.mem.eql(u8, call.callee, "println")) and call.args.len == 1) {
                    try self.compile(call.args[0]);
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.print));
                } else {
                    if (self.resolveLocal(call.callee)) |slot| {
                        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.get_local));
                        try self.chunk.writeChunk(self.allocator, slot);
                    } else {
                        const idx = try self.chunk.addConstant(self.allocator, eval.Value{ .string = call.callee });
                        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.get_global));
                        try self.chunk.writeChunk(self.allocator, @intCast((idx >> 8) & 0xFF));
                try self.chunk.writeChunk(self.allocator, @intCast(idx & 0xFF));
                    }
                    for (call.args) |arg| {
                        try self.compile(arg);
                    }
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.call));
                    try self.chunk.writeChunk(self.allocator, @intCast(call.args.len));
                }
            },
            .block => |blk| {
                if (blk.statements.len == 0) {
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
                    const nil_idx = try self.chunk.addConstant(self.allocator, eval.Value{ .nil = {} });
                    try self.chunk.writeChunk(self.allocator, @intCast((nil_idx >> 8) & 0xFF));
                    try self.chunk.writeChunk(self.allocator, @intCast(nil_idx & 0xFF));
                } else {
                    for (blk.statements, 0..) |stmt, i| {
                        try self.compile(stmt);
                        if (i < blk.statements.len - 1) {
                            try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.pop));
                        }
                    }
                }
            },
            .if_expr => |if_node| {
                try self.compile(if_node.condition);
                const then_jump = try self.emitJump(@intFromEnum(OpCode.jump_if_false));
                try self.compile(if_node.then_branch);

                if (if_node.else_branch) |else_br| {
                    const else_jump = try self.emitJump(@intFromEnum(OpCode.jump));
                    try self.patchJump(then_jump);
                    try self.compile(else_br);
                    try self.patchJump(else_jump);
                } else {
                    const else_jump = try self.emitJump(@intFromEnum(OpCode.jump));
                    try self.patchJump(then_jump);
                    try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
                    const nil_idx = try self.chunk.addConstant(self.allocator, eval.Value{ .nil = {} });
                    try self.chunk.writeChunk(self.allocator, @intCast((nil_idx >> 8) & 0xFF));
                    try self.chunk.writeChunk(self.allocator, @intCast(nil_idx & 0xFF));
                    try self.patchJump(else_jump);
                }
            },
            .while_expr => |while_node| {
                const loop_start = self.chunk.code.items.len;
                try self.compile(while_node.condition);
                const exit_jump = try self.emitJump(@intFromEnum(OpCode.jump_if_false));
                try self.compile(while_node.body);
                try self.emitLoop(loop_start);
                try self.patchJump(exit_jump);
            },
            .function_decl => |func| {
                const jump_over = try self.emitJump(@intFromEnum(OpCode.jump));
                const fn_start = self.chunk.code.items.len;

                self.scope_depth += 1;
                const old_count = self.local_count;
                self.locals[self.local_count] = func.name; // slot 0 is function itself
                self.local_count += 1;
                for (func.params) |param| {
                    self.locals[self.local_count] = param;
                    self.local_count += 1;
                }

                try self.compile(func.body);

                const fn_local_count = self.local_count;
                self.local_count = old_count;
                self.scope_depth -= 1;

                try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
                const nil_idx = try self.chunk.addConstant(self.allocator, eval.Value{ .nil = {} });
                try self.chunk.writeChunk(self.allocator, @intCast((nil_idx >> 8) & 0xFF));
                    try self.chunk.writeChunk(self.allocator, @intCast(nil_idx & 0xFF));
                try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.return_op));

                try self.patchJump(jump_over);

                const vm_func = eval.Function{ .name = func.name, .arity = func.params.len, .local_count = fn_local_count, .ip_start = fn_start };
                const fn_idx = try self.chunk.addConstant(self.allocator, eval.Value{ .function = vm_func });
                try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
                try self.chunk.writeChunk(self.allocator, @intCast((fn_idx >> 8) & 0xFF));
                try self.chunk.writeChunk(self.allocator, @intCast(fn_idx & 0xFF));

                const name_idx = try self.chunk.addConstant(self.allocator, eval.Value{ .string = func.name });
                try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.set_global));
                try self.chunk.writeChunk(self.allocator, @intCast((name_idx >> 8) & 0xFF));
                try self.chunk.writeChunk(self.allocator, @intCast(name_idx & 0xFF));
            },
            .return_expr => |ret| {
                if (ret.value) |v| try self.compile(v);
                try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.return_op));
            },
            .index_expr => |index| {
                try self.compile(index.target);
                try self.compile(index.index);
                try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.index_get));
            },
            .array_literal => |array| {
                for (array.elements) |element| {
                    try self.compile(element);
                }
                try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.build_array));
                try self.chunk.writeChunk(self.allocator, @intCast(array.elements.len));
            },
            .index_assignment => |ia| {
                try self.compile(ia.value);
                try self.compile(ia.target);
                try self.compile(ia.index);
                try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.index_set));
            },
            
        }
    }
};

test "compiler basic" {
    const allocator = std.testing.allocator;
    var ch = chunk.Chunk.init();
    defer ch.deinit(allocator);

    var comp = Compiler.init(allocator, &ch);

    const int1 = try allocator.create(ast.Node);
    defer allocator.destroy(int1);
    int1.* = .{ .number_literal = .{ .value = "10" } };

    const int2 = try allocator.create(ast.Node);
    defer allocator.destroy(int2);
    int2.* = .{ .number_literal = .{ .value = "20" } };

    const bin = try allocator.create(ast.Node);
    defer allocator.destroy(bin);
    bin.* = .{
        .binary_expr = .{
            .left = int1,
            .operator = .plus,
            .right = int2,
        },
    };

    try comp.compile(bin);

    try std.testing.expectEqual(@as(usize, 5), ch.code.items.len);
    try std.testing.expectEqual(@intFromEnum(OpCode.constant), ch.code.items[0]);
    try std.testing.expectEqual(@as(u8, 0), ch.code.items[1]);
    try std.testing.expectEqual(@intFromEnum(OpCode.constant), ch.code.items[2]);
    try std.testing.expectEqual(@as(u8, 1), ch.code.items[3]);
    try std.testing.expectEqual(@intFromEnum(OpCode.add), ch.code.items[4]);
}
