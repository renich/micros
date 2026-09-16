const std = @import("std");
const linux = @import("linux.zig");

pub fn read(fd: i32, buf: []u8) !usize {
    // Retry loop for EINTR could go here, but for now we let the caller handle it or wrap it
    var retries: usize = 0;
    while (retries < 3) : (retries += 1) {
        if (linux.read(fd, buf)) |bytes| {
            return bytes;
        } else |err| {
            if (err == error.Interrupted) continue;
            return err;
        }
    }
    return error.Interrupted;
}

pub fn write(fd: i32, buf: []const u8) !usize {
    var retries: usize = 0;
    while (retries < 3) : (retries += 1) {
        if (linux.write(fd, buf)) |bytes| {
            return bytes;
        } else |err| {
            if (err == error.Interrupted) continue;
            return err;
        }
    }
    return error.Interrupted;
}

pub fn pipe() ![2]i32 {
    var fds: [2]i32 = undefined;
    try linux.pipe2(&fds, 0); // O_CLOEXEC would be better if we defined it
    return fds;
}

pub fn close(fd: i32) !void {
    return linux.close(fd);
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
