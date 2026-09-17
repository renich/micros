const std = @import("std");
const sys = @import("../sys.zig");
const macros = @import("../macros.zig");

pub const Shell = struct {
    allocator: std.mem.Allocator,
    vm: macros.vm.VM,
    stage0_chunk: *macros.chunk.Chunk,
    in_fd: i32,
    out_fd: i32,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, in_fd: i32, out_fd: i32) !Shell {
        const chunk_ptr = try allocator.create(macros.chunk.Chunk);
        chunk_ptr.* = macros.chunk.Chunk.init();
        return Shell{
            .allocator = allocator,
            .stage0_chunk = chunk_ptr,
            .vm = try macros.vm.VM.init(allocator, chunk_ptr),
            .in_fd = in_fd,
            .out_fd = out_fd,
            .running = true,
        };
    }

    pub fn deinit(self: *Shell) void {
        self.stage0_chunk.deinit(self.allocator);
        self.allocator.destroy(self.stage0_chunk);
        self.vm.deinit();
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
            \\  exit/quit     - Terminate current shell session
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
        var it = self.vm.globals.iterator();
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

    fn printVersion(self: *Shell) void {
        const v_text =
            \\MicrOS (µOS) Substrate v0.1.0 (Phase 0 Userspace Sandbox)
            \\Macros Language Runtime v0.1.0 | MicroShell (msh)
            \\Architecture: x86_64 freestanding (Zero-Libc)
            \\
        ;
        self.writeOut(v_text);
    }

    fn handleBuiltin(self: *Shell, cmd: []const u8, args: []const u8) bool {
        if (std.mem.eql(u8, cmd, "help")) {
            self.printHelp();
            return true;
        }
        if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "about")) {
            self.printVersion();
            return true;
        }
        if (std.mem.eql(u8, cmd, "clear")) {
            self.writeOut("\x1b[2J\x1b[H");
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

    fn writeEvalError(self: *Shell, err: anyerror) void {
        var buf: [64]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "\x1b[31mmsh: eval error: {}\x1b[0m\n", .{err})) |msg| {
            self.writeOut(msg);
        } else |_| {}
        if (self.vm.last_missing_symbol) |sym| {
            self.writeOut("\x1b[31m  missing symbol: \x1b[0m");
            self.writeOut(sym);
            self.writeOut("\n");
        }
    }

    fn writeEvalResult(self: *Shell, val: macros.eval.Value) void {
        if (val == .nil) {
            self.writeOut("\x1b[90m=> nil\x1b[0m\n");
            return;
        }

        var color_prefix: []const u8 = "\x1b[37m=> ";
        switch (val) {
            .integer => color_prefix = "\x1b[36m=> ",
            .boolean => color_prefix = "\x1b[33m=> ",
            .string => color_prefix = "\x1b[32m=> ",
            .closure => color_prefix = "\x1b[35m=> ",
            .function => color_prefix = "\x1b[35m=> ",
            .array => color_prefix = "\x1b[34m=> ",
            else => {},
        }

        self.writeOut(color_prefix);
        val.printToFd(self.out_fd);
        self.writeOut("\x1b[0m\n");
    }

    fn evalStage0(self: *Shell, code: []const u8) void {
        var parser = macros.parser.Parser.init(self.allocator, code);
        const start_ip = self.stage0_chunk.code.items.len;
        var compiler = macros.compiler.Compiler.init(self.allocator, self.stage0_chunk);

        while (parser.current_token.token_type != .eof) {
            const stmt = parser.parseStatement() catch {
                self.writeOut("msh: stage0 parse error\n");
                return;
            };

            compiler.compile(stmt) catch {
                self.writeOut("msh: stage0 compile error\n");
                return;
            };
            stmt.deinit(self.allocator);
        }

        self.vm.chunk = self.stage0_chunk;
        self.vm.ip = start_ip;
        self.vm.sp = 0;
        self.vm.run(self.vm.frame_count) catch |err| {
            self.writeEvalError(err);
        };

        if (self.vm.sp > 0) {
            const val = self.vm.pop() catch return;
            self.registerTopValue(val);
        }
    }

    fn registerTopValue(self: *Shell, val: macros.eval.Value) void {
        if (val == .nil) return;
        if (val == .function) {
            const name_dupe = self.allocator.dupe(u8, val.function.name) catch return;
            self.vm.globals.put(name_dupe, val) catch return;
        } else if (val == .closure) {
            const name_dupe = self.allocator.dupe(u8, val.closure.function.name) catch return;
            self.vm.globals.put(name_dupe, val) catch return;
        }
        self.writeEvalResult(val);
    }

    pub fn loadStage1(self: *Shell) void {
        self.writeOut("Bootstrapping Macros Stage 1 Compiler...\n");
        const files = [_][:0]const u8{
            "lib/macros/lexer.mx",
            "lib/macros/parser.mx",
            "lib/macros/compiler.mx",
            "lib/macros/eval_shim.mx",
            "lib/macros/compiler_main.mx",
        };
        for (files) |path| {
            const fd = sys.io.open(path, sys.io.OpenFlags.rdonly, 0) catch {
                self.writeOut("msh: unable to open bootstrap file\n");
                return;
            };
            defer sys.io.close(fd) catch {};

            const buf = self.allocator.alloc(u8, 64 * 1024) catch return;
            defer self.allocator.free(buf);
            const bytes = sys.io.read(fd, buf) catch {
                self.writeOut("msh: unable to read bootstrap file\n");
                return;
            };
            if (bytes == 0) continue;
            self.evalStage0(buf[0..bytes]);
        }
        self.writeOut("Stage 1 Pipeline Ready.\n");
    }

    fn evalMacrosStream(self: *Shell, code: []const u8) void {
        const eval_val = self.vm.globals.get("shell_eval");
        if (eval_val == null) {
            self.writeOut("msh: Stage 1 compiler not loaded. Run 'bootstrap' first.\n");
            return;
        }

        const code_dupe = self.allocator.dupe(u8, code) catch return;
        const key_dupe = self.allocator.dupe(u8, "__stream_input") catch return;
        self.vm.globals.put(key_dupe, .{ .string = code_dupe }) catch return;
        self.evalStage0("shell_eval(__stream_input);");
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

        self.evalMacrosStream(trimmed);
    }

    pub fn executeStream(self: *Shell, stream: []const u8) void {
        var lines_it = std.mem.splitScalar(u8, stream, '\n');
        while (lines_it.next()) |line| {
            if (!self.running) break;
            self.executeLine(line);
        }
    }

    pub fn executeFile(self: *Shell, path: [:0]const u8) void {
        var buf: [256]u8 = undefined;
        const call = std.fmt.bufPrint(&buf, "compiler_main(\"{s}\");", .{path}) catch return;
        self.evalStage0(call);
    }

    pub fn run(self: *Shell) void {
        var line_buf: [512]u8 = undefined;
        while (self.running) {
            self.writeOut("\x1b[1;36mµOS\x1b[0m \x1b[34mmsh\x1b[0m \x1b[32m❯\x1b[0m ");
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

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var sh = try Shell.init(arena.allocator(), read_fd, write_fd);
    defer sh.deinit();

    sh.executeLine("echo MicroShell Test");
    try testing.expect(sh.running);

    sh.evalStage0("val = 10 + 32");
    const val = sh.vm.globals.get("val");
    try testing.expect(val != null);
    try testing.expectEqual(@as(i64, 42), val.?.integer);

    sh.executeLine("exit");
    try testing.expect(!sh.running);
}

test "MicroShell version and clear builtins" {
    const fds = try sys.io.pipe();
    const read_fd = fds[0];
    const write_fd = fds[1];
    defer {
        sys.io.close(read_fd) catch {};
        sys.io.close(write_fd) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var sh = try Shell.init(arena.allocator(), read_fd, write_fd);
    defer sh.deinit();

    sh.executeLine("version");
    try testing.expect(sh.running);

    sh.executeLine("clear");
    try testing.expect(sh.running);
}

test "Stage 1 compiler bootstrap execution" {
    const read_fd = try sys.io.open("/dev/null", sys.io.OpenFlags.rdonly, 0);
    const write_fd = try sys.io.open("/dev/null", sys.io.OpenFlags.wronly, 0);
    defer {
        sys.io.close(read_fd) catch {};
        sys.io.close(write_fd) catch {};
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var sh = try Shell.init(arena.allocator(), read_fd, write_fd);
    defer sh.deinit();

    sh.loadStage1();
    try testing.expect(sh.vm.globals.get("shell_eval") != null);

    sh.evalStage0("toks = lex(\"1 + 2;\");");
    const toks = sh.vm.globals.get("toks");
    try testing.expect(toks != null);
    try testing.expect(toks.? == .array);

    sh.evalStage0("ast_tree = parse(toks);");
    const ast_tree = sh.vm.globals.get("ast_tree");
    try testing.expect(ast_tree != null);
    try testing.expect(ast_tree.? == .array);

    sh.evalStage0("bc_state = compile_program(ast_tree);");
    const bc_state = sh.vm.globals.get("bc_state");
    try testing.expect(bc_state != null);
    try testing.expect(bc_state.? == .array);

    sh.evalStage0("exec_chunk(bc_state[0], bc_state[1]);");

    sh.evalMacrosStream("1 + 2;");

    sh.evalStage0("fn_toks = lex(\"fn add(a, b) { return a + b; } x = add(15, 27);\");");
    sh.evalStage0("fn_ast = parse(fn_toks);");
    const fn_ast = sh.vm.globals.get("fn_ast");
    try testing.expect(fn_ast != null);
    try testing.expectEqual(@as(usize, 2), fn_ast.?.array[1].array.len);

    sh.evalStage0("fn_bc = compile_program(fn_ast);");
    const fn_bc = sh.vm.globals.get("fn_bc");
    try testing.expect(fn_bc != null);
    sh.evalStage0("exec_chunk(fn_bc[0], fn_bc[1]);");
    const x_val = sh.vm.globals.get("x");
    try testing.expect(x_val != null);
    try testing.expectEqual(@as(i64, 42), x_val.?.integer);
}
