const std = @import("std");
const sys = @import("sys.zig");
const macros = @import("macros.zig");
const msh = @import("msh.zig");

fn printBanner() void {
    const banner =
        \\=============================================
        \\ MicrOS (µOS) Init Sandbox (Phase 0)
        \\=============================================
        \\ Booting PID 1 Substrate...
        \\
    ;
    _ = sys.io.write(1, banner) catch {
        sys.process.exit(1);
    };
}

fn runSelfTest(allocator: std.mem.Allocator) bool {
    var env = macros.eval.Environment.init(allocator);
    defer env.deinit();

    var evaluator = macros.eval.Evaluator.init(allocator, &env);
    var p = macros.parser.Parser.init(allocator, "boot_check = 20 + 22");
    const node = p.parseStatement() catch return false;
    defer allocator.destroy(node);

    const val = evaluator.eval(node) catch return false;
    if (val != .integer or val.integer != 42) return false;

    _ = sys.io.write(1, "[micros-init] Substrate self-test verified (Macros 20+22=42).\n") catch {};
    return true;
}

pub fn main() !void {
    printBanner();

    const allocator = std.heap.page_allocator;
    if (!runSelfTest(allocator)) {
        _ = sys.io.write(2, "[micros-init] ERROR: Substrate self-test failed.\n") catch {};
        sys.process.exit(1);
    }

    _ = sys.io.write(1, "[micros-init] Spawning MicroShell (msh)...\n\n") catch {};
    var shell = msh.Shell.init(allocator, 0, 1);
    defer shell.deinit();

    shell.executeLine("echo MicroShell initialized by PID 1.");
    shell.executeLine("ready = 1");

    _ = sys.io.write(1, "[micros-init] Execution completed. Halting.\n") catch {};
    if (sys.process.getpid() == 1) {
        sys.process.poweroff();
    }
    sys.process.exit(0);
}
