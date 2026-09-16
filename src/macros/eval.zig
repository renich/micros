const std = @import("std");
const ast = @import("ast.zig");

pub const EvalError = error{
    UndefinedVariable,
    TypeMismatch,
    DivisionByZero,
    InvalidLiteral,
    OutOfMemory,
};

pub const Value = union(enum) {
    integer: i64,
    boolean: bool,
    string: []const u8,
    nil: void,

    pub fn format(
        self: Value,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .integer => |v| try writer.print("{}", .{v}),
            .boolean => |v| try writer.print("{}", .{v}),
            .string => |v| try writer.print("{s}", .{v}),
            .nil => try writer.print("nil", .{}),
        }
    }
};

pub const Environment = struct {
    allocator: std.mem.Allocator,
    bindings: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator) Environment {
        return Environment{
            .allocator = allocator,
            .bindings = std.StringHashMap(Value).init(allocator),
        };
    }

    pub fn deinit(self: *Environment) void {
        var it = self.bindings.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.bindings.deinit();
    }

    pub fn set(self: *Environment, name: []const u8, val: Value) !void {
        const gop = try self.bindings.getOrPut(name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, name);
        }
        gop.value_ptr.* = val;
    }

    pub fn get(self: *const Environment, name: []const u8) ?Value {
        return self.bindings.get(name);
    }
};

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    env: *Environment,

    pub fn init(allocator: std.mem.Allocator, env: *Environment) Evaluator {
        return Evaluator{
            .allocator = allocator,
            .env = env,
        };
    }

    fn evalNumber(node: *const ast.Node) EvalError!Value {
        const raw = node.number_literal.value;
        const num = std.fmt.parseInt(i64, raw, 10) catch {
            return EvalError.InvalidLiteral;
        };
        return Value{ .integer = num };
    }

    fn evalIdentifier(self: *Evaluator, node: *const ast.Node) EvalError!Value {
        const name = node.identifier.name;
        if (self.env.get(name)) |val| {
            return val;
        }
        return EvalError.UndefinedVariable;
    }

    fn evalPlus(left: Value, right: Value) EvalError!Value {
        if (left == .integer and right == .integer) {
            return Value{ .integer = left.integer + right.integer };
        }
        return EvalError.TypeMismatch;
    }

    fn evalMinus(left: Value, right: Value) EvalError!Value {
        if (left == .integer and right == .integer) {
            return Value{ .integer = left.integer - right.integer };
        }
        return EvalError.TypeMismatch;
    }

    fn evalEqualEqual(left: Value, right: Value) EvalError!Value {
        if (left == .integer and right == .integer) {
            return Value{ .boolean = (left.integer == right.integer) };
        }
        if (left == .boolean and right == .boolean) {
            return Value{ .boolean = (left.boolean == right.boolean) };
        }
        if (left == .string and right == .string) {
            const eq = std.mem.eql(u8, left.string, right.string);
            return Value{ .boolean = eq };
        }
        return Value{ .boolean = false };
    }

    fn evalBinary(self: *Evaluator, node: *const ast.Node) EvalError!Value {
        const bin = node.binary_expr;
        const left_val = try self.eval(bin.left);
        const right_val = try self.eval(bin.right);

        switch (bin.operator) {
            .plus => return evalPlus(left_val, right_val),
            .minus => return evalMinus(left_val, right_val),
            .equal_equal => return evalEqualEqual(left_val, right_val),
        }
    }

    fn evalAssignment(self: *Evaluator, node: *const ast.Node) EvalError!Value {
        const assign = node.assignment;
        const val = try self.eval(assign.value);
        try self.env.set(assign.target.name, val);
        return val;
    }

    pub fn eval(self: *Evaluator, node: *const ast.Node) EvalError!Value {
        switch (node.*) {
            .number_literal => return evalNumber(node),
            .identifier => return self.evalIdentifier(node),
            .binary_expr => return self.evalBinary(node),
            .assignment => return self.evalAssignment(node),
        }
    }
};

const testing = std.testing;

test "Evaluator evaluates integer arithmetic" {
    var env = Environment.init(testing.allocator);
    defer env.deinit();

    var evaluator = Evaluator.init(testing.allocator, &env);

    var left = ast.Node{ .number_literal = ast.NumberLiteral{ .value = "20" } };
    var right = ast.Node{ .number_literal = ast.NumberLiteral{ .value = "22" } };
    const bin = ast.Node{
        .binary_expr = ast.BinaryExpr{
            .left = &left,
            .operator = .plus,
            .right = &right,
        },
    };

    const res = try evaluator.eval(&bin);
    try testing.expectEqual(Value{ .integer = 42 }, res);
}

test "Evaluator variable assignment and resolution" {
    var env = Environment.init(testing.allocator);
    defer env.deinit();

    var evaluator = Evaluator.init(testing.allocator, &env);

    var val_node = ast.Node{ .number_literal = ast.NumberLiteral{ .value = "100" } };
    const assign = ast.Node{
        .assignment = ast.Assignment{
            .target = ast.Identifier{ .name = "x" },
            .value = &val_node,
        },
    };

    const assign_res = try evaluator.eval(&assign);
    try testing.expectEqual(Value{ .integer = 100 }, assign_res);

    const lookup_node = ast.Node{ .identifier = ast.Identifier{ .name = "x" } };
    const lookup_res = try evaluator.eval(&lookup_node);
    try testing.expectEqual(Value{ .integer = 100 }, lookup_res);
}

test "Evaluator equality comparison" {
    var env = Environment.init(testing.allocator);
    defer env.deinit();

    var evaluator = Evaluator.init(testing.allocator, &env);

    var left = ast.Node{ .number_literal = ast.NumberLiteral{ .value = "7" } };
    var right = ast.Node{ .number_literal = ast.NumberLiteral{ .value = "7" } };
    const eq_node = ast.Node{
        .binary_expr = ast.BinaryExpr{
            .left = &left,
            .operator = .equal_equal,
            .right = &right,
        },
    };

    const res = try evaluator.eval(&eq_node);
    try testing.expectEqual(Value{ .boolean = true }, res);
}
