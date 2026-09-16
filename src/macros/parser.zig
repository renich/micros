const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

pub const ParseError = error{
    UnexpectedToken,
    OutOfMemory,
};

pub const Parser = struct {
    lex: lexer.Lexer,
    current_token: lexer.Token,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        var p = Parser{
            .lex = lexer.Lexer.init(source),
            .current_token = undefined,
            .allocator = allocator,
        };
        p.advance();
        return p;
    }

    fn advance(self: *Parser) void {
        self.current_token = self.lex.nextToken();
    }

    pub fn parseExpression(self: *Parser) ParseError!*ast.Node {
        const left = try self.parsePrimary();

        if (self.current_token.token_type == .plus or self.current_token.token_type == .minus) {
            return self.parseBinaryRight(left);
        }

        return left;
    }

    fn parseBinaryRight(self: *Parser, left: *ast.Node) ParseError!*ast.Node {
        const op: ast.BinaryOperator = if (self.current_token.token_type == .plus) .plus else .minus;
        self.advance();
        const right = try self.parsePrimary();

        const node = try self.allocator.create(ast.Node);
        node.* = ast.Node{ .binary_expr = ast.BinaryExpr{
            .left = left,
            .operator = op,
            .right = right,
        } };
        return node;
    }

    fn createNumberNode(self: *Parser, lexeme: []const u8) ParseError!*ast.Node {
        const node = try self.allocator.create(ast.Node);
        node.* = ast.Node{ .number_literal = ast.NumberLiteral{ .value = lexeme } };
        return node;
    }

    fn createIdentifierNode(self: *Parser, lexeme: []const u8) ParseError!*ast.Node {
        const node = try self.allocator.create(ast.Node);
        node.* = ast.Node{ .identifier = ast.Identifier{ .name = lexeme } };
        return node;
    }

    fn parsePrimary(self: *Parser) ParseError!*ast.Node {
        const tok = self.current_token;

        if (tok.token_type == .number) {
            const node = try self.createNumberNode(tok.lexeme);
            self.advance();
            return node;
        }

        if (tok.token_type == .identifier) {
            const node = try self.createIdentifierNode(tok.lexeme);
            self.advance();
            return node;
        }

        return error.UnexpectedToken;
    }
};

test "Parser binary expression" {
    const testing = std.testing;
    var p = Parser.init(testing.allocator, "foo + 42");

    const node = try p.parseExpression();
    defer {
        testing.allocator.destroy(node.binary_expr.left);
        testing.allocator.destroy(node.binary_expr.right);
        testing.allocator.destroy(node);
    }

    try testing.expectEqual(ast.BinaryOperator.plus, node.binary_expr.operator);
    try testing.expectEqualStrings("foo", node.binary_expr.left.identifier.name);
    try testing.expectEqualStrings("42", node.binary_expr.right.number_literal.value);
}
