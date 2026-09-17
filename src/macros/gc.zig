const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LINE_SIZE = 256;
pub const LINES_PER_BLOCK = 128;
pub const BLOCK_SIZE = 32768; // 32 * 1024 (32 KB)

pub const Block = struct {
    memory: []u8,
    line_marks: [LINES_PER_BLOCK]u8,

    pub fn init(allocator: Allocator) !*Block {
        const b = try allocator.create(Block);
        b.memory = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), BLOCK_SIZE);
        @memset(&b.line_marks, 0);
        return b;
    }

    pub fn deinit(self: *Block, allocator: Allocator) void {
        allocator.free(self.memory);
        allocator.destroy(self);
    }
};

pub const Heap = struct {
    base_allocator: Allocator,
    blocks: std.ArrayList(*Block),
    los: std.ArrayList(struct { mem: []u8, marked: bool }),
    active_block: ?*Block,
    cursor: usize,
    limit: usize,

    pub fn init(base_allocator: Allocator) Heap {
        return .{
            .base_allocator = base_allocator,
            .blocks = .empty,
            .los = .empty,
            .active_block = null,
            .cursor = 0,
            .limit = 0,
        };
    }

    pub fn deinit(self: *Heap) void {
        for (self.blocks.items) |block| {
            block.deinit(self.base_allocator);
        }
        self.blocks.deinit(self.base_allocator);
        for (self.los.items) |large| {
            self.base_allocator.free(large.mem);
        }
        self.los.deinit(self.base_allocator);
    }

    pub fn allocator(self: *Heap) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = allocFn,
                .resize = resizeFn,
                .remap = remapFn,
                .free = freeFn,
            },
        };
    }

    fn allocFn(ptr: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ptr_align;
        _ = ret_addr;
        const self: *Heap = @ptrCast(@alignCast(ptr));
        const mem = self.alloc(len) catch return null;
        return mem.ptr;
    }

    fn resizeFn(ptr: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ptr;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    fn remapFn(ptr: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ptr;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn freeFn(ptr: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = ptr;
        _ = buf;
        _ = buf_align;
        _ = ret_addr;
    }

    pub fn alloc(self: *Heap, size: usize) ![]u8 {
        const alloc_size = std.mem.alignForward(usize, size, 8);
        if (alloc_size >= BLOCK_SIZE) {
            const ptr = try self.base_allocator.alloc(u8, alloc_size);
            try self.los.append(self.base_allocator, .{ .mem = ptr, .marked = false });
            return ptr[0..size];
        }

        if (self.active_block) |block| {
            if (self.allocInCurrentBlock(block, alloc_size)) |ptr| {
                return ptr[0..size];
            }
        }

        // Search existing blocks for holes
        for (self.blocks.items) |block| {
            if (block == self.active_block) continue;
            if (self.findHoleAndAlloc(block, alloc_size)) |ptr| {
                self.active_block = block;
                return ptr[0..size];
            }
        }

        try self.allocateNewBlock();
        const block = self.active_block.?;
        if (self.allocInCurrentBlock(block, alloc_size)) |ptr| {
            return ptr[0..size];
        }

        return error.OutOfMemory;
    }

    fn allocInCurrentBlock(self: *Heap, block: *Block, size: usize) ?[]u8 {
        const next_cursor = self.cursor + size;
        if (next_cursor <= self.limit) {
            const ptr = block.memory[self.cursor..next_cursor];
            self.cursor = next_cursor;
            self.markLinesUsed(block, self.cursor - size, size);
            return ptr;
        }
        return self.findHoleAndAlloc(block, size);
    }

    fn findHoleAndAlloc(self: *Heap, block: *Block, size: usize) ?[]u8 {
        var current_line = self.limit / LINE_SIZE;
        while (current_line < LINES_PER_BLOCK) {
            if (block.line_marks[current_line] != 0) {
                current_line += 1;
                continue;
            }
            const hole_end = self.findHoleEnd(block, current_line);
            if ((hole_end - current_line) * LINE_SIZE >= size) {
                return self.allocateFromHole(block, current_line, hole_end, size);
            }
            current_line = hole_end;
        }
        return null;
    }

    fn findHoleEnd(self: *Heap, block: *Block, start_line: usize) usize {
        _ = self;
        var end = start_line;
        while (end < LINES_PER_BLOCK and block.line_marks[end] == 0) {
            end += 1;
        }
        return end;
    }

    fn allocateFromHole(self: *Heap, block: *Block, hole_start: usize, hole_end: usize, size: usize) []u8 {
        self.cursor = hole_start * LINE_SIZE;
        self.limit = hole_end * LINE_SIZE;

        const next_cursor = self.cursor + size;
        const ptr = block.memory[self.cursor..next_cursor];
        self.cursor = next_cursor;

        self.markLinesUsed(block, hole_start * LINE_SIZE, size);

        return ptr;
    }

    fn markLinesUsed(self: *Heap, block: *Block, start_addr: usize, size: usize) void {
        _ = self;
        const start_l = start_addr / LINE_SIZE;
        // avoid subtraction underflow if size is 0
        if (size == 0) return;
        const end_l = (start_addr + size - 1) / LINE_SIZE;

        var l = start_l;
        while (l <= end_l) : (l += 1) {
            block.line_marks[l] = 1;
        }
    }

    pub fn clearMarks(self: *Heap) void {
        for (self.blocks.items) |block| {
            @memset(&block.line_marks, 0);
        }
    }

    pub fn markSlice(self: *Heap, ptr_raw: [*]const u8, size: usize) void {
        const ptr_int = @intFromPtr(ptr_raw);
        for (self.blocks.items) |block| {
            const block_start = @intFromPtr(block.memory.ptr);
            const block_end = block_start + BLOCK_SIZE;
            if (ptr_int >= block_start and ptr_int < block_end) {
                const offset = ptr_int - block_start;
                self.markLinesUsed(block, offset, size);
                return;
            }
        }
        for (self.los.items) |*lo| {
            const lo_start = @intFromPtr(lo.mem.ptr);
            const lo_end = lo_start + lo.mem.len;
            if (ptr_int >= lo_start and ptr_int < lo_end) {
                lo.marked = true;
                return;
            }
        }
    }

    pub fn sweep(self: *Heap) void {
        var i: usize = 0;
        while (i < self.blocks.items.len) {
            if (self.sweepBlock(self.blocks.items[i], i)) {
                continue;
            }
            i += 1;
        }

        var j: usize = 0;
        while (j < self.los.items.len) {
            var lo = &self.los.items[j];
            if (!lo.marked) {
                self.base_allocator.free(lo.mem);
                _ = self.los.orderedRemove(j);
                continue;
            }
            lo.marked = false;
            j += 1;
        }
    }

    fn sweepBlock(self: *Heap, block: *Block, index: usize) bool {
        for (block.line_marks) |m| {
            if (m != 0) return false;
        }
        if (block == self.active_block) return false;
        _ = self.blocks.orderedRemove(index);
        block.deinit(self.base_allocator);
        return true;
    }

    fn allocateNewBlock(self: *Heap) !void {
        const new_block = try Block.init(self.base_allocator);
        try self.blocks.append(self.base_allocator, new_block);
        self.active_block = new_block;
        self.cursor = 0;
        self.limit = BLOCK_SIZE;
    }
};

test "Heap init and deinit" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();
}

test "Heap basic alloc" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const ptr = try heap.alloc(1024);
    try std.testing.expectEqual(@as(usize, 1024), ptr.len);
    try std.testing.expect(heap.blocks.items.len == 1);
}

test "Heap multi block alloc" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    // 32KB is 32768. Alloc 16KB 3 times to force new block.
    const ptr1 = try heap.alloc(16384);
    const ptr2 = try heap.alloc(16384);
    const ptr3 = try heap.alloc(16384);

    try std.testing.expectEqual(@as(usize, 16384), ptr1.len);
    try std.testing.expectEqual(@as(usize, 16384), ptr2.len);
    try std.testing.expectEqual(@as(usize, 16384), ptr3.len);
    try std.testing.expect(heap.blocks.items.len == 2);
}
