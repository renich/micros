const std = @import("std");
const linux = @import("linux.zig");

pub const Prot = struct {
    pub const read = 0x1;
    pub const write = 0x2;
    pub const exec = 0x4;
};

pub const Flags = struct {
    pub const shared = 0x01;
    pub const private = 0x02;
    pub const anonymous = 0x20;
};

pub fn map(addr: ?*anyopaque, length: usize, prot: usize, flags: usize, fd: i32, offset: usize) !*anyopaque {
    return linux.mmap(addr, length, prot, flags, fd, offset);
}

pub fn unmap(addr: *anyopaque, length: usize) !void {
    // Ensure page alignment
    if (@intFromPtr(addr) & (4096 - 1) != 0) return error.InvalidArgument;
    return linux.munmap(addr, length);
}

const testing = std.testing;

test "memory allocation via mmap" {
    const length = 4096;
    const prot_flags = Prot.read | Prot.write;
    const mmap_flags = Flags.private | Flags.anonymous;
    
    const ptr = try map(null, length, prot_flags, mmap_flags, -1, 0);
    const slice = @as([*]u8, @ptrCast(ptr))[0..length];
    
    slice[0] = 42;
    try testing.expectEqual(@as(u8, 42), slice[0]);
    
    try unmap(ptr, length);
}
