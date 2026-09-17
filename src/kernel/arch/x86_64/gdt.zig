// x86_64 Global Descriptor Table (GDT) & Task State Segment (TSS)

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

var gdt_entries: [5]GdtDescriptor = undefined;
var gdt_ptr: GdtPointer = undefined;

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

pub fn init() void {
    gdt_entries[0] = createDescriptor(0, 0, 0, 0); // Null descriptor
    gdt_entries[1] = createDescriptor(0, 0xFFFFF, 0x9A, 0xA0); // Kernel 64-bit Code (0x08)
    gdt_entries[2] = createDescriptor(0, 0xFFFFF, 0x92, 0xC0); // Kernel 64-bit Data (0x10)
    gdt_entries[3] = createDescriptor(0, 0xFFFFF, 0xFA, 0xA0); // User 64-bit Code (0x18)
    gdt_entries[4] = createDescriptor(0, 0xFFFFF, 0xF2, 0xC0); // User 64-bit Data (0x20)

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
        :
        : [ptr] "r" (&gdt_ptr),
    );
}
