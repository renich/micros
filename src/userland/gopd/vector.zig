// MicrOS (µOS) AABB-Bounded Vector Rasterizer & Glyph Atlas Cache
// SPEC-TECH-UI-002: Fixed-point 16.16 math, Signed Distance Field (SDF) primitives,
// anti-aliased alpha blending, and zero-allocation glyph atlas cache. Freestanding, zero libc.

const std = @import("std");
const hypertree = @import("hypertree.zig");
pub const DamageRect = hypertree.DamageRect;

pub const ATLAS_WIDTH: usize = 256;
pub const ATLAS_HEIGHT: usize = 256;
pub const MAX_GLYPHS: usize = 128;

pub inline fn fp(v: i32) i32 {
    return v << 16;
}

pub inline fn fpToInt(v: i32) i32 {
    return v >> 16;
}

pub inline fn fpMul(a: i32, b: i32) i32 {
    const p = @as(i64, a) * @as(i64, b);
    return @intCast(p >> 16);
}

pub fn intSqrt(val: u32) u32 {
    if (val == 0) return 0;
    var x0 = val / 2;
    if (x0 == 0) return 1;
    var x1 = (x0 + val / x0) / 2;
    while (x1 < x0) {
        x0 = x1;
        x1 = (x0 + val / x0) / 2;
    }
    return x0;
}

pub fn blendColor(src: u32, dst: u32, alpha: u8) u32 {
    if (alpha == 0) return dst;
    if (alpha == 255) return src;

    const inv_a: u32 = 255 - @as(u32, alpha);
    const a: u32 = @as(u32, alpha);

    const sr = (src >> 16) & 0xFF;
    const sg = (src >> 8) & 0xFF;
    const sb = src & 0xFF;

    const dr = (dst >> 16) & 0xFF;
    const dg = (dst >> 8) & 0xFF;
    const db = dst & 0xFF;

    const out_r = (sr * a + dr * inv_a) / 255;
    const out_g = (sg * a + dg * inv_a) / 255;
    const out_b = (sb * a + db * inv_a) / 255;

    return (out_r << 16) | (out_g << 8) | out_b;
}

pub const VectorCanvas = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    stride: u32,

    pub fn setPixelBlend(self: *VectorCanvas, x: u32, y: u32, color: u32, alpha: u8) void {
        if (x >= self.width or y >= self.height) return;
        const idx = y * self.stride + x;
        if (idx >= self.pixels.len) return;
        self.pixels[idx] = blendColor(color, self.pixels[idx], alpha);
    }

    inline fn boxDistance(x: i32, y: i32, cx: i32, cy: i32, hw: i32, hh: i32, r: i32) i32 {
        const dx = @as(i32, @intCast(@abs(x - cx))) - (hw - r);
        const dy = @as(i32, @intCast(@abs(y - cy))) - (hh - r);
        const qx = @max(dx, 0);
        const qy = @max(dy, 0);
        return @as(i32, @intCast(intSqrt(@intCast(qx * qx + qy * qy)))) + @min(@max(dx, dy), 0) - r;
    }

    pub fn drawRoundedRect(
        self: *VectorCanvas,
        rx: i32,
        ry: i32,
        rw: u32,
        rh: u32,
        radius: u32,
        color: u32,
        bounds: ?DamageRect,
    ) void {
        const half_w: i32 = @intCast(rw / 2);
        const half_h: i32 = @intCast(rh / 2);
        const cx = rx + half_w;
        const cy = ry + half_h;
        const r: i32 = @intCast(radius);

        const x_min = @max(0, rx);
        const y_min = @max(0, ry);
        const x_max = @min(@as(i32, @intCast(self.width)), rx + @as(i32, @intCast(rw)));
        const y_max = @min(@as(i32, @intCast(self.height)), ry + @as(i32, @intCast(rh)));

        var y = y_min;
        while (y < y_max) : (y += 1) {
            if (bounds) |b| {
                if (y < b.min_y or y >= b.max_y) continue;
            }
            var x = x_min;
            while (x < x_max) : (x += 1) {
                if (bounds) |b| {
                    if (x < b.min_x or x >= b.max_x) continue;
                }
                const dist = boxDistance(x, y, cx, cy, half_w, half_h, r);
                if (dist <= 0) {
                    self.setPixelBlend(@intCast(x), @intCast(y), color, 255);
                } else if (dist < 2) {
                    const alpha: u8 = @intCast(255 - dist * 120);
                    self.setPixelBlend(@intCast(x), @intCast(y), color, alpha);
                }
            }
        }
    }

    pub fn drawCircle(
        self: *VectorCanvas,
        cx: i32,
        cy: i32,
        radius: u32,
        color: u32,
    ) void {
        const r: i32 = @intCast(radius);
        const x0 = @max(0, cx - r - 1);
        const x1 = @min(@as(i32, @intCast(self.width)), cx + r + 2);
        const y0 = @max(0, cy - r - 1);
        const y1 = @min(@as(i32, @intCast(self.height)), cy + r + 2);

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const dx = x - cx;
                const dy = y - cy;
                const dist_sq: u32 = @intCast(dx * dx + dy * dy);
                const dist = intSqrt(dist_sq);
                if (dist <= radius) {
                    self.setPixelBlend(@intCast(x), @intCast(y), color, 255);
                } else if (dist <= radius + 1) {
                    self.setPixelBlend(@intCast(x), @intCast(y), color, 128);
                }
            }
        }
    }

    pub fn drawDropShadow(
        self: *VectorCanvas,
        rx: i32,
        ry: i32,
        rw: u32,
        rh: u32,
        spread: u32,
        shadow_color: u32,
    ) void {
        if (spread == 0) return;
        const sx = rx - @as(i32, @intCast(spread));
        const sy = ry - @as(i32, @intCast(spread));
        const sw = rw + spread * 2;
        const sh = rh + spread * 2;
        const x0 = @max(0, sx);
        const y0 = @max(0, sy);
        const x1 = @min(@as(i32, @intCast(self.width)), sx + @as(i32, @intCast(sw)));
        const y1 = @min(@as(i32, @intCast(self.height)), sy + @as(i32, @intCast(sh)));

        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                // Skip inner rectangle
                if (x >= rx and x < rx + @as(i32, @intCast(rw)) and
                    y >= ry and y < ry + @as(i32, @intCast(rh))) continue;

                const dx: u32 = if (x < rx) @intCast(rx - x) else if (x >= rx + @as(i32, @intCast(rw))) @intCast(x - (rx + @as(i32, @intCast(rw)))) else 0;
                const dy: u32 = if (y < ry) @intCast(ry - y) else if (y >= ry + @as(i32, @intCast(rh))) @intCast(y - (ry + @as(i32, @intCast(rh)))) else 0;
                const dist = intSqrt(dx * dx + dy * dy);
                if (dist < spread) {
                    const a: u8 = @intCast(120 - (dist * 120 / spread));
                    self.setPixelBlend(@intCast(x), @intCast(y), shadow_color, a);
                }
            }
        }
    }
};

pub const GlyphKey = struct {
    codepoint: u16,
    size_px: u8,
    weight: u16,

    pub fn equals(a: GlyphKey, b: GlyphKey) bool {
        return a.codepoint == b.codepoint and a.size_px == b.size_px and a.weight == b.weight;
    }
};

pub const CachedGlyph = struct {
    atlas_x: u16,
    atlas_y: u16,
    width: u8,
    height: u8,
    advance: u8,
    valid: bool,
};

pub const GlyphAtlasCache = struct {
    atlas: [ATLAS_WIDTH * ATLAS_HEIGHT]u8,
    keys: [MAX_GLYPHS]GlyphKey,
    glyphs: [MAX_GLYPHS]CachedGlyph,
    count: usize,
    shelf_x: u16,
    shelf_y: u16,
    shelf_h: u16,

    pub fn init() GlyphAtlasCache {
        return GlyphAtlasCache{
            .atlas = [_]u8{0} ** (ATLAS_WIDTH * ATLAS_HEIGHT),
            .keys = [_]GlyphKey{std.mem.zeroes(GlyphKey)} ** MAX_GLYPHS,
            .glyphs = [_]CachedGlyph{std.mem.zeroes(CachedGlyph)} ** MAX_GLYPHS,
            .count = 0,
            .shelf_x = 0,
            .shelf_y = 0,
            .shelf_h = 0,
        };
    }

    pub fn find(self: *const GlyphAtlasCache, key: GlyphKey) ?CachedGlyph {
        for (0..self.count) |i| {
            if (self.glyphs[i].valid and self.keys[i].equals(key)) {
                return self.glyphs[i];
            }
        }
        return null;
    }

    fn copyMaskToAtlas(self: *GlyphAtlasCache, gx: usize, gy: usize, w: usize, h: usize, mask_data: []const u8) void {
        var row: usize = 0;
        while (row < h) : (row += 1) {
            const dest_offset = (gy + row) * ATLAS_WIDTH + gx;
            const src_offset = row * w;
            if (src_offset + w <= mask_data.len) {
                @memcpy(self.atlas[dest_offset .. dest_offset + w], mask_data[src_offset .. src_offset + w]);
            }
        }
    }

    pub fn insertGlyph(
        self: *GlyphAtlasCache,
        key: GlyphKey,
        w: u8,
        h: u8,
        advance: u8,
        mask_data: []const u8,
    ) !CachedGlyph {
        if (self.count >= MAX_GLYPHS) return error.AtlasFull;
        if (@as(usize, self.shelf_x) + w >= ATLAS_WIDTH) {
            self.shelf_x = 0;
            self.shelf_y += self.shelf_h;
            self.shelf_h = 0;
        }
        if (@as(usize, self.shelf_y) + h >= ATLAS_HEIGHT) return error.AtlasFull;

        const gx = self.shelf_x;
        const gy = self.shelf_y;
        self.copyMaskToAtlas(gx, gy, w, h, mask_data);

        self.shelf_x += w + 1;
        if (h > self.shelf_h) self.shelf_h = h;

        const cached = CachedGlyph{
            .atlas_x = gx,
            .atlas_y = gy,
            .width = w,
            .height = h,
            .advance = advance,
            .valid = true,
        };

        self.keys[self.count] = key;
        self.glyphs[self.count] = cached;
        self.count += 1;
        return cached;
    }

    pub fn renderGlyph(
        self: *const GlyphAtlasCache,
        canvas: *VectorCanvas,
        cached: CachedGlyph,
        dest_x: i32,
        dest_y: i32,
        fg_color: u32,
    ) void {
        var row: usize = 0;
        while (row < cached.height) : (row += 1) {
            const py = dest_y + @as(i32, @intCast(row));
            if (py < 0 or py >= canvas.height) continue;

            const atlas_row_start = (@as(usize, cached.atlas_y) + row) * ATLAS_WIDTH + cached.atlas_x;
            var col: usize = 0;
            while (col < cached.width) : (col += 1) {
                const px = dest_x + @as(i32, @intCast(col));
                if (px < 0 or px >= canvas.width) continue;

                const alpha = self.atlas[atlas_row_start + col];
                if (alpha > 0) {
                    canvas.setPixelBlend(@intCast(px), @intCast(py), fg_color, alpha);
                }
            }
        }
    }
};

test "intSqrt integer square root correctness" {
    try std.testing.expectEqual(@as(u32, 0), intSqrt(0));
    try std.testing.expectEqual(@as(u32, 1), intSqrt(1));
    try std.testing.expectEqual(@as(u32, 3), intSqrt(9));
    try std.testing.expectEqual(@as(u32, 4), intSqrt(16));
    try std.testing.expectEqual(@as(u32, 5), intSqrt(25));
    try std.testing.expectEqual(@as(u32, 10), intSqrt(100));
}

test "blendColor Porter-Duff Over alpha blending" {
    // 0% alpha -> dst remains
    try std.testing.expectEqual(@as(u32, 0x0000_0000), blendColor(0x00FF_FFFF, 0x0000_0000, 0));
    // 100% alpha -> src replaces
    try std.testing.expectEqual(@as(u32, 0x00FF_FFFF), blendColor(0x00FF_FFFF, 0x0000_0000, 255));
    // 50% blend of white (0xFFFFFF) and black (0x000000) -> 0x7F7F7F
    const mid = blendColor(0x00FF_FFFF, 0x0000_0000, 128);
    const r = (mid >> 16) & 0xFF;
    const g = (mid >> 8) & 0xFF;
    const b = mid & 0xFF;
    try std.testing.expect(r >= 127 and r <= 128);
    try std.testing.expect(g >= 127 and g <= 128);
    try std.testing.expect(b >= 127 and b <= 128);
}

test "VectorCanvas rounded rectangle, circle, and shadow rasterization" {
    var raw_pixels: [64 * 64]u32 = [_]u32{0} ** (64 * 64);
    var canvas = VectorCanvas{
        .pixels = &raw_pixels,
        .width = 64,
        .height = 64,
        .stride = 64,
    };

    // Draw circle centered at (32, 32) radius 10
    canvas.drawCircle(32, 32, 10, 0x00FF_0000);
    // Center pixel must be red
    try std.testing.expectEqual(@as(u32, 0x00FF_0000), raw_pixels[32 * 64 + 32]);
    // Corner pixel must still be black
    try std.testing.expectEqual(@as(u32, 0x0000_0000), raw_pixels[0]);

    // Draw rounded rect
    canvas.drawRoundedRect(10, 10, 20, 20, 4, 0x0000_FF00, null);
    try std.testing.expectEqual(@as(u32, 0x0000_FF00), raw_pixels[15 * 64 + 15]);

    // Draw drop shadow
    canvas.drawDropShadow(10, 10, 20, 20, 5, 0x0033_3333);
    try std.testing.expect(raw_pixels[8 * 64 + 8] != 0);
}

test "GlyphAtlasCache insertion, hit test, and canvas rendering" {
    var cache = GlyphAtlasCache.init();
    const key = GlyphKey{ .codepoint = 'A', .size_px = 16, .weight = 400 };

    var mock_mask = [_]u8{255} ** (8 * 8);
    const cached = try cache.insertGlyph(key, 8, 8, 8, &mock_mask);

    try std.testing.expect(cached.valid);
    try std.testing.expectEqual(@as(u8, 8), cached.width);
    try std.testing.expectEqual(@as(u8, 8), cached.height);

    const hit = cache.find(key);
    try std.testing.expect(hit != null);
    try std.testing.expectEqual(cached.atlas_x, hit.?.atlas_x);

    var raw_pixels: [32 * 32]u32 = [_]u32{0} ** (32 * 32);
    var canvas = VectorCanvas{
        .pixels = &raw_pixels,
        .width = 32,
        .height = 32,
        .stride = 32,
    };

    cache.renderGlyph(&canvas, cached, 4, 4, 0x00FF_FFFF);
    try std.testing.expectEqual(@as(u32, 0x00FF_FFFF), raw_pixels[4 * 32 + 4]);
}
