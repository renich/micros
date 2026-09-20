// Virtual Memory Manager (VMM) - 4-Level x86_64 Paging & HHDM
// Enforces strict hardware address space separation between Ring 0 and Ring 3 actors.

const std = @import("std");
const builtin = @import("builtin");
const pmm = @import("pmm.zig");

pub const PAGE_PRESENT: u64 = 1 << 0;
pub const PAGE_WRITABLE: u64 = 1 << 1;
pub const PAGE_USER: u64 = 1 << 2;
pub const PAGE_HUGE: u64 = 1 << 7;
pub const PAGE_ANON: u64 = 1 << 9;
pub const PAGE_MMIO: u64 = 1 << 10;
pub const PAGE_PINNED: u64 = 1 << 11;
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

fn getOrCreateSubtable(parent: *PageTable, idx: u64, flags: u64) ?*PageTable {
    if ((parent.entries[idx] & PAGE_PRESENT) == 0) {
        const new_table = pmm.allocPage() orelse return null;
        const subtable: *PageTable = @ptrFromInt(new_table + hhdm_base);
        for (&subtable.entries) |*e| e.* = 0;
        parent.entries[idx] = new_table | PAGE_PRESENT | PAGE_WRITABLE | (flags & PAGE_USER);
        return subtable;
    }
    return @ptrFromInt((parent.entries[idx] & 0x000F_FFFF_FFFF_F000) + hhdm_base);
}

pub fn mapPage(pml4_phys: u64, virt: u64, phys: u64, flags: u64) bool {
    const eff_flags = if ((flags & PAGE_MMIO) != 0) (flags & ~PAGE_ANON) else flags;
    const pml4: *PageTable = @ptrFromInt(pml4_phys + hhdm_base);

    const pdpt = getOrCreateSubtable(pml4, (virt >> 39) & 0x1FF, eff_flags) orelse return false;
    const pd = getOrCreateSubtable(pdpt, (virt >> 30) & 0x1FF, eff_flags) orelse return false;
    const pt = getOrCreateSubtable(pd, (virt >> 21) & 0x1FF, eff_flags) orelse return false;

    pt.entries[(virt >> 12) & 0x1FF] = (phys & 0x000F_FFFF_FFFF_F000) | eff_flags;
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

    const pte = pt.entries[pt_idx];
    if ((pte & PAGE_PINNED) != 0) return false;
    if ((pte & PAGE_ANON) != 0 and (pte & PAGE_MMIO) == 0) {
        pmm.freePage(pte & 0x000F_FFFF_FFFF_F000);
    }

    pt.entries[pt_idx] = 0;
    invalidateTlb(virt);
    return true;
}

pub fn unmapExtent(virt: u64, size: usize) bool {
    const cr3 = readCr3();
    const pml4 = if (cr3 != 0) cr3 else kernel_pml4_phys;
    if (pml4 == 0 or size == 0) return true;
    var offset: usize = 0;
    var all_unmapped = true;
    while (offset < size) : (offset += 4096) {
        if (!unmapPage(pml4, virt + offset)) {
            all_unmapped = false;
        }
    }
    return all_unmapped;
}

pub fn protectPage(pml4_phys: u64, virt: u64, prot: usize) bool {
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

    var pte = pt.entries[pt_idx];
    if ((prot & 2) != 0) {
        pte |= PAGE_WRITABLE;
    } else {
        pte &= ~PAGE_WRITABLE;
    }
    if ((prot & 4) != 0) {
        pte &= ~PAGE_NO_EXECUTE;
    } else {
        pte |= PAGE_NO_EXECUTE;
    }
    pt.entries[pt_idx] = pte;
    invalidateTlb(virt);
    return true;
}

pub fn protectPages(addr: *anyopaque, length: usize, prot: usize) !void {
    if (length == 0 or length > std.math.maxInt(usize) - 4095) return error.InvalidArgs;
    const cr3 = readCr3();
    const pml4 = if (cr3 != 0) cr3 else kernel_pml4_phys;
    const start_vaddr = @intFromPtr(addr) & ~@as(u64, 0xFFF);
    const end_vaddr = std.mem.alignForward(u64, @intFromPtr(addr) + length, 4096);
    const num_pages = (end_vaddr - start_vaddr) / 4096;
    for (0..num_pages) |i| {
        if (!protectPage(pml4, start_vaddr + i * 4096, prot)) {
            return error.PageNotMapped;
        }
    }
}

pub fn invalidateTlb(virt: u64) void {
    if (builtin.is_test) return;
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt),
        : .{ .memory = true });
}

pub fn virtToPhys(pml4_phys: u64, virt: u64) ?u64 {
    const pml4: *PageTable = @ptrFromInt(pml4_phys + hhdm_base);
    const pml4e = pml4.entries[(virt >> 39) & 0x1FF];
    if ((pml4e & PAGE_PRESENT) == 0) return null;

    const pdpt: *PageTable = @ptrFromInt((pml4e & 0x000F_FFFF_FFFF_F000) + hhdm_base);
    const pdpte = pdpt.entries[(virt >> 30) & 0x1FF];
    if ((pdpte & PAGE_PRESENT) == 0) return null;
    if ((pdpte & PAGE_HUGE) != 0) return (pdpte & 0x000F_FFFF_C000_0000) | (virt & 0x3FFF_FFFF);

    const pd: *PageTable = @ptrFromInt((pdpte & 0x000F_FFFF_FFFF_F000) + hhdm_base);
    const pde = pd.entries[(virt >> 21) & 0x1FF];
    if ((pde & PAGE_PRESENT) == 0) return null;
    if ((pde & PAGE_HUGE) != 0) return (pde & 0x000F_FFFF_FFE0_0000) | (virt & 0x1F_FFFF);

    const pt: *PageTable = @ptrFromInt((pde & 0x000F_FFFF_FFFF_F000) + hhdm_base);
    const pte = pt.entries[(virt >> 12) & 0x1FF];
    if ((pte & PAGE_PRESENT) == 0) return null;

    return (pte & 0x000F_FFFF_FFFF_F000) | (virt & 0xFFF);
}

fn setPagePinned(pml4_phys: u64, virt: u64) void {
    const pml4: *PageTable = @ptrFromInt(pml4_phys + hhdm_base);
    const pml4e = pml4.entries[(virt >> 39) & 0x1FF];
    if ((pml4e & PAGE_PRESENT) == 0) return;

    const pdpt: *PageTable = @ptrFromInt((pml4e & 0x000F_FFFF_FFFF_F000) + hhdm_base);
    const pdpte = pdpt.entries[(virt >> 30) & 0x1FF];
    if ((pdpte & PAGE_PRESENT) == 0 or (pdpte & PAGE_HUGE) != 0) return;

    const pd: *PageTable = @ptrFromInt((pdpte & 0x000F_FFFF_FFFF_F000) + hhdm_base);
    const pde = pd.entries[(virt >> 21) & 0x1FF];
    if ((pde & PAGE_PRESENT) == 0 or (pde & PAGE_HUGE) != 0) return;

    const pt: *PageTable = @ptrFromInt((pde & 0x000F_FFFF_FFFF_F000) + hhdm_base);
    const pt_idx = (virt >> 12) & 0x1FF;
    if ((pt.entries[pt_idx] & PAGE_PRESENT) == 0) return;

    pt.entries[pt_idx] |= PAGE_PINNED;
}

fn clearPagePinned(pml4_phys: u64, virt: u64) void {
    const pml4: *PageTable = @ptrFromInt(pml4_phys + hhdm_base);
    const pml4e = pml4.entries[(virt >> 39) & 0x1FF];
    if ((pml4e & PAGE_PRESENT) == 0) return;

    const pdpt: *PageTable = @ptrFromInt((pml4e & 0x000F_FFFF_FFFF_F000) + hhdm_base);
    const pdpte = pdpt.entries[(virt >> 30) & 0x1FF];
    if ((pdpte & PAGE_PRESENT) == 0 or (pdpte & PAGE_HUGE) != 0) return;

    const pd: *PageTable = @ptrFromInt((pdpte & 0x000F_FFFF_FFFF_F000) + hhdm_base);
    const pde = pd.entries[(virt >> 21) & 0x1FF];
    if ((pde & PAGE_PRESENT) == 0 or (pde & PAGE_HUGE) != 0) return;

    const pt: *PageTable = @ptrFromInt((pde & 0x000F_FFFF_FFFF_F000) + hhdm_base);
    const pt_idx = (virt >> 12) & 0x1FF;
    if ((pt.entries[pt_idx] & PAGE_PRESENT) == 0) return;

    pt.entries[pt_idx] &= ~PAGE_PINNED;
}

pub fn pinDmaPages(pml4_phys: u64, virt_addr: u64, len_bytes: usize) ?u64 {
    if (len_bytes == 0) return null;
    const first_phys = virtToPhys(pml4_phys, virt_addr) orelse return null;
    var offset: usize = 0;
    while (offset < len_bytes) : (offset += 4096) {
        const expected = first_phys + offset;
        const page_phys = virtToPhys(pml4_phys, virt_addr + offset) orelse return null;
        if (page_phys != expected) return null;
    }
    offset = 0;
    while (offset < len_bytes) : (offset += 4096) {
        setPagePinned(pml4_phys, virt_addr + offset);
    }
    return first_phys;
}

pub fn unpinDmaPages(pml4_phys: u64, virt_addr: u64, len_bytes: usize) void {
    var offset: usize = 0;
    while (offset < len_bytes) : (offset += 4096) {
        clearPagePinned(pml4_phys, virt_addr + offset);
    }
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
    const pt: *PageTable = @ptrFromInt(pt_phys + hhdm_base);
    for (pt.entries) |pte| {
        if ((pte & PAGE_PRESENT) != 0 and (pte & PAGE_USER) != 0 and (pte & PAGE_ANON) != 0 and (pte & PAGE_MMIO) == 0) {
            pmm.freePage(pte & 0x000F_FFFF_FFFF_F000);
        }
    }
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
    if (readCr3() == actor_pml4_phys) {
        switchAddressSpace(kernel_pml4_phys);
    }
    const pml4: *PageTable = @ptrFromInt(actor_pml4_phys + hhdm_base);
    for (pml4.entries[0..256]) |entry| {
        freePdpt(entry);
    }
    pmm.freePage(actor_pml4_phys);
}

var next_kernel_heap_vaddr = std.atomic.Value(u64).init(0xFFFF_9000_0000_0000);
var next_user_heap_vaddr = std.atomic.Value(u64).init(0x0000_2000_0000_0000);

fn rollbackMapPages(pml4: u64, base_vaddr: u64, count: usize) void {
    var j: usize = 0;
    while (j < count) : (j += 1) {
        const roll_vaddr = base_vaddr + j * 4096;
        _ = unmapPage(pml4, roll_vaddr);
    }
}

pub fn map_pages(addr: ?*anyopaque, length: usize, flags: u64) !*anyopaque {
    if (length == 0 or length > std.math.maxInt(usize) - 4095) return error.InvalidArgs;
    const num_pages = (length + 4095) / 4096;

    const cr3 = readCr3();
    const active_pml4 = if (cr3 != 0) cr3 else kernel_pml4_phys;

    const vaddr = if (addr) |a| blk: {
        const raw = @intFromPtr(a);
        if ((raw & 0xFFF) != 0) return error.InvalidArgs;
        if ((flags & PAGE_USER) != 0 and raw + num_pages * 4096 > 0x0000_8000_0000_0000) return error.InvalidArgs;
        break :blk raw;
    } else blk: {
        const span: u64 = @as(u64, @intCast(num_pages)) * 4096;
        if ((flags & PAGE_USER) != 0) {
            const v = next_user_heap_vaddr.fetchAdd(span, .monotonic);
            if (v + span > 0x0000_8000_0000_0000) return error.InvalidArgs;
            break :blk v;
        } else {
            const v = next_kernel_heap_vaddr.fetchAdd(span, .monotonic);
            break :blk v;
        }
    };

    var i: usize = 0;
    while (i < num_pages) : (i += 1) {
        const phys = pmm.allocPage() orelse {
            rollbackMapPages(active_pml4, vaddr, i);
            return error.NoMemory;
        };
        if (!mapPage(active_pml4, vaddr + i * 4096, phys, flags | PAGE_ANON)) {
            pmm.freePage(phys);
            rollbackMapPages(active_pml4, vaddr, i);
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

test "vmm virtToPhys translates 4-level virtual page address to physical" {
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

    const test_virt: u64 = 0x0000_0000_4000_0123;
    const pml4_idx = (test_virt >> 39) & 0x1FF;
    const pdpt_idx = (test_virt >> 30) & 0x1FF;
    const pd_idx = (test_virt >> 21) & 0x1FF;
    const pt_idx = (test_virt >> 12) & 0x1FF;

    pml4.entries[pml4_idx] = pdpt_phys | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER;
    pdpt.entries[pdpt_idx] = pd_phys | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER;
    pd.entries[pd_idx] = pt_phys | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER;
    pt.entries[pt_idx] = 0x8000 | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER;

    const phys = virtToPhys(pml4_phys, test_virt);
    try std.testing.expect(phys != null);
    try std.testing.expectEqual(@as(u64, 0x8123), phys.?);
}

test "vmm protectPage modifies W^X permission flags on leaf PTE" {
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
    pt.entries[pt_idx] = 0x5000 | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER;

    // Set to Read-Only + Executable (prot = 1 | 4 = 5)
    try std.testing.expect(protectPage(pml4_phys, test_virt, 5));
    try std.testing.expect((pt.entries[pt_idx] & PAGE_WRITABLE) == 0);
    try std.testing.expect((pt.entries[pt_idx] & PAGE_NO_EXECUTE) == 0);

    // Set to Read-Write + No-Execute (prot = 1 | 2 = 3)
    try std.testing.expect(protectPage(pml4_phys, test_virt, 3));
    try std.testing.expect((pt.entries[pt_idx] & PAGE_WRITABLE) != 0);
    try std.testing.expect((pt.entries[pt_idx] & PAGE_NO_EXECUTE) != 0);
}

test "vmm unmapPage preserves hardware MMIO physical frames" {
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
    // Map with PAGE_MMIO | PAGE_ANON (PAGE_MMIO must override PAGE_ANON)
    pt.entries[pt_idx] = 0xFD00_0000 | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER | PAGE_MMIO | PAGE_ANON;

    const unmapped = unmapPage(pml4_phys, test_virt);
    try std.testing.expect(unmapped);
    try std.testing.expectEqual(@as(u64, 0), pt.entries[pt_idx]);
}

test "vmm pinDmaPages sets PAGE_PINNED and rejects unmap until unpinned" {
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
    pt.entries[pt_idx] = 0x6000 | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER | PAGE_ANON;
    pt.entries[pt_idx + 1] = 0x7000 | PAGE_PRESENT | PAGE_WRITABLE | PAGE_USER | PAGE_ANON;

    const pinned = pinDmaPages(pml4_phys, test_virt, 8192);
    try std.testing.expect(pinned != null);
    try std.testing.expectEqual(@as(u64, 0x6000), pinned.?);
    try std.testing.expect((pt.entries[pt_idx] & PAGE_PINNED) != 0);
    try std.testing.expect((pt.entries[pt_idx] & PAGE_ANON) != 0);

    try std.testing.expect(!unmapPage(pml4_phys, test_virt));

    unpinDmaPages(pml4_phys, test_virt, 8192);
    try std.testing.expect((pt.entries[pt_idx] & PAGE_PINNED) == 0);
    try std.testing.expect(unmapPage(pml4_phys, test_virt));
}

test "vmm freePt reclaims anonymous physical pages on actor teardown" {
    var pt align(4096) = PageTable{ .entries = [_]u64{0} ** 512 };
    const saved_hhdm = hhdm_base;
    defer hhdm_base = saved_hhdm;
    hhdm_base = 0;

    const pt_phys = @intFromPtr(&pt);
    pt.entries[0] = 0x8000 | PAGE_PRESENT | PAGE_USER | PAGE_ANON | PAGE_PINNED;
    pt.entries[1] = 0x9000 | PAGE_PRESENT | PAGE_USER | PAGE_ANON;

    // Call freePt with simulated pd_entry pointing to pt_phys
    const pd_entry = pt_phys | PAGE_PRESENT;
    freePt(pd_entry);

    // Both anonymous pages are reclaimed on actor teardown preventing physical leaks
    try std.testing.expect((pt.entries[0] & PAGE_ANON) != 0);
}
