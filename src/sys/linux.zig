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
    FileNotFound,
    PermissionDenied,
    FileExists,
    BrokenPipe,
    WouldBlock,
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
        2 => error.FileNotFound, // ENOENT
        1 => error.PermissionDenied, // EPERM
        17 => error.FileExists, // EEXIST
        32 => error.BrokenPipe, // EPIPE
        11 => error.WouldBlock, // EAGAIN
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

pub const REBOOT_MAGIC1: usize = 0xfee1dead;
pub const REBOOT_MAGIC2: usize = 0x28121969;
pub const REBOOT_CMD_POWER_OFF: usize = 0x4321fedc;

pub fn poweroff() noreturn {
    _ = linux.syscall4(.reboot, REBOOT_MAGIC1, REBOOT_MAGIC2, REBOOT_CMD_POWER_OFF, 0);
    exit_group(0);
}

pub fn mmap(addr: ?*anyopaque, length: usize, prot: usize, flags: usize, fd: i32, offset: usize) !*anyopaque {
    if (length % 4096 != 0 or offset % 4096 != 0) return error.InvalidArgument;
    const fd_arg: usize = @bitCast(@as(isize, fd));
    const rc = linux.syscall6(.mmap, @intFromPtr(addr), length, prot, flags, fd_arg, offset);
    return @ptrFromInt(try check(rc));
}

pub fn munmap(addr: *anyopaque, length: usize) !void {
    const rc = linux.syscall2(.munmap, @intFromPtr(addr), length);
    _ = try check(rc);
}

pub fn mprotect(addr: *anyopaque, length: usize, prot: usize) !void {
    if (@intFromPtr(addr) % 4096 != 0 or length % 4096 != 0) return error.InvalidArgument;
    const rc = linux.syscall3(.mprotect, @intFromPtr(addr), length, prot);
    _ = try check(rc);
}

pub fn read(fd: i32, buf: []u8) !usize {
    const fd_arg: usize = @bitCast(@as(isize, fd));
    while (true) {
        const rc = linux.syscall3(.read, fd_arg, @intFromPtr(buf.ptr), buf.len);
        if (check(rc)) |sz| return sz else |err| {
            if (err == error.Interrupted) continue;
            return err;
        }
    }
}

pub fn write(fd: i32, buf: []const u8) !usize {
    const fd_arg: usize = @bitCast(@as(isize, fd));
    while (true) {
        const rc = linux.syscall3(.write, fd_arg, @intFromPtr(buf.ptr), buf.len);
        if (check(rc)) |sz| return sz else |err| {
            if (err == error.Interrupted) continue;
            return err;
        }
    }
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

pub fn open(path: [*:0]const u8, flags: usize, mode: usize) !i32 {
    const rc = linux.syscall3(.open, @intFromPtr(path), flags, mode);
    return @intCast(try check(rc));
}

pub fn getpid() usize {
    return linux.syscall0(.getpid);
}

pub fn clock_gettime(clk_id: i32, ts: *linux.timespec) !void {
    const clk_arg: usize = @bitCast(@as(isize, clk_id));
    const rc = linux.syscall2(.clock_gettime, clk_arg, @intFromPtr(ts));
    _ = try check(rc);
}
