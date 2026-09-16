const std = @import("std");
const sys = @import("sys.zig");
const msh = @import("msh.zig");

pub fn main() !void {
    const banner =
        \\=============================================
        \\ MicroShell (msh) - MicrOS Phase 0 Sandbox
        \\ Type 'help' for builtins or write Macros code
        \\=============================================
        \\
    ;
    _ = sys.io.write(1, banner) catch {
        sys.process.exit(1);
    };

    const allocator = std.heap.page_allocator;
    var shell = msh.Shell.init(allocator, 0, 1);
    defer shell.deinit();

    shell.run();

    _ = sys.io.write(1, "\n[msh] Session terminated cleanly.\n") catch {};
    if (sys.process.getpid() == 1) {
        sys.process.poweroff();
    }
    sys.process.exit(0);
}
