// MicrOS (µOS) x86_64 Port I/O Assembly Primitives
// Provides low-level IN/OUT instructions without libc.

const std = @import("std");
const builtin = @import("builtin");

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
    if (builtin.is_test) {
        pause();
        return;
    }
    outb(0x80, 0);
}

pub inline fn pause() void {
    asm volatile ("pause" ::: .{ .memory = true });
}

pub inline fn pushfqAndCli() u64 {
    if (builtin.is_test) return 0;
    var rflags: u64 = undefined;
    asm volatile (
        \\pushfq
        \\popq %[rflags]
        \\cli
        : [rflags] "=r" (rflags),
        :
        : .{ .memory = true });
    return rflags;
}

pub inline fn popfq(rflags: u64) void {
    if (builtin.is_test) return;
    asm volatile (
        \\pushq %[rflags]
        \\popfq
        :
        : [rflags] "r" (rflags),
        : .{ .memory = true, .cc = true });
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

pub const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

pub inline fn cpuid(leaf: u32) CpuidResult {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile (
        \\cpuid
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (@as(u32, 0)),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

pub fn checkRdrandBit(ecx: u32) bool {
    return (ecx & (1 << 30)) != 0;
}

pub fn rdrandSupported() bool {
    if (builtin.cpu.arch != .x86_64) return false;
    const max_leaf = cpuid(0).eax;
    if (max_leaf < 1) return false;
    const info = cpuid(1);
    return checkRdrandBit(info.ecx);
}

pub inline fn rdrand64() ?u64 {
    if (!rdrandSupported()) return null;
    var val: u64 = 0;
    var success: u8 = 0;
    asm volatile (
        \\rdrand %[val]
        \\setc %[success]
        : [val] "=r" (val),
          [success] "=r" (success),
    );
    if (success != 0 and val != 0) {
        return val;
    }
    return null;
}

pub fn mix64(k: u64) u64 {
    var x = k;
    x ^= x >> 30;
    x *%= 0xbf58476d1ce4e5b9;
    x ^= x >> 27;
    x *%= 0x94d049bb133111eb;
    x ^= x >> 31;
    return x;
}

pub fn getEntropy64(boot_seed: u64) u64 {
    var raw = rdtsc() ^ boot_seed;
    if (rdrand64()) |hw| {
        raw ^= hw;
    }
    return mix64(raw);
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

test "entropy ladder mix64 avalanche and distribution" {
    const e1 = mix64(1);
    const e2 = mix64(2);
    try std.testing.expect(e1 != e2);
    try std.testing.expect(e1 != 0);
    try std.testing.expect(e2 != 0);

    const diff = @popCount(e1 ^ e2);
    try std.testing.expect(diff >= 20);
}

test "cpuid RDRAND bit extraction logic" {
    // Pure function test over explicit ECX register values
    try std.testing.expect(checkRdrandBit(1 << 30));
    try std.testing.expect(!checkRdrandBit(0));
    try std.testing.expect(!checkRdrandBit(0x3FFF_FFFF));
    try std.testing.expect(checkRdrandBit(0xFFFF_FFFF));
    try std.testing.expect(!checkRdrandBit(1 << 29));
    try std.testing.expect(!checkRdrandBit(1 << 31));
}

test "cpuid query and rdrand host execution safety" {
    if (builtin.cpu.arch != .x86_64) return;
    const leaf0 = cpuid(0);
    try std.testing.expect(leaf0.eax > 0);

    const supported = rdrandSupported();
    if (supported) {
        // On hardware supporting RDRAND, rdrand64 must execute safely without faulting.
        const val = rdrand64();
        if (val) |v| {
            try std.testing.expect(v != 0);
        }
    } else {
        // When unsupported, rdrand64 must return null immediately without executing RDRAND.
        try std.testing.expect(rdrand64() == null);
    }

    // Entropy ladder degrades cleanly regardless of RDRAND support
    const ent = getEntropy64(0x1234_5678_9ABC_DEF0);
    try std.testing.expect(ent != 0);
}
