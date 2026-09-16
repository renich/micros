const std = @import("std");

pub const BoxAssert = struct {
    x: usize,
    y: usize,
    w: usize,
    h: usize,
    r: u8,
    g: u8,
    b: u8,
};

pub const Image = struct {
    width: usize,
    height: usize,
    max_val: usize,
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Image) void {
        self.allocator.free(self.pixels);
    }

    pub fn getPixel(self: *const Image, x: usize, y: usize) [3]u8 {
        if (x >= self.width or y >= self.height) return .{ 0, 0, 0 };
        const idx = (y * self.width + x) * 3;
        return .{ self.pixels[idx], self.pixels[idx + 1], self.pixels[idx + 2] };
    }

    pub fn calculateVariance(self: *const Image) f64 {
        if (self.pixels.len == 0) return 0.0;
        var sum: f64 = 0.0;
        for (self.pixels) |byte| {
            sum += @floatFromInt(byte);
        }
        const mean = sum / @as(f64, @floatFromInt(self.pixels.len));

        var var_sum: f64 = 0.0;
        for (self.pixels) |byte| {
            const diff = @as(f64, @floatFromInt(byte)) - mean;
            var_sum += diff * diff;
        }
        return @sqrt(var_sum / @as(f64, @floatFromInt(self.pixels.len)));
    }

    fn checkPixelRow(self: *const Image, box: BoxAssert, cur_y: usize, tolerance: u8, total: *usize) usize {
        var matches: usize = 0;
        var cur_x = box.x;
        while (cur_x < box.x + box.w and cur_x < self.width) : (cur_x += 1) {
            const p = self.getPixel(cur_x, cur_y);
            const dr = @abs(@as(i16, p[0]) - @as(i16, box.r));
            const dg = @abs(@as(i16, p[1]) - @as(i16, box.g));
            const db = @abs(@as(i16, p[2]) - @as(i16, box.b));
            if (dr <= tolerance and dg <= tolerance and db <= tolerance) matches += 1;
            total.* += 1;
        }
        return matches;
    }

    pub fn checkColorBox(self: *const Image, box: BoxAssert, tolerance: u8) f64 {
        var match_count: usize = 0;
        var total_count: usize = 0;

        var cur_y = box.y;
        while (cur_y < box.y + box.h and cur_y < self.height) : (cur_y += 1) {
            match_count += self.checkPixelRow(box, cur_y, tolerance, &total_count);
        }

        if (total_count == 0) return 0.0;
        return @as(f64, @floatFromInt(match_count)) / @as(f64, @floatFromInt(total_count));
    }
};

pub fn parsePpmP6(allocator: std.mem.Allocator, data: []const u8) !Image {
    var it = std.mem.tokenizeAny(u8, data, " \t\r\n");
    const magic = it.next() orelse return error.InvalidFormat;
    if (!std.mem.eql(u8, magic, "P6")) return error.UnsupportedFormat;

    const w_str = it.next() orelse return error.InvalidHeader;
    const h_str = it.next() orelse return error.InvalidHeader;
    const max_str = it.next() orelse return error.InvalidHeader;

    const width = try std.fmt.parseInt(usize, w_str, 10);
    const height = try std.fmt.parseInt(usize, h_str, 10);
    const max_val = try std.fmt.parseInt(usize, max_str, 10);

    var header_end = it.index;
    if (header_end < data.len and (data[header_end] == ' ' or data[header_end] == '\t' or data[header_end] == '\r' or data[header_end] == '\n')) {
        header_end += 1;
    }

    const expected_bytes = width * height * 3;
    if (data.len < header_end + expected_bytes) return error.UnexpectedEof;

    const pixel_data = data[header_end .. header_end + expected_bytes];
    const pixels = try allocator.dupe(u8, pixel_data);

    return Image{
        .width = width,
        .height = height,
        .max_val = max_val,
        .pixels = pixels,
        .allocator = allocator,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = init.minimal.args.iterate();
    _ = args.skip(); // skip binary name

    var file_path: ?[]const u8 = null;
    var expected_w: usize = 1280;
    var expected_h: usize = 800;
    var min_variance: f64 = 10.0;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--width")) {
            if (args.next()) |v| expected_w = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--height")) {
            if (args.next()) |v| expected_h = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--min-variance")) {
            if (args.next()) |v| min_variance = try std.fmt.parseFloat(f64, v);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            file_path = arg;
        }
    }

    const path = file_path orelse {
        std.debug.print("Usage: micros-fb-verify [options] <image.ppm>\n", .{});
        std.process.exit(1);
    };

    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        init.io,
        path,
        allocator,
        .limited(64 * 1024 * 1024),
        .of(u8),
        0,
    );
    defer allocator.free(source);

    var img = try parsePpmP6(allocator, source);
    defer img.deinit();

    if (img.width != expected_w or img.height != expected_h) {
        std.debug.print("FAIL: Dimensions {}x{} != expected {}x{}\n", .{ img.width, img.height, expected_w, expected_h });
        std.process.exit(1);
    }

    const v = img.calculateVariance();
    if (v < min_variance) {
        std.debug.print("FAIL: Color variance {d:.2} < minimum threshold {d:.2}\n", .{ v, min_variance });
        std.process.exit(1);
    }

    std.debug.print("PASS: Framebuffer verified ({}x{}, variance {d:.2}).\n", .{ img.width, img.height, v });
}

const testing = std.testing;

test "PPM P6 parser and variance audit" {
    const raw_ppm = "P6\n2 2\n255\n" ++
        "\xFF\x00\x00" ++ "\x00\xFF\x00" ++
        "\x00\x00\xFF" ++ "\xFF\xFF\xFF";

    var img = try parsePpmP6(testing.allocator, raw_ppm);
    defer img.deinit();

    try testing.expectEqual(@as(usize, 2), img.width);
    try testing.expectEqual(@as(usize, 2), img.height);
    try testing.expect(img.calculateVariance() > 50.0);

    const box = BoxAssert{ .x = 0, .y = 0, .w = 1, .h = 1, .r = 0xFF, .g = 0, .b = 0 };
    const ratio = img.checkColorBox(box, 5);
    try testing.expectEqual(@as(f64, 1.0), ratio);
}
