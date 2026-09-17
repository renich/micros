const std = @import("std");
const hal = @import("hal.zig");

pub fn read(fd: i32, buf: []u8) !usize {
    return hal.read(fd, buf);
}

pub fn write(fd: i32, buf: []const u8) !usize {
    return hal.write(fd, buf);
}

pub fn pipe() ![2]i32 {
    var fds: [2]i32 = undefined;
    try hal.pipe2(&fds, 0); // O_CLOEXEC would be better if we defined it
    return fds;
}

pub const OpenFlags = struct {
    pub const rdonly: usize = 0;
    pub const wronly: usize = 1;
    pub const rdwr: usize = 2;
    pub const creat: usize = 64;
    pub const trunc: usize = 512;
};

pub fn open(path: [*:0]const u8, flags: usize, mode: usize) !i32 {
    return hal.open(path, flags, mode);
}

pub fn close(fd: i32) !void {
    return hal.close(fd);
}

const testing = std.testing;

test "inter-process communication via pipe" {
    const fds = try pipe();
    const read_fd = fds[0];
    const write_fd = fds[1];

    const msg = "MicrOS";
    const written = try write(write_fd, msg);
    try testing.expectEqual(msg.len, written);

    var buf: [16]u8 = undefined;
    const bytes_read = try read(read_fd, &buf);

    try testing.expectEqual(msg.len, bytes_read);
    try testing.expectEqualStrings(msg, buf[0..bytes_read]);

    try close(write_fd);
    try close(read_fd);
}
