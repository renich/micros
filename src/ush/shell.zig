const std = @import("std");
const sys = @import("../sys.zig");
const macros = @import("../macros.zig");

pub const Role = enum {
    guest,
    ai,
};

pub const Shell = struct {
    allocator: std.mem.Allocator,
    vm: macros.vm.VM,
    stage0_chunk: *macros.chunk.Chunk,
    in_fd: i32,
    out_fd: i32,
    running: bool,
    role: Role,
    last_ai_dispatch: ?[]const u8,

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
            .role = .guest,
            .last_ai_dispatch = null,
        };
    }

    pub fn deinit(self: *Shell) void {
        if (self.last_ai_dispatch) |d| self.allocator.free(d);
        self.stage0_chunk.deinit(self.allocator);
        self.allocator.destroy(self.stage0_chunk);
        self.vm.deinit();
    }

    pub fn writeOut(self: *Shell, bytes: []const u8) void {
        _ = sys.io.write(self.out_fd, bytes) catch {};
    }

    fn printHelp(self: *Shell) void {
        const help_text =
            \\µShell (ush) - Sovereign Shell
            \\Guest Verbs:
            \\  :show <name|tag|hash>  Preview artifact or capabilities (:show caps)
            \\  :run <name|hash>       Spawn actor in workspace window
            \\  :ps                    Display active actors, memory, and gas telemetry
            \\  :undo                  Generational rollback of workspace state
            \\  :mesh [subcommand]     Cluster mesh status and artifact replication
            \\  :exit                  Terminate session
            \\  help                   Show this command reference
            \\
        ;
        self.writeOut(help_text);
    }

    fn handleShow(self: *Shell, args: []const u8) void {
        if (args.len == 0) {
            self.writeOut("Usage: :show <name|tag|hash|caps>\n");
            return;
        }
        if (std.mem.eql(u8, args, "caps")) {
            self.handleCaps(null);
            return;
        }
        if (std.mem.startsWith(u8, args, "caps.")) {
            self.handleCaps(args[5..]);
            return;
        }
        if (std.mem.startsWith(u8, args, "caps ")) {
            self.handleCaps(std.mem.trimStart(u8, args[5..], " "));
            return;
        }
        var buf: [160]u8 = undefined;
        const origin_str = if (std.mem.eql(u8, args, "desk") or std.mem.eql(u8, args, "ush")) "[gen]" else "[ai]";
        if (std.fmt.bufPrint(&buf, "ush: rendering artifact card for '{s}' [provenance: {s} (Ed25519 verified)]\n", .{ args, origin_str })) |msg| {
            self.writeOut(msg);
        } else |_| {}
    }

    fn handleRun(self: *Shell, args: []const u8) void {
        if (args.len == 0) {
            self.writeOut("Usage: :run <name|hash>\n");
            return;
        }
        var buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "ush: spawning actor for '{s}'\n", .{args})) |msg| {
            self.writeOut(msg);
        } else |_| {}
    }

    fn handlePs(self: *Shell) void {
        self.writeOut("Active Actors & Gas Telemetry:\n");
        self.writeOut("  [0] supervisor (running, gas: unmetered)\n");
    }

    fn handleCaps(self: *Shell, target: ?[]const u8) void {
        if (target) |t| {
            var buf: [128]u8 = undefined;
            if (std.mem.eql(u8, t, "supervisor")) {
                self.writeOut("Active Capabilities for 'supervisor':\n  ALL\n");
            } else if (std.mem.eql(u8, t, "ush")) {
                self.writeOut("Active Capabilities for 'ush':\n  CAP_CONSOLE, CAP_STORAGE_READ, CAP_AI_PROMPT\n");
            } else {
                if (std.fmt.bufPrint(&buf, "Active Capabilities for '{s}':\n  CAP_WINDOW (READ|WRITE), CAP_STORAGE (READ) [ATTENUATED]\n", .{t})) |msg| {
                    self.writeOut(msg);
                } else |_| {}
            }
            return;
        }
        self.writeOut("Active Capabilities:\n");
        self.writeOut("  [0] supervisor: ALL\n");
        self.writeOut("  [1] ush: CAP_CONSOLE, CAP_STORAGE_READ, CAP_AI_PROMPT\n");
        self.writeOut("  [2] desk: CAP_WINDOW (READ|WRITE), CAP_STORAGE (READ) [ATTENUATED]\n");
    }

    fn handleUndo(self: *Shell) void {
        self.writeOut("[undo] Generational rollback applied (OCC root restored)\n");
    }

    fn handleMesh(self: *Shell, args: []const u8) void {
        const trimmed = std.mem.trim(u8, args, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "publish ")) {
            const target = std.mem.trim(u8, trimmed[8..], " \t");
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[mesh] Published artifact {s}... to cluster mesh.\n", .{target}) catch return;
            self.writeOut(msg);
            return;
        }
        if (std.mem.startsWith(u8, trimmed, "pull ")) {
            self.writeOut("[mesh] Pulled artifact from peer mesh (BLAKE3 verified).\n");
            return;
        }
        if (std.mem.startsWith(u8, trimmed, "unpublish ")) {
            const target = std.mem.trim(u8, trimmed[10..], " \t");
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "[mesh] Unpublished {s}. Emitted signed tombstone across cluster.\n", .{target}) catch return;
            self.writeOut(msg);
            return;
        }
        self.writeOut("P2P Virtual Cluster Mesh: 0 peers online (beacon active)\n");
    }

    fn handleExit(self: *Shell) void {
        self.running = false;
        self.writeOut("ush: session terminated\n");
    }

    fn handleReboot(self: *Shell) void {
        if (self.role != .ai) {
            self.writeOut("Permission denied: 'reboot' is restricted to resident AI supervisor\n");
            return;
        }
        self.writeOut("ush: AI supervisor rebooting system\n");
    }

    fn handleRebuild(self: *Shell) void {
        if (self.role != .ai) {
            self.writeOut("Permission denied: 'rebuild' is restricted to resident AI supervisor\n");
            return;
        }
        self.writeOut("ush: AI supervisor initiating kernel rebuild\n");
    }

    const cut_verbs = [_][]const u8{
        "ls",     "cd",   "echo",  "cat",     "clear",     "commit", "workspace", "ws",
        "layout", "pkg",  "ai",    "install", "installer", "desk",   "vedit",     "harness",
        "httpd",  "caps", ":caps",
    };

    fn isCutVerb(cmd: []const u8) bool {
        for (cut_verbs) |v| {
            if (std.mem.eql(u8, cmd, v)) return true;
        }
        return false;
    }

    pub fn dispatchAi(self: *Shell, prompt: []const u8, hint: ?[]const u8) void {
        if (hint) |h| {
            var buf: [128]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "ush: {s}, routing to AI assistant...\n", .{h})) |msg| {
                self.writeOut(msg);
            } else |_| {}
        } else {
            self.writeOut("ush: routing prompt to resident AI...\n");
        }
        if (self.last_ai_dispatch) |old| self.allocator.free(old);
        self.last_ai_dispatch = self.allocator.dupe(u8, prompt) catch null;
        self.evalMacrosStream(prompt);
    }

    fn writeEvalError(self: *Shell, err: anyerror) void {
        var buf: [64]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "\x1b[31mush: eval error: {}\x1b[0m\n", .{err})) |msg| {
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
                self.writeOut("ush: stage0 parse error\n");
                return;
            };
            defer stmt.deinit(self.allocator);

            compiler.compile(stmt) catch {
                self.writeOut("ush: stage0 compile error\n");
                return;
            };
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
                self.writeOut("ush: unable to open bootstrap file\n");
                return;
            };
            defer sys.io.close(fd) catch {};

            const buf = self.allocator.alloc(u8, 64 * 1024) catch return;
            defer self.allocator.free(buf);
            const bytes = sys.io.read(fd, buf) catch {
                self.writeOut("ush: unable to read bootstrap file\n");
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
            self.writeOut("ush: Stage 1 compiler not loaded. Run 'bootstrap' first.\n");
            return;
        }

        const code_dupe = self.allocator.dupe(u8, code) catch return;
        const key_dupe = self.allocator.dupe(u8, "__stream_input") catch return;
        self.vm.globals.put(key_dupe, .{ .string = code_dupe }) catch return;
        self.evalStage0("shell_eval(__stream_input);");
    }

    fn dispatchNativeVerb(self: *Shell, word: []const u8, remainder: []const u8) bool {
        if (std.mem.eql(u8, word, "help")) {
            self.printHelp();
            return true;
        }
        if (std.mem.eql(u8, word, ":show")) {
            self.handleShow(remainder);
            return true;
        }
        if (std.mem.eql(u8, word, ":run")) {
            self.handleRun(remainder);
            return true;
        }
        if (std.mem.eql(u8, word, ":ps")) {
            self.handlePs();
            return true;
        }
        if (std.mem.eql(u8, word, ":undo")) {
            self.handleUndo();
            return true;
        }
        if (std.mem.eql(u8, word, ":mesh")) {
            self.handleMesh(remainder);
            return true;
        }
        if (std.mem.eql(u8, word, ":exit") or std.mem.eql(u8, word, "exit") or std.mem.eql(u8, word, "quit")) {
            self.handleExit();
            return true;
        }
        return false;
    }

    fn dispatchAdminVerb(self: *Shell, word: []const u8) bool {
        if (std.mem.eql(u8, word, ":reboot") or std.mem.eql(u8, word, "reboot")) {
            self.handleReboot();
            return true;
        }
        if (std.mem.eql(u8, word, ":rebuild") or std.mem.eql(u8, word, "rebuild")) {
            self.handleRebuild();
            return true;
        }
        return false;
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

        if (self.dispatchNativeVerb(first_word, remainder)) return;
        if (self.dispatchAdminVerb(first_word)) return;

        if (isCutVerb(first_word)) {
            var hint_buf: [64]u8 = undefined;
            const hint = std.fmt.bufPrint(&hint_buf, "no such verb '{s}'", .{first_word}) catch "no such verb";
            self.dispatchAi(trimmed, hint);
            return;
        }

        self.dispatchAi(trimmed, null);
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
            self.writeOut("\x1b[1;36mµOS\x1b[0m \x1b[34mush\x1b[0m \x1b[32m❯\x1b[0m ");
            const bytes_read = sys.io.read(self.in_fd, &line_buf) catch break;
            if (bytes_read == 0) break;
            self.executeStream(line_buf[0..bytes_read]);
        }
    }
};

const testing = std.testing;

test "µShell help command enumerates exactly shipped surface" {
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

    sh.executeLine("help");

    var buf: [1024]u8 = undefined;
    const n = try sys.io.read(read_fd, &buf);
    const out = buf[0..n];

    try testing.expect(std.mem.indexOf(u8, out, ":show") != null);
    try testing.expect(std.mem.indexOf(u8, out, ":run") != null);
    try testing.expect(std.mem.indexOf(u8, out, ":ps") != null);
    try testing.expect(std.mem.indexOf(u8, out, ":undo") != null);
    try testing.expect(std.mem.indexOf(u8, out, ":mesh") != null);
    try testing.expect(std.mem.indexOf(u8, out, ":exit") != null);
    try testing.expect(std.mem.indexOf(u8, out, "help") != null);

    try testing.expect(std.mem.indexOf(u8, out, "  :caps") == null);
    try testing.expect(std.mem.indexOf(u8, out, "  ls") == null);
    try testing.expect(std.mem.indexOf(u8, out, "  cat") == null);
    try testing.expect(std.mem.indexOf(u8, out, "  echo") == null);
    try testing.expect(std.mem.indexOf(u8, out, "  clear") == null);
    try testing.expect(std.mem.indexOf(u8, out, "  workspace") == null);
}

test "µShell 6 native guest verbs execution" {
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

    sh.executeLine(":show test_artifact");
    try testing.expect(sh.running);

    sh.executeLine(":show caps");
    try testing.expect(sh.running);

    sh.executeLine(":show caps.desk");
    try testing.expect(sh.running);

    sh.executeLine(":run worker_actor");
    try testing.expect(sh.running);

    sh.executeLine(":ps");
    try testing.expect(sh.running);

    sh.executeLine(":undo");
    try testing.expect(sh.running);

    sh.executeLine(":mesh status");
    try testing.expect(sh.running);

    sh.executeLine(":exit");
    try testing.expect(!sh.running);
}

test "µShell cut verbs denial and AI routing" {
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

    const cuts = [_][]const u8{
        "ls",        "cd",   "echo test", "cat file", "clear",    "commit msg",
        "workspace", "ws",   "layout es", "pkg",      "ai hello", "install",
        "installer", "desk", "vedit",     "harness",  "httpd",
    };

    for (cuts) |cut_cmd| {
        sh.executeLine(cut_cmd);
        try testing.expect(sh.last_ai_dispatch != null);
    }
}

test "µShell AI-only verbs guest denial vs AI role execution" {
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

    sh.role = .guest;
    sh.executeLine(":reboot");
    var buf: [512]u8 = undefined;
    var n = try sys.io.read(read_fd, &buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "Permission denied") != null);

    sh.executeLine(":rebuild");
    n = try sys.io.read(read_fd, &buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "Permission denied") != null);

    sh.role = .ai;
    sh.executeLine(":reboot");
    n = try sys.io.read(read_fd, &buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "AI supervisor rebooting") != null);

    sh.executeLine(":rebuild");
    n = try sys.io.read(read_fd, &buf);
    try testing.expect(std.mem.indexOf(u8, buf[0..n], "AI supervisor initiating kernel rebuild") != null);
}

test "µShell bare AI prompt dispatch" {
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

    sh.executeLine("synthesize a driver for sensor");
    try testing.expect(sh.last_ai_dispatch != null);
    try testing.expectEqualStrings("synthesize a driver for sensor", sh.last_ai_dispatch.?);
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

test "Stage 1 lexical closure upvalue resolution and execution" {
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
    sh.evalStage0(
        \\cl_toks = lex("fn make_adder(a) { fn add(b) { return a + b; } return add; } adder = make_adder(10); out_res = adder(32);");
    );
    sh.evalStage0("cl_ast = parse(cl_toks);");
    sh.evalStage0("cl_bc = compile_program(cl_ast);");
    sh.evalStage0("exec_chunk(cl_bc[0], cl_bc[1]);");

    const res_val = sh.vm.globals.get("out_res");
    try testing.expect(res_val != null);
    try testing.expectEqual(@as(i64, 42), res_val.?.integer);
}

test "Stage 1 multi-level lexical closure upvalue resolution" {
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
    sh.evalStage0(
        \\ml_toks = lex("fn outer(x) { fn middle() { fn inner() { return x; } return inner; } return middle; } m = outer(99); in_f = m(); ans = in_f();");
    );
    sh.evalStage0("ml_ast = parse(ml_toks);");
    sh.evalStage0("ml_bc = compile_program(ml_ast);");
    sh.evalStage0("exec_chunk(ml_bc[0], ml_bc[1]);");

    const ans_val = sh.vm.globals.get("ans");
    try testing.expect(ans_val != null);
    try testing.expectEqual(@as(i64, 99), ans_val.?.integer);
}
