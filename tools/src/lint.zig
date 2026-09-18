const std = @import("std");

const RULES = struct {
    const max_file_lines: usize = 1000;
    const max_func_lines: usize = 40;
    const max_dispatch_lines: usize = 150;
    const max_nesting: usize = 3;
};

const TokenState = struct {
    current_nesting: usize = 0,
    struct_literal_depth: usize = 0,
    in_function: bool = false,
    func_start_line: usize = 0,
    func_nesting_level: usize = 0,
    has_switch: bool = false,
};

const Linter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    errors_found: usize = 0,

    fn reportError(self: *Linter, path: []const u8, line: usize, message: []const u8) void {
        std.debug.print("{s}:{}: error: {s}\n", .{ path, line, message });
        self.errors_found += 1;
    }

    fn checkForbiddenNames(self: *Linter, path: []const u8) void {
        const basename = std.fs.path.basename(path);
        if (std.mem.eql(u8, basename, "utils.zig") or
            std.mem.eql(u8, basename, "common.zig") or
            std.mem.eql(u8, basename, "helpers.zig"))
        {
            self.reportError(path, 1, "Forbidden filename. Use domain-driven names.");
        }
    }

    fn checkLineCount(self: *Linter, path: []const u8, source: [:0]const u8) !void {
        const line_count = std.mem.count(u8, source, "\n") + 1;
        if (line_count <= RULES.max_file_lines) return;

        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "File exceeds {} lines ({}).", .{ RULES.max_file_lines, line_count });
        self.reportError(path, 1, msg);
    }

    fn checkCatchUnreachable(self: *Linter, path: []const u8, ast: *const std.zig.Ast, i: usize, line: usize) void {
        if (i + 1 >= ast.tokens.len) return;
        if (ast.tokens.items(.tag)[i + 1] != .keyword_unreachable) return;
        self.reportError(path, line, "Forbidden 'catch unreachable'. Explicitly handle errors.");
    }

    fn isStructInit(ast: *const std.zig.Ast, i: usize) bool {
        if (i == 0) return false;
        if (i + 1 < ast.tokens.len) {
            const next_tag = ast.tokens.items(.tag)[i + 1];
            if (next_tag == .period or next_tag == .r_brace) return true;
        }
        const prev = ast.tokens.items(.tag)[i - 1];
        if (prev == .period) return true;
        if (prev == .identifier) {
            if (i >= 2) {
                const prev2 = ast.tokens.items(.tag)[i - 2];
                if (prev2 == .period or prev2 == .equal or prev2 == .equal_angle_bracket_right or prev2 == .colon or prev2 == .keyword_return) return true;
            }
        }
        return false;
    }

    fn handleRBrace(self: *Linter, path: []const u8, state: *TokenState, line: usize) !void {
        if (state.struct_literal_depth > 0) {
            state.struct_literal_depth -= 1;
            return;
        }
        if (state.current_nesting > 0) state.current_nesting -= 1;
        if (!state.in_function or state.current_nesting != state.func_nesting_level) return;

        const func_len = line - state.func_start_line;
        const limit: usize = if (state.has_switch) RULES.max_dispatch_lines else RULES.max_func_lines;
        if (func_len > limit) {
            var buf: [128]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Function exceeds {} lines ({}).", .{ limit, func_len });
            self.reportError(path, state.func_start_line, msg);
        }
        state.in_function = false;
        state.has_switch = false;
    }

    fn handleLBrace(self: *Linter, path: []const u8, ast: *const std.zig.Ast, state: *TokenState, i: usize, line: usize) void {
        if (isStructInit(ast, i)) {
            state.struct_literal_depth += 1;
            return;
        }
        state.current_nesting += 1;
        if (state.in_function) {
            const rel_depth = state.current_nesting - state.func_nesting_level;
            if (rel_depth > RULES.max_nesting + 1) {
                self.reportError(path, line, "Nesting depth exceeds maximum of 3 levels.");
            }
        }
    }

    fn analyzeToken(self: *Linter, path: []const u8, ast: *const std.zig.Ast, state: *TokenState, tag: std.zig.Token.Tag, i: usize) !void {
        const loc = ast.tokenLocation(0, @intCast(i));
        const line = loc.line + 1;

        if (tag == .keyword_catch) {
            self.checkCatchUnreachable(path, ast, i, line);
        } else if (tag == .keyword_switch) {
            if (state.in_function) state.has_switch = true;
        } else if (tag == .keyword_fn) {
            state.in_function = true;
            state.has_switch = false;
            state.func_start_line = line;
            state.func_nesting_level = state.current_nesting;
        } else if (tag == .l_brace) {
            self.handleLBrace(path, ast, state, i, line);
        } else if (tag == .r_brace) {
            try self.handleRBrace(path, state, line);
        }
    }

    fn analyzeFile(self: *Linter, path: []const u8) !void {
        self.checkForbiddenNames(path);

        const source = try std.Io.Dir.cwd().readFileAllocOptions(self.io, path, self.allocator, .limited(1024 * 1024 * 10), .of(u8), 0);
        defer self.allocator.free(source);

        var ast = try std.zig.Ast.parse(self.allocator, source, .zig);
        defer ast.deinit(self.allocator);

        if (ast.errors.len > 0) {
            self.reportError(path, 1, "File contains Zig syntax errors.");
            return;
        }

        try self.checkLineCount(path, source);

        var state = TokenState{};
        for (ast.tokens.items(.tag), 0..) |tag, i| {
            try self.analyzeToken(path, &ast, &state, tag, i);
        }
    }

    fn walkDirectory(self: *Linter, dir_path: []const u8, dir: *std.Io.Dir) !void {
        var walker = try std.Io.Dir.walk(dir.*, self.allocator);
        defer walker.deinit();

        const trimmed_dir = std.mem.trimEnd(u8, dir_path, "/");

        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const full_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ trimmed_dir, entry.path });
            try self.analyzeFile(full_path);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = init.minimal.args.iterate();
    _ = args.skip(); // skip executable name

    var linter = Linter{ .allocator = allocator, .io = init.io };
    var has_args = false;

    while (args.next()) |path| {
        has_args = true;
        if (std.Io.Dir.openDir(std.Io.Dir.cwd(), init.io, path, .{ .iterate = true })) |dir| {
            var d = dir;
            defer d.close(init.io);
            try linter.walkDirectory(path, &d);
        } else |_| {
            try linter.analyzeFile(path);
        }
    }

    if (!has_args) {
        std.debug.print("Usage: micros-lint <files/directories...>\n", .{});
        std.process.exit(1);
    }

    if (linter.errors_found > 0) {
        std.debug.print("\nFound {} violation(s).\n", .{linter.errors_found});
        std.process.exit(1);
    } else {
        std.debug.print("All code complies with the MicrOS Sovereign Commandments.\n", .{});
    }
}
