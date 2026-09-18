// x86_64 Global Descriptor Table (GDT) & Task State Segment (TSS)
// Provides hardware Ring 0 / Ring 3 segmentation, TSS RSP0 stack switching, and task register loading.

const std = @import("std");

pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
pub const USER_CS32: u16 = 0x18;
pub const USER_DS: u16 = 0x20;
pub const USER_CS64: u16 = 0x28;
pub const TSS_SELECTOR: u16 = 0x30;

pub const GdtDescriptor = extern struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    granularity: u8,
    base_high: u8,
};

pub const GdtPointer = packed struct {
    limit: u16,
    base: u64,
};

pub const TaskStateSegment = extern struct {
    reserved0: u32 = 0,
    rsp0: u64 align(4) = 0,
    rsp1: u64 align(4) = 0,
    rsp2: u64 align(4) = 0,
    reserved1: u64 align(4) = 0,
    ist1: u64 align(4) = 0,
    ist2: u64 align(4) = 0,
    ist3: u64 align(4) = 0,
    ist4: u64 align(4) = 0,
    ist5: u64 align(4) = 0,
    ist6: u64 align(4) = 0,
    ist7: u64 align(4) = 0,
    reserved2: u64 align(4) = 0,
    reserved3: u16 = 0,
    iomap_base: u16 = 104,
};

var gdt_entries: [8]GdtDescriptor = undefined;
var gdt_ptr: GdtPointer = undefined;
pub var kernel_tss: TaskStateSegment = std.mem.zeroes(TaskStateSegment);
var kernel_stack: [16384]u8 align(4096) = undefined;

fn createDescriptor(base: u32, limit: u32, access: u8, flags: u8) GdtDescriptor {
    return GdtDescriptor{
        .limit_low = @intCast(limit & 0xFFFF),
        .base_low = @intCast(base & 0xFFFF),
        .base_mid = @intCast((base >> 16) & 0xFF),
        .access = access,
        .granularity = @intCast(((limit >> 16) & 0x0F) | (flags & 0xF0)),
        .base_high = @intCast((base >> 24) & 0xFF),
    };
}

fn setTssDescriptor(base: u64, limit: u32) void {
    gdt_entries[6] = GdtDescriptor{
        .limit_low = @truncate(limit & 0xFFFF),
        .base_low = @truncate(base & 0xFFFF),
        .base_mid = @truncate((base >> 16) & 0xFF),
        .access = 0x89, // Present, DPL=0, Type 9 (64-bit TSS available)
        .granularity = @truncate((limit >> 16) & 0x0F),
        .base_high = @truncate((base >> 24) & 0xFF),
    };

    const base_upper: u32 = @truncate(base >> 32);
    gdt_entries[7] = GdtDescriptor{
        .limit_low = @truncate(base_upper & 0xFFFF),
        .base_low = @truncate((base_upper >> 16) & 0xFFFF),
        .base_mid = 0,
        .access = 0,
        .granularity = 0,
        .base_high = 0,
    };
}

pub fn setKernelStack(rsp: u64) void {
    kernel_tss.rsp0 = rsp;
}

pub fn getTss() *const TaskStateSegment {
    return &kernel_tss;
}

pub fn init() void {
    gdt_entries[0] = createDescriptor(0, 0, 0, 0); // Null descriptor
    gdt_entries[1] = createDescriptor(0, 0xFFFFF, 0x9A, 0xA0); // Kernel 64-bit Code (0x08)
    gdt_entries[2] = createDescriptor(0, 0xFFFFF, 0x92, 0xC0); // Kernel 64-bit Data (0x10)
    gdt_entries[3] = createDescriptor(0, 0xFFFFF, 0xFA, 0xC0); // User 32-bit Code (0x18)
    gdt_entries[4] = createDescriptor(0, 0xFFFFF, 0xF2, 0xC0); // User 64-bit Data (0x20)
    gdt_entries[5] = createDescriptor(0, 0xFFFFF, 0xFA, 0xA0); // User 64-bit Code (0x28)

    kernel_tss.iomap_base = @sizeOf(TaskStateSegment);
    kernel_tss.rsp0 = @intFromPtr(&kernel_stack) + kernel_stack.len;
    setTssDescriptor(@intFromPtr(&kernel_tss), @sizeOf(TaskStateSegment) - 1);

    gdt_ptr.limit = @sizeOf(@TypeOf(gdt_entries)) - 1;
    gdt_ptr.base = @intFromPtr(&gdt_entries);

    asm volatile (
        \\lgdt (%[ptr])
        \\pushq $0x08
        \\leaq 1f(%rip), %rax
        \\pushq %rax
        \\lretq
        \\1:
        \\movw $0x10, %ax
        \\movw %ax, %ds
        \\movw %ax, %es
        \\movw %ax, %fs
        \\movw %ax, %gs
        \\movw %ax, %ss
        \\movw $0x30, %ax
        \\ltr %ax
        :
        : [ptr] "r" (&gdt_ptr),
    );
}

test "gdt and tss binary layouts comply with x86_64 architecture" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(GdtDescriptor));
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(TaskStateSegment));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(@TypeOf(gdt_entries)));

    var dummy_tss: TaskStateSegment = std.mem.zeroes(TaskStateSegment);
    dummy_tss.rsp0 = 0xFFFF_8000_0001_0000;
    try std.testing.expect(dummy_tss.rsp0 == 0xFFFF_8000_0001_0000);
}
