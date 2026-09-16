const std = @import("std");
const sys = @import("sys.zig");

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

    _ = sys.io.write(1, "[micros-init] Execution completed. Halting.\n") catch {};
    sys.process.exit(0);
}
