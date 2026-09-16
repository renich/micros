const std = @import("std");
const linux = @import("linux.zig");

pub fn exit(status: usize) noreturn {
    linux.exit_group(status);
}
