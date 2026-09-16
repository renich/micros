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
