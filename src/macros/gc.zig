// Macros Sovereign Immix Mark-Region Garbage Collector (gc.zig)
// Consolidates Immix allocator with 32 KiB blocks and 256-byte lines.
// Implements SPEC-TECH-LANG-002 Section 4.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const BLOCK_SIZE: usize = 32768; // 32 KiB (32 * 1024)
pub const LINE_SIZE: usize = 256; // 256 bytes
pub const LINES_PER_BLOCK: usize = BLOCK_SIZE / LINE_SIZE; // 128 lines
pub const LARGE_OBJECT_THRESHOLD: usize = 4096; // 4 KiB
pub const PAGE_ALIGNMENT = std.mem.Alignment.fromByteUnits(4096);
pub const DEFAULT_GC_THRESHOLD: usize = 64 * 1024; // 64 KiB
pub const MAX_HEAP_BLOCKS: usize = 512; // 16 MiB max heap safety limit
pub const GC_GROWTH_FACTOR: usize = 2;

pub const LineState = enum(u8) {
    free = 0,
    allocated = 1,
    marked = 2,
};

pub const Block = struct {
    memory: []align(4096) u8,
    line_marks: [LINES_PER_BLOCK]LineState,
    cursor: usize,
    limit: usize,
    marked_count: usize,

    pub fn init(allocator: Allocator) !*Block {
        const b = try allocator.create(Block);
        b.memory = try allocator.alignedAlloc(u8, PAGE_ALIGNMENT, BLOCK_SIZE);
        @memset(b.memory, 0);
        @memset(&b.line_marks, .free);
        b.cursor = 0;
        b.limit = BLOCK_SIZE;
        b.marked_count = 0;
        return b;
    }

    pub fn deinit(self: *Block, allocator: Allocator) void {
        allocator.free(self.memory);
        allocator.destroy(self);
    }

    fn findHoleEnd(self: *const Block, start: usize) usize {
        var end = start;
        while (end < LINES_PER_BLOCK and self.line_marks[end] == .free) : (end += 1) {}
        return end;
    }

    pub fn resetHoles(self: *Block) void {
        var i: usize = 0;
        while (i < LINES_PER_BLOCK) : (i += 1) {
            if (self.line_marks[i] == .free) {
                self.cursor = i * LINE_SIZE;
                self.limit = self.findHoleEnd(i) * LINE_SIZE;
                return;
            }
        }
        self.cursor = BLOCK_SIZE;
        self.limit = BLOCK_SIZE;
    }
};

pub const Heap = struct {
    base_allocator: Allocator,
    blocks: std.ArrayList(*Block),
    los: std.ArrayList(struct { mem: []align(4096) u8, marked: bool }),
    active_block: ?*Block,
    bytes_allocated: usize,
    gc_threshold: usize = DEFAULT_GC_THRESHOLD,
    gc_callback: ?*const fn (ctx: *anyopaque) void = null,
    gc_ctx: ?*anyopaque = null,
    in_gc: bool = false,
    max_blocks: usize = MAX_HEAP_BLOCKS,

    pub fn init(base_allocator: Allocator) Heap {
        return .{
            .base_allocator = base_allocator,
            .blocks = .empty,
            .los = .empty,
            .active_block = null,
            .bytes_allocated = 0,
            .gc_threshold = DEFAULT_GC_THRESHOLD,
            .gc_callback = null,
            .gc_ctx = null,
            .in_gc = false,
            .max_blocks = MAX_HEAP_BLOCKS,
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

    fn maybeTriggerGc(self: *Heap, needed: usize) void {
        if ((self.bytes_allocated + needed) >= self.gc_threshold and !self.in_gc) {
            if (self.gc_callback) |cb| {
                self.in_gc = true;
                cb(self.gc_ctx orelse @ptrCast(self));
                self.in_gc = false;
                self.gc_threshold = @max(self.bytes_allocated * GC_GROWTH_FACTOR, DEFAULT_GC_THRESHOLD);
            }
        }
    }

    fn findHoleInBlocks(self: *Heap, alloc_size: usize, size: usize) ?[]u8 {
        for (self.blocks.items) |block| {
            if (self.findHoleAndAlloc(block, alloc_size, size)) |ptr| {
                self.active_block = block;
                return ptr;
            }
        }
        return null;
    }

    pub fn alloc(self: *Heap, size: usize) ![]u8 {
        const alloc_size = std.mem.alignForward(usize, size, LINE_SIZE);
        if (alloc_size >= LARGE_OBJECT_THRESHOLD) return self.allocLarge(alloc_size, size);

        self.maybeTriggerGc(alloc_size);

        if (self.active_block) |block| {
            if (self.allocInBlock(block, alloc_size, size)) |ptr| return ptr;
        }

        if (self.findHoleInBlocks(alloc_size, size)) |ptr| return ptr;

        try self.allocateNewBlock();
        const block = self.active_block.?;
        if (self.allocInBlock(block, alloc_size, size)) |ptr| return ptr;
        return error.OutOfMemory;
    }

    fn allocLarge(self: *Heap, alloc_size: usize, orig_size: usize) ![]u8 {
        self.maybeTriggerGc(alloc_size);
        const mem_len = std.mem.alignForward(usize, alloc_size, 4096);
        const ptr = try self.base_allocator.alignedAlloc(u8, PAGE_ALIGNMENT, mem_len);
        @memset(ptr, 0);
        try self.los.append(self.base_allocator, .{ .mem = ptr, .marked = false });
        self.bytes_allocated += orig_size;
        return ptr[0..orig_size];
    }

    fn allocInBlock(self: *Heap, block: *Block, alloc_size: usize, orig_size: usize) ?[]u8 {
        const next_cursor = block.cursor + alloc_size;
        if (next_cursor <= block.limit) {
            const ptr = block.memory[block.cursor..next_cursor];
            @memset(ptr, 0);
            self.markLines(block, block.cursor, alloc_size, .allocated);
            block.cursor = next_cursor;
            self.bytes_allocated += orig_size;
            return ptr[0..orig_size];
        }
        return self.findHoleAndAlloc(block, alloc_size, orig_size);
    }

    fn findHoleAndAlloc(self: *Heap, block: *Block, alloc_size: usize, orig_size: usize) ?[]u8 {
        var line = block.cursor / LINE_SIZE;
        while (line < LINES_PER_BLOCK) {
            if (block.line_marks[line] != .free) {
                line += 1;
                continue;
            }
            const hole_end = self.findHoleEnd(block, line);
            if ((hole_end - line) * LINE_SIZE >= alloc_size) {
                return self.allocateFromHole(block, line, hole_end, alloc_size, orig_size);
            }
            line = hole_end;
        }
        return null;
    }

    fn findHoleEnd(self: *Heap, block: *Block, start: usize) usize {
        _ = self;
        var end = start;
        while (end < LINES_PER_BLOCK and block.line_marks[end] == .free) : (end += 1) {}
        return end;
    }

    fn allocateFromHole(self: *Heap, block: *Block, start: usize, end: usize, alloc_sz: usize, orig_sz: usize) []u8 {
        block.cursor = start * LINE_SIZE;
        block.limit = end * LINE_SIZE;
        const next_cursor = block.cursor + alloc_sz;
        const ptr = block.memory[block.cursor..next_cursor];
        @memset(ptr, 0); // Zero recycled memory to eliminate zombie references
        self.markLines(block, block.cursor, alloc_sz, .allocated);
        block.cursor = next_cursor;
        self.bytes_allocated += orig_sz;
        return ptr[0..orig_sz];
    }

    fn markLines(self: *Heap, block: *Block, start: usize, size: usize, state: LineState) void {
        _ = self;
        if (size == 0) return;
        const start_l = start / LINE_SIZE;
        const end_l = (start + size - 1) / LINE_SIZE;
        var l = start_l;
        while (l <= end_l and l < LINES_PER_BLOCK) : (l += 1) {
            block.line_marks[l] = state;
        }
    }

    pub fn clearMarks(self: *Heap) void {
        for (self.blocks.items) |block| {
            self.clearBlockMarks(block);
        }
    }

    fn clearBlockMarks(self: *Heap, block: *Block) void {
        _ = self;
        for (&block.line_marks) |*m| {
            if (m.* == .marked) m.* = .allocated;
        }
        block.marked_count = 0;
    }

    pub fn markSlice(self: *Heap, ptr_raw: [*]const u8, size: usize) void {
        const ptr_int = @intFromPtr(ptr_raw);
        for (self.blocks.items) |block| {
            const start = @intFromPtr(block.memory.ptr);
            const end = start + BLOCK_SIZE;
            if (ptr_int >= start and ptr_int < end) {
                const offset = ptr_int - start;
                self.markLines(block, offset, size, .marked);
                block.marked_count += 1;
                return;
            }
        }
        for (self.los.items) |*lo| {
            const start = @intFromPtr(lo.mem.ptr);
            const end = start + lo.mem.len;
            if (ptr_int >= start and ptr_int < end) {
                lo.marked = true;
                return;
            }
        }
    }

    fn sweepBlockLines(block: *Block) usize {
        var allocated_lines: usize = 0;
        for (&block.line_marks) |*m| {
            if (m.* == .marked) {
                m.* = .allocated;
                allocated_lines += 1;
            } else if (m.* == .allocated) {
                m.* = .free;
            }
        }
        return allocated_lines;
    }

    pub fn sweep(self: *Heap) void {
        var surviving_bytes: usize = 0;
        var i: usize = 0;
        while (i < self.blocks.items.len) {
            const block = self.blocks.items[i];
            const allocated_lines = sweepBlockLines(block);
            if (allocated_lines == 0 and block != self.active_block) {
                _ = self.blocks.orderedRemove(i);
                block.deinit(self.base_allocator);
                continue;
            }
            surviving_bytes += allocated_lines * LINE_SIZE;
            block.resetHoles();
            i += 1;
        }
        surviving_bytes += self.sweepLos();
        self.bytes_allocated = surviving_bytes;
    }

    fn sweepLos(self: *Heap) usize {
        var surviving: usize = 0;
        var j: usize = 0;
        while (j < self.los.items.len) {
            var lo = &self.los.items[j];
            if (!lo.marked) {
                self.base_allocator.free(lo.mem);
                _ = self.los.orderedRemove(j);
                continue;
            }
            surviving += lo.mem.len;
            lo.marked = false;
            j += 1;
        }
        return surviving;
    }

    fn allocateNewBlock(self: *Heap) !void {
        if (self.blocks.items.len >= self.max_blocks) return error.OutOfMemory;
        const new_block = try Block.init(self.base_allocator);
        try self.blocks.append(self.base_allocator, new_block);
        self.active_block = new_block;
    }
};

test "Heap init and basic allocation" {
    const testing = std.testing;
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const ptr = try heap.alloc(1024);
    try testing.expectEqual(@as(usize, 1024), ptr.len);
    try testing.expect(heap.blocks.items.len == 1);
}

test "Heap multi block and hole recycling" {
    const testing = std.testing;
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // 2048 * 17 = 34816 > 32768 (BLOCK_SIZE), forces second block allocation
    var i: usize = 0;
    var last_ptr: []u8 = undefined;
    while (i < 18) : (i += 1) {
        last_ptr = try heap.alloc(2048);
        try testing.expectEqual(@as(usize, 2048), last_ptr.len);
    }

    try testing.expect(heap.blocks.items.len >= 2);

    // Mark last_ptr and sweep
    heap.markSlice(last_ptr.ptr, last_ptr.len);
    heap.sweep();
}

test "Heap large object allocation" {
    const testing = std.testing;
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const large = try heap.alloc(8192);
    try testing.expectEqual(@as(usize, 8192), large.len);
    try testing.expect(heap.los.items.len == 1);

    heap.markSlice(large.ptr, large.len);
    heap.sweep();
    try testing.expect(heap.los.items.len == 1);

    heap.sweep(); // Unmarked, should be freed
    try testing.expect(heap.los.items.len == 0);
}

var gc_test_counter: usize = 0;
fn testGcCallback(ctx: *anyopaque) void {
    _ = ctx;
    gc_test_counter += 1;
}

test "Heap adaptive GC callback and block limits" {
    const testing = std.testing;
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    gc_test_counter = 0;
    heap.gc_threshold = 1024;
    heap.gc_callback = testGcCallback;

    _ = try heap.alloc(512);
    try testing.expectEqual(@as(usize, 0), gc_test_counter);

    _ = try heap.alloc(600); // Exceeds threshold
    try testing.expectEqual(@as(usize, 1), gc_test_counter);

    heap.max_blocks = 2;
    var oom_triggered = false;
    for (0..40) |_| {
        _ = heap.alloc(2048) catch |err| {
            if (err == error.OutOfMemory) {
                oom_triggered = true;
                break;
            }
            return err;
        };
    }
    try testing.expect(oom_triggered);
}
