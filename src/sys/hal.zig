const builtin = @import("builtin");

pub const impl = if (builtin.os.tag == .freestanding or builtin.os.tag == .uefi)
    @import("hal_kernel.zig")
else
    @import("linux.zig");

pub fn mmap(addr: ?*anyopaque, length: usize, prot: usize, flags: usize, fd: i32, offset: usize) !*anyopaque {
    return impl.mmap(addr, length, prot, flags, fd, offset);
}

pub fn munmap(addr: *anyopaque, length: usize) !void {
    return impl.munmap(addr, length);
}

pub fn read(fd: i32, buf: []u8) !usize {
    return impl.read(fd, buf);
}

pub fn write(fd: i32, buf: []const u8) !usize {
    return impl.write(fd, buf);
}

pub fn pipe2(fds: *[2]i32, flags: usize) !void {
    return impl.pipe2(fds, flags);
}

pub fn open(path: [*:0]const u8, flags: usize, mode: usize) !i32 {
    return impl.open(path, flags, mode);
}

pub fn close(fd: i32) !void {
    return impl.close(fd);
}

pub fn exit_group(status: usize) noreturn {
    impl.exit_group(status);
}

pub fn poweroff() noreturn {
    impl.poweroff();
}

pub fn getpid() usize {
    return impl.getpid();
}
