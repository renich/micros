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

    fn match(self: *Parser, expected: lexer.TokenType) ParseError!void {
        if (self.current_token.token_type != expected) {
            return error.UnexpectedToken;
        }
        self.advance();
    }

    fn matchBinaryOp(tok: lexer.TokenType) ?ast.BinaryOperator {
        return switch (tok) {
            .plus => .plus,
            .minus => .minus,
            .star => .star,
            .slash => .slash,
            .percent => .percent,
            .ampersand => .bitwise_and,
            .pipe => .bitwise_or,
            .caret => .bitwise_xor,
            .less_less => .shift_left,
            .greater_greater => .shift_right,
            .equal_equal => .equal_equal,
            .bang_equal => .not_equal,
            .less_than => .less_than,
            .less_equal => .less_equal,
            .greater_than => .greater_than,
            .greater_equal => .greater_equal,
            else => null,
        };
    }

    pub fn parseStatement(self: *Parser) ParseError!*ast.Node {
        const t = self.current_token.token_type;
        if (t == .kw_fn) return self.parseFunctionDecl();
        if (t == .kw_if) return self.parseIf();
        if (t == .kw_while) return self.parseWhile();
        if (t == .kw_return) return self.parseReturn();
        if (t == .lbrace) return self.parseBlock();
        if (t == .kw_export) return self.parseExport();

        const expr = try self.parseExpression();
        if (self.current_token.token_type == .equal) {
            return self.parseAssignment(expr);
        }

        if (self.current_token.token_type == .semicolon) {
            self.advance();
        }
        return expr;
    }

    fn parseAssignment(self: *Parser, expr: *ast.Node) ParseError!*ast.Node {
        self.advance(); // consume '='
        const value = try self.parseExpression();
        if (self.current_token.token_type == .semicolon) {
            self.advance();
        }

        const node = try self.allocator.create(ast.Node);
        if (expr.* == .identifier) {
            node.* = ast.Node{
                .assignment = ast.Assignment{
                    .target = expr.identifier,
                    .value = value,
                },
            };
            self.allocator.destroy(expr);
            return node;
        }
        if (expr.* == .index_expr) {
            node.* = ast.Node{
                .index_assignment = ast.IndexAssignment{
                    .target = expr.index_expr.target,
                    .index = expr.index_expr.index,
                    .value = value,
                },
            };
            self.allocator.destroy(expr);
            return node;
        }
        return ParseError.UnexpectedToken;
    }

    fn parseReturn(self: *Parser) ParseError!*ast.Node {
        self.advance(); // consume 'return'
        var val: ?*ast.Node = null;
        if (self.current_token.token_type != .semicolon and self.current_token.token_type != .rbrace) {
            val = try self.parseExpression();
        }
        if (self.current_token.token_type == .semicolon) {
            self.advance();
        }
        const node = try self.allocator.create(ast.Node);
        node.* = ast.Node{ .return_expr = ast.ReturnExpr{ .value = val } };
        return node;
    }

    fn parseExport(self: *Parser) ParseError!*ast.Node {
        self.advance(); // consume 'export'
        if (self.current_token.token_type == .kw_fn) {
            const fn_node = try self.parseFunctionDecl();
            const node = try self.allocator.create(ast.Node);
            node.* = ast.Node{
                .export_stmt = ast.ExportStmt{
                    .name = fn_node.function_decl.name,
                    .value = fn_node,
                },
            };
            return node;
        }
        if (self.current_token.token_type == .identifier) {
            const name = self.current_token.lexeme;
            self.advance();
            var val_node: *ast.Node = undefined;
            if (self.current_token.token_type == .equal) {
                self.advance();
                val_node = try self.parseExpression();
            } else {
                val_node = try self.allocator.create(ast.Node);
                val_node.* = ast.Node{ .identifier = ast.Identifier{ .name = name } };
            }
            if (self.current_token.token_type == .semicolon) {
                self.advance();
            }
            const node = try self.allocator.create(ast.Node);
            node.* = ast.Node{
                .export_stmt = ast.ExportStmt{
                    .name = name,
                    .value = val_node,
                },
            };
            return node;
        }
        return error.UnexpectedToken;
    }

    fn parseIf(self: *Parser) ParseError!*ast.Node {
        self.advance(); // consume 'if'
        try self.match(.lparen);
        const cond = try self.parseExpression();
        try self.match(.rparen);
        const then_branch = try self.parseStatement();
        var else_branch: ?*ast.Node = null;
        if (self.current_token.token_type == .kw_else) {
            self.advance();
            else_branch = try self.parseStatement();
        }
        const node = try self.allocator.create(ast.Node);
        node.* = ast.Node{
            .if_expr = ast.IfExpr{
                .condition = cond,
                .then_branch = then_branch,
                .else_branch = else_branch,
            },
        };
        return node;
    }

    fn parseWhile(self: *Parser) ParseError!*ast.Node {
        self.advance(); // consume 'while'
        try self.match(.lparen);
        const cond = try self.parseExpression();
        try self.match(.rparen);
        const body = try self.parseStatement();
        const node = try self.allocator.create(ast.Node);
        node.* = ast.Node{
            .while_expr = ast.WhileExpr{
                .condition = cond,
                .body = body,
            },
        };
        return node;
    }

    fn parseBlock(self: *Parser) ParseError!*ast.Node {
        self.advance(); // consume '{'
        var stmts: std.ArrayList(*ast.Node) = .empty;
        errdefer {
            for (stmts.items) |stmt| self.allocator.destroy(stmt);
            stmts.deinit(self.allocator);
        }
        while (self.current_token.token_type != .rbrace and self.current_token.token_type != .eof) {
            const stmt = try self.parseStatement();
            try stmts.append(self.allocator, stmt);
        }
        try self.match(.rbrace);
        const node = try self.allocator.create(ast.Node);
        node.* = ast.Node{
            .block = ast.Block{
                .statements = try stmts.toOwnedSlice(self.allocator),
            },
        };
        return node;
    }

    fn parseFunctionDecl(self: *Parser) ParseError!*ast.Node {
        self.advance(); // consume 'fn'
        if (self.current_token.token_type != .identifier) return error.UnexpectedToken;
        const name = self.current_token.lexeme;
        self.advance();
        try self.match(.lparen);
        var params: std.ArrayList([]const u8) = .empty;
        while (self.current_token.token_type == .identifier) {
            try params.append(self.allocator, self.current_token.lexeme);
            self.advance();
            if (self.current_token.token_type == .comma) self.advance();
        }
        try self.match(.rparen);
        const body = try self.parseBlock();
        const node = try self.allocator.create(ast.Node);
        node.* = ast.Node{
            .function_decl = ast.FunctionDecl{
                .name = name,
                .params = try params.toOwnedSlice(self.allocator),
                .body = body,
            },
        };
        return node;
    }

    fn getPrecedence(op: ast.BinaryOperator) u8 {
        return switch (op) {
            .bitwise_or => 11,
            .bitwise_xor => 12,
            .bitwise_and => 13,
            .equal_equal, .not_equal, .less_than, .less_equal, .greater_than, .greater_equal => 15,
            .shift_left, .shift_right => 18,
            .plus, .minus => 20,
            .star, .slash, .percent => 30,
        };
    }

    fn parseUnary(self: *Parser) ParseError!*ast.Node {
        if (self.current_token.token_type == .minus or self.current_token.token_type == .bang) {
            const op: ast.UnaryOperator = if (self.current_token.token_type == .minus) .minus else .not;
            self.advance();
            const operand = try self.parseUnary();
            const node = try self.allocator.create(ast.Node);
            node.* = ast.Node{
                .unary_expr = ast.UnaryExpr{
                    .operator = op,
                    .operand = operand,
                },
            };
            return node;
        }
        return self.parsePrimary();
    }

    fn parsePrecedence(self: *Parser, min_prec: u8) ParseError!*ast.Node {
        var left = try self.parseUnary();
        while (matchBinaryOp(self.current_token.token_type)) |op| {
            const prec = getPrecedence(op);
            if (prec < min_prec) break;
            self.advance();
            const right = try self.parsePrecedence(prec + 1);
            const node = try self.allocator.create(ast.Node);
            node.* = ast.Node{
                .binary_expr = ast.BinaryExpr{
                    .left = left,
                    .operator = op,
                    .right = right,
                },
            };
            left = node;
        }
        return left;
    }

    pub fn parseExpression(self: *Parser) ParseError!*ast.Node {
        return self.parsePrecedence(0);
    }

    fn parseCall(self: *Parser, name: []const u8) ParseError!*ast.Node {
        self.advance(); // consume '('
        var args: std.ArrayList(*ast.Node) = .empty;
        while (self.current_token.token_type != .rparen and self.current_token.token_type != .eof) {
            const arg = try self.parseExpression();
            try args.append(self.allocator, arg);
            if (self.current_token.token_type == .comma) self.advance();
        }
        try self.match(.rparen);
        const node = try self.allocator.create(ast.Node);
        node.* = ast.Node{
            .call_expr = ast.CallExpr{
                .callee = name,
                .args = try args.toOwnedSlice(self.allocator),
            },
        };
        return node;
    }

    fn parseArrayLiteral(self: *Parser) ParseError!*ast.Node {
        self.advance();
        var elements: std.ArrayList(*ast.Node) = .empty;
        if (self.current_token.token_type == .rbracket) {
            try self.match(.rbracket);
            const node = try self.allocator.create(ast.Node);
            node.* = ast.Node{ .array_literal = ast.ArrayLiteral{ .elements = try elements.toOwnedSlice(self.allocator) } };
            return node;
        }

        while (true) {
            const el = try self.parseExpression();
            try elements.append(self.allocator, el);
            if (self.current_token.token_type != .comma) break;
            self.advance();
        }
        try self.match(.rbracket);
        const node = try self.allocator.create(ast.Node);
        node.* = ast.Node{ .array_literal = ast.ArrayLiteral{ .elements = try elements.toOwnedSlice(self.allocator) } };
        return node;
    }

    fn parsePrimaryBase(self: *Parser) ParseError!*ast.Node {
        const tok = self.current_token;
        switch (tok.token_type) {
            .number => {
                self.advance();
                const node = try self.allocator.create(ast.Node);
                node.* = ast.Node{ .number_literal = ast.NumberLiteral{ .value = tok.lexeme } };
                return node;
            },
            .string => {
                self.advance();
                const node = try self.allocator.create(ast.Node);
                node.* = ast.Node{ .string_literal = ast.StringLiteral{ .value = tok.lexeme } };
                return node;
            },
            .kw_true, .kw_false => {
                self.advance();
                const node = try self.allocator.create(ast.Node);
                node.* = ast.Node{ .boolean_literal = ast.BooleanLiteral{ .value = (tok.token_type == .kw_true) } };
                return node;
            },
            .lparen => {
                self.advance();
                const node = try self.parseExpression();
                try self.match(.rparen);
                return node;
            },
            .lbracket => return self.parseArrayLiteral(),
            .kw_import => {
                self.advance();
                const has_paren = (self.current_token.token_type == .lparen);
                if (has_paren) self.advance();
                if (self.current_token.token_type != .string) return error.UnexpectedToken;
                const path = self.current_token.lexeme;
                self.advance();
                if (has_paren) try self.match(.rparen);
                const node = try self.allocator.create(ast.Node);
                node.* = ast.Node{ .import_expr = ast.ImportExpr{ .path = path } };
                return node;
            },
            .identifier => {
                const name = tok.lexeme;
                self.advance();
                if (self.current_token.token_type == .lparen) return self.parseCall(name);
                const node = try self.allocator.create(ast.Node);
                node.* = ast.Node{ .identifier = ast.Identifier{ .name = name } };
                return node;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn parseMethodCall(self: *Parser, callee: *ast.Node) ParseError!*ast.Node {
        self.advance();
        var args: std.ArrayList(*ast.Node) = .empty;
        errdefer {
            for (args.items) |arg| arg.deinit(self.allocator);
            args.deinit(self.allocator);
        }
        if (self.current_token.token_type != .rparen) {
            while (true) {
                const a = try self.parseExpression();
                try args.append(self.allocator, a);
                if (self.current_token.token_type == .comma) {
                    self.advance();
                } else break;
            }
        }
        try self.match(.rparen);
        const call_node = try self.allocator.create(ast.Node);
        call_node.* = ast.Node{
            .expr_call = ast.ExprCall{
                .callee = callee,
                .args = try args.toOwnedSlice(self.allocator),
            },
        };
        return call_node;
    }

    fn parsePostfixIndex(self: *Parser, base: *ast.Node) ParseError!*ast.Node {
        var node = base;
        while (true) {
            if (self.current_token.token_type == .lbracket) {
                self.advance();
                const idx = try self.parseExpression();
                try self.match(.rbracket);
                const index_node = try self.allocator.create(ast.Node);
                index_node.* = ast.Node{ .index_expr = .{ .target = node, .index = idx } };
                node = index_node;
            } else if (self.current_token.token_type == .dot) {
                self.advance();
                if (self.current_token.token_type != .identifier) return error.UnexpectedToken;
                const prop = self.current_token.lexeme;
                self.advance();
                const prop_node = try self.allocator.create(ast.Node);
                prop_node.* = ast.Node{ .property_access = .{ .target = node, .property = prop } };
                node = prop_node;
            } else if (self.current_token.token_type == .lparen and node.* == .property_access) {
                node = try self.parseMethodCall(node);
            } else break;
        }
        return node;
    }

    fn parsePrimary(self: *Parser) ParseError!*ast.Node {
        const base = try self.parsePrimaryBase();
        return self.parsePostfixIndex(base);
    }
};

const testing = std.testing;

test "Parser function declaration and calls" {
    var p = Parser.init(testing.allocator, "fn add(a, b) { return a + b; }");
    const node = try p.parseStatement();
    defer node.deinit(testing.allocator);
    try testing.expectEqualStrings("add", node.function_decl.name);
    try testing.expectEqual(@as(usize, 2), node.function_decl.params.len);
}

test "Parser if and while control structures" {
    var p = Parser.init(testing.allocator, "if (x <= 1) { return 42; }");
    const node = try p.parseStatement();
    defer node.deinit(testing.allocator);
    try testing.expectEqual(ast.BinaryOperator.less_equal, node.if_expr.condition.binary_expr.operator);
}

test "Parser unary and mathematical operators" {
    var p = Parser.init(testing.allocator, "-(x % 5) + !flag");
    const node = try p.parseStatement();
    defer node.deinit(testing.allocator);
    try testing.expectEqual(ast.BinaryOperator.plus, node.binary_expr.operator);
    try testing.expectEqual(ast.UnaryOperator.minus, node.binary_expr.left.unary_expr.operator);
    try testing.expectEqual(ast.UnaryOperator.not, node.binary_expr.right.unary_expr.operator);
}

test "Parser bitwise and shift operators" {
    var p = Parser.init(testing.allocator, "a << 2 | b & 3 ^ c >> 1");
    const node = try p.parseStatement();
    defer node.deinit(testing.allocator);
    try testing.expectEqual(ast.BinaryOperator.bitwise_or, node.binary_expr.operator);
}
