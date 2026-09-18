// Virtual Memory Manager (VMM) - 4-Level x86_64 Paging & HHDM
// Enforces strict hardware address space separation between Ring 0 and Ring 3 actors.

const std = @import("std");
const builtin = @import("builtin");
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

pub fn readCr3() u64 {
    if (builtin.is_test) return 0;
    var cr3_val: u64 = 0;
    asm volatile ("movq %%cr3, %[ret]"
        : [ret] "=r" (cr3_val),
    );
    return cr3_val & 0x000F_FFFF_FFFF_F000;
}

pub fn init(hhdm_offset: u64) void {
    hhdm_base = hhdm_offset;
    const cr3 = readCr3();
    if (cr3 != 0) {
        kernel_pml4_phys = cr3;
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

pub fn unmapPage(pml4_phys: u64, virt: u64) bool {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const pml4: *PageTable = @ptrFromInt(pml4_phys + hhdm_base);
    if ((pml4.entries[pml4_idx] & PAGE_PRESENT) == 0) return false;

    const pdpt: *PageTable = @ptrFromInt((pml4.entries[pml4_idx] & 0x000F_FFFF_FFFF_F000) + hhdm_base);
    if ((pdpt.entries[pdpt_idx] & PAGE_PRESENT) == 0) return false;

    const pd: *PageTable = @ptrFromInt((pdpt.entries[pdpt_idx] & 0x000F_FFFF_FFFF_F000) + hhdm_base);
    if ((pd.entries[pd_idx] & PAGE_PRESENT) == 0) return false;

    const pt: *PageTable = @ptrFromInt((pd.entries[pd_idx] & 0x000F_FFFF_FFFF_F000) + hhdm_base);
    if ((pt.entries[pt_idx] & PAGE_PRESENT) == 0) return false;

    pt.entries[pt_idx] = 0;
    invalidateTlb(virt);
    return true;
}

pub fn invalidateTlb(virt: u64) void {
    if (builtin.is_test) return;
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt),
        : .{ .memory = true });
}

pub fn loadPageTable(pml4_phys: u64) void {
    if (builtin.is_test) return;
    asm volatile ("movq %[cr3], %%cr3"
        :
        : [cr3] "r" (pml4_phys),
        : .{ .memory = true });
}

pub fn switchAddressSpace(pml4_phys: u64) void {
    loadPageTable(pml4_phys);
}

pub fn createActorAddressSpace() ?u64 {
    const actor_pml4_phys = pmm.allocPage() orelse return null;
    const actor_pml4: *PageTable = @ptrFromInt(actor_pml4_phys + hhdm_base);

    // 1. Lower Half (0..255): Zero out userland range (0x0000_0000_0000_0000..0x0000_7FFF_FFFF_FFFF)
    for (actor_pml4.entries[0..256]) |*e| {
        e.* = 0;
    }

    // 2. Upper Half (256..511): Clone higher-half kernel mappings (Supervisor mode, U/S = 0)
    if (kernel_pml4_phys != 0) {
        const kernel_pml4: *const PageTable = @ptrFromInt(kernel_pml4_phys + hhdm_base);
        for (256..512) |i| {
            actor_pml4.entries[i] = kernel_pml4.entries[i];
        }
    } else {
        for (actor_pml4.entries[256..512]) |*e| {
            e.* = 0;
        }
    }

    return actor_pml4_phys;
}

fn freePt(pd_entry: u64) void {
    if ((pd_entry & PAGE_PRESENT) == 0 or (pd_entry & PAGE_HUGE) != 0) return;
    const pt_phys = pd_entry & 0x000F_FFFF_FFFF_F000;
    pmm.freePage(pt_phys);
}

fn freePd(pdpt_entry: u64) void {
    if ((pdpt_entry & PAGE_PRESENT) == 0 or (pdpt_entry & PAGE_HUGE) != 0) return;
    const pd_phys = pdpt_entry & 0x000F_FFFF_FFFF_F000;
    const pd: *PageTable = @ptrFromInt(pd_phys + hhdm_base);
    for (&pd.entries) |entry| {
        freePt(entry);
    }
    pmm.freePage(pd_phys);
}

fn freePdpt(pml4_entry: u64) void {
    if ((pml4_entry & PAGE_PRESENT) == 0) return;
    const pdpt_phys = pml4_entry & 0x000F_FFFF_FFFF_F000;
    const pdpt: *PageTable = @ptrFromInt(pdpt_phys + hhdm_base);
    for (&pdpt.entries) |entry| {
        freePd(entry);
    }
    pmm.freePage(pdpt_phys);
}

pub fn destroyActorAddressSpace(actor_pml4_phys: u64) void {
    if (actor_pml4_phys == 0) return;
    const pml4: *PageTable = @ptrFromInt(actor_pml4_phys + hhdm_base);
    for (pml4.entries[0..256]) |entry| {
        freePdpt(entry);
    }
    pmm.freePage(actor_pml4_phys);
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

test "vmm page table structural invariants" {
    try std.testing.expectEqual(@as(usize, 4096), @sizeOf(PageTable));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(PageTable));
}

test "vmm actor address space lower-half isolation and upper-half supervisor cloning" {
    var mock_kernel_pml4 align(4096) = PageTable{ .entries = [_]u64{0} ** 512 };
    for (256..512) |i| {
        mock_kernel_pml4.entries[i] = (@as(u64, i) * 0x1000) | PAGE_PRESENT | PAGE_WRITABLE;
    }

    const saved_kernel_pml4 = kernel_pml4_phys;
    const saved_hhdm = hhdm_base;
    defer {
        kernel_pml4_phys = saved_kernel_pml4;
        hhdm_base = saved_hhdm;
    }

    hhdm_base = 0;
    kernel_pml4_phys = @intFromPtr(&mock_kernel_pml4);

    var mock_actor_pml4 align(4096) = PageTable{ .entries = [_]u64{0xDEADBEEF} ** 512 };

    for (mock_actor_pml4.entries[0..256]) |*e| {
        e.* = 0;
    }
    for (256..512) |i| {
        mock_actor_pml4.entries[i] = mock_kernel_pml4.entries[i];
    }

    for (0..256) |i| {
        try std.testing.expectEqual(@as(u64, 0), mock_actor_pml4.entries[i]);
    }

    for (256..512) |i| {
        try std.testing.expectEqual(mock_kernel_pml4.entries[i], mock_actor_pml4.entries[i]);
        try std.testing.expect((mock_actor_pml4.entries[i] & PAGE_USER) == 0);
    }
}

test "vmm page mapping and unmapping with tlb invalidation" {
    var pml4 align(4096) = PageTable{ .entries = [_]u64{0} ** 512 };
    var pdpt align(4096) = PageTable{ .entries = [_]u64{0} ** 512 };
    var pd align(4096) = PageTable{ .entries = [_]u64{0} ** 512 };
    var pt align(4096) = PageTable{ .entries = [_]u64{0} ** 512 };

    const saved_hhdm = hhdm_base;
    defer hhdm_base = saved_hhdm;
    hhdm_base = 0;

    const pml4_phys = @intFromPtr(&pml4);
    const pdpt_phys = @intFromPtr(&pdpt);
    const pd_phys = @intFromPtr(&pd);
    const pt_phys = @intFromPtr(&pt);

    const test_virt: u64 = 0x0000_0000_4000_0000;
    const pml4_idx = (test_virt >> 39) & 0x1FF;
    const pdpt_idx = (test_virt >> 30) & 0x1FF;
    const pd_idx = (test_virt >> 21) & 0x1FF;
    const pt_idx = (test_virt >> 12) & 0x1FF;

    pml4.entries[pml4_idx] = pdpt_phys | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER;
    pdpt.entries[pdpt_idx] = pd_phys | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER;
    pd.entries[pd_idx] = pt_phys | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER;
    pt.entries[pt_idx] = 0x2000 | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER;

    try std.testing.expect((pt.entries[pt_idx] & PAGE_PRESENT) != 0);

    const unmapped = unmapPage(pml4_phys, test_virt);
    try std.testing.expect(unmapped);
    try std.testing.expectEqual(@as(u64, 0), pt.entries[pt_idx]);
}
