// Virtual Memory Manager (VMM) - 4-Level x86_64 Paging & HHDM

const pmm = @import("pmm.zig");

pub const PAGE_PRESENT: u64 = 1 << 0;
pub const PAGE_WRITABLE: u64 = 1 << 1;
pub const PAGE_USER: u64 = 1 << 2;
pub const PAGE_HUGE: u64 = 1 << 7;
pub const PAGE_NO_EXECUTE: u64 = 1 << 63;

pub const PageTable = extern struct {
    entries: [512]u64,
};

pub var kernel_pml4_phys: u64 = 0;
pub var hhdm_base: u64 = 0xFFFF_8000_0000_0000;

pub fn init(hhdm_offset: u64) void {
    hhdm_base = hhdm_offset;
    kernel_pml4_phys = pmm.allocPage() orelse return;

    const pml4: *PageTable = @ptrFromInt(kernel_pml4_phys + hhdm_base);
    for (&pml4.entries) |*entry| {
        entry.* = 0;
    }
}

pub fn mapPage(pml4_phys: u64, virt: u64, phys: u64, flags: u64) bool {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const pml4: *PageTable = @ptrFromInt(pml4_phys + hhdm_base);

    // PML4 -> PDPT
    if ((pml4.entries[pml4_idx] & PAGE_PRESENT) == 0) {
        const new_table = pmm.allocPage() orelse return false;
        const pdpt: *PageTable = @ptrFromInt(new_table + hhdm_base);
        for (&pdpt.entries) |*e| e.* = 0;
        pml4.entries[pml4_idx] = new_table | PAGE_PRESENT | PAGE_WRITABLE | (flags & PAGE_USER);
    }

    const pdpt: *PageTable = @ptrFromInt((pml4.entries[pml4_idx] & 0x000F_FFFF_FFFF_F000) + hhdm_base);

    // PDPT -> PD
    if ((pdpt.entries[pdpt_idx] & PAGE_PRESENT) == 0) {
        const new_table = pmm.allocPage() orelse return false;
        const pd: *PageTable = @ptrFromInt(new_table + hhdm_base);
        for (&pd.entries) |*e| e.* = 0;
        pdpt.entries[pdpt_idx] = new_table | PAGE_PRESENT | PAGE_WRITABLE | (flags & PAGE_USER);
    }

    const pd: *PageTable = @ptrFromInt((pdpt.entries[pdpt_idx] & 0x000F_FFFF_FFFF_F000) + hhdm_base);

    // PD -> PT
    if ((pd.entries[pd_idx] & PAGE_PRESENT) == 0) {
        const new_table = pmm.allocPage() orelse return false;
        const pt: *PageTable = @ptrFromInt(new_table + hhdm_base);
        for (&pt.entries) |*e| e.* = 0;
        pd.entries[pd_idx] = new_table | PAGE_PRESENT | PAGE_WRITABLE | (flags & PAGE_USER);
    }

    const pt: *PageTable = @ptrFromInt((pd.entries[pd_idx] & 0x000F_FFFF_FFFF_F000) + hhdm_base);
    pt.entries[pt_idx] = (phys & 0x000F_FFFF_FFFF_F000) | flags;

    return true;
}

pub fn loadPageTable(pml4_phys: u64) void {
    asm volatile ("movq %[cr3], %%cr3"
        :
        : [cr3] "r" (pml4_phys),
        : "memory");
}

var next_heap_vaddr: u64 = 0x0000_1000_0000_0000;

pub fn map_pages(addr: ?*anyopaque, length: usize, flags: u64) !*anyopaque {
    const num_pages = (length + 4095) / 4096;

    const vaddr = if (addr) |a| @intFromPtr(a) else blk: {
        const v = next_heap_vaddr;
        next_heap_vaddr += num_pages * 4096;
        break :blk v;
    };

    var i: usize = 0;
    while (i < num_pages) : (i += 1) {
        const phys = pmm.allocPage() orelse return error.NoMemory;
        if (!mapPage(kernel_pml4_phys, vaddr + i * 4096, phys, flags)) {
            return error.NoMemory;
        }
    }

    return @ptrFromInt(vaddr);
}
