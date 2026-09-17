const std = @import("std");

pub const Node = union(enum) {
    identifier: Identifier,
    number_literal: NumberLiteral,
    string_literal: StringLiteral,
    boolean_literal: BooleanLiteral,
    binary_expr: BinaryExpr,
    assignment: Assignment,
    index_assignment: IndexAssignment,
    block: Block,
    if_expr: IfExpr,
    while_expr: WhileExpr,
    return_expr: ReturnExpr,
    function_decl: FunctionDecl,
    call_expr: CallExpr,
    index_expr: IndexExpr,
    array_literal: ArrayLiteral,
    unary_expr: UnaryExpr,

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .binary_expr => |bin| {
                bin.left.deinit(allocator);
                bin.right.deinit(allocator);
            },
            .unary_expr => |un| un.operand.deinit(allocator),
            .assignment => |assign| assign.value.deinit(allocator),
            .index_assignment => |*ia| ia.deinit(allocator),
            .if_expr => |*ife| ife.deinit(allocator),
            .while_expr => |*wh| wh.deinit(allocator),
            .block => |*blk| blk.deinit(allocator),
            .function_decl => |*fnd| fnd.deinit(allocator),
            .call_expr => |*call| call.deinit(allocator),
            .index_expr => |*idx| idx.deinit(allocator),
            .array_literal => |*arr| arr.deinit(allocator),
            .return_expr => |ret| {
                if (ret.value) |v| v.deinit(allocator);
            },
            else => {},
        }
        allocator.destroy(self);
    }
};

pub const IndexExpr = struct {
    target: *Node,
    index: *Node,

    pub fn deinit(self: *IndexExpr, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        self.index.deinit(allocator);
    }
};

pub const Identifier = struct {
    name: []const u8,
};

pub const NumberLiteral = struct {
    value: []const u8,
};

pub const StringLiteral = struct {
    value: []const u8,
};

pub const ArrayLiteral = struct {
    elements: []*Node,

    pub fn deinit(self: *ArrayLiteral, allocator: std.mem.Allocator) void {
        for (self.elements) |el| el.deinit(allocator);
        allocator.free(self.elements);
    }
};

pub const BooleanLiteral = struct {
    value: bool,
};

pub const UnaryOperator = enum {
    minus,
    not,
};

pub const UnaryExpr = struct {
    operator: UnaryOperator,
    operand: *Node,
};

pub const BinaryOperator = enum {
    plus,
    minus,
    star,
    slash,
    percent,
    bitwise_and,
    bitwise_or,
    bitwise_xor,
    shift_left,
    shift_right,
    equal_equal,
    not_equal,
    less_than,
    less_equal,
    greater_than,
    greater_equal,
};

pub const BinaryExpr = struct {
    left: *Node,
    operator: BinaryOperator,
    right: *Node,
};

pub const Assignment = struct {
    target: Identifier,
    value: *Node,
};

pub const IndexAssignment = struct {
    target: *Node,
    index: *Node,
    value: *Node,

    pub fn deinit(self: *IndexAssignment, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        self.index.deinit(allocator);
        self.value.deinit(allocator);
    }
};

pub const Block = struct {
    statements: []*Node,

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        for (self.statements) |stmt| {
            stmt.deinit(allocator);
        }
        allocator.free(self.statements);
    }
};

pub const IfExpr = struct {
    condition: *Node,
    then_branch: *Node,
    else_branch: ?*Node,

    pub fn deinit(self: *IfExpr, allocator: std.mem.Allocator) void {
        self.condition.deinit(allocator);
        self.then_branch.deinit(allocator);
        if (self.else_branch) |eb| eb.deinit(allocator);
    }
};

pub const WhileExpr = struct {
    condition: *Node,
    body: *Node,

    pub fn deinit(self: *WhileExpr, allocator: std.mem.Allocator) void {
        self.condition.deinit(allocator);
        self.body.deinit(allocator);
    }
};

pub const ReturnExpr = struct {
    value: ?*Node,
};

pub const FunctionDecl = struct {
    name: []const u8,
    params: [][]const u8,
    body: *Node,

    pub fn deinit(self: *FunctionDecl, allocator: std.mem.Allocator) void {
        allocator.free(self.params);
        self.body.deinit(allocator);
    }
};

pub const CallExpr = struct {
    callee: []const u8,
    args: []*Node,

    pub fn deinit(self: *CallExpr, allocator: std.mem.Allocator) void {
        for (self.args) |arg| {
            arg.deinit(allocator);
        }
        allocator.free(self.args);
    }
};

const testing = std.testing;

test "AST nodes instantiation" {
    const ident = Identifier{ .name = "self_host" };
    try testing.expectEqualStrings("self_host", ident.name);

    const b = BooleanLiteral{ .value = true };
    try testing.expect(b.value);
}
