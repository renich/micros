const std = @import("std");
const sys = @import("sys.zig");
const msh = @import("msh.zig");

fn printBanner() void {
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
}

fn dispatchArgs(shell: *msh.Shell, init: std.process.Init) bool {
    var args = init.minimal.args.iterate();
    _ = args.skip(); // skip binary name

    const first_arg = args.next() orelse return false;
    if (std.mem.eql(u8, first_arg, "-c")) {
        if (args.next()) |cmd| {
            shell.executeStream(cmd);
        }
        return true;
    }
    shell.executeFile(first_arg);
    return true;
}

pub fn main(init: std.process.Init) !void {
    const base_alloc = std.heap.page_allocator;
    var heap = @import("macros.zig").gc.Heap.init(base_alloc);
    defer heap.deinit();

    var shell = try msh.Shell.init(heap.allocator(), 0, 1);
    defer shell.deinit();

    shell.loadStage1();

    if (!dispatchArgs(&shell, init)) {
        printBanner();
        shell.run();
        _ = sys.io.write(1, "\n[msh] Session terminated cleanly.\n") catch {};
    }

    if (sys.process.getpid() == 1) {
        sys.process.poweroff();
    }
    sys.process.exit(0);
}
