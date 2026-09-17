// MicrOS (µOS) Page-Aligned Bounded Block Cache
// Implements a 64-frame (256 KiB) LRU write-back sector cache over VirtIO-Blk.
// Zero libc, explicit allocator, and mathematically enforced 4096-byte page alignment.

const std = @import("std");
const block = @import("../drivers/block.zig");

pub const PAGE_SIZE: usize = 4096;
pub const SECTOR_SIZE: usize = 512;
pub const SECTORS_PER_PAGE: usize = PAGE_SIZE / SECTOR_SIZE; // 8
pub const MAX_CACHE_PAGES: usize = 64;

pub const CacheEntry = struct {
    page_sector: u64 = 0,
    data: []align(PAGE_SIZE) u8,
    dirty: bool = false,
    valid: bool = false,
    lru_ticket: u64 = 0,
};

pub const BlockCache = struct {
    entries: [MAX_CACHE_PAGES]CacheEntry,
    allocator: std.mem.Allocator,
    next_ticket: u64,

    pub fn init(allocator: std.mem.Allocator) !BlockCache {
        var entries: [MAX_CACHE_PAGES]CacheEntry = undefined;
        for (0..MAX_CACHE_PAGES) |i| {
            const buf = try allocator.alignedAlloc(u8, comptime std.mem.Alignment.fromByteUnits(PAGE_SIZE), PAGE_SIZE);
            entries[i] = CacheEntry{
                .page_sector = 0,
                .data = buf,
                .dirty = false,
                .valid = false,
                .lru_ticket = 0,
            };
        }
        return BlockCache{
            .entries = entries,
            .allocator = allocator,
            .next_ticket = 1,
        };
    }

    pub fn deinit(self: *BlockCache) void {
        for (0..MAX_CACHE_PAGES) |i| {
            self.allocator.free(self.entries[i].data);
        }
    }

    pub fn readSector(
        self: *BlockCache,
        sector: u64,
        out_buf: *[SECTOR_SIZE]u8,
        dev: ?*block.BlockDevice,
    ) !void {
        const page_base = sector & ~@as(u64, SECTORS_PER_PAGE - 1);
        const sec_idx = @as(usize, @intCast(sector % SECTORS_PER_PAGE));
        const byte_offset = sec_idx * SECTOR_SIZE;

        const entry_idx = try self.lookupOrLoad(page_base, dev);
        const entry = &self.entries[entry_idx];
        entry.lru_ticket = self.tick();

        @memcpy(out_buf, entry.data[byte_offset .. byte_offset + SECTOR_SIZE]);
    }

    pub fn writeSector(
        self: *BlockCache,
        sector: u64,
        in_buf: *const [SECTOR_SIZE]u8,
        dev: ?*block.BlockDevice,
    ) !void {
        const page_base = sector & ~@as(u64, SECTORS_PER_PAGE - 1);
        const sec_idx = @as(usize, @intCast(sector % SECTORS_PER_PAGE));
        const byte_offset = sec_idx * SECTOR_SIZE;

        const entry_idx = try self.lookupOrLoad(page_base, dev);
        const entry = &self.entries[entry_idx];
        entry.lru_ticket = self.tick();

        @memcpy(entry.data[byte_offset .. byte_offset + SECTOR_SIZE], in_buf);
        entry.dirty = true;
    }

    pub fn flush(self: *BlockCache, dev: ?*block.BlockDevice) !void {
        const d = dev orelse return;
        for (&self.entries) |*entry| {
            if (entry.valid and entry.dirty) {
                try flushEntry(entry, d);
                entry.dirty = false;
            }
        }
    }

    fn tick(self: *BlockCache) u64 {
        const t = self.next_ticket;
        self.next_ticket +%= 1;
        return t;
    }

    fn lookupOrLoad(self: *BlockCache, page_base: u64, dev: ?*block.BlockDevice) !usize {
        for (0..MAX_CACHE_PAGES) |i| {
            if (self.entries[i].valid and self.entries[i].page_sector == page_base) {
                return i;
            }
        }
        return try self.evictAndLoad(page_base, dev);
    }

    fn evictAndLoad(self: *BlockCache, page_base: u64, dev: ?*block.BlockDevice) !usize {
        const victim_idx = self.findVictim();
        const victim = &self.entries[victim_idx];

        try flushVictim(victim, dev);

        if (dev) |d| {
            try loadEntry(victim, page_base, d);
        } else {
            @memset(victim.data, 0);
        }

        victim.page_sector = page_base;
        victim.valid = true;
        victim.dirty = false;
        return victim_idx;
    }

    fn findVictim(self: *const BlockCache) usize {
        for (0..MAX_CACHE_PAGES) |i| {
            if (!self.entries[i].valid) return i;
        }
        var oldest_idx: usize = 0;
        var lowest_ticket: u64 = std.math.maxInt(u64);
        for (0..MAX_CACHE_PAGES) |i| {
            if (self.entries[i].lru_ticket < lowest_ticket) {
                lowest_ticket = self.entries[i].lru_ticket;
                oldest_idx = i;
            }
        }
        return oldest_idx;
    }
};

fn flushVictim(victim: *CacheEntry, dev: ?*block.BlockDevice) !void {
    if (!victim.valid or !victim.dirty) return;
    const d = dev orelse return;
    try flushEntry(victim, d);
    victim.dirty = false;
}

fn flushEntry(entry: *CacheEntry, dev: *block.BlockDevice) !void {
    try dev.writeSectors(entry.page_sector, SECTORS_PER_PAGE, entry.data);
}

fn loadEntry(entry: *CacheEntry, page_base: u64, dev: *block.BlockDevice) !void {
    try dev.readSectors(page_base, SECTORS_PER_PAGE, entry.data);
}

test "block cache memory page alignment" {
    var cache = try BlockCache.init(std.testing.allocator);
    defer cache.deinit();

    for (cache.entries) |entry| {
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(entry.data.ptr) % PAGE_SIZE);
    }
}

test "block cache read and write without device" {
    var cache = try BlockCache.init(std.testing.allocator);
    defer cache.deinit();

    var write_data: [SECTOR_SIZE]u8 = undefined;
    @memset(&write_data, 0xAB);
    try cache.writeSector(12, &write_data, null);

    var read_data: [SECTOR_SIZE]u8 = undefined;
    try cache.readSector(12, &read_data, null);

    try std.testing.expectEqualSlices(u8, &write_data, &read_data);
}
