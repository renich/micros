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
    if (length == 0 or length > std.math.maxInt(usize) - 4095) return error.InvalidArgs;
    const cr3 = vmm.readCr3();
    const pml4 = if (cr3 != 0) cr3 else vmm.kernel_pml4_phys;
    const start_vaddr = @intFromPtr(addr) & ~@as(u64, 0xFFF);
    const end_vaddr = std.mem.alignForward(u64, @intFromPtr(addr) + length, 4096);
    const num_pages = (end_vaddr - start_vaddr) / 4096;
    for (0..num_pages) |i| {
        _ = vmm.unmapPage(pml4, start_vaddr + i * 4096);
    }
}

pub fn mprotect(addr: *anyopaque, length: usize, prot: usize) !void {
    return vmm.protectPages(addr, length, prot);
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
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn poweroff() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn getpid() usize {
    return 0; // Actor 0 (Genesis Actor)
}
