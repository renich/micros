const std = @import("std");

pub const TokenType = enum {
    identifier,
    number,
    plus,
    minus,
    equal,
    equal_equal,
    eof,
    invalid,
};

pub const Token = struct {
    token_type: TokenType,
    lexeme: []const u8,
};

pub const Lexer = struct {
    source: []const u8,
    position: usize,

    pub fn init(source: []const u8) Lexer {
        return Lexer{
            .source = source,
            .position = 0,
        };
    }

    fn advance(self: *Lexer) void {
        self.position += 1;
    }

    fn peek(self: *Lexer) u8 {
        if (self.position >= self.source.len) return 0;
        return self.source[self.position];
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn parseIdentifier(self: *Lexer) Token {
        const start = self.position;
        while (self.position < self.source.len) {
            const p = self.peek();
            if (isAlpha(p) or isDigit(p)) {
                self.advance();
            } else {
                break;
            }
        }
        return Token{ .token_type = .identifier, .lexeme = self.source[start..self.position] };
    }

    fn parseNumber(self: *Lexer) Token {
        const start = self.position;
        while (self.position < self.source.len) {
            if (isDigit(self.peek())) {
                self.advance();
            } else {
                break;
            }
        }
        return Token{ .token_type = .number, .lexeme = self.source[start..self.position] };
    }

    fn advanceAndReturn(self: *Lexer, t: TokenType, lex: []const u8) Token {
        self.advance();
        return Token{ .token_type = t, .lexeme = lex };
    }

    fn processEqual(self: *Lexer) Token {
        self.advance();
        if (self.peek() == '=') {
            return self.advanceAndReturn(.equal_equal, "==");
        }
        return Token{ .token_type = .equal, .lexeme = "=" };
    }

    fn processOther(self: *Lexer, c: u8) Token {
        if (isAlpha(c)) {
            return self.parseIdentifier();
        } else if (isDigit(c)) {
            return self.parseNumber();
        } else {
            const invalid_lexeme = self.source[self.position .. self.position + 1];
            return self.advanceAndReturn(.invalid, invalid_lexeme);
        }
    }

    fn processChar(self: *Lexer, c: u8) ?Token {
        switch (c) {
            ' ', '\t', '\r', '\n' => {
                self.advance();
                return null;
            },
            '+' => return self.advanceAndReturn(.plus, "+"),
            '-' => return self.advanceAndReturn(.minus, "-"),
            '=' => return self.processEqual(),
            else => return self.processOther(c),
        }
    }

    pub fn nextToken(self: *Lexer) Token {
        while (self.position < self.source.len) {
            const c = self.peek();
            if (self.processChar(c)) |tok| {
                return tok;
            }
        }
        return Token{ .token_type = .eof, .lexeme = "" };
    }
};

const testing = std.testing;

test "Lexer basic operators" {
    var lexer = Lexer.init("+-= ==");

    const t1 = lexer.nextToken();
    try testing.expectEqual(TokenType.plus, t1.token_type);

    const t2 = lexer.nextToken();
    try testing.expectEqual(TokenType.minus, t2.token_type);

    const t3 = lexer.nextToken();
    try testing.expectEqual(TokenType.equal, t3.token_type);

    const t4 = lexer.nextToken();
    try testing.expectEqual(TokenType.equal_equal, t4.token_type);

    const t5 = lexer.nextToken();
    try testing.expectEqual(TokenType.eof, t5.token_type);
}

test "Lexer identifiers and numbers" {
    var lexer = Lexer.init("var12 123 foo");

    const t1 = lexer.nextToken();
    try testing.expectEqual(TokenType.identifier, t1.token_type);
    try testing.expectEqualStrings("var12", t1.lexeme);

    const t2 = lexer.nextToken();
    try testing.expectEqual(TokenType.number, t2.token_type);
    try testing.expectEqualStrings("123", t2.lexeme);

    const t3 = lexer.nextToken();
    try testing.expectEqual(TokenType.identifier, t3.token_type);
    try testing.expectEqualStrings("foo", t3.lexeme);

    const t4 = lexer.nextToken();
    try testing.expectEqual(TokenType.eof, t4.token_type);
}

test "Lexer invalid character" {
    var lexer = Lexer.init("!");
    const t1 = lexer.nextToken();
    try testing.expectEqual(TokenType.invalid, t1.token_type);
}
