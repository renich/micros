const std = @import("std");
const syscall = @import("syscall.zig");
const linux = std.os.linux;
const testing = std.testing;

test "mmap and munmap" {
    const page_size = 4096;
    
    const prot: usize = @as(u32, @bitCast(linux.PROT{ .READ = true, .WRITE = true }));
    const flags: usize = @as(u32, @bitCast(linux.MAP{ .TYPE = .PRIVATE, .ANONYMOUS = true }));
    
    const ret = syscall.mmap(null, page_size, prot, flags, 0, 0);
    const ptr = @as(*anyopaque, @ptrFromInt(ret));
    try testing.expect(@as(isize, @bitCast(ret)) > 0);
    
    const unmap_ret = syscall.munmap(ptr, page_size);
    try testing.expect(unmap_ret == 0);
}

test "write and read" {
    var fds: [2]i32 = undefined;
    const pipe_ret = linux.syscall2(.pipe2, @intFromPtr(&fds), 0);
    try testing.expect(pipe_ret == 0);
    
    const read_fd = @as(usize, @intCast(fds[0]));
    const write_fd = @as(usize, @intCast(fds[1]));
    
    const msg = "hello syscalls";
    const write_ret = syscall.write(write_fd, msg.ptr, msg.len);
    try testing.expect(write_ret == msg.len);
    
    var buf: [32]u8 = undefined;
    const read_ret = syscall.read(read_fd, &buf, buf.len);
    try testing.expect(read_ret == msg.len);
    try testing.expectEqualStrings(msg, buf[0..msg.len]);
    
    _ = linux.syscall1(.close, write_fd);
    _ = linux.syscall1(.close, read_fd);
}
