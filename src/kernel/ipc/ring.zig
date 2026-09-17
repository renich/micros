// MicrOS (µOS) Typed Lock-Free IPC Ring Buffer
// Zero-copy, single-producer single-consumer (SPSC) shared-memory queue.
// Eradicates unstructured ASCII byte pipes in favor of 64-byte typed frames.

const std = @import("std");

pub const MessageType = enum(u16) {
    null_msg = 0x0000,
    telemetry = 0x0001,
    stream_data = 0x0002,
    capability_grant = 0x0003,
    event_signal = 0x0004,
    yield_request = 0x0005,
};

pub const MessageFrame = extern struct {
    msg_type: MessageType align(64),
    flags: u16,
    sequence: u32,
    payload_len: u32,
    reserved: u32,
    payload: [48]u8,

    pub const EMPTY = MessageFrame{
        .msg_type = .null_msg,
        .flags = 0,
        .sequence = 0,
        .payload_len = 0,
        .reserved = 0,
        .payload = [_]u8{0} ** 48,
    };

    pub fn init(msg_type: MessageType, seq: u32, data: []const u8) MessageFrame {
        var frame = EMPTY;
        frame.msg_type = msg_type;
        frame.sequence = seq;
        const copy_len = @min(data.len, 48);
        frame.payload_len = @intCast(copy_len);
        @memcpy(frame.payload[0..copy_len], data[0..copy_len]);
        return frame;
    }
};

comptime {
    std.debug.assert(@sizeOf(MessageFrame) == 64);
    std.debug.assert(@alignOf(MessageFrame) == 64);
}

pub const DEFAULT_RING_CAPACITY: usize = 64; // 64 * 64 bytes = 4096 bytes (1 page)

pub const RingBuffer = struct {
    frames: []MessageFrame,
    capacity: usize,
    mask: usize,
    head: std.atomic.Value(usize) align(64),
    tail: std.atomic.Value(usize) align(64),

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !*RingBuffer {
        if (!std.math.isPowerOfTwo(capacity)) return error.InvalidCapacity;
        const ring = try allocator.create(RingBuffer);
        errdefer allocator.destroy(ring);
        const frames = try allocator.alloc(MessageFrame, capacity);
        for (frames) |*frame| {
            frame.* = MessageFrame.EMPTY;
        }

        ring.* = RingBuffer{
            .frames = frames,
            .capacity = capacity,
            .mask = capacity - 1,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
        };
        return ring;
    }

    pub fn deinit(self: *RingBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.frames);
        allocator.destroy(self);
    }

    pub fn count(self: *const RingBuffer) usize {
        const tail = self.tail.load(.acquire);
        const head = self.head.load(.acquire);
        const diff = head -% tail;
        if (diff > self.capacity) return 0;
        return diff;
    }

    pub fn isFull(self: *const RingBuffer) bool {
        return self.count() >= self.capacity;
    }

    pub fn isEmpty(self: *const RingBuffer) bool {
        return self.count() == 0;
    }

    pub fn push(self: *RingBuffer, frame: MessageFrame) bool {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        if (head -% tail >= self.capacity) return false;

        const idx = head & self.mask;
        self.frames[idx] = frame;
        self.head.store(head +% 1, .release);
        return true;
    }

    pub fn pop(self: *RingBuffer) ?MessageFrame {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        if (head == tail) return null;

        const idx = tail & self.mask;
        const frame = self.frames[idx];
        self.tail.store(tail +% 1, .release);
        return frame;
    }
};

test "RingBuffer rejects non-power-of-two capacity" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidCapacity, RingBuffer.init(allocator, 15));
}

test "RingBuffer 64-byte frame push, pop, and SPSC lock-free ordering" {
    const allocator = std.testing.allocator;
    var ring = try RingBuffer.init(allocator, 4);
    defer ring.deinit(allocator);

    try std.testing.expect(ring.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), ring.count());

    const frame1 = MessageFrame.init(.telemetry, 1, "telemetry_frame_01");
    const frame2 = MessageFrame.init(.stream_data, 2, "stream_frame_02");

    try std.testing.expect(ring.push(frame1));
    try std.testing.expect(ring.push(frame2));
    try std.testing.expectEqual(@as(usize, 2), ring.count());

    const popped1 = ring.pop().?;
    try std.testing.expectEqual(MessageType.telemetry, popped1.msg_type);
    try std.testing.expectEqual(@as(u32, 1), popped1.sequence);
    try std.testing.expectEqualStrings("telemetry_frame_01", popped1.payload[0..popped1.payload_len]);

    const popped2 = ring.pop().?;
    try std.testing.expectEqual(MessageType.stream_data, popped2.msg_type);
    try std.testing.expectEqualStrings("stream_frame_02", popped2.payload[0..popped2.payload_len]);

    try std.testing.expect(ring.isEmpty());
}
