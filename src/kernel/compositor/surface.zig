// MicrOS (µOS) Reactive Vector Compositor - Actor Surfaces & IPC
// Provides isolated, bounds-checked rendering surfaces for independent actor domains.
// Surfaces submit bounded DamageRect commits over lock-free SPSC IPC rings.

const std = @import("std");
const canvas_mod = @import("canvas.zig");
const DamageRect = canvas_mod.DamageRect;
const font_mod = @import("../font.zig");

pub const MAX_SURFACE_WIDTH: u32 = 1280;
pub const MAX_SURFACE_HEIGHT: u32 = 800;
pub const FONT_WIDTH: u32 = 8;
pub const FONT_HEIGHT: u32 = 8;
pub const COLOR_MASK_RGB: u32 = 0x00FF_FFFF;

pub const SurfaceCommit = extern struct {
    surface_id: u32,
    actor_id: u32,
    damage: DamageRect,
    timestamp: u64,
};

pub const Surface = struct {
    id: u32,
    actor_id: u32,
    width: u32,
    height: u32,
    stride: u32,
    pos_x: i32,
    pos_y: i32,
    z_order: u32,
    visible: bool,
    pixels: []u32,
    damage: DamageRect,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        id: u32,
        actor_id: u32,
        w: u32,
        h: u32,
    ) !*Surface {
        if (w == 0 or h == 0 or w > MAX_SURFACE_WIDTH or h > MAX_SURFACE_HEIGHT) {
            return error.InvalidDimensions;
        }

        const surf = try allocator.create(Surface);
        errdefer allocator.destroy(surf);

        const total_pixels = @as(usize, w) * h;
        const pixels = try allocator.alloc(u32, total_pixels);
        errdefer allocator.free(pixels);

        @memset(pixels, 0);

        surf.* = Surface{
            .id = id,
            .actor_id = actor_id,
            .width = w,
            .height = h,
            .stride = w,
            .pos_x = 0,
            .pos_y = 0,
            .z_order = 0,
            .visible = true,
            .pixels = pixels,
            .damage = DamageRect.empty(),
            .allocator = allocator,
        };
        return surf;
    }

    pub fn deinit(self: *Surface) void {
        self.allocator.free(self.pixels);
        self.allocator.destroy(self);
    }

    pub fn setPixelRaw(self: *Surface, x: u32, y: u32, color_rgb: u32) void {
        if (x >= self.width or y >= self.height) return;
        const offset = @as(usize, y) * self.stride + x;
        self.pixels[offset] = color_rgb & COLOR_MASK_RGB;
    }

    pub fn setPixel(self: *Surface, x: u32, y: u32, color_rgb: u32) void {
        if (x >= self.width or y >= self.height) return;
        self.setPixelRaw(x, y, color_rgb);
        self.damage.addPoint(x, y);
    }

    pub fn getPixel(self: *const Surface, x: u32, y: u32) u32 {
        if (x >= self.width or y >= self.height) return 0;
        const offset = @as(usize, y) * self.stride + x;
        return self.pixels[offset];
    }

    pub fn clear(self: *Surface, color_rgb: u32) void {
        const clean_color = color_rgb & COLOR_MASK_RGB;
        @memset(self.pixels, clean_color);
        self.damage = DamageRect.full(self.width, self.height);
    }

    pub fn drawRect(self: *Surface, x: u32, y: u32, w: u32, h: u32, color_rgb: u32) void {
        if (w == 0 or h == 0 or x >= self.width or y >= self.height) return;
        const max_y = @min(@as(u64, y) + h, self.height);
        const max_x = @min(@as(u64, x) + w, self.width);

        var cy: u32 = y;
        while (cy < max_y) : (cy += 1) {
            var cx: u32 = x;
            while (cx < max_x) : (cx += 1) {
                self.setPixelRaw(cx, cy, color_rgb);
            }
        }
        self.damage.addRect(x, y, w, h, self.width, self.height);
    }

    pub fn drawChar(self: *Surface, x: u32, y: u32, c: u8, fg: u32, bg: u32) void {
        if (c < 32 or c > 126) return;
        if (x + FONT_WIDTH > self.width or y + FONT_HEIGHT > self.height) return;

        const glyph = font_mod.FONT_8X8[c - 32];
        var row: u32 = 0;
        while (row < FONT_HEIGHT) : (row += 1) {
            const bits = glyph[row];
            var col: u32 = 0;
            while (col < FONT_WIDTH) : (col += 1) {
                const is_fg = ((bits >> @intCast(col)) & 1) != 0;
                self.setPixelRaw(x + col, y + row, if (is_fg) fg else bg);
            }
        }
        self.damage.addRect(x, y, FONT_WIDTH, FONT_HEIGHT, self.width, self.height);
    }

    pub fn drawString(self: *Surface, x: u32, y: u32, str: []const u8, fg: u32, bg: u32) void {
        var cur_x = x;
        for (str) |c| {
            if (cur_x + FONT_WIDTH > self.width) break;
            self.drawChar(cur_x, y, c, fg, bg);
            cur_x += FONT_WIDTH;
        }
    }

    pub fn commit(self: *Surface, timestamp: u64) SurfaceCommit {
        const c = SurfaceCommit{
            .surface_id = self.id,
            .actor_id = self.actor_id,
            .damage = self.damage,
            .timestamp = timestamp,
        };
        self.damage.reset();
        return c;
    }

    pub fn blitToCanvas(self: *const Surface, canvas: *canvas_mod.Canvas, clip_opt: ?DamageRect) void {
        if (!self.visible) return;

        const rect = computeBlitBounds(self, canvas, clip_opt);
        if (rect.isEmpty()) return;

        var canvas_y: u32 = rect.min_y;
        while (canvas_y < rect.max_y) : (canvas_y += 1) {
            self.blitRow(canvas, canvas_y, rect.min_x, rect.max_x);
        }
        canvas.damage.unionWith(rect);
    }

    fn blitRow(self: *const Surface, canvas: *canvas_mod.Canvas, cy: u32, cx0: u32, cx1: u32) void {
        const sy_i64 = @as(i64, cy) - self.pos_y;
        if (sy_i64 < 0 or sy_i64 >= self.height) return;
        const sy: u32 = @intCast(sy_i64);

        var cx = cx0;
        while (cx < cx1) : (cx += 1) {
            const sx_i64 = @as(i64, cx) - self.pos_x;
            if (sx_i64 >= 0 and sx_i64 < self.width) {
                const color = self.getPixel(@intCast(sx_i64), sy);
                canvas.setPixelRaw(cx, cy, color);
            }
        }
    }
};

fn computeBlitBounds(surf: *const Surface, canvas: *const canvas_mod.Canvas, clip_opt: ?DamageRect) DamageRect {
    const raw_x0 = surf.pos_x;
    const raw_y0 = surf.pos_y;
    const raw_x1 = raw_x0 + @as(i32, @intCast(surf.width));
    const raw_y1 = raw_y0 + @as(i32, @intCast(surf.height));

    const c_w: i32 = @intCast(canvas.width);
    const c_h: i32 = @intCast(canvas.height);

    const clamped_x0 = @max(0, @min(c_w, raw_x0));
    const clamped_y0 = @max(0, @min(c_h, raw_y0));
    const clamped_x1 = @max(0, @min(c_w, raw_x1));
    const clamped_y1 = @max(0, @min(c_h, raw_y1));

    var rect = DamageRect{
        .min_x = @intCast(clamped_x0),
        .min_y = @intCast(clamped_y0),
        .max_x = @intCast(clamped_x1),
        .max_y = @intCast(clamped_y1),
    };

    if (clip_opt) |clip| {
        rect.intersectWith(clip);
    }
    return rect;
}

test "Surface allocation, drawing, commit, and blitToCanvas" {
    const allocator = std.testing.allocator;
    var surf = try Surface.init(allocator, 1, 10, 32, 32);
    defer surf.deinit();

    try std.testing.expectEqual(@as(u32, 32), surf.width);
    try std.testing.expectEqual(@as(u32, 32), surf.height);

    surf.drawRect(4, 4, 8, 8, 0x112233);
    try std.testing.expectEqual(@as(u32, 4), surf.damage.min_x);
    try std.testing.expectEqual(@as(u32, 4), surf.damage.min_y);
    try std.testing.expectEqual(@as(u32, 12), surf.damage.max_x);
    try std.testing.expectEqual(@as(u32, 12), surf.damage.max_y);

    const c = surf.commit(100);
    try std.testing.expectEqual(@as(u32, 1), c.surface_id);
    try std.testing.expectEqual(@as(u32, 10), c.actor_id);
    try std.testing.expect(surf.damage.isEmpty());

    var canvas = try canvas_mod.Canvas.init(allocator, 64, 64, .rgb_888);
    defer canvas.deinit();

    surf.pos_x = 10;
    surf.pos_y = 10;
    surf.blitToCanvas(&canvas, null);

    try std.testing.expectEqual(@as(u32, 0x112233), canvas.getPixel(14, 14));
    try std.testing.expectEqual(@as(u32, 0), canvas.getPixel(0, 0));
}
