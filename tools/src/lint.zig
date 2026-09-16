const std = @import("std");

const RULES = struct {
    const max_file_lines = 1000;
    const max_func_lines = 40;
    const max_nesting = 3;
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
            std.mem.eql(u8, basename, "helpers.zig")) {
            self.reportError(path, 1, "Forbidden filename. Use domain-driven names.");
        }
    }

    fn analyzeFile(self: *Linter, path: []const u8) !void {
        self.checkForbiddenNames(path);

        const file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), self.io, path, .{});
        defer file.close(self.io);
        
        const len = try file.length(self.io);
        var source = try self.allocator.alloc(u8, len + 1);
        defer self.allocator.free(source);
        
        _ = try file.readPositionalAll(self.io, source[0..len], 0);
        source[len] = 0;
        const source_z = source[0..len :0];

        var ast = try std.zig.Ast.parse(self.allocator, source_z, .zig);
        defer ast.deinit(self.allocator);

        if (ast.errors.len > 0) {
            self.reportError(path, 1, "File contains Zig syntax errors.");
            return;
        }

        const line_count = std.mem.count(u8, source_z, "\n") + 1;
        if (line_count > RULES.max_file_lines) {
            var buf: [128]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "File exceeds {} lines ({}).", .{RULES.max_file_lines, line_count});
            self.reportError(path, 1, msg);
        }

        var current_nesting: usize = 0;
        var in_function = false;
        var func_start_line: usize = 0;

        for (ast.tokens.items(.tag), 0..) |tag, i| {
            const loc = ast.tokenLocation(0, @intCast(i));
            
            if (tag == .keyword_catch) {
                if (i + 1 < ast.tokens.len and ast.tokens.items(.tag)[i + 1] == .keyword_unreachable) {
                    self.reportError(path, loc.line + 1, "Forbidden 'catch unreachable'. Explicitly handle errors.");
                }
            }

            if (tag == .keyword_fn) {
                in_function = true;
                func_start_line = loc.line + 1;
            }

            if (tag == .l_brace) {
                current_nesting += 1;
                if (current_nesting > RULES.max_nesting + 1) {
                    self.reportError(path, loc.line + 1, "Nesting depth exceeds maximum of 3 levels.");
                }
            } else if (tag == .r_brace) {
                if (current_nesting > 0) {
                    current_nesting -= 1;
                }
                
                if (in_function and current_nesting == 1) {
                    const func_len = (loc.line + 1) - func_start_line;
                    if (func_len > RULES.max_func_lines) {
                        var buf: [128]u8 = undefined;
                        const msg = try std.fmt.bufPrint(&buf, "Function exceeds {} lines ({}).", .{RULES.max_func_lines, func_len});
                        self.reportError(path, func_start_line, msg);
                    }
                    in_function = false;
                }
            }
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
        try linter.analyzeFile(path);
    }

    if (!has_args) {
        std.debug.print("Usage: micros-lint <file1.zig> [file2.zig...]\n", .{});
        std.process.exit(1);
    }

    if (linter.errors_found > 0) {
        std.debug.print("\nFound {} violation(s).\n", .{linter.errors_found});
        std.process.exit(1);
    } else {
        std.debug.print("All code complies with the MicrOS Ten Commandments.\n", .{});
    }
}
