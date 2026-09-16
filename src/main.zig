const std = @import("std");
const sys = @import("sys.zig");
const macros = @import("macros.zig");

pub fn main() !void {
    const banner =
        \\=============================================
        \\ MicrOS (µOS) Init Sandbox (Phase 0)
        \\=============================================
        \\ Booting...
        \\
    ;

    _ = sys.io.write(1, banner) catch {
        sys.process.exit(1);
    };

    // Instantiate an allocator for the Sandbox (we use a simple page allocator here)
    // For Phase 0, testing with std.heap.page_allocator is acceptable until we write our PMM.
    const allocator = std.heap.page_allocator;

    const source_code = "foo + 42";

    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[macros] Parsing: {s}\n", .{source_code}) catch {
        sys.process.exit(1);
    };
    _ = sys.io.write(1, msg) catch {};

    var p = macros.parser.Parser.init(allocator, source_code);
    if (p.parseExpression()) |node| {
        const success_msg = std.fmt.bufPrint(&buf, "[macros] AST Root: BinaryExpr({s})\n", .{@tagName(node.binary_expr.operator)}) catch {
            sys.process.exit(1);
        };
        _ = sys.io.write(1, success_msg) catch {};
    } else |err| {
        const err_msg = std.fmt.bufPrint(&buf, "[macros] Parser Error: {}\n", .{err}) catch {
            sys.process.exit(1);
        };
        _ = sys.io.write(1, err_msg) catch {};
    }

    _ = sys.io.write(1, "[micros-init] Execution completed. Halting.\n") catch {};
    sys.process.exit(0);
}
