const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    AccessDenied,
    BadAddress,
    BadFileDescriptor,
    Interrupted,
    InvalidArgument,
    NoMemory,
    SystemResources,
    Unexpected,
};

pub fn errnoToError(err: isize) Error {
    return switch (-err) {
        13 => error.AccessDenied, // EACCES
        14 => error.BadAddress, // EFAULT
        9 => error.BadFileDescriptor, // EBADF
        4 => error.Interrupted, // EINTR
        22 => error.InvalidArgument, // EINVAL
        12 => error.NoMemory, // ENOMEM
        23, 24 => error.SystemResources, // ENFILE, EMFILE
        else => error.Unexpected,
    };
}

pub fn check(rc: usize) Error!usize {
    const signed_rc: isize = @bitCast(rc);
    if (signed_rc < 0 and signed_rc > -4096) {
        return errnoToError(signed_rc);
    }
    return rc;
}

pub fn exit_group(status: usize) noreturn {
    _ = linux.syscall1(.exit_group, status);
    unreachable;
}

pub fn mmap(addr: ?*anyopaque, length: usize, prot: usize, flags: usize, fd: i32, offset: usize) !*anyopaque {
    const fd_arg: usize = @bitCast(@as(isize, fd));
    const rc = linux.syscall6(.mmap, @intFromPtr(addr), length, prot, flags, fd_arg, offset);
    return @ptrFromInt(try check(rc));
}

pub fn munmap(addr: *anyopaque, length: usize) !void {
    const rc = linux.syscall2(.munmap, @intFromPtr(addr), length);
    _ = try check(rc);
}

pub fn read(fd: i32, buf: []u8) !usize {
    const fd_arg: usize = @bitCast(@as(isize, fd));
    const rc = linux.syscall3(.read, fd_arg, @intFromPtr(buf.ptr), buf.len);
    return try check(rc);
}

pub fn write(fd: i32, buf: []const u8) !usize {
    const fd_arg: usize = @bitCast(@as(isize, fd));
    const rc = linux.syscall3(.write, fd_arg, @intFromPtr(buf.ptr), buf.len);
    return try check(rc);
}

pub fn pipe2(fds: *[2]i32, flags: usize) !void {
    const rc = linux.syscall2(.pipe2, @intFromPtr(fds), flags);
    _ = try check(rc);
}

pub fn close(fd: i32) !void {
    const fd_arg: usize = @bitCast(@as(isize, fd));
    const rc = linux.syscall1(.close, fd_arg);
    _ = try check(rc);
}
