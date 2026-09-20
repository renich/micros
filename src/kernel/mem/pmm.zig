// Physical Memory Manager (PMM) - Bitmap Page Frame Allocator

const std = @import("std");
const boot_info_mod = @import("../boot_info.zig");
const BootInfo = boot_info_mod.BootInfo;
const io = @import("../arch/x86_64/io.zig");

pub const PAGE_SIZE: usize = 4096;

var bitmap_ptr: [*]u8 = undefined;
var total_pages: usize = 0;
var free_pages: usize = 0;
var last_alloc_index: usize = 0;
var pmm_lock = std.atomic.Value(bool).init(false);

fn acquirePmmLock() u64 {
    const rflags = io.pushfqAndCli();
    while (pmm_lock.swap(true, .acquire)) {
        io.pause();
    }
    return rflags;
}

fn releasePmmLock(rflags: u64) void {
    pmm_lock.store(false, .release);
    io.popfq(rflags);
}

fn setBit(page: usize) void {
    bitmap_ptr[page / 8] |= @as(u8, 1) << @intCast(page % 8);
}

fn clearBit(page: usize) void {
    bitmap_ptr[page / 8] &= ~(@as(u8, 1) << @intCast(page % 8));
}

fn testBit(page: usize) bool {
    return (bitmap_ptr[page / 8] & (@as(u8, 1) << @intCast(page % 8))) != 0;
}

fn findMaxPhysAddr(info: *const BootInfo) u64 {
    var max_phys_addr: u64 = 0;
    var i: usize = 0;
    while (i < info.memory_map_entries) : (i += 1) {
        const desc = info.memory_map_ptr[i];
        const end_addr = desc.physical_start + desc.number_of_pages * PAGE_SIZE;
        if (end_addr > max_phys_addr) {
            max_phys_addr = end_addr;
        }
    }
    return max_phys_addr;
}

fn placeBitmap(info: *const BootInfo, bitmap_bytes: usize) ?u64 {
    var i: usize = 0;
    while (i < info.memory_map_entries) : (i += 1) {
        const desc = info.memory_map_ptr[i];
        if (desc.type == .usable and desc.number_of_pages * PAGE_SIZE >= bitmap_bytes) {
            bitmap_ptr = @ptrFromInt(desc.physical_start + info.hhdm_offset);
            return desc.physical_start;
        }
    }
    return null;
}

fn freeUsableRegions(info: *const BootInfo) void {
    var i: usize = 0;
    while (i < info.memory_map_entries) : (i += 1) {
        const desc = info.memory_map_ptr[i];
        if (desc.type == .usable) {
            const start_page = desc.physical_start / PAGE_SIZE;
            for (0..desc.number_of_pages) |page_offset| {
                clearBit(start_page + page_offset);
                free_pages += 1;
            }
        }
    }
}

fn reserveRange(phys_base: u64, size_bytes: usize) void {
    if (phys_base == 0 or size_bytes == 0) return;
    const start_page: usize = @intCast(phys_base / PAGE_SIZE);
    const page_count = (size_bytes + PAGE_SIZE - 1) / PAGE_SIZE;
    for (0..page_count) |p| {
        const page = start_page + p;
        if (page < total_pages) {
            if (!testBit(page)) {
                setBit(page);
                if (free_pages > 0) free_pages -= 1;
            }
        }
    }
}

fn reserveCriticalPages(info: *const BootInfo, bitmap_phys: u64, bitmap_bytes: usize) void {
    if (!testBit(0)) {
        setBit(0);
        if (free_pages > 0) free_pages -= 1;
    }
    reserveRange(bitmap_phys, bitmap_bytes);
    reserveRange(info.kernel_physical_base, info.kernel_size_bytes);
    reserveRange(info.bundle_base, info.bundle_size);
}

pub fn init(info: *const BootInfo) void {
    const max_phys_addr = findMaxPhysAddr(info);
    total_pages = @intCast(max_phys_addr / PAGE_SIZE);
    const bitmap_bytes = (total_pages + 7) / 8;

    const bitmap_phys = placeBitmap(info, bitmap_bytes) orelse return;

    for (0..bitmap_bytes) |byte_idx| {
        bitmap_ptr[byte_idx] = 0xFF;
    }
    free_pages = 0;

    freeUsableRegions(info);
    reserveCriticalPages(info, bitmap_phys, bitmap_bytes);
}

pub fn allocPage() ?u64 {
    const rflags = acquirePmmLock();
    defer releasePmmLock(rflags);

    var i: usize = last_alloc_index;
    while (i < total_pages) : (i += 1) {
        if (!testBit(i)) {
            setBit(i);
            free_pages -= 1;
            last_alloc_index = i + 1;
            return @as(u64, @intCast(i * PAGE_SIZE));
        }
    }
    var j: usize = 1;
    while (j < last_alloc_index) : (j += 1) {
        if (!testBit(j)) {
            setBit(j);
            free_pages -= 1;
            last_alloc_index = j + 1;
            return @as(u64, @intCast(j * PAGE_SIZE));
        }
    }
    return null;
}

fn findAndMarkContiguous(start: usize, limit: usize, count: usize) ?usize {
    var i = start;
    while (i + count <= limit) {
        var found = true;
        for (0..count) |offset| {
            if (testBit(i + offset)) {
                i = i + offset + 1;
                found = false;
                break;
            }
        }
        if (found) {
            for (0..count) |offset| {
                setBit(i + offset);
                free_pages -= 1;
            }
            return i;
        }
    }
    return null;
}

pub fn allocContiguousPages(count: usize) ?u64 {
    if (count == 0) return null;
    if (count == 1) return allocPage();

    const rflags = acquirePmmLock();
    defer releasePmmLock(rflags);

    if (findAndMarkContiguous(last_alloc_index, total_pages, count)) |idx| {
        last_alloc_index = idx + count;
        return @as(u64, @intCast(idx * PAGE_SIZE));
    }
    if (findAndMarkContiguous(1, last_alloc_index, count)) |idx| {
        last_alloc_index = idx + count;
        return @as(u64, @intCast(idx * PAGE_SIZE));
    }
    return null;
}

pub fn freePage(phys_addr: u64) void {
    const rflags = acquirePmmLock();
    defer releasePmmLock(rflags);

    const page = phys_addr / PAGE_SIZE;
    if (page < total_pages and testBit(page)) {
        clearBit(page);
        free_pages += 1;
        if (page < last_alloc_index) {
            last_alloc_index = page;
        }
    }
}
