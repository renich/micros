// MicrOS (µOS) Reactive Vector Compositor - Canvas & Damage Pipeline
// High-performance double-buffered backbuffer operating in page-aligned RAM.
// Tracks bounded axis-aligned bounding box (AABB) damage regions to minimize VRAM bus traffic.

const std = @import("std");
const boot_info_mod = @import("../boot_info.zig");
const PixelFormat = boot_info_mod.PixelFormat;
const fb_mod = @import("../fb.zig");
const font_mod = @import("../font.zig");

pub const PAGE_ALIGNMENT: usize = 4096;
pub const DEFAULT_CANVAS_WIDTH: u32 = 1280;
pub const DEFAULT_CANVAS_HEIGHT: u32 = 800;
pub const BYTES_PER_PIXEL: usize = 4;
pub const FONT_WIDTH: u32 = 8;
pub const FONT_HEIGHT: u32 = 8;
pub const COLOR_MASK_RGB: u32 = 0x00FF_FFFF;

pub const DamageRect = extern struct {
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,

    pub fn empty() DamageRect {
        return DamageRect{
            .min_x = std.math.maxInt(u32),
            .min_y = std.math.maxInt(u32),
            .max_x = 0,
            .max_y = 0,
        };
    }

    pub fn full(w: u32, h: u32) DamageRect {
        return DamageRect{
            .min_x = 0,
            .min_y = 0,
            .max_x = w,
            .max_y = h,
        };
    }

    pub fn isEmpty(self: DamageRect) bool {
        return self.min_x >= self.max_x or self.min_y >= self.max_y;
    }

    pub fn width(self: DamageRect) u32 {
        if (self.isEmpty()) return 0;
        return self.max_x - self.min_x;
    }

    pub fn height(self: DamageRect) u32 {
        if (self.isEmpty()) return 0;
        return self.max_y - self.min_y;
    }

    pub fn reset(self: *DamageRect) void {
        self.* = empty();
    }

    pub fn addPoint(self: *DamageRect, x: u32, y: u32) void {
        self.min_x = @min(self.min_x, x);
        self.min_y = @min(self.min_y, y);
        self.max_x = @max(self.max_x, x + 1);
        self.max_y = @max(self.max_y, y + 1);
    }

    pub fn addRect(self: *DamageRect, x: u32, y: u32, w: u32, h: u32, limit_w: u32, limit_h: u32) void {
        if (w == 0 or h == 0 or x >= limit_w or y >= limit_h) return;
        const clamped_max_x = @min(@as(u64, x) + w, limit_w);
        const clamped_max_y = @min(@as(u64, y) + h, limit_h);
        self.min_x = @min(self.min_x, x);
        self.min_y = @min(self.min_y, y);
        self.max_x = @max(self.max_x, @as(u32, @intCast(clamped_max_x)));
        self.max_y = @max(self.max_y, @as(u32, @intCast(clamped_max_y)));
    }

    pub fn unionWith(self: *DamageRect, other: DamageRect) void {
        if (other.isEmpty()) return;
        self.min_x = @min(self.min_x, other.min_x);
        self.min_y = @min(self.min_y, other.min_y);
        self.max_x = @max(self.max_x, other.max_x);
        self.max_y = @max(self.max_y, other.max_y);
    }

    pub fn intersectWith(self: *DamageRect, other: DamageRect) void {
        if (self.isEmpty() or other.isEmpty()) {
            self.reset();
            return;
        }
        self.min_x = @max(self.min_x, other.min_x);
        self.min_y = @max(self.min_y, other.min_y);
        self.max_x = @min(self.max_x, other.max_x);
        self.max_y = @min(self.max_y, other.max_y);
        if (self.min_x >= self.max_x or self.min_y >= self.max_y) {
            self.reset();
        }
    }
};

pub const Canvas = struct {
    pixels: []align(PAGE_ALIGNMENT) u32,
    width: u32,
    height: u32,
    stride: u32,
    format: PixelFormat,
    damage: DamageRect,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, format: PixelFormat) !Canvas {
        const total_pixels = @as(usize, width) * height;
        const align_val = comptime std.mem.Alignment.fromByteUnits(PAGE_ALIGNMENT);
        const pixels = try allocator.alignedAlloc(u32, align_val, total_pixels);
        errdefer allocator.free(pixels);

        @memset(pixels, 0);

        return Canvas{
            .pixels = pixels,
            .width = width,
            .height = height,
            .stride = width,
            .format = format,
            .damage = DamageRect.empty(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.allocator.free(self.pixels);
    }

    pub fn setPixelRaw(self: *Canvas, x: u32, y: u32, color_rgb: u32) void {
        if (x >= self.width or y >= self.height) return;
        const offset = @as(usize, y) * self.stride + x;
        self.pixels[offset] = color_rgb & COLOR_MASK_RGB;
    }

    pub fn setPixel(self: *Canvas, x: u32, y: u32, color_rgb: u32) void {
        if (x >= self.width or y >= self.height) return;
        self.setPixelRaw(x, y, color_rgb);
        self.damage.addPoint(x, y);
    }

    pub fn getPixel(self: *const Canvas, x: u32, y: u32) u32 {
        if (x >= self.width or y >= self.height) return 0;
        const offset = @as(usize, y) * self.stride + x;
        return self.pixels[offset];
    }

    pub fn clear(self: *Canvas, color_rgb: u32) void {
        const clean_color = color_rgb & COLOR_MASK_RGB;
        @memset(self.pixels, clean_color);
        self.damage = DamageRect.full(self.width, self.height);
    }

    pub fn drawRect(self: *Canvas, x: u32, y: u32, w: u32, h: u32, color_rgb: u32) void {
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

    pub fn drawChar(self: *Canvas, x: u32, y: u32, c: u8, fg: u32, bg: u32) void {
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

    pub fn drawString(self: *Canvas, x: u32, y: u32, str: []const u8, fg: u32, bg: u32) void {
        var cur_x = x;
        for (str) |c| {
            if (cur_x + FONT_WIDTH > self.width) break;
            self.drawChar(cur_x, y, c, fg, bg);
            cur_x += FONT_WIDTH;
        }
    }

    pub fn flush(self: *Canvas, vram: *fb_mod.Framebuffer) void {
        if (self.damage.isEmpty()) return;

        const x0 = @min(self.damage.min_x, @min(self.width, vram.width));
        const x1 = @min(self.damage.max_x, @min(self.width, vram.width));
        const y0 = @min(self.damage.min_y, @min(self.height, vram.height));
        const y1 = @min(self.damage.max_y, @min(self.height, vram.height));

        if (x0 < x1 and y0 < y1) {
            var y = y0;
            while (y < y1) : (y += 1) {
                self.flushRow(vram, y, x0, x1);
            }
        }
        self.damage.reset();
    }

    fn flushRow(self: *const Canvas, vram: *fb_mod.Framebuffer, y: u32, x0: u32, x1: u32) void {
        var x = x0;
        while (x < x1) : (x += 1) {
            const color = self.getPixel(x, y);
            vram.setPixel(x, y, color);
        }
    }
};

test "DamageRect union, intersect, and bounds math" {
    var dmg = DamageRect.empty();
    try std.testing.expect(dmg.isEmpty());
    try std.testing.expectEqual(@as(u32, 0), dmg.width());

    dmg.addPoint(10, 20);
    try std.testing.expect(!dmg.isEmpty());
    try std.testing.expectEqual(@as(u32, 10), dmg.min_x);
    try std.testing.expectEqual(@as(u32, 20), dmg.min_y);
    try std.testing.expectEqual(@as(u32, 11), dmg.max_x);
    try std.testing.expectEqual(@as(u32, 21), dmg.max_y);

    const other = DamageRect{ .min_x = 5, .min_y = 15, .max_x = 25, .max_y = 35 };
    dmg.unionWith(other);
    try std.testing.expectEqual(@as(u32, 5), dmg.min_x);
    try std.testing.expectEqual(@as(u32, 15), dmg.min_y);
    try std.testing.expectEqual(@as(u32, 25), dmg.max_x);
    try std.testing.expectEqual(@as(u32, 35), dmg.max_y);

    const clip = DamageRect{ .min_x = 10, .min_y = 20, .max_x = 20, .max_y = 30 };
    dmg.intersectWith(clip);
    try std.testing.expectEqual(@as(u32, 10), dmg.min_x);
    try std.testing.expectEqual(@as(u32, 20), dmg.min_y);
    try std.testing.expectEqual(@as(u32, 20), dmg.max_x);
    try std.testing.expectEqual(@as(u32, 30), dmg.max_y);
}

test "Canvas page-aligned allocation, drawing, and VRAM flush" {
    const allocator = std.testing.allocator;
    var canvas = try Canvas.init(allocator, 64, 64, .rgb_888);
    defer canvas.deinit();

    // Verify 4096-byte page alignment mathematically
    const ptr_val = @intFromPtr(canvas.pixels.ptr);
    try std.testing.expectEqual(@as(usize, 0), ptr_val % PAGE_ALIGNMENT);

    canvas.clear(0x112233);
    try std.testing.expectEqual(@as(u32, 0x112233), canvas.getPixel(0, 0));
    try std.testing.expectEqual(@as(u32, 64), canvas.damage.width());
    try std.testing.expectEqual(@as(u32, 64), canvas.damage.height());

    // Prepare simulated VRAM framebuffer
    var vram_raw: [64 * 64 * 4]u8 = [_]u8{0} ** (64 * 64 * 4);
    var vram = fb_mod.Framebuffer{
        .base = &vram_raw,
        .size_bytes = vram_raw.len,
        .width = 64,
        .height = 64,
        .stride = 64,
        .format = .rgb_888,
    };

    // Flush clear into VRAM
    canvas.flush(&vram);
    try std.testing.expect(canvas.damage.isEmpty());
    try std.testing.expectEqual(@as(u8, 0x11), vram_raw[0]);
    try std.testing.expectEqual(@as(u8, 0x22), vram_raw[1]);
    try std.testing.expectEqual(@as(u8, 0x33), vram_raw[2]);

    // Draw partial rect and flush damage region only
    canvas.drawRect(8, 8, 16, 16, 0xAABBCC);
    try std.testing.expectEqual(@as(u32, 8), canvas.damage.min_x);
    try std.testing.expectEqual(@as(u32, 8), canvas.damage.min_y);
    try std.testing.expectEqual(@as(u32, 24), canvas.damage.max_x);
    try std.testing.expectEqual(@as(u32, 24), canvas.damage.max_y);

    canvas.flush(&vram);
    try std.testing.expect(canvas.damage.isEmpty());
    const offset = (8 * 64 + 8) * 4;
    try std.testing.expectEqual(@as(u8, 0xAA), vram_raw[offset + 0]);
    try std.testing.expectEqual(@as(u8, 0xBB), vram_raw[offset + 1]);
    try std.testing.expectEqual(@as(u8, 0xCC), vram_raw[offset + 2]);
}
