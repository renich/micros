const std = @import("std");
const sys = @import("sys.zig");
const macros = @import("macros.zig");

fn printUsage() void {
    const usage =
        \\Macros Language Runner & REPL (Phase 0)
        \\Usage:
        \\  macros <script.mx|script.macros>   Run a Macros script
        \\  macros -e "<code>"                 Evaluate inline code
        \\  macros                             Start interactive REPL
        \\  macros --help                      Show this help message
        \\
        \\Supported File Extensions:
        \\  .mx, .macros
        \\
    ;
    _ = sys.io.write(1, usage) catch {};
}

fn printError(prefix: []const u8, err: anyerror) void {
    var err_buf: [64]u8 = undefined;
    if (std.fmt.bufPrint(&err_buf, "macros: {s}: {}\n", .{ prefix, err })) |msg| {
        _ = sys.io.write(2, msg) catch {};
    } else |_| {}
}

fn printResult(val: macros.eval.Value) void {
    if (val == .nil) {
        _ = sys.io.write(1, "=> nil\n") catch {};
        return;
    }
    _ = sys.io.write(1, "=> ") catch {};
    val.printToFd(1);
    _ = sys.io.write(1, "\n") catch {};
}

fn printParseError(err: anyerror, tok: macros.lexer.Token) void {
    var err_buf: [128]u8 = undefined;
    if (std.fmt.bufPrint(&err_buf, "macros: parse error: {} at token '{s}' ({s})\n", .{
        err,
        tok.lexeme,
        @tagName(tok.token_type),
    })) |msg| {
        _ = sys.io.write(2, msg) catch {};
    } else |_| {}
}

fn evalCode(allocator: std.mem.Allocator, vm: *macros.vm.VM, code: []const u8) !void {
    var parser = macros.parser.Parser.init(allocator, code);
    var chunk = macros.chunk.Chunk.init();
    defer chunk.deinit(allocator);
    var compiler = macros.compiler.Compiler.init(allocator, &chunk);

    while (parser.current_token.token_type != .eof) {
        const stmt = parser.parseStatement() catch |err| {
            printParseError(err, parser.current_token);
            return;
        };

        compiler.compile(stmt) catch |err| {
            printError("compile error", err);
            return;
        };
    }

    vm.chunk = &chunk;
    vm.ip = 0;
    vm.sp = 0;
    vm.run(vm.frame_count) catch |err| {
        printError("runtime error", err);
        return;
    };

    if (vm.sp > 0) {
        const val = vm.pop() catch return;
        if (val != .nil) {
            printResult(val);
        }
    }
}

fn runFile(allocator: std.mem.Allocator, vm: *macros.vm.VM, path: [:0]const u8) !void {
    const fd = sys.io.open(path, sys.io.OpenFlags.rdonly, 0) catch {
        _ = sys.io.write(2, "macros: unable to open source file\n") catch {};
        return;
    };
    defer sys.io.close(fd) catch {};

    var buf: [64 * 1024]u8 = undefined;
    const bytes = sys.io.read(fd, &buf) catch {
        _ = sys.io.write(2, "macros: unable to read source file\n") catch {};
        return;
    };

    try evalCode(allocator, vm, buf[0..bytes]);
}

fn runRepl(allocator: std.mem.Allocator, vm: *macros.vm.VM) !void {
    _ = sys.io.write(1, "Macros Interactive REPL (Type 'exit' to quit)\n") catch {};
    var buf: [1024]u8 = undefined;

    while (true) {
        _ = sys.io.write(1, "macros> ") catch {};
        const bytes_read = sys.io.read(0, &buf) catch break;
        if (bytes_read == 0) break;

        const line = std.mem.trim(u8, buf[0..bytes_read], " \t\r\n");
        if (std.mem.eql(u8, line, "exit") or std.mem.eql(u8, line, "quit")) break;
        if (line.len == 0) continue;

        evalCode(allocator, vm, line) catch {};
    }
}

pub fn main(init: std.process.Init) !void {
    const base_alloc = std.heap.page_allocator;
    var heap = macros.gc.Heap.init(base_alloc);
    defer heap.deinit();

    const allocator = heap.allocator();
    const dummy_chunk: *macros.chunk.Chunk = undefined;
    var vm = try macros.vm.VM.init(allocator, dummy_chunk);
    defer vm.deinit();

    var args = init.minimal.args.iterate();
    _ = args.skip(); // skip binary name

    const first_arg = args.next();
    if (first_arg == null) {
        try runRepl(allocator, &vm);
    } else if (std.mem.eql(u8, first_arg.?, "--help") or std.mem.eql(u8, first_arg.?, "-h")) {
        printUsage();
    } else if (std.mem.eql(u8, first_arg.?, "-e")) {
        if (args.next()) |expr| {
            try evalCode(allocator, &vm, expr);
        }
    } else {
        try runFile(allocator, &vm, first_arg.?);
    }
}
