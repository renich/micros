// MicrOS (µOS) PS/2 Keyboard Driver (8042 Controller)
// Translates bare-metal Scancode Set 1 make/break events to typed KeyEvents.
// Zero-allocation, interrupt-safe, and independent of Unix TTY line disciplines.

const std = @import("std");
const events_mod = @import("../ipc/events.zig");
pub const KeyEvent = events_mod.KeyEvent;
pub const KeyAction = events_mod.KeyAction;
pub const KeyModifiers = events_mod.KeyModifiers;
pub const KeyCode = events_mod.KeyCode;

pub const PORT_DATA: u16 = 0x60;
pub const PORT_STATUS: u16 = 0x64;
pub const PORT_COMMAND: u16 = 0x64;

pub const STATUS_OUTPUT_FULL: u8 = 0x01;
pub const STATUS_INPUT_FULL: u8 = 0x02;

pub const SCANCODE_EXTENDED: u8 = 0xE0;
pub const SCANCODE_RELEASE_FLAG: u8 = 0x80;

pub const SCAN_LSHIFT: u8 = 0x2A;
pub const SCAN_RSHIFT: u8 = 0x36;
pub const SCAN_LCTRL: u8 = 0x1D;
pub const SCAN_LALT: u8 = 0x38;
pub const SCAN_CAPSLOCK: u8 = 0x3A;
pub const SCAN_ENTER: u8 = 0x1C;
pub const SCAN_BACKSPACE: u8 = 0x0E;
pub const SCAN_TAB: u8 = 0x0F;
pub const SCAN_ESCAPE: u8 = 0x01;
pub const SCAN_SPACE: u8 = 0x39;

const UNPRINTABLE_MAP = [_]struct { scan: u8, code: u16, ascii: u8 }{
    .{ .scan = SCAN_ESCAPE, .code = KeyCode.ESCAPE, .ascii = 0x1B },
    .{ .scan = SCAN_BACKSPACE, .code = KeyCode.BACKSPACE, .ascii = 0x08 },
    .{ .scan = SCAN_TAB, .code = KeyCode.TAB, .ascii = '\t' },
    .{ .scan = SCAN_ENTER, .code = KeyCode.ENTER, .ascii = '\n' },
    .{ .scan = SCAN_SPACE, .code = KeyCode.SPACE, .ascii = ' ' },
};

const LOWER_MAP: []const u8 = "??1234567890-=\x08\tqwertyuiop[]\n?asdfghjkl;'`?\\zxcvbnm,./?*? ?";
const UPPER_MAP: []const u8 = "??!@#$%^&*()_+\x08\tQWERTYUIOP{}\n?ASDFGHJKL:\"~?|ZXCVBNM<>??*? ?";

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
    );
}

pub fn hasData() bool {
    return (inb(PORT_STATUS) & STATUS_OUTPUT_FULL) != 0;
}

pub fn readScancode() u8 {
    return inb(PORT_DATA);
}

pub const Ps2Keyboard = struct {
    modifiers: KeyModifiers,
    extended: bool,

    pub fn init() Ps2Keyboard {
        return Ps2Keyboard{
            .modifiers = .{},
            .extended = false,
        };
    }

    fn updateModifiers(self: *Ps2Keyboard, scan: u8, is_release: bool) bool {
        if (scan == SCAN_LSHIFT or scan == SCAN_RSHIFT) {
            self.modifiers.shift = !is_release;
            return true;
        } else if (scan == SCAN_LCTRL) {
            self.modifiers.ctrl = !is_release;
            return true;
        } else if (scan == SCAN_LALT) {
            self.modifiers.alt = !is_release;
            return true;
        } else if (scan == SCAN_CAPSLOCK) {
            if (!is_release) self.modifiers.caps = !self.modifiers.caps;
            return true;
        }
        return false;
    }

    fn resolveAscii(scan: u8, shift: bool, caps: bool) u8 {
        if (scan >= LOWER_MAP.len) return 0;
        const lower = LOWER_MAP[scan];
        if (lower == '?') return 0;

        if (lower >= 'a' and lower <= 'z') {
            const is_upper = shift != caps;
            return if (is_upper) UPPER_MAP[scan] else lower;
        }
        return if (shift) UPPER_MAP[scan] else lower;
    }

    fn resolveExtended(self: *Ps2Keyboard, scan: u8, is_release: bool) ?KeyEvent {
        self.extended = false;
        const code: u16 = switch (scan) {
            0x48 => KeyCode.UP,
            0x50 => KeyCode.DOWN,
            0x4B => KeyCode.LEFT,
            0x4D => KeyCode.RIGHT,
            0x47 => KeyCode.HOME,
            0x4F => KeyCode.END,
            0x49 => KeyCode.PAGE_UP,
            0x51 => KeyCode.PAGE_DOWN,
            0x52 => KeyCode.INSERT,
            0x53 => KeyCode.DELETE,
            else => KeyCode.UNKNOWN,
        };
        if (code == KeyCode.UNKNOWN) return null;

        return KeyEvent{
            .scancode = scan,
            .action = if (is_release) .release else .press,
            .modifiers = self.modifiers,
            .ascii = 0,
            .keycode = code,
        };
    }

    fn resolveUnprintable(base_scan: u8) ?struct { code: u16, ascii: u8 } {
        for (UNPRINTABLE_MAP) |entry| {
            if (entry.scan == base_scan) {
                return .{ .code = entry.code, .ascii = entry.ascii };
            }
        }
        return null;
    }

    pub fn processScancode(self: *Ps2Keyboard, raw_scan: u8) ?KeyEvent {
        if (raw_scan == SCANCODE_EXTENDED) {
            self.extended = true;
            return null;
        }

        const is_release = (raw_scan & SCANCODE_RELEASE_FLAG) != 0;
        const base_scan = raw_scan & ~SCANCODE_RELEASE_FLAG;

        if (self.extended) {
            return self.resolveExtended(base_scan, is_release);
        }

        const is_mod = self.updateModifiers(base_scan, is_release);
        const action: KeyAction = if (is_release) .release else .press;

        if (resolveUnprintable(base_scan)) |unprintable| {
            return KeyEvent{
                .scancode = raw_scan,
                .action = action,
                .modifiers = self.modifiers,
                .ascii = unprintable.ascii,
                .keycode = unprintable.code,
            };
        }

        const ascii = resolveAscii(base_scan, self.modifiers.shift, self.modifiers.caps);
        const keycode: u16 = if (ascii != 0) ascii else if (is_mod) KeyCode.UNKNOWN else base_scan;

        return KeyEvent{
            .scancode = raw_scan,
            .action = action,
            .modifiers = self.modifiers,
            .ascii = ascii,
            .keycode = keycode,
        };
    }
};

test "Ps2Keyboard make and break scancodes" {
    var kbd = Ps2Keyboard.init();

    // Key 'a' press (scancode 0x1E)
    const event_a = kbd.processScancode(0x1E);
    try std.testing.expect(event_a != null);
    try std.testing.expectEqual(KeyAction.press, event_a.?.action);
    try std.testing.expectEqual('a', event_a.?.ascii);
    try std.testing.expectEqual('a', event_a.?.keycode);

    // Key 'a' release (scancode 0x9E)
    const event_a_rel = kbd.processScancode(0x9E);
    try std.testing.expect(event_a_rel != null);
    try std.testing.expectEqual(KeyAction.release, event_a_rel.?.action);
    try std.testing.expectEqual('a', event_a_rel.?.ascii);
}

test "Ps2Keyboard shift modifier tracking" {
    var kbd = Ps2Keyboard.init();

    // Shift press (0x2A)
    _ = kbd.processScancode(SCAN_LSHIFT);
    try std.testing.expect(kbd.modifiers.shift);

    // Key 'a' with shift -> 'A'
    const event_cap = kbd.processScancode(0x1E);
    try std.testing.expect(event_cap != null);
    try std.testing.expectEqual('A', event_cap.?.ascii);

    // Key '1' with shift -> '!'
    const event_excl = kbd.processScancode(0x02);
    try std.testing.expect(event_excl != null);
    try std.testing.expectEqual('!', event_excl.?.ascii);

    // Shift release (0xAA)
    _ = kbd.processScancode(SCAN_LSHIFT | SCANCODE_RELEASE_FLAG);
    try std.testing.expect(!kbd.modifiers.shift);
}

test "Ps2Keyboard extended arrow keys" {
    var kbd = Ps2Keyboard.init();

    // Extended prefix 0xE0
    const prefix = kbd.processScancode(SCANCODE_EXTENDED);
    try std.testing.expect(prefix == null);
    try std.testing.expect(kbd.extended);

    // Up arrow make (0x48)
    const event_up = kbd.processScancode(0x48);
    try std.testing.expect(event_up != null);
    try std.testing.expectEqual(KeyCode.UP, event_up.?.keycode);
    try std.testing.expect(!kbd.extended);
}

test "Ps2Keyboard caps lock toggle" {
    var kbd = Ps2Keyboard.init();

    // Caps Lock press (0x3A)
    _ = kbd.processScancode(SCAN_CAPSLOCK);
    try std.testing.expect(kbd.modifiers.caps);

    const event_cap = kbd.processScancode(0x1E);
    try std.testing.expect(event_cap != null);
    try std.testing.expectEqual('A', event_cap.?.ascii);

    // Caps Lock press again toggles off
    _ = kbd.processScancode(SCAN_CAPSLOCK);
    try std.testing.expect(!kbd.modifiers.caps);

    const event_low = kbd.processScancode(0x1E);
    try std.testing.expect(event_low != null);
    try std.testing.expectEqual('a', event_low.?.ascii);
}
