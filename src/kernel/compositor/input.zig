// MicrOS (µOS) Reactive Vector Compositor - Pointer Ingress & Focus Arbitration
// Decodes 3-byte PS/2 mouse packets, manages non-destructive cursor sprite rendering,
// and routes hit-tested focus arbitration and hotkey events between actors.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const wm_mod = @import("wm.zig");
const WindowManager = wm_mod.WindowManager;
const ps2_kbd_mod = @import("../drivers/ps2_kbd.zig");

pub const CURSOR_WIDTH: u32 = 8;
pub const CURSOR_HEIGHT: u32 = 8;
pub const CURSOR_PIXEL_COUNT: usize = CURSOR_WIDTH * CURSOR_HEIGHT;
pub const CURSOR_COLOR_FG: u32 = 0x00FF_FFFF;
pub const CURSOR_COLOR_BORDER: u32 = 0x0000_0000;

pub const PS2_SYNC_BIT: u8 = 0x08;
pub const PS2_OVERFLOW_MASK: u8 = 0xC0;
pub const PS2_BTN_LEFT: u8 = 0x01;
pub const PS2_BTN_RIGHT: u8 = 0x02;
pub const PS2_BTN_MIDDLE: u8 = 0x04;

pub const CURSOR_SPRITE: [CURSOR_HEIGHT]u8 = [_]u8{
    0b1000_0000,
    0b1100_0000,
    0b1110_0000,
    0b1111_0000,
    0b1111_1000,
    0b1110_0000,
    0b1011_0000,
    0b0001_1000,
};

pub const MouseButtons = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    _reserved: u5 = 0,
};

pub const MouseEvent = struct {
    buttons: MouseButtons,
    dx: i32,
    dy: i32,
};

pub fn decodePs2Packet(b0: u8, b1: u8, b2: u8) ?MouseEvent {
    if ((b0 & PS2_SYNC_BIT) == 0) return null;
    if ((b0 & PS2_OVERFLOW_MASK) != 0) return null;

    const left = (b0 & PS2_BTN_LEFT) != 0;
    const right = (b0 & PS2_BTN_RIGHT) != 0;
    const middle = (b0 & PS2_BTN_MIDDLE) != 0;

    const raw_dx: i8 = @bitCast(b1);
    const raw_dy: i8 = @bitCast(b2);

    return MouseEvent{
        .buttons = .{
            .left = left,
            .right = right,
            .middle = middle,
        },
        .dx = @as(i32, raw_dx),
        .dy = -@as(i32, raw_dy),
    };
}

pub const Ps2MouseDecoder = struct {
    byte_idx: u8 = 0,
    packet: [3]u8 = [_]u8{0} ** 3,

    pub fn init() Ps2MouseDecoder {
        return Ps2MouseDecoder{};
    }

    pub fn processByte(self: *Ps2MouseDecoder, byte: u8) ?MouseEvent {
        if (self.byte_idx == 0) {
            if ((byte & PS2_SYNC_BIT) == 0) return null;
            self.packet[0] = byte;
            self.byte_idx = 1;
            return null;
        } else if (self.byte_idx == 1) {
            self.packet[1] = byte;
            self.byte_idx = 2;
            return null;
        } else {
            self.packet[2] = byte;
            self.byte_idx = 0;
            return decodePs2Packet(self.packet[0], self.packet[1], self.packet[2]);
        }
    }
};

pub const CursorBacking = struct {
    saved_pixels: [CURSOR_PIXEL_COUNT]u32 = [_]u32{0} ** CURSOR_PIXEL_COUNT,
    saved_x: i32 = -1,
    saved_y: i32 = -1,
    is_saved: bool = false,

    pub fn restore(self: *CursorBacking, canvas: *Canvas) void {
        if (!self.is_saved) return;
        var r: u32 = 0;
        while (r < CURSOR_HEIGHT) : (r += 1) {
            var c: u32 = 0;
            while (c < CURSOR_WIDTH) : (c += 1) {
                self.restorePixel(canvas, c, r);
            }
        }
        self.is_saved = false;
    }

    fn restorePixel(self: *const CursorBacking, canvas: *Canvas, c: u32, r: u32) void {
        const px = self.saved_x + @as(i32, @intCast(c));
        const py = self.saved_y + @as(i32, @intCast(r));
        if (px < 0 or py < 0 or px >= canvas.width or py >= canvas.height) return;
        const idx = r * CURSOR_WIDTH + c;
        canvas.setPixelRaw(@intCast(px), @intCast(py), self.saved_pixels[idx]);
    }

    pub fn saveAndDraw(self: *CursorBacking, canvas: *Canvas, x: i32, y: i32) void {
        self.saved_x = x;
        self.saved_y = y;
        self.is_saved = true;

        var r: u32 = 0;
        while (r < CURSOR_HEIGHT) : (r += 1) {
            var c: u32 = 0;
            while (c < CURSOR_WIDTH) : (c += 1) {
                self.saveAndDrawPixel(canvas, x, y, c, r);
            }
        }
    }

    fn saveAndDrawPixel(self: *CursorBacking, canvas: *Canvas, x: i32, y: i32, c: u32, r: u32) void {
        const px = x + @as(i32, @intCast(c));
        const py = y + @as(i32, @intCast(r));
        if (px < 0 or py < 0 or px >= canvas.width or py >= canvas.height) return;

        const ux: u32 = @intCast(px);
        const uy: u32 = @intCast(py);
        const idx = r * CURSOR_WIDTH + c;
        self.saved_pixels[idx] = canvas.getPixel(ux, uy);

        const row_mask = CURSOR_SPRITE[r];
        const bit = @as(u8, 1) << @as(u3, @intCast(7 - c));
        if ((row_mask & bit) != 0) {
            canvas.setPixel(ux, uy, CURSOR_COLOR_FG);
        }
    }
};

pub const PointerState = struct {
    x: i32,
    y: i32,
    buttons: MouseButtons,
    screen_w: u32,
    screen_h: u32,
    backing: CursorBacking,

    pub fn init(screen_w: u32, screen_h: u32) PointerState {
        return PointerState{
            .x = @as(i32, @intCast(screen_w / 2)),
            .y = @as(i32, @intCast(screen_h / 2)),
            .buttons = .{},
            .screen_w = screen_w,
            .screen_h = screen_h,
            .backing = CursorBacking{},
        };
    }

    pub fn update(
        self: *PointerState,
        event: MouseEvent,
        wm: *WindowManager,
        canvas: *Canvas,
    ) void {
        self.backing.restore(canvas);

        const max_x = @as(i32, @intCast(self.screen_w - 1));
        const max_y = @as(i32, @intCast(self.screen_h - 1));
        self.x = std.math.clamp(self.x + event.dx, 0, max_x);
        self.y = std.math.clamp(self.y + event.dy, 0, max_y);

        const prev_left = self.buttons.left;
        self.buttons = event.buttons;

        if (!prev_left and self.buttons.left) {
            if (wm.hitTest(self.x, self.y)) |win_id| {
                wm.focusWindow(win_id);
            }
        }

        self.backing.saveAndDraw(canvas, self.x, self.y);
    }
};

pub fn isShellToggleHotkey(event: ps2_kbd_mod.KeyEvent) bool {
    return event.modifiers.ctrl and event.modifiers.alt and
        event.keycode == ps2_kbd_mod.KeyCode.SPACE and
        event.action == .press;
}

pub fn arbitrateShellToggle(wm: *WindowManager, shell_win_id: u32) void {
    if (wm.active_window_id == shell_win_id) {
        var i = wm.window_count;
        while (i > 0) : (i -= 1) {
            const win = wm.windows[i - 1] orelse continue;
            if (win.id != shell_win_id) {
                wm.focusWindow(win.id);
                return;
            }
        }
    } else {
        wm.focusWindow(shell_win_id);
    }
}

test "decodePs2Packet movement and buttons" {
    // Left click + move right 4, up 6 (-dy = -6 in PS/2, so dy = 6 on screen)
    // b0 = 0x09 (sync 0x08 | left 0x01)
    // b1 = 4
    // b2 = 6 (up 6 in PS/2) -> dy = -6 on screen
    const ev = decodePs2Packet(0x09, 4, 6);
    try std.testing.expect(ev != null);
    const m = ev.?;
    try std.testing.expect(m.buttons.left);
    try std.testing.expect(!m.buttons.right);
    try std.testing.expectEqual(@as(i32, 4), m.dx);
    try std.testing.expectEqual(@as(i32, -6), m.dy);
}

test "Ps2MouseDecoder 3-byte stream decoding" {
    var decoder = Ps2MouseDecoder.init();
    try std.testing.expectEqual(@as(?MouseEvent, null), decoder.processByte(0x08));
    try std.testing.expectEqual(@as(?MouseEvent, null), decoder.processByte(10));
    const ev = decoder.processByte(20);
    try std.testing.expect(ev != null);
    try std.testing.expectEqual(@as(i32, 10), ev.?.dx);
    try std.testing.expectEqual(@as(i32, -20), ev.?.dy);
}

test "PointerState movement clamping and non-destructive cursor restoration" {
    const allocator = std.testing.allocator;
    var canvas = try Canvas.init(allocator, 100, 100, .rgb_888);
    defer canvas.deinit();

    // Fill background with known color
    canvas.drawRect(0, 0, 100, 100, 0x0012_3456);

    var wm = WindowManager.init(allocator, 100, 100);
    defer wm.deinit();

    var ptr = PointerState.init(100, 100);
    try std.testing.expectEqual(@as(i32, 50), ptr.x);
    try std.testing.expectEqual(@as(i32, 50), ptr.y);

    // Initial draw
    ptr.backing.saveAndDraw(&canvas, ptr.x, ptr.y);
    try std.testing.expectEqual(CURSOR_COLOR_FG, canvas.getPixel(50, 50));

    // Move right 10, down 10
    const move_ev = MouseEvent{
        .buttons = .{},
        .dx = 10,
        .dy = 10,
    };
    ptr.update(move_ev, &wm, &canvas);

    try std.testing.expectEqual(@as(i32, 60), ptr.x);
    try std.testing.expectEqual(@as(i32, 60), ptr.y);
    // Old position restored to background color
    try std.testing.expectEqual(@as(u32, 0x0012_3456), canvas.getPixel(50, 50));
    // New position drawn
    try std.testing.expectEqual(CURSOR_COLOR_FG, canvas.getPixel(60, 60));
}

test "Focus arbitration and shell toggle hotkey" {
    const allocator = std.testing.allocator;
    var wm = WindowManager.init(allocator, 800, 600);
    defer wm.deinit();

    const shell = try wm.createWindow(1, "Shell", 400, 600, .tiled);
    const editor = try wm.createWindow(2, "Editor", 400, 600, .tiled);

    try std.testing.expectEqual(editor.id, wm.active_window_id.?);

    // Toggle back to shell
    arbitrateShellToggle(&wm, shell.id);
    try std.testing.expectEqual(shell.id, wm.active_window_id.?);

    // Toggle back to editor
    arbitrateShellToggle(&wm, shell.id);
    try std.testing.expectEqual(editor.id, wm.active_window_id.?);
}
