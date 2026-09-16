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

    fn matchBinaryOp(tok: lexer.TokenType) ?ast.BinaryOperator {
        switch (tok) {
            .plus => return .plus,
            .minus => return .minus,
            .equal_equal => return .equal_equal,
            else => return null,
        }
    }

    fn parseAssignment(self: *Parser, target_name: []const u8) ParseError!*ast.Node {
        self.advance(); // consume '='
        const val = try self.parseExpression();

        const node = try self.allocator.create(ast.Node);
        node.* = ast.Node{
            .assignment = ast.Assignment{
                .target = ast.Identifier{ .name = target_name },
                .value = val,
            },
        };
        return node;
    }

    pub fn parseStatement(self: *Parser) ParseError!*ast.Node {
        if (self.current_token.token_type == .identifier) {
            const name = self.current_token.lexeme;
            var lookahead = self.lex;
            const next_tok = lookahead.nextToken();
            if (next_tok.token_type == .equal) {
                self.advance(); // consume identifier
                return self.parseAssignment(name);
            }
        }
        return self.parseExpression();
    }

    pub fn parseExpression(self: *Parser) ParseError!*ast.Node {
        const left = try self.parsePrimary();

        if (matchBinaryOp(self.current_token.token_type)) |op| {
            return self.parseBinaryRight(left, op);
        }

        return left;
    }

    fn parseBinaryRight(self: *Parser, left: *ast.Node, op: ast.BinaryOperator) ParseError!*ast.Node {
        self.advance();
        const right = try self.parsePrimary();

        const node = try self.allocator.create(ast.Node);
        node.* = ast.Node{
            .binary_expr = ast.BinaryExpr{
                .left = left,
                .operator = op,
                .right = right,
            },
        };
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

const testing = std.testing;

test "Parser binary expression" {
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

test "Parser assignment statement" {
    var p = Parser.init(testing.allocator, "alpha = 99");

    const node = try p.parseStatement();
    defer {
        testing.allocator.destroy(node.assignment.value);
        testing.allocator.destroy(node);
    }

    try testing.expectEqualStrings("alpha", node.assignment.target.name);
    try testing.expectEqualStrings("99", node.assignment.value.number_literal.value);
}

test "Parser equality expression" {
    var p = Parser.init(testing.allocator, "10 == 10");

    const node = try p.parseExpression();
    defer {
        testing.allocator.destroy(node.binary_expr.left);
        testing.allocator.destroy(node.binary_expr.right);
        testing.allocator.destroy(node);
    }

    try testing.expectEqual(ast.BinaryOperator.equal_equal, node.binary_expr.operator);
}
