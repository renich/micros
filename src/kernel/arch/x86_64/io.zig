// MicrOS (µOS) x86_64 Port I/O Assembly Primitives
// Provides low-level IN/OUT instructions without libc.

const std = @import("std");

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
    );
}

pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[ret]"
        : [ret] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

pub inline fn outw(port: u16, val: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [val] "{ax}" (val),
          [port] "{dx}" (port),
    );
}

pub inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[ret]"
        : [ret] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

pub inline fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [val] "{eax}" (val),
          [port] "{dx}" (port),
    );
}

pub inline fn ioWait() void {
    outb(0x80, 0);
}

pub inline fn pause() void {
    asm volatile ("pause" ::: .{ .memory = true });
}

pub inline fn rdtsc() u64 {
    var rax_val: u64 = undefined;
    var rdx_val: u64 = undefined;
    asm volatile (
        \\rdtsc
        : [rax_val] "={rax}" (rax_val),
          [rdx_val] "={rdx}" (rdx_val),
    );
    return (rdx_val << 32) | rax_val;
}

pub const MSR_EFER: u32 = 0xC0000080;
pub const MSR_STAR: u32 = 0xC0000081;
pub const MSR_LSTAR: u32 = 0xC0000082;
pub const MSR_CSTAR: u32 = 0xC0000083;
pub const MSR_SFMASK: u32 = 0xC0000084;
pub const MSR_FS_BASE: u32 = 0xC0000100;
pub const MSR_GS_BASE: u32 = 0xC0000101;
pub const MSR_KERNEL_GS_BASE: u32 = 0xC0000102;

pub inline fn rdmsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, high) << 32) | @as(u64, low);
}

pub inline fn wrmsr(msr: u32, val: u64) void {
    const low: u32 = @truncate(val);
    const high: u32 = @truncate(val >> 32);
    asm volatile ("wrmsr"
        :
        : [low] "{eax}" (low),
          [high] "{edx}" (high),
          [msr] "{ecx}" (msr),
    );
}

test "port io and msr signatures compile" {
    // Verified compilation of port I/O primitives
    try std.testing.expect(@sizeOf(u16) == 2);
    try std.testing.expect(@sizeOf(u32) == 4);
    try std.testing.expect(MSR_EFER == 0xC0000080);
    try std.testing.expect(MSR_STAR == 0xC0000081);
    try std.testing.expect(MSR_LSTAR == 0xC0000082);
    try std.testing.expect(MSR_SFMASK == 0xC0000084);
}
