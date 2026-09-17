const std = @import("std");
const sys = @import("../sys.zig");

pub const BLOCK_SIZE: usize = 32 * 1024; // 32 KB
pub const LINE_SIZE: usize = 128; // 128 bytes
pub const LINES_PER_BLOCK: usize = BLOCK_SIZE / LINE_SIZE; // 256 lines
pub const PAGE_SIZE: usize = 4096;

pub const LineState = enum(u8) {
    free = 0,
    marked = 1,
};

pub const Block = struct {
    memory: []u8,
    line_marks: [LINES_PER_BLOCK]LineState,
    cursor: usize,
    limit: usize,
    marked_count: usize,
    next: ?*Block,

    pub fn init(mem: []u8) Block {
        var b = Block{
            .memory = mem,
            .line_marks = [_]LineState{.free} ** LINES_PER_BLOCK,
            .cursor = 0,
            .limit = BLOCK_SIZE,
            .marked_count = 0,
            .next = null,
        };
        b.resetHoles();
        return b;
    }

    pub fn resetHoles(self: *Block) void {
        self.cursor = 0;
        self.limit = BLOCK_SIZE;
        var i: usize = 0;
        while (i < LINES_PER_BLOCK) : (i += 1) {
            if (self.line_marks[i] == .free) {
                self.cursor = i * LINE_SIZE;
                break;
            }
        }
    }

    pub fn markAddress(self: *Block, ptr: *const anyopaque, size: usize) void {
        const offset = @intFromPtr(ptr) - @intFromPtr(self.memory.ptr);
        if (offset >= BLOCK_SIZE) return;

        const start_line = offset / LINE_SIZE;
        const end_line = (offset + size + LINE_SIZE - 1) / LINE_SIZE;

        var l = start_line;
        while (l < end_line and l < LINES_PER_BLOCK) : (l += 1) {
            if (self.line_marks[l] == .free) {
                self.line_marks[l] = .marked;
                self.marked_count += 1;
            }
        }
    }

    pub fn alloc(self: *Block, size: usize) ?[]u8 {
        const aligned_size = std.mem.alignForward(usize, size, 8);
        if (self.cursor + aligned_size <= self.limit) {
            const result = self.memory[self.cursor .. self.cursor + aligned_size];
            self.cursor += aligned_size;
            return result;
        }
        return self.findNextHole(aligned_size);
    }

    fn findNextHole(self: *Block, aligned_size: usize) ?[]u8 {
        const start_line = (self.cursor + LINE_SIZE - 1) / LINE_SIZE;
        var i = start_line;
        while (i < LINES_PER_BLOCK) : (i += 1) {
            if (self.line_marks[i] == .free) {
                return self.scanHoleSpan(i, aligned_size);
            }
        }
        return null;
    }

    fn scanHoleSpan(self: *Block, start: usize, aligned_size: usize) ?[]u8 {
        var end = start;
        while (end < LINES_PER_BLOCK and self.line_marks[end] == .free) : (end += 1) {}

        const hole_bytes = (end - start) * LINE_SIZE;
        if (hole_bytes >= aligned_size) {
            self.cursor = start * LINE_SIZE;
            self.limit = end * LINE_SIZE;
            const res = self.memory[self.cursor .. self.cursor + aligned_size];
            self.cursor += aligned_size;
            return res;
        }
        return null;
    }

    pub fn sweep(self: *Block) void {
        for (&self.line_marks) |*mark| {
            if (mark.* == .marked) {
                mark.* = .free;
            }
        }
        self.marked_count = 0;
        self.resetHoles();
    }
};

pub const ImmixHeap = struct {
    blocks: ?*Block,
    large_allocations: std.ArrayList([]u8),
    allocator: std.mem.Allocator,
    total_allocated: usize,

    pub fn init(allocator: std.mem.Allocator) ImmixHeap {
        return ImmixHeap{
            .blocks = null,
            .large_allocations = .empty,
            .allocator = allocator,
            .total_allocated = 0,
        };
    }

    pub fn deinit(self: *ImmixHeap) void {
        var cur = self.blocks;
        while (cur) |b| {
            const next = b.next;
            sys.mem.unmap(b.memory.ptr, BLOCK_SIZE) catch {};
            self.allocator.destroy(b);
            cur = next;
        }
        for (self.large_allocations.items) |large| {
            sys.mem.unmap(large.ptr, large.len) catch {};
        }
        self.large_allocations.deinit(self.allocator);
    }

    fn newBlock(self: *ImmixHeap) !*Block {
        const ptr = try sys.mem.map(
            null,
            BLOCK_SIZE,
            sys.mem.Prot.read | sys.mem.Prot.write,
            sys.mem.Flags.private | sys.mem.Flags.anonymous,
            -1,
            0,
        );
        const mem_slice = @as([*]u8, @ptrCast(ptr))[0..BLOCK_SIZE];

        const block = try self.allocator.create(Block);
        block.* = Block.init(mem_slice);
        block.next = self.blocks;
        self.blocks = block;
        return block;
    }

    pub fn alloc(self: *ImmixHeap, size: usize) ![]u8 {
        if (size > LINE_SIZE * 4) {
            return self.allocLarge(size);
        }

        var cur = self.blocks;
        while (cur) |b| {
            if (b.alloc(size)) |slice| {
                self.total_allocated += slice.len;
                return slice;
            }
            cur = b.next;
        }

        const fresh_block = try self.newBlock();
        const slice = fresh_block.alloc(size) orelse return error.OutOfMemory;
        self.total_allocated += slice.len;
        return slice;
    }

    fn allocLarge(self: *ImmixHeap, size: usize) ![]u8 {
        const aligned_len = std.mem.alignForward(usize, size, PAGE_SIZE);
        const ptr = try sys.mem.map(
            null,
            aligned_len,
            sys.mem.Prot.read | sys.mem.Prot.write,
            sys.mem.Flags.private | sys.mem.Flags.anonymous,
            -1,
            0,
        );
        const slice = @as([*]u8, @ptrCast(ptr))[0..aligned_len];
        try self.large_allocations.append(self.allocator, slice);
        self.total_allocated += slice.len;
        return slice[0..size];
    }

    pub fn sweep(self: *ImmixHeap) void {
        var cur = self.blocks;
        while (cur) |b| {
            b.sweep();
            cur = b.next;
        }
    }
};

const testing = std.testing;

test "ImmixHeap allocation and line hole reclamation" {
    var heap = ImmixHeap.init(testing.allocator);
    defer heap.deinit();

    const p1 = try heap.alloc(64);
    @memset(p1, 0xAA);
    try testing.expectEqual(@as(usize, 64), p1.len);

    const p2 = try heap.alloc(128);
    @memset(p2, 0xBB);
    try testing.expectEqual(@as(usize, 128), p2.len);

    // Large allocation directly mapped
    const large = try heap.alloc(8192);
    @memset(large, 0xCC);
    try testing.expectEqual(@as(usize, 8192), large.len);

    // Mark p1 and sweep
    if (heap.blocks) |b| {
        b.markAddress(p1.ptr, p1.len);
        try testing.expect(b.marked_count > 0);
    }

    heap.sweep();
    if (heap.blocks) |b| {
        try testing.expectEqual(@as(usize, 0), b.marked_count);
    }
}
