const std = @import("std");
const io = @import("sys/io.zig");
const process = @import("sys/process.zig");

pub fn main() !void {
    const banner = 
        \\=============================================
        \\ MicrOS (µOS) Init Sandbox (Phase 0)
        \\=============================================
        \\ Booting...
        \\
    ;
    
    _ = io.write(1, banner) catch {
        process.exit(1);
    };

    _ = io.write(1, "[micros-init] Execution completed. Halting.\n") catch {};
    process.exit(0);
}
