const std = @import("std");

const RULES = struct {
    const max_file_lines: usize = 1000;
    const max_func_lines: usize = 40;
    const max_dispatch_lines: usize = 150;
    const max_nesting: usize = 3;
    const waiver_marker = "lint-waiver:";
};

/// Waivable rule identifiers. The tag names are exactly the identifiers that
/// `// lint-waiver:` comments must use.
const Rule = enum {
    @"forbidden-name",
    @"file-length",
    @"function-length",
    @"dispatch-length",
    nesting,
    @"catch-unreachable",
};

const Waiver = struct {
    rule: Rule,
    max: usize,
    used: usize = 0,
    line: usize,
    path: []const u8,
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
    waived_findings: usize = 0,
    waivers: std.ArrayList(Waiver) = .empty,

    fn reportError(self: *Linter, path: []const u8, line: usize, message: []const u8) void {
        std.debug.print("{s}:{}: error: {s}\n", .{ path, line, message });
        self.errors_found += 1;
    }

    /// Suppress a finding only when a declared waiver for the same file still has
    /// capacity for it. Waived findings are counted and printed so the debt stays
    /// visible, and any finding beyond the declared `max` is reported as a violation.
    fn reportWaivable(self: *Linter, path: []const u8, line: usize, rule: Rule, message: []const u8) void {
        for (self.waivers.items) |*waiver| {
            if (waiver.rule != rule or !std.mem.eql(u8, waiver.path, path)) continue;
            if (waiver.used >= waiver.max) continue;
            waiver.used += 1;
            self.waived_findings += 1;
            return;
        }
        self.reportError(path, line, message);
    }

    /// Waivers are cumulative across the run for reporting, so re-analyzing a path
    /// must not grant it a second budget of suppressions.
    fn dropWaiversFor(self: *Linter, path: []const u8) void {
        var i: usize = 0;
        while (i < self.waivers.items.len) {
            if (std.mem.eql(u8, self.waivers.items[i].path, path)) {
                _ = self.waivers.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn checkForbiddenNames(self: *Linter, path: []const u8) void {
        const basename = std.fs.path.basename(path);
        if (std.mem.eql(u8, basename, "utils.zig") or
            std.mem.eql(u8, basename, "common.zig") or
            std.mem.eql(u8, basename, "helpers.zig"))
        {
            self.reportWaivable(path, 1, .@"forbidden-name", "Forbidden filename. Use domain-driven names.");
        }
    }

    fn checkLineCount(self: *Linter, path: []const u8, source: [:0]const u8) !void {
        const line_count = std.mem.count(u8, source, "\n") + 1;
        if (line_count <= RULES.max_file_lines) return;

        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "File exceeds {} lines ({}).", .{ RULES.max_file_lines, line_count });
        self.reportWaivable(path, 1, .@"file-length", msg);
    }

    fn checkCatchUnreachable(self: *Linter, path: []const u8, ast: *const std.zig.Ast, i: usize, line: usize) void {
        if (i + 1 >= ast.tokens.len) return;
        if (ast.tokens.items(.tag)[i + 1] != .keyword_unreachable) return;
        self.reportWaivable(path, line, .@"catch-unreachable", "Forbidden 'catch unreachable'. Explicitly handle errors.");
    }

    /// A waiver is a standalone comment line of the form
    /// `// lint-waiver: <rule>[,<rule>...] [max=N] <reason>`.
    /// The reason is mandatory, and `max` bounds how many findings of each named
    /// rule the waiver may suppress so suppressed debt cannot grow silently.
    fn parseWaivers(self: *Linter, path: []const u8, source: []const u8) !void {
        var lines = std.mem.splitScalar(u8, source, '\n');
        var line_no: usize = 0;
        while (lines.next()) |raw_line| {
            line_no += 1;
            const line = std.mem.trimStart(u8, raw_line, " \t");
            if (!std.mem.startsWith(u8, line, "//")) continue;
            const comment = std.mem.trimStart(u8, line[2..], " \t");
            if (!std.mem.startsWith(u8, comment, RULES.waiver_marker)) continue;
            const body = std.mem.trim(u8, comment[RULES.waiver_marker.len..], " \t");
            try self.parseWaiverBody(path, line_no, body);
        }
    }

    fn parseWaiverBody(self: *Linter, path: []const u8, line_no: usize, body: []const u8) !void {
        const rules_end = std.mem.indexOfAny(u8, body, " \t") orelse body.len;
        const rule_list = body[0..rules_end];
        if (rule_list.len == 0) {
            self.reportError(path, line_no, "lint-waiver requires a rule list.");
            return;
        }

        var rest = std.mem.trimStart(u8, body[rules_end..], " \t");
        var max: usize = 1;
        if (std.mem.startsWith(u8, rest, "max=")) {
            const val_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            max = std.fmt.parseInt(usize, rest[4..val_end], 10) catch {
                self.reportError(path, line_no, "lint-waiver max= must be a positive integer.");
                return;
            };
            if (max == 0) {
                self.reportError(path, line_no, "lint-waiver max= must be a positive integer.");
                return;
            }
            rest = std.mem.trimStart(u8, rest[val_end..], " \t");
        }

        if (rest.len == 0) {
            self.reportError(path, line_no, "lint-waiver requires a reason after the rule list.");
            return;
        }
        try self.appendWaivers(path, line_no, rule_list, max);
    }

    fn appendWaivers(self: *Linter, path: []const u8, line_no: usize, rule_list: []const u8, max: usize) !void {
        var rules = std.mem.splitScalar(u8, rule_list, ',');
        while (rules.next()) |raw_name| {
            const name = std.mem.trim(u8, raw_name, " \t");
            const rule = std.meta.stringToEnum(Rule, name) orelse {
                self.reportError(path, line_no, "lint-waiver names an unknown rule.");
                continue;
            };
            try self.waivers.append(self.allocator, .{
                .rule = rule,
                .max = max,
                .line = line_no,
                .path = try self.allocator.dupe(u8, path),
            });
        }
    }

    fn printWaivers(self: *Linter) void {
        if (self.waivers.items.len == 0) return;
        std.debug.print("\nWaivers in effect:\n", .{});
        for (self.waivers.items) |waiver| {
            const note = if (waiver.used == 0) " (unused)" else "";
            std.debug.print("  {s}:{} {s} {}/{}{s}\n", .{ waiver.path, waiver.line, @tagName(waiver.rule), waiver.used, waiver.max, note });
        }
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

        const rule: Rule = if (state.has_switch) .@"dispatch-length" else .@"function-length";
        const limit: usize = if (state.has_switch) RULES.max_dispatch_lines else RULES.max_func_lines;
        const func_len = line - state.func_start_line;
        if (func_len > limit) {
            var buf: [128]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Function exceeds {} lines ({}).", .{ limit, func_len });
            self.reportWaivable(path, state.func_start_line, rule, msg);
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
        if (state.in_function and state.current_nesting >= state.func_nesting_level) {
            const rel_depth = state.current_nesting - state.func_nesting_level;
            if (rel_depth > RULES.max_nesting + 1) {
                self.reportWaivable(path, line, .nesting, "Nesting depth exceeds maximum of 3 levels.");
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
        const source = try std.Io.Dir.cwd().readFileAllocOptions(self.io, path, self.allocator, .limited(1024 * 1024 * 10), .of(u8), 0);
        defer self.allocator.free(source);

        self.dropWaiversFor(path);
        try self.parseWaivers(path, source);
        self.checkForbiddenNames(path);

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

    linter.printWaivers();

    if (linter.errors_found > 0) {
        std.debug.print("\nFound {} violation(s); {} finding(s) waived.\n", .{ linter.errors_found, linter.waived_findings });
        std.process.exit(1);
    } else {
        std.debug.print("All code complies with the MicrOS Sovereign Commandments ({} finding(s) waived).\n", .{linter.waived_findings});
    }
}

test "lint waiver parsing accepts rules, max, and reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var linter = Linter{ .allocator = arena.allocator(), .io = undefined };

    const source =
        "// lint-waiver: nesting max=7 linear TLS record state machine\n" ++
        "// lint-waiver: file-length,function-length cohesion supersedes line count\n";
    try linter.parseWaivers("demo.zig", source);

    try std.testing.expectEqual(@as(usize, 3), linter.waivers.items.len);
    try std.testing.expectEqual(Rule.nesting, linter.waivers.items[0].rule);
    try std.testing.expectEqual(@as(usize, 7), linter.waivers.items[0].max);
    try std.testing.expectEqual(Rule.@"file-length", linter.waivers.items[1].rule);
    try std.testing.expectEqual(@as(usize, 1), linter.waivers.items[1].max);
    try std.testing.expectEqual(Rule.@"function-length", linter.waivers.items[2].rule);
    try std.testing.expectEqual(@as(usize, 0), linter.errors_found);
}

test "lint waiver rejects missing reasons and unknown rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var linter = Linter{ .allocator = arena.allocator(), .io = undefined };

    const source =
        "// lint-waiver: nesting max=4\n" ++
        "// lint-waiver: filename-length some reason\n" ++
        "// lint-waiver: nesting max=zero some reason\n";
    try linter.parseWaivers("demo.zig", source);

    try std.testing.expectEqual(@as(usize, 0), linter.waivers.items.len);
    try std.testing.expectEqual(@as(usize, 3), linter.errors_found);
}

test "lint waiver suppresses only up to its declared max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var linter = Linter{ .allocator = arena.allocator(), .io = undefined };

    try linter.parseWaivers("demo.zig", "// lint-waiver: nesting max=1 linear state machine\n");
    linter.reportWaivable("demo.zig", 10, .nesting, "Nesting depth exceeds maximum of 3 levels.");
    linter.reportWaivable("demo.zig", 20, .nesting, "Nesting depth exceeds maximum of 3 levels.");
    linter.reportWaivable("demo.zig", 30, .@"catch-unreachable", "Forbidden 'catch unreachable'. Explicitly handle errors.");

    try std.testing.expectEqual(@as(usize, 1), linter.waived_findings);
    try std.testing.expectEqual(@as(usize, 2), linter.errors_found);
    try std.testing.expectEqual(@as(usize, 1), linter.waivers.items[0].used);
}

test "lint waiver applies to its own file only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var linter = Linter{ .allocator = arena.allocator(), .io = undefined };

    try linter.parseWaivers("waived.zig", "// lint-waiver: nesting max=1 linear state machine\n");
    linter.reportWaivable("waived.zig", 10, .nesting, "Nesting depth exceeds maximum of 3 levels.");
    linter.reportWaivable("other.zig", 10, .nesting, "Nesting depth exceeds maximum of 3 levels.");

    try std.testing.expectEqual(@as(usize, 1), linter.waived_findings);
    try std.testing.expectEqual(@as(usize, 1), linter.errors_found);
}

test "lint waiver budget is not doubled when a path is analyzed twice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var linter = Linter{ .allocator = arena.allocator(), .io = undefined };

    const source = "// lint-waiver: nesting max=1 linear state machine\n";
    try linter.parseWaivers("demo.zig", source);
    linter.dropWaiversFor("demo.zig");
    try linter.parseWaivers("demo.zig", source);

    try std.testing.expectEqual(@as(usize, 1), linter.waivers.items.len);
    linter.reportWaivable("demo.zig", 10, .nesting, "Nesting depth exceeds maximum of 3 levels.");
    linter.reportWaivable("demo.zig", 20, .nesting, "Nesting depth exceeds maximum of 3 levels.");
    try std.testing.expectEqual(@as(usize, 1), linter.waived_findings);
    try std.testing.expectEqual(@as(usize, 1), linter.errors_found);
}
