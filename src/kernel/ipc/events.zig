// MicrOS (µOS) Typed Event ABI & Serialization
// Bridges bare-metal input/hardware events into 64-byte IPC MessageFrames.
// Eradicates untyped Unix terminal byte streams in favor of structured event frames.

const std = @import("std");
const ring_mod = @import("ring.zig");
const MessageFrame = ring_mod.MessageFrame;
const MessageType = ring_mod.MessageType;

pub const KeyAction = enum(u8) {
    press = 0x01,
    release = 0x02,
    repeat = 0x03,
};

pub const KeyModifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    caps: bool = false,
    super: bool = false,
    _reserved: u3 = 0,
};

pub const KeyCode = struct {
    pub const UNKNOWN: u16 = 0;
    pub const ENTER: u16 = 0x000D;
    pub const ESCAPE: u16 = 0x001B;
    pub const BACKSPACE: u16 = 0x0008;
    pub const TAB: u16 = 0x0009;
    pub const SPACE: u16 = 0x0020;
    pub const UP: u16 = 0x0100;
    pub const DOWN: u16 = 0x0101;
    pub const LEFT: u16 = 0x0102;
    pub const RIGHT: u16 = 0x0103;
    pub const PAGE_UP: u16 = 0x0104;
    pub const PAGE_DOWN: u16 = 0x0105;
    pub const HOME: u16 = 0x0106;
    pub const END: u16 = 0x0107;
    pub const INSERT: u16 = 0x0108;
    pub const DELETE: u16 = 0x0109;
    pub const F1: u16 = 0x0110;
    pub const F2: u16 = 0x0111;
    pub const F3: u16 = 0x0112;
    pub const F4: u16 = 0x0113;
    pub const F5: u16 = 0x0114;
    pub const F6: u16 = 0x0115;
    pub const F7: u16 = 0x0116;
    pub const F8: u16 = 0x0117;
    pub const F9: u16 = 0x0118;
    pub const F10: u16 = 0x0119;
    pub const F11: u16 = 0x011A;
    pub const F12: u16 = 0x011B;
};

pub const KeyEvent = extern struct {
    scancode: u8,
    action: KeyAction,
    modifiers: KeyModifiers,
    ascii: u8,
    keycode: u16,
    reserved: u16 = 0,

    pub const EMPTY = KeyEvent{
        .scancode = 0,
        .action = .press,
        .modifiers = .{},
        .ascii = 0,
        .keycode = 0,
        .reserved = 0,
    };
};

comptime {
    std.debug.assert(@sizeOf(KeyEvent) == 8);
}

pub const EVENT_FLAG_KEY: u16 = 0x0001;

pub fn toMessageFrame(event: KeyEvent, seq: u32) MessageFrame {
    var frame = MessageFrame.EMPTY;
    frame.msg_type = .event_signal;
    frame.flags = EVENT_FLAG_KEY;
    frame.sequence = seq;
    frame.payload_len = @sizeOf(KeyEvent);
    const bytes: *const [@sizeOf(KeyEvent)]u8 = @ptrCast(&event);
    @memcpy(frame.payload[0..@sizeOf(KeyEvent)], bytes);
    return frame;
}

pub fn fromMessageFrame(frame: *const MessageFrame) ?KeyEvent {
    if (frame.msg_type != .event_signal) return null;
    if ((frame.flags & EVENT_FLAG_KEY) == 0) return null;
    if (frame.payload_len < @sizeOf(KeyEvent)) return null;

    var event: KeyEvent = undefined;
    const dest: *[@sizeOf(KeyEvent)]u8 = @ptrCast(&event);
    @memcpy(dest, frame.payload[0..@sizeOf(KeyEvent)]);
    return event;
}

test "KeyEvent memory size and field alignment" {
    try std.testing.expectEqual(8, @sizeOf(KeyEvent));
    try std.testing.expectEqual(1, @sizeOf(KeyModifiers));
    try std.testing.expectEqual(1, @sizeOf(KeyAction));
}

test "KeyEvent to MessageFrame round-trip serialization" {
    const event = KeyEvent{
        .scancode = 0x1E,
        .action = .press,
        .modifiers = .{ .shift = true, .caps = false },
        .ascii = 'A',
        .keycode = 'A',
        .reserved = 0,
    };

    const frame = toMessageFrame(event, 42);
    try std.testing.expectEqual(MessageType.event_signal, frame.msg_type);
    try std.testing.expectEqual(EVENT_FLAG_KEY, frame.flags);
    try std.testing.expectEqual(42, frame.sequence);
    try std.testing.expectEqual(8, frame.payload_len);

    const recovered = fromMessageFrame(&frame);
    try std.testing.expect(recovered != null);
    const rec = recovered.?;
    try std.testing.expectEqual(0x1E, rec.scancode);
    try std.testing.expectEqual(KeyAction.press, rec.action);
    try std.testing.expect(rec.modifiers.shift);
    try std.testing.expect(!rec.modifiers.ctrl);
    try std.testing.expectEqual('A', rec.ascii);
    try std.testing.expectEqual('A', rec.keycode);
}

test "fromMessageFrame rejects non-event frames" {
    var frame = MessageFrame.EMPTY;
    frame.msg_type = .telemetry;
    try std.testing.expect(fromMessageFrame(&frame) == null);

    frame.msg_type = .event_signal;
    frame.flags = 0; // Missing EVENT_FLAG_KEY
    try std.testing.expect(fromMessageFrame(&frame) == null);

    frame.flags = EVENT_FLAG_KEY;
    frame.payload_len = 4; // Truncated
    try std.testing.expect(fromMessageFrame(&frame) == null);
}
