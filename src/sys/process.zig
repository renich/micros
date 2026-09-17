const std = @import("std");
const hal = @import("hal.zig");

pub fn exit(status: usize) noreturn {
    hal.exit_group(status);
}

pub fn poweroff() noreturn {
    hal.poweroff();
}

pub fn getpid() usize {
    return hal.getpid();
}
