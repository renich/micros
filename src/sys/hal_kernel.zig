const std = @import("std");
const vmm = @import("../kernel/mem/vmm.zig");
const serial = @import("../kernel/serial.zig");

pub fn mmap(addr: ?*anyopaque, length: usize, prot: usize, flags: usize, fd: i32, offset: usize) !*anyopaque {
    _ = fd;
    _ = offset;
    _ = flags;

    var vmm_flags: u64 = vmm.PAGE_PRESENT | vmm.PAGE_USER;

    if ((prot & 0x2) != 0) { // Prot.write
        vmm_flags |= vmm.PAGE_WRITABLE;
    }

    return vmm.map_pages(addr, length, vmm_flags);
}

pub fn munmap(addr: *anyopaque, length: usize) !void {
    _ = addr;
    _ = length;
    // Stub
}

pub fn mprotect(addr: *anyopaque, length: usize, prot: usize) !void {
    _ = addr;
    _ = length;
    _ = prot;
}

pub fn read(fd: i32, buf: []u8) !usize {
    if (fd == 0) {
        var count: usize = 0;
        while (count < buf.len) {
            const ch = serial.readChar() orelse break;
            buf[count] = ch;
            count += 1;
        }
        return count;
    }
    return 0;
}

pub fn write(fd: i32, buf: []const u8) !usize {
    _ = fd;
    serial.writeString(buf);
    return buf.len;
}

pub fn pipe2(fds: *[2]i32, flags: usize) !void {
    _ = fds;
    _ = flags;
}

pub fn open(path: [*:0]const u8, flags: usize, mode: usize) !i32 {
    _ = path;
    _ = flags;
    _ = mode;
    return -1;
}

pub fn close(fd: i32) !void {
    _ = fd;
}

pub fn exit_group(status: usize) noreturn {
    _ = status;
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn poweroff() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn getpid() usize {
    return 0; // Actor 0 (Genesis Actor)
}
