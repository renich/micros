// MicrOS (µOS) Direct Framebuffer Graphics Substrate
// High-performance 2D vector & text canvas operating on UEFI GOP capabilities.
// Eradicates legacy terminal line disciplines in favor of direct GPU/memory surfaces.

const std = @import("std");
const boot_info_mod = @import("boot_info.zig");
const PixelFormat = boot_info_mod.PixelFormat;
const FramebufferInfo = boot_info_mod.FramebufferInfo;

const font_mod = @import("font.zig");

pub const Framebuffer = struct {
    base: [*]u8,
    size_bytes: usize,
    width: u32,
    height: u32,
    stride: u32,
    format: PixelFormat,

    pub fn init(info: FramebufferInfo) Framebuffer {
        return Framebuffer{
            .base = @as([*]u8, @ptrFromInt(info.base_addr)),
            .size_bytes = info.size_bytes,
            .width = info.width,
            .height = info.height,
            .stride = info.stride,
            .format = info.format,
        };
    }

    pub fn setPixel(self: *Framebuffer, x: u32, y: u32, color_rgb: u32) void {
        if (x >= self.width or y >= self.height) return;
        const offset = (@as(usize, y) * self.stride + x) * 4;
        if (offset + 4 > self.size_bytes) return;

        const r: u8 = @intCast((color_rgb >> 16) & 0xFF);
        const g: u8 = @intCast((color_rgb >> 8) & 0xFF);
        const b: u8 = @intCast(color_rgb & 0xFF);

        if (self.format == .bgr_888) {
            self.base[offset + 0] = b;
            self.base[offset + 1] = g;
            self.base[offset + 2] = r;
            self.base[offset + 3] = 0xFF;
        } else {
            self.base[offset + 0] = r;
            self.base[offset + 1] = g;
            self.base[offset + 2] = b;
            self.base[offset + 3] = 0xFF;
        }
    }

    pub fn clear(self: *Framebuffer, color_rgb: u32) void {
        const r: u8 = @intCast((color_rgb >> 16) & 0xFF);
        const g: u8 = @intCast((color_rgb >> 8) & 0xFF);
        const b: u8 = @intCast(color_rgb & 0xFF);
        const p0: u8 = if (self.format == .bgr_888) b else r;
        const p1: u8 = g;
        const p2: u8 = if (self.format == .bgr_888) r else b;
        const p3: u8 = 0xFF;

        const pix32: u32 = @as(u32, p0) | (@as(u32, p1) << 8) | (@as(u32, p2) << 16) | (@as(u32, p3) << 24);
        const pix64: u64 = @as(u64, pix32) | (@as(u64, pix32) << 32);
        const total_qwords = self.size_bytes / 8;
        const qwords: [*]align(1) u64 = @ptrCast(self.base);
        var i: usize = 0;
        while (i < total_qwords) : (i += 1) {
            qwords[i] = pix64;
        }
    }

    pub fn drawRect(self: *Framebuffer, x: u32, y: u32, w: u32, h: u32, color_rgb: u32) void {
        const max_y = @min(@as(u64, y) + h, self.height);
        const max_x = @min(@as(u64, x) + w, self.width);
        var cy: u32 = y;
        while (cy < max_y) : (cy += 1) {
            var cx: u32 = x;
            while (cx < max_x) : (cx += 1) {
                self.setPixel(cx, cy, color_rgb);
            }
        }
    }

    pub fn drawChar(self: *Framebuffer, x: u32, y: u32, c: u8, fg: u32, bg: u32) void {
        if (c < 32 or c > 126) return;
        const glyph = font_mod.FONT_8X8[c - 32];
        var row: u32 = 0;
        while (row < 8) : (row += 1) {
            const bits = glyph[row];
            var col: u32 = 0;
            while (col < 8) : (col += 1) {
                const is_fg = ((bits >> @intCast(col)) & 1) != 0;
                self.setPixel(x + col, y + row, if (is_fg) fg else bg);
            }
        }
    }

    pub fn drawString(self: *Framebuffer, x: u32, y: u32, str: []const u8, fg: u32, bg: u32) void {
        var cur_x = x;
        for (str) |c| {
            if (cur_x + 8 > self.width) break;
            self.drawChar(cur_x, y, c, fg, bg);
            cur_x += 8;
        }
    }
};

test "Framebuffer clear, setPixel, drawRect, and drawString" {
    var raw_buf: [64 * 64 * 4]u8 = [_]u8{0} ** (64 * 64 * 4);
    var fb = Framebuffer{
        .base = &raw_buf,
        .size_bytes = raw_buf.len,
        .width = 64,
        .height = 64,
        .stride = 64,
        .format = .rgb_888,
    };

    fb.clear(0x000000);
    try std.testing.expectEqual(@as(u8, 0), raw_buf[0]);

    fb.drawRect(10, 10, 5, 5, 0xFF0000);
    const pixel_offset = (10 * 64 + 10) * 4;
    try std.testing.expectEqual(@as(u8, 0xFF), raw_buf[pixel_offset + 0]); // R
    try std.testing.expectEqual(@as(u8, 0x00), raw_buf[pixel_offset + 1]); // G
    try std.testing.expectEqual(@as(u8, 0x00), raw_buf[pixel_offset + 2]); // B

    // Test text blitting including lowercase
    fb.drawString(0, 0, "MicrOS!", 0xFFFFFF, 0x000000);
    // Out of bounds guard test
    fb.setPixel(100, 100, 0xFFFFFF);
}
