// MicrOS (µOS) Reactive Vector Compositor - Window Manager (WM)
// Manages multi-actor desktop real estate via BSP dynamic tiling and floating HUDs.
// Renders active/inactive window decorations (borders, title bars) and handles Z-order stacking.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const Canvas = canvas_mod.Canvas;
const DamageRect = canvas_mod.DamageRect;
const surface_mod = @import("surface.zig");
const Surface = surface_mod.Surface;

pub const MAX_WINDOWS: usize = 16;
pub const DEFAULT_TITLE_HEIGHT: u32 = 16;
pub const DEFAULT_BORDER_WIDTH: u32 = 1;
pub const MAX_TITLE_LEN: usize = 32;

pub const COLOR_BG_DESKTOP: u32 = 0x000F_141C;
pub const COLOR_BORDER_ACTIVE: u32 = 0x003A_86FF;
pub const COLOR_BORDER_INACTIVE: u32 = 0x002A_303C;
pub const COLOR_TITLE_ACTIVE_BG: u32 = 0x001E_2638;
pub const COLOR_TITLE_INACTIVE_BG: u32 = 0x0014_1A26;
pub const COLOR_TITLE_ACTIVE_FG: u32 = 0x00E0_E6ED;
pub const COLOR_TITLE_INACTIVE_FG: u32 = 0x006C_7A89;

pub const WindowMode = enum(u8) {
    tiled = 0,
    floating = 1,
};

pub const Window = struct {
    id: u32,
    actor_id: u32,
    title: [MAX_TITLE_LEN]u8,
    title_len: usize,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    mode: WindowMode,
    visible: bool,
    surface: *Surface,

    pub fn clientX(self: *const Window) i32 {
        return self.x + @as(i32, @intCast(DEFAULT_BORDER_WIDTH));
    }

    pub fn clientY(self: *const Window) i32 {
        return self.y + @as(i32, @intCast(DEFAULT_TITLE_HEIGHT + DEFAULT_BORDER_WIDTH));
    }

    pub fn clientW(self: *const Window) u32 {
        const inset = DEFAULT_BORDER_WIDTH * 2;
        if (self.w <= inset) return 0;
        return self.w - inset;
    }

    pub fn clientH(self: *const Window) u32 {
        const inset = DEFAULT_TITLE_HEIGHT + DEFAULT_BORDER_WIDTH * 2;
        if (self.h <= inset) return 0;
        return self.h - inset;
    }
};

pub const WindowManager = struct {
    allocator: std.mem.Allocator,
    windows: [MAX_WINDOWS]?*Window,
    window_count: usize,
    active_window_id: ?u32,
    desktop_w: u32,
    desktop_h: u32,
    next_win_id: u32,

    pub fn init(allocator: std.mem.Allocator, w: u32, h: u32) WindowManager {
        return WindowManager{
            .allocator = allocator,
            .windows = [_]?*Window{null} ** MAX_WINDOWS,
            .window_count = 0,
            .active_window_id = null,
            .desktop_w = w,
            .desktop_h = h,
            .next_win_id = 1,
        };
    }

    pub fn deinit(self: *WindowManager) void {
        var i: usize = 0;
        while (i < self.window_count) : (i += 1) {
            if (self.windows[i]) |win| {
                win.surface.deinit();
                self.allocator.destroy(win);
                self.windows[i] = null;
            }
        }
        self.window_count = 0;
    }

    pub fn findWindowIndex(self: *const WindowManager, id: u32) ?usize {
        var i: usize = 0;
        while (i < self.window_count) : (i += 1) {
            const win = self.windows[i] orelse continue;
            if (win.id == id) return i;
        }
        return null;
    }

    pub fn createWindow(
        self: *WindowManager,
        actor_id: u32,
        title: []const u8,
        w: u32,
        h: u32,
        mode: WindowMode,
    ) !*Window {
        if (self.window_count >= MAX_WINDOWS) return error.WindowLimitReached;

        const win = try self.allocator.create(Window);
        errdefer self.allocator.destroy(win);

        const win_id = self.next_win_id;
        self.next_win_id += 1;

        const surf = try Surface.init(self.allocator, win_id, actor_id, w, h);
        errdefer surf.deinit();

        win.* = initWindowStruct(win_id, actor_id, title, w, h, mode, surf);
        self.windows[self.window_count] = win;
        self.window_count += 1;
        self.active_window_id = win_id;

        if (mode == .tiled) self.retile();
        return win;
    }

    pub fn closeWindow(self: *WindowManager, id: u32) void {
        const idx = self.findWindowIndex(id) orelse return;
        const target = self.windows[idx].?;
        target.surface.deinit();
        self.allocator.destroy(target);

        var j = idx;
        while (j + 1 < self.window_count) : (j += 1) {
            self.windows[j] = self.windows[j + 1];
        }
        self.windows[self.window_count - 1] = null;
        self.window_count -= 1;

        if (self.active_window_id == id) {
            self.updateActiveAfterClose();
        }
        self.retile();
    }

    pub fn focusWindow(self: *WindowManager, id: u32) void {
        const idx = self.findWindowIndex(id) orelse return;
        const win = self.windows[idx].?;

        var j = idx;
        while (j + 1 < self.window_count) : (j += 1) {
            self.windows[j] = self.windows[j + 1];
        }
        self.windows[self.window_count - 1] = win;
        self.active_window_id = id;
    }

    fn updateActiveAfterClose(self: *WindowManager) void {
        if (self.window_count > 0) {
            self.active_window_id = self.windows[self.window_count - 1].?.id;
        } else {
            self.active_window_id = null;
        }
    }

    pub fn retile(self: *WindowManager) void {
        var tiled_count: usize = 0;
        var i: usize = 0;
        while (i < self.window_count) : (i += 1) {
            const win = self.windows[i].?;
            if (win.mode == .tiled and win.visible) tiled_count += 1;
        }
        if (tiled_count == 0) return;

        var tile_idx: usize = 0;
        i = 0;
        while (i < self.window_count) : (i += 1) {
            const win = self.windows[i].?;
            if (win.mode != .tiled or !win.visible) continue;
            tileWindowIndex(win, tile_idx, tiled_count, self.desktop_w, self.desktop_h);
            tile_idx += 1;
        }
    }

    pub fn compose(self: *WindowManager, canvas: *Canvas) void {
        var i: usize = 0;
        while (i < self.window_count) : (i += 1) {
            const win = self.windows[i].?;
            if (!win.visible) continue;
            self.drawWindowFrame(canvas, win);
            win.surface.blitToCanvas(canvas, null);
        }
    }

    fn drawWindowFrame(self: *WindowManager, canvas: *Canvas, win: *const Window) void {
        const is_active = (self.active_window_id != null and self.active_window_id.? == win.id);
        const border_color = if (is_active) COLOR_BORDER_ACTIVE else COLOR_BORDER_INACTIVE;
        const title_bg = if (is_active) COLOR_TITLE_ACTIVE_BG else COLOR_TITLE_INACTIVE_BG;
        const title_fg = if (is_active) COLOR_TITLE_ACTIVE_FG else COLOR_TITLE_INACTIVE_FG;

        const wx: u32 = @intCast(@max(0, win.x));
        const wy: u32 = @intCast(@max(0, win.y));

        canvas.drawRect(wx, wy, win.w, DEFAULT_TITLE_HEIGHT, title_bg);
        drawWindowBorders(canvas, wx, wy, win.w, win.h, border_color);

        const title_str = win.title[0..win.title_len];
        canvas.drawString(wx + 4, wy + 4, title_str, title_fg, title_bg);
    }

    pub fn hitTest(self: *const WindowManager, x: i32, y: i32) ?u32 {
        var i = self.window_count;
        while (i > 0) : (i -= 1) {
            const win = self.windows[i - 1] orelse continue;
            if (!win.visible) continue;
            if (windowContains(win, x, y)) return win.id;
        }
        return null;
    }
};

fn initWindowStruct(
    win_id: u32,
    actor_id: u32,
    title: []const u8,
    w: u32,
    h: u32,
    mode: WindowMode,
    surf: *Surface,
) Window {
    var title_buf: [MAX_TITLE_LEN]u8 = [_]u8{0} ** MAX_TITLE_LEN;
    const copy_len = @min(title.len, MAX_TITLE_LEN);
    @memcpy(title_buf[0..copy_len], title[0..copy_len]);

    return Window{
        .id = win_id,
        .actor_id = actor_id,
        .title = title_buf,
        .title_len = copy_len,
        .x = 0,
        .y = 0,
        .w = w,
        .h = h,
        .mode = mode,
        .visible = true,
        .surface = surf,
    };
}

fn tileWindowIndex(win: *Window, idx: usize, total: usize, dw: u32, dh: u32) void {
    if (total == 1) {
        win.x = 0;
        win.y = 0;
        win.w = dw;
        win.h = dh;
    } else if (total == 2) {
        const half_w = dw / 2;
        win.x = @intCast(if (idx == 0) 0 else half_w);
        win.y = 0;
        win.w = if (idx == 0) half_w else (dw - half_w);
        win.h = dh;
    } else {
        tileThreeOrMore(win, idx, total, dw, dh);
    }
    syncSurfacePosition(win);
}

fn tileThreeOrMore(win: *Window, idx: usize, total: usize, dw: u32, dh: u32) void {
    const half_w = dw / 2;
    if (idx == 0) {
        win.x = 0;
        win.y = 0;
        win.w = half_w;
        win.h = dh;
    } else {
        const stack_count = @as(u32, @intCast(total - 1));
        const stack_h = dh / stack_count;
        const stack_idx = @as(u32, @intCast(idx - 1));
        win.x = @intCast(half_w);
        win.y = @intCast(stack_idx * stack_h);
        win.w = dw - half_w;
        win.h = if (stack_idx == stack_count - 1) (dh - stack_idx * stack_h) else stack_h;
    }
}

fn syncSurfacePosition(win: *Window) void {
    win.surface.pos_x = win.clientX();
    win.surface.pos_y = win.clientY();
}

fn windowContains(win: *const Window, x: i32, y: i32) bool {
    const wx2 = win.x + @as(i32, @intCast(win.w));
    const wy2 = win.y + @as(i32, @intCast(win.h));
    return (x >= win.x and x < wx2 and y >= win.y and y < wy2);
}

fn drawWindowBorders(canvas: *Canvas, x: u32, y: u32, w: u32, h: u32, border_color: u32) void {
    canvas.drawRect(x, y, w, 1, border_color); // Top
    canvas.drawRect(x, y + h - 1, w, 1, border_color); // Bottom
    canvas.drawRect(x, y, 1, h, border_color); // Left
    canvas.drawRect(x + w - 1, y, 1, h, border_color); // Right
}

test "WindowManager window creation, BSP retiling, and focus raising" {
    const allocator = std.testing.allocator;
    var wm = WindowManager.init(allocator, 1280, 800);
    defer wm.deinit();

    const w1 = try wm.createWindow(1, "Shell", 640, 480, .tiled);
    try std.testing.expectEqual(@as(u32, 1), w1.id);
    try std.testing.expectEqual(@as(u32, 1280), w1.w);
    try std.testing.expectEqual(@as(u32, 800), w1.h);

    const w2 = try wm.createWindow(2, "Inspector", 640, 480, .tiled);
    try std.testing.expectEqual(@as(u32, 2), w2.id);
    try std.testing.expectEqual(@as(u32, 640), w1.w);
    try std.testing.expectEqual(@as(u32, 640), w2.w);
    try std.testing.expectEqual(@as(i32, 640), w2.x);

    wm.focusWindow(w1.id);
    try std.testing.expectEqual(@as(u32, 1), wm.active_window_id.?);

    // Hit testing
    try std.testing.expectEqual(@as(?u32, 1), wm.hitTest(100, 100));
    try std.testing.expectEqual(@as(?u32, 2), wm.hitTest(700, 100));
    try std.testing.expectEqual(@as(?u32, null), wm.hitTest(-10, -10));

    var canvas = try Canvas.init(allocator, 1280, 800, .rgb_888);
    defer canvas.deinit();

    wm.compose(&canvas);
    try std.testing.expect(!canvas.damage.isEmpty());
}
