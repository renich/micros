const std = @import("std");
const sys = @import("../sys.zig");
const macros = @import("../macros.zig");

pub const Shell = struct {
    allocator: std.mem.Allocator,
    env: macros.eval.Environment,
    in_fd: i32,
    out_fd: i32,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, in_fd: i32, out_fd: i32) Shell {
        return Shell{
            .allocator = allocator,
            .env = macros.eval.Environment.init(allocator),
            .in_fd = in_fd,
            .out_fd = out_fd,
            .running = true,
        };
    }

    pub fn deinit(self: *Shell) void {
        self.env.deinit();
    }

    pub fn writeOut(self: *Shell, bytes: []const u8) void {
        _ = sys.io.write(self.out_fd, bytes) catch {};
    }

    fn printHelp(self: *Shell) void {
        const help_text =
            \\MicroShell (msh) - MicrOS Typed Command Interpreter
            \\Builtin Commands:
            \\  help          - Display this assistance message
            \\  echo <text>   - Output text directly to stdout
            \\  vars          - List active environment bindings
            \\  mem           - Display substrate memory stats
            \\  exit / quit   - Terminate current shell session
            \\
            \\Macros Expressions:
            \\  <var> = <expr> (e.g. x = 10 + 20)
            \\  <expr> + <expr> | <expr> - <expr> | <expr> == <expr>
            \\
        ;
        self.writeOut(help_text);
    }

    fn printVars(self: *Shell) void {
        self.writeOut("Active Environment Bindings:\n");
        var it = self.env.bindings.iterator();
        var buf: [128]u8 = undefined;
        while (it.next()) |entry| {
            if (std.fmt.bufPrint(&buf, "  {s} = {}\n", .{ entry.key_ptr.*, entry.value_ptr.* })) |msg| {
                self.writeOut(msg);
            } else |_| {}
        }
    }

    fn printMem(self: *Shell) void {
        const page_size: usize = 4096;
        const test_pages: usize = 1;
        const ptr = sys.mem.map(
            null,
            test_pages * page_size,
            sys.mem.Prot.read | sys.mem.Prot.write,
            sys.mem.Flags.private | sys.mem.Flags.anonymous,
            -1,
            0,
        ) catch {
            self.writeOut("Substrate memory audit failed.\n");
            return;
        };

        var buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "Substrate Memory: 4096-byte page mapped at 0x{x}\n", .{@intFromPtr(ptr)})) |msg| {
            self.writeOut(msg);
        } else |_| {}

        sys.mem.unmap(ptr, test_pages * page_size) catch {};
    }

    fn handleBuiltin(self: *Shell, cmd: []const u8, args: []const u8) bool {
        if (std.mem.eql(u8, cmd, "help")) {
            self.printHelp();
            return true;
        }
        if (std.mem.eql(u8, cmd, "exit") or std.mem.eql(u8, cmd, "quit")) {
            self.running = false;
            return true;
        }
        if (std.mem.eql(u8, cmd, "vars") or std.mem.eql(u8, cmd, "env")) {
            self.printVars();
            return true;
        }
        if (std.mem.eql(u8, cmd, "mem")) {
            self.printMem();
            return true;
        }
        if (std.mem.eql(u8, cmd, "echo")) {
            self.writeOut(args);
            self.writeOut("\n");
            return true;
        }
        return false;
    }

    fn evalMacrosLine(self: *Shell, line: []const u8) void {
        var parser = macros.parser.Parser.init(self.allocator, line);
        const node = parser.parseStatement() catch {
            self.writeOut("msh: parse error\n");
            return;
        };
        defer self.freeNode(node);

        var evaluator = macros.eval.Evaluator.init(self.allocator, &self.env);
        const val = evaluator.eval(node) catch |err| {
            var buf: [64]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "msh: eval error: {}\n", .{err})) |msg| {
                self.writeOut(msg);
            } else |_| {}
            return;
        };

        var val_buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&val_buf, "=> {}\n", .{val})) |msg| {
            self.writeOut(msg);
        } else |_| {}
    }

    fn freeNode(self: *Shell, node: *macros.ast.Node) void {
        switch (node.*) {
            .binary_expr => |bin| {
                self.freeNode(bin.left);
                self.freeNode(bin.right);
            },
            .assignment => |assign| {
                self.freeNode(assign.value);
            },
            else => {},
        }
        self.allocator.destroy(node);
    }

    pub fn executeLine(self: *Shell, raw_line: []const u8) void {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r\n");
        if (trimmed.len == 0) return;

        var split_it = std.mem.splitScalar(u8, trimmed, ' ');
        const first_word = split_it.first();
        const remainder = if (trimmed.len > first_word.len)
            std.mem.trimStart(u8, trimmed[first_word.len..], " \t")
        else
            "";

        if (self.handleBuiltin(first_word, remainder)) return;

        self.evalMacrosLine(trimmed);
    }

    pub fn executeStream(self: *Shell, stream: []const u8) void {
        var lines_it = std.mem.splitScalar(u8, stream, '\n');
        while (lines_it.next()) |line| {
            if (!self.running) break;
            self.executeLine(line);
        }
    }

    pub fn run(self: *Shell) void {
        var line_buf: [512]u8 = undefined;
        while (self.running) {
            self.writeOut("msh> ");
            const bytes_read = sys.io.read(self.in_fd, &line_buf) catch break;
            if (bytes_read == 0) break;
            self.executeStream(line_buf[0..bytes_read]);
        }
    }
};

const testing = std.testing;

test "MicroShell builtin execution" {
    const fds = try sys.io.pipe();
    const read_fd = fds[0];
    const write_fd = fds[1];
    defer {
        sys.io.close(read_fd) catch {};
        sys.io.close(write_fd) catch {};
    }

    var sh = Shell.init(testing.allocator, read_fd, write_fd);
    defer sh.deinit();

    sh.executeLine("echo MicroShell Test");
    try testing.expect(sh.running);

    sh.executeLine("val = 10 + 32");
    const val = sh.env.get("val");
    try testing.expect(val != null);
    try testing.expectEqual(@as(i64, 42), val.?.integer);

    sh.executeLine("exit");
    try testing.expect(!sh.running);
}
