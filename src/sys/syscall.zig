const std = @import("std");
const linux = std.os.linux;

pub fn write(fd: usize, buf: [*]const u8, count: usize) usize {
    return linux.syscall3(.write, fd, @intFromPtr(buf), count);
}

pub fn read(fd: usize, buf: [*]u8, count: usize) usize {
    return linux.syscall3(.read, fd, @intFromPtr(buf), count);
}

pub fn exit(status: usize) noreturn {
    _ = linux.syscall1(.exit, status);
    unreachable;
}

pub fn mmap(addr: ?*anyopaque, length: usize, prot: usize, flags: usize, fd: usize, offset: usize) usize {
    return linux.syscall6(.mmap, @intFromPtr(addr), length, prot, flags, fd, offset);
}

pub fn munmap(addr: *anyopaque, length: usize) usize {
    return linux.syscall2(.munmap, @intFromPtr(addr), length);
}
