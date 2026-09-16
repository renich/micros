const std = @import("std");
const mem = @import("mem.zig");
const io = @import("io.zig");

test "memory allocation via mmap" {
    const length = 4096;
    const prot = mem.Prot.read | mem.Prot.write;
    const flags = mem.Flags.private | mem.Flags.anonymous;
    
    const ptr = try mem.map(null, length, prot, flags, -1, 0);
    const slice = @as([*]u8, @ptrCast(ptr))[0..length];
    
    slice[0] = 42;
    try std.testing.expectEqual(@as(u8, 42), slice[0]);
    
    try mem.unmap(ptr, length);
}

test "inter-process communication via pipe" {
    const fds = try io.pipe();
    const read_fd = fds[0];
    const write_fd = fds[1];

    const msg = "MicrOS";
    const written = try io.write(write_fd, msg);
    try std.testing.expectEqual(msg.len, written);

    var buf: [16]u8 = undefined;
    const bytes_read = try io.read(read_fd, &buf);
    
    try std.testing.expectEqual(msg.len, bytes_read);
    try std.testing.expectEqualStrings(msg, buf[0..bytes_read]);

    try io.close(write_fd);
    try io.close(read_fd);
}
