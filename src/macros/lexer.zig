const std = @import("std");

pub const TokenType = enum {
    identifier,
    number,
    string,
    kw_fn,
    kw_return,
    kw_if,
    kw_else,
    kw_while,
    kw_true,
    kw_false,
    plus,
    minus,
    star,
    slash,
    percent,
    ampersand,
    pipe,
    caret,
    less_less,
    greater_greater,
    bang,
    equal,
    equal_equal,
    bang_equal,
    less_than,
    less_equal,
    greater_than,
    greater_equal,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    comma,
    semicolon,
    colon,
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

    fn matchKeyword(lex: []const u8) TokenType {
        if (std.mem.eql(u8, lex, "fn")) return .kw_fn;
        if (std.mem.eql(u8, lex, "return")) return .kw_return;
        if (std.mem.eql(u8, lex, "if")) return .kw_if;
        if (std.mem.eql(u8, lex, "else")) return .kw_else;
        if (std.mem.eql(u8, lex, "while")) return .kw_while;
        if (std.mem.eql(u8, lex, "true")) return .kw_true;
        if (std.mem.eql(u8, lex, "false")) return .kw_false;
        return .identifier;
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
        const lex = self.source[start..self.position];
        return Token{ .token_type = matchKeyword(lex), .lexeme = lex };
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

    fn skipEscapedChar(self: *Lexer) void {
        if (self.position < self.source.len) {
            self.advance();
        }
    }

    fn parseString(self: *Lexer) Token {
        self.advance(); // Skip opening quote
        const start = self.position;
        while (self.position < self.source.len) {
            const c = self.peek();
            if (c == '"') break;
            if (c == '\\') {
                self.advance();
                self.skipEscapedChar();
                continue;
            }
            self.advance();
        }
        const str = self.source[start..self.position];
        if (self.position < self.source.len) {
            self.advance(); // Skip closing quote
        }
        return Token{ .token_type = .string, .lexeme = str };
    }

    fn advanceAndReturn(self: *Lexer, t: TokenType, lex: []const u8) Token {
        self.advance();
        return Token{ .token_type = t, .lexeme = lex };
    }

    fn processSlash(self: *Lexer) ?Token {
        self.advance();
        if (self.peek() == '/') {
            while (self.position < self.source.len and self.peek() != '\n') {
                self.advance();
            }
            return null;
        }
        return Token{ .token_type = .slash, .lexeme = "/" };
    }

    fn processPunctuation(self: *Lexer, c: u8) ?Token {
        return switch (c) {
            '(' => self.advanceAndReturn(.lparen, "("),
            ')' => self.advanceAndReturn(.rparen, ")"),
            '{' => self.advanceAndReturn(.lbrace, "{"),
            '}' => self.advanceAndReturn(.rbrace, "}"),
            '[' => self.advanceAndReturn(.lbracket, "["),
            ']' => self.advanceAndReturn(.rbracket, "]"),
            ',' => self.advanceAndReturn(.comma, ","),
            ';' => self.advanceAndReturn(.semicolon, ";"),
            ':' => self.advanceAndReturn(.colon, ":"),
            '+' => self.advanceAndReturn(.plus, "+"),
            '-' => self.advanceAndReturn(.minus, "-"),
            '*' => self.advanceAndReturn(.star, "*"),
            '%' => self.advanceAndReturn(.percent, "%"),
            '&' => self.advanceAndReturn(.ampersand, "&"),
            '|' => self.advanceAndReturn(.pipe, "|"),
            '^' => self.advanceAndReturn(.caret, "^"),
            else => null,
        };
    }

    fn processComparison(self: *Lexer, c: u8) ?Token {
        if (c == '=') {
            self.advance();
            if (self.peek() == '=') return self.advanceAndReturn(.equal_equal, "==");
            return Token{ .token_type = .equal, .lexeme = "=" };
        }
        if (c == '!') {
            self.advance();
            if (self.peek() == '=') return self.advanceAndReturn(.bang_equal, "!=");
            return Token{ .token_type = .bang, .lexeme = "!" };
        }
        if (c == '<') {
            self.advance();
            if (self.peek() == '=') return self.advanceAndReturn(.less_equal, "<=");
            if (self.peek() == '<') return self.advanceAndReturn(.less_less, "<<");
            return Token{ .token_type = .less_than, .lexeme = "<" };
        }
        if (c == '>') {
            self.advance();
            if (self.peek() == '=') return self.advanceAndReturn(.greater_equal, ">=");
            if (self.peek() == '>') return self.advanceAndReturn(.greater_greater, ">>");
            return Token{ .token_type = .greater_than, .lexeme = ">" };
        }
        return null;
    }

    fn processChar(self: *Lexer, c: u8) ?Token {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            self.advance();
            return null;
        }
        if (c == '/') return self.processSlash();
        if (c == '"') return self.parseString();
        if (self.processPunctuation(c)) |tok| return tok;
        if (self.processComparison(c)) |tok| return tok;
        if (isAlpha(c)) return self.parseIdentifier();
        if (isDigit(c)) return self.parseNumber();

        const invalid_lex = self.source[self.position .. self.position + 1];
        return self.advanceAndReturn(.invalid, invalid_lex);
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

test "Lexer keywords and blocks" {
    var lexer = Lexer.init("// A comment\nfn main() { if (x == 42) return \"done\"; }");

    const expected = [_]TokenType{
        .kw_fn,  .identifier, .lparen,     .rparen,      .lbrace,
        .kw_if,  .lparen,     .identifier, .equal_equal, .number,
        .rparen, .kw_return,  .string,     .semicolon,   .rbrace,
        .eof,
    };

    for (expected) |exp| {
        const tok = lexer.nextToken();
        try testing.expectEqual(exp, tok.token_type);
    }
}

test "Lexer mathematical, bitwise, and unary operators" {
    var lexer = Lexer.init("% & | ^ << >> !");
    const expected = [_]TokenType{
        .percent,
        .ampersand,
        .pipe,
        .caret,
        .less_less,
        .greater_greater,
        .bang,
        .eof,
    };
    for (expected) |exp| {
        const tok = lexer.nextToken();
        try testing.expectEqual(exp, tok.token_type);
    }
}
