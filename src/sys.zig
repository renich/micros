pub const io = @import("sys/io.zig");
pub const linux = @import("sys/linux.zig");
pub const mem = @import("sys/mem.zig");
pub const process = @import("sys/process.zig");

test "sys module tests" {
    _ = @import("sys/io.zig");
    _ = @import("sys/mem.zig");
}
