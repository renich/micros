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

    pub fn patchJump(self: *Compiler, offset: usize) anyerror!void {
        const jump = self.chunk.code.items.len - offset - 2;
        if (jump > std.math.maxInt(u16)) return error.TooMuchCodeToJump;
        self.chunk.code.items[offset] = @intCast((jump >> 8) & 0xff);
        self.chunk.code.items[offset + 1] = @intCast(jump & 0xff);
    }

    pub fn emitLoop(self: *Compiler, loop_start: usize) anyerror!void {
        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.loop));
        const offset = self.chunk.code.items.len - loop_start + 2;
        if (offset > std.math.maxInt(u16)) return error.TooMuchCodeToJump;
        try self.chunk.writeChunk(self.allocator, @intCast((offset >> 8) & 0xff));
        try self.chunk.writeChunk(self.allocator, @intCast(offset & 0xff));
    }

    pub fn compile(self: *Compiler, node: *const ast.Node) anyerror!void {
        switch (node.*) {
            .number_literal => |num| try self.compileNumberLiteral(num),
            .string_literal => |str| try self.compileStringLiteral(str),
            .boolean_literal => |bool_lit| try self.compileBooleanLiteral(bool_lit),
            .binary_expr => |bin| try self.compileBinaryExpr(bin),
            .assignment => |assign| try self.compileAssignment(assign),
            .identifier => |ident| try self.compileIdentifier(ident),
            .call_expr => |call| try self.compileCallExpr(call),
            .block => |blk| try self.compileBlock(blk),
            .if_expr => |if_node| try self.compileIfExpr(if_node),
            .while_expr => |while_node| try self.compileWhileExpr(while_node),
            .function_decl => |func| try self.compileFunctionDecl(func),
            .return_expr => |ret| try self.compileReturnExpr(ret),
            .index_expr => |index| try self.compileIndexExpr(index),
            .array_literal => |array| try self.compileArrayLiteral(array),
            .index_assignment => |ia| try self.compileIndexAssignment(ia),
            .unary_expr => |unary| try self.compileUnaryExpr(unary),
        }
    }
    fn compileBooleanLiteral(self: *Compiler, lit: ast.BooleanLiteral) anyerror!void {
        const idx = try self.chunk.addConstant(self.allocator, eval.Value{ .boolean = lit.value });
        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
        try self.chunk.writeChunk(self.allocator, @intCast((idx >> 8) & 0xFF));
        try self.chunk.writeChunk(self.allocator, @intCast(idx & 0xFF));
    }
    fn compileNumberLiteral(self: *Compiler, num: ast.NumberLiteral) anyerror!void {
        const val = try std.fmt.parseInt(i64, num.value, 10);
        const idx = try self.chunk.addConstant(self.allocator, eval.Value{ .integer = val });
        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
        try self.chunk.writeChunk(self.allocator, @intCast((idx >> 8) & 0xFF));
        try self.chunk.writeChunk(self.allocator, @intCast(idx & 0xFF));
    }

    fn decodeEscape(c: u8) u8 {
        return switch (c) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\' => '\\',
            '"' => '"',
            '0' => 0,
            'e' => 0x1B,
            else => c,
        };
    }

    fn unescapeString(self: *Compiler, raw: []const u8) ![]const u8 {
        var buf = try self.allocator.alloc(u8, raw.len);
        errdefer self.allocator.free(buf);
        var src_i: usize = 0;
        var dst_i: usize = 0;
        while (src_i < raw.len) {
            if (raw[src_i] == '\\' and src_i + 1 < raw.len) {
                buf[dst_i] = decodeEscape(raw[src_i + 1]);
                src_i += 2;
            } else {
                buf[dst_i] = raw[src_i];
                src_i += 1;
            }
            dst_i += 1;
        }
        return try self.allocator.realloc(buf, dst_i);
    }

    fn addStringConstant(self: *Compiler, str: []const u8) !u16 {
        const duped = try self.allocator.dupe(u8, str);
        const owned = try self.chunk.addAllocatedString(self.allocator, duped);
        return try self.chunk.addConstant(self.allocator, eval.Value{ .string = owned });
    }

    fn compileStringLiteral(self: *Compiler, str: ast.StringLiteral) anyerror!void {
        var val = str.value;
        if (std.mem.indexOfScalar(u8, val, '\\') != null) {
            const decoded = try self.unescapeString(val);
            val = try self.chunk.addAllocatedString(self.allocator, decoded);
        } else {
            const duped = try self.allocator.dupe(u8, val);
            val = try self.chunk.addAllocatedString(self.allocator, duped);
        }
        const idx = try self.chunk.addConstant(self.allocator, eval.Value{ .string = val });
        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
        try self.chunk.writeChunk(self.allocator, @intCast((idx >> 8) & 0xFF));
        try self.chunk.writeChunk(self.allocator, @intCast(idx & 0xFF));
    }

    fn compileBinaryExpr(self: *Compiler, bin: ast.BinaryExpr) anyerror!void {
        try self.compile(bin.left);
        try self.compile(bin.right);
        const op: OpCode = switch (bin.operator) {
            .plus => .add,
            .minus => .sub,
            .star => .multiply,
            .slash => .divide,
            .percent => .modulo,
            .bitwise_and => .bitwise_and,
            .bitwise_or => .bitwise_or,
            .bitwise_xor => .bitwise_xor,
            .shift_left => .shift_left,
            .shift_right => .shift_right,
            .equal_equal => .equal,
            .not_equal => .not_equal,
            .greater_than => .greater,
            .less_than => .less,
            .greater_equal => .greater_equal,
            .less_equal => .less_equal,
        };
        try self.chunk.writeChunk(self.allocator, @intFromEnum(op));
    }

    fn compileUnaryExpr(self: *Compiler, unary: ast.UnaryExpr) anyerror!void {
        try self.compile(unary.operand);
        const op: OpCode = switch (unary.operator) {
            .minus => .negate,
            .not => .not,
        };
        try self.chunk.writeChunk(self.allocator, @intFromEnum(op));
    }

    fn compileVariableDecl(self: *Compiler, decl: ast.VariableDecl) anyerror!void {
        if (decl.initializer) |init_node| {
            try self.compile(init_node);
        } else {
            const idx = try self.chunk.addConstant(self.allocator, eval.Value{ .nil = {} });
            try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
            try self.chunk.writeChunk(self.allocator, @intCast((idx >> 8) & 0xFF));
            try self.chunk.writeChunk(self.allocator, @intCast(idx & 0xFF));
        }

        if (self.scope_depth > 0) {
            if (self.local_count >= 256) return error.TooManyLocals;
            self.locals[self.local_count] = decl.name;
            try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.set_local));
            try self.chunk.writeChunk(self.allocator, @intCast(self.local_count));
            try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.pop));
            self.local_count += 1;
        } else {
            const idx = try self.addStringConstant(decl.name);
            try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.set_global));
            try self.chunk.writeChunk(self.allocator, @intCast((idx >> 8) & 0xFF));
            try self.chunk.writeChunk(self.allocator, @intCast(idx & 0xFF));
        }
    }

    fn compileAssignment(self: *Compiler, assign: ast.Assignment) anyerror!void {
        try self.compile(assign.value);

        if (self.resolveLocal(assign.target.name)) |slot| {
            try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.set_local));
            try self.chunk.writeChunk(self.allocator, slot);
        } else {
            const idx = try self.addStringConstant(assign.target.name);
            try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.set_global));
            try self.chunk.writeChunk(self.allocator, @intCast((idx >> 8) & 0xFF));
            try self.chunk.writeChunk(self.allocator, @intCast(idx & 0xFF));
        }
    }

    fn compileIdentifier(self: *Compiler, ident: ast.Identifier) anyerror!void {
        if (self.resolveLocal(ident.name)) |slot| {
            try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.get_local));
            try self.chunk.writeChunk(self.allocator, slot);
        } else {
            const idx = try self.addStringConstant(ident.name);
            try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.get_global));
            try self.chunk.writeChunk(self.allocator, @intCast((idx >> 8) & 0xFF));
            try self.chunk.writeChunk(self.allocator, @intCast(idx & 0xFF));
        }
    }

    fn compileCallExpr(self: *Compiler, call: ast.CallExpr) anyerror!void {
        if ((std.mem.eql(u8, call.callee, "print") or std.mem.eql(u8, call.callee, "println")) and call.args.len == 1) {
            try self.compile(call.args[0]);
            try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.print));
            // Push nil so expr_statement's pop doesn't underflow!
            try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
            const nil_idx = try self.chunk.addConstant(self.allocator, eval.Value{ .nil = {} });
            try self.chunk.writeChunk(self.allocator, @intCast((nil_idx >> 8) & 0xFF));
            try self.chunk.writeChunk(self.allocator, @intCast(nil_idx & 0xFF));
        } else {
            if (self.resolveLocal(call.callee)) |slot| {
                try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.get_local));
                try self.chunk.writeChunk(self.allocator, slot);
            } else {
                const idx = try self.addStringConstant(call.callee);
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
    }

    fn compileBlock(self: *Compiler, blk: ast.Block) anyerror!void {
        if (blk.statements.len == 0) {
            try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
            const nil_idx = try self.chunk.addConstant(self.allocator, eval.Value{ .nil = {} });
            try self.chunk.writeChunk(self.allocator, @intCast((nil_idx >> 8) & 0xFF));
            try self.chunk.writeChunk(self.allocator, @intCast(nil_idx & 0xFF));
            return;
        }

        for (blk.statements, 0..) |stmt, i| {
            try self.compile(stmt);
            if (i < blk.statements.len - 1) {
                try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.pop));
            }
        }
    }

    fn compileIfExpr(self: *Compiler, if_node: ast.IfExpr) anyerror!void {
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
    }

    fn compileWhileExpr(self: *Compiler, while_node: ast.WhileExpr) anyerror!void {
        const loop_start = self.chunk.code.items.len;
        try self.compile(while_node.condition);
        const exit_jump = try self.emitJump(@intFromEnum(OpCode.jump_if_false));
        try self.compile(while_node.body);
        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.pop));
        try self.emitLoop(loop_start);
        try self.patchJump(exit_jump);
        const nil_idx = try self.chunk.addConstant(self.allocator, eval.Value{ .nil = {} });
        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
        try self.chunk.writeChunk(self.allocator, @intCast((nil_idx >> 8) & 0xFF));
        try self.chunk.writeChunk(self.allocator, @intCast(nil_idx & 0xFF));
    }

    fn compileFunctionDecl(self: *Compiler, func: ast.FunctionDecl) anyerror!void {
        const jump_over = try self.emitJump(@intFromEnum(OpCode.jump));
        const fn_start = self.chunk.code.items.len;

        self.scope_depth += 1;
        const old_count = self.local_count;
        self.locals[self.local_count] = func.name;
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
        try self.emitFunctionConstant(func, fn_local_count, fn_start);
    }

    fn emitFunctionConstant(self: *Compiler, func: ast.FunctionDecl, fn_local_count: usize, fn_start: usize) !void {
        const duped_name = try self.allocator.dupe(u8, func.name);
        const owned_name = try self.chunk.addAllocatedString(self.allocator, duped_name);
        const vm_func = eval.Function{
            .name = owned_name,
            .arity = func.params.len,
            .local_count = fn_local_count,
            .upvalue_count = 0,
            .ip_start = fn_start,
            .chunk = @ptrCast(self.chunk),
        };
        const fn_idx = try self.chunk.addConstant(self.allocator, eval.Value{ .function = vm_func });
        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.constant));
        try self.chunk.writeChunk(self.allocator, @intCast((fn_idx >> 8) & 0xFF));
        try self.chunk.writeChunk(self.allocator, @intCast(fn_idx & 0xFF));

        const name_idx = try self.chunk.addConstant(self.allocator, eval.Value{ .string = owned_name });
        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.set_global));
        try self.chunk.writeChunk(self.allocator, @intCast((name_idx >> 8) & 0xFF));
        try self.chunk.writeChunk(self.allocator, @intCast(name_idx & 0xFF));
    }

    fn compileReturnExpr(self: *Compiler, ret: ast.ReturnExpr) anyerror!void {
        if (ret.value) |v| try self.compile(v);
        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.return_op));
    }

    fn compileIndexExpr(self: *Compiler, index: ast.IndexExpr) anyerror!void {
        try self.compile(index.target);
        try self.compile(index.index);
        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.index_get));
    }

    fn compileArrayLiteral(self: *Compiler, array: ast.ArrayLiteral) anyerror!void {
        for (array.elements) |element| {
            try self.compile(element);
        }
        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.build_array));
        try self.chunk.writeChunk(self.allocator, @intCast(array.elements.len));
    }

    fn compileIndexAssignment(self: *Compiler, ia: ast.IndexAssignment) anyerror!void {
        try self.compile(ia.value);
        try self.compile(ia.target);
        try self.compile(ia.index);
        try self.chunk.writeChunk(self.allocator, @intFromEnum(OpCode.index_set));
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

    try std.testing.expectEqual(@as(usize, 7), ch.code.items.len);
}

test "compiler unescapes string literals" {
    const allocator = std.testing.allocator;
    var ch = chunk.Chunk.init();
    defer ch.deinit(allocator);

    var comp = Compiler.init(allocator, &ch);

    const str_node = try allocator.create(ast.Node);
    defer allocator.destroy(str_node);
    str_node.* = .{ .string_literal = .{ .value = "hello\\nworld\\t\\\"quotes\\\"" } };

    try comp.compile(str_node);
    try std.testing.expectEqual(@as(usize, 1), ch.constants.items.len);
    const val = ch.constants.items[0];
    try std.testing.expect(val == .string);
    try std.testing.expectEqualStrings("hello\nworld\t\"quotes\"", val.string);
}

test "compiler compiles unary and multiplication expressions" {
    const allocator = std.testing.allocator;
    var ch = chunk.Chunk.init();
    defer ch.deinit(allocator);

    var comp = Compiler.init(allocator, &ch);

    const int1 = try allocator.create(ast.Node);
    defer allocator.destroy(int1);
    int1.* = .{ .number_literal = .{ .value = "5" } };

    const un = try allocator.create(ast.Node);
    defer allocator.destroy(un);
    un.* = .{ .unary_expr = .{ .operator = .minus, .operand = int1 } };

    try comp.compile(un);
    // constant (3 bytes) + negate (1 byte) = 4 bytes
    try std.testing.expectEqual(@as(usize, 4), ch.code.items.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(OpCode.negate)), ch.code.items[3]);
}
