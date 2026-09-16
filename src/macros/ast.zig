const std = @import("std");

pub const Node = union(enum) {
    identifier: Identifier,
    number_literal: NumberLiteral,
    binary_expr: BinaryExpr,
    assignment: Assignment,
};

pub const Identifier = struct {
    name: []const u8,
};

pub const NumberLiteral = struct {
    value: []const u8,
};

pub const BinaryOperator = enum {
    plus,
    minus,
    equal_equal,
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

const testing = std.testing;

test "AST dummy" {
    const ident = Identifier{ .name = "foo" };
    try testing.expectEqualStrings("foo", ident.name);
}
