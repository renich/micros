// MicrOS (µOS) Graphics Output Protocol Daemon (gopd)
// Isolated userland service actor executing double-buffered vector compositing,
// AABB damage tracking, dynamic window management, and pointer/keyboard input routing.
// Controlled via CSpace capabilities. Freestanding, zero libc.

const std = @import("std");
const cap_mod = @import("../../kernel/cap/capability.zig");
const compositor_mod = @import("../../kernel/compositor.zig");
const boot_info_mod = @import("../../kernel/boot_info.zig");
const fb_mod = @import("../../kernel/fb.zig");

pub const DaemonState = enum(u8) {
    uninitialized = 0,
    offline = 1,
    active = 2,
    suspended = 3,
    faulted = 4,
};

pub const GopIpcCommand = enum(u8) {
    none = 0,
    create_surface = 1,
    destroy_surface = 2,
    commit_surface = 3,
    set_mode = 4,
    handle_input = 5,
    flush_damage = 6,
    status = 7,
};

pub const GopDaemon = struct {
    allocator: std.mem.Allocator,
    fb_cap: cap_mod.Capability,
    canvas: compositor_mod.Canvas,
    wm: compositor_mod.WindowManager,
    pointer: compositor_mod.PointerState,
    mouse_decoder: compositor_mod.Ps2MouseDecoder,
    state: DaemonState,
    frames_presented: u64,
    damage_flushes: u64,
    input_events_processed: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        fb_info: boot_info_mod.FramebufferInfo,
        fb_cap: cap_mod.Capability,
    ) !GopDaemon {
        if (fb_cap.cap_type != .framebuffer or !fb_cap.hasRight(cap_mod.Rights.WRITE)) {
            return error.PermissionDenied;
        }
        if (fb_info.base_addr == 0 or fb_info.width == 0 or fb_info.height == 0) {
            return error.InvalidFramebuffer;
        }

        var canvas = try compositor_mod.Canvas.init(
            allocator,
            fb_info.width,
            fb_info.height,
            fb_info.format,
        );
        errdefer canvas.deinit();

        var wm = compositor_mod.WindowManager.init(allocator, fb_info.width, fb_info.height);
        errdefer wm.deinit();

        const pointer = compositor_mod.PointerState.init(fb_info.width, fb_info.height);
        const mouse_decoder = compositor_mod.Ps2MouseDecoder.init();

        return GopDaemon{
            .allocator = allocator,
            .fb_cap = fb_cap,
            .canvas = canvas,
            .wm = wm,
            .pointer = pointer,
            .mouse_decoder = mouse_decoder,
            .state = .active,
            .frames_presented = 0,
            .damage_flushes = 0,
            .input_events_processed = 0,
        };
    }

    pub fn deinit(self: *GopDaemon) void {
        if (self.state != .uninitialized and self.state != .offline) {
            self.wm.deinit();
            self.canvas.deinit();
            self.state = .offline;
        }
    }

    pub fn createSurface(
        self: *GopDaemon,
        width: u32,
        height: u32,
        actor_id: u32,
    ) !*compositor_mod.Surface {
        if (self.state != .active) return error.DaemonNotActive;
        return compositor_mod.Surface.init(self.allocator, width, height, actor_id);
    }

    pub fn destroySurface(self: *GopDaemon, surf: *compositor_mod.Surface) void {
        surf.deinit(self.allocator);
    }

    pub fn createWindow(
        self: *GopDaemon,
        actor_id: u32,
        title: []const u8,
        w: u32,
        h: u32,
        mode: compositor_mod.WindowMode,
    ) !u32 {
        if (self.state != .active) return error.DaemonNotActive;
        const win = try self.wm.createWindow(actor_id, title, w, h, mode);
        return win.id;
    }

    pub fn commitSurface(self: *GopDaemon, commit: compositor_mod.SurfaceCommit) bool {
        if (self.state != .active) return false;
        var i: usize = 0;
        while (i < self.wm.window_count) : (i += 1) {
            const win = self.wm.windows[i] orelse continue;
            if (win.surface.actor_id == commit.surface.actor_id) {
                self.wm.commitSurface(win, commit);
                return true;
            }
        }
        return false;
    }

    pub fn handleMouseByte(self: *GopDaemon, byte: u8) ?compositor_mod.MouseEvent {
        if (self.state != .active) return null;
        const ev = self.mouse_decoder.processByte(byte) orelse return null;
        self.pointer.update(ev, &self.wm, &self.canvas);
        self.input_events_processed += 1;
        return ev;
    }

    pub fn handleMousePacket(
        self: *GopDaemon,
        b0: u8,
        b1: u8,
        b2: u8,
    ) ?compositor_mod.MouseEvent {
        _ = self.handleMouseByte(b0);
        _ = self.handleMouseByte(b1);
        return self.handleMouseByte(b2);
    }

    pub fn handleKeyboardScancode(self: *GopDaemon, scancode: u8) void {
        if (self.state != .active) return;
        self.input_events_processed += 1;
        _ = scancode;
    }

    fn copyRow(
        self: *const GopDaemon,
        vram_slice: []u32,
        y: u32,
        x0: u32,
        x1: u32,
    ) usize {
        const row_offset = @as(usize, y) * self.canvas.stride;
        var copied: usize = 0;
        var x = x0;
        while (x < x1) : (x += 1) {
            const idx = row_offset + x;
            if (idx >= vram_slice.len or idx >= self.canvas.pixels.len) continue;
            vram_slice[idx] = self.canvas.pixels[idx];
            copied += 1;
        }
        return copied;
    }

    pub fn presentFrame(self: *GopDaemon, vram_slice: []u32) usize {
        if (self.state != .active) return 0;
        if (self.canvas.damage.isEmpty()) return 0;

        const dmg = self.canvas.damage;
        const x0 = @min(dmg.min_x, self.canvas.width);
        const x1 = @min(dmg.max_x, self.canvas.width);
        const y0 = @min(dmg.min_y, self.canvas.height);
        const y1 = @min(dmg.max_y, self.canvas.height);

        if (x0 >= x1 or y0 >= y1) {
            self.canvas.damage.reset();
            return 0;
        }

        var pixels_copied: usize = 0;
        var y = y0;
        while (y < y1) : (y += 1) {
            pixels_copied += self.copyRow(vram_slice, y, x0, x1);
        }

        self.canvas.damage.reset();
        self.frames_presented += 1;
        self.damage_flushes += 1;
        return pixels_copied;
    }

    pub fn poll(self: *GopDaemon) void {
        if (self.state != .active) return;
        self.wm.composeAllWindows(&self.canvas);
    }
};

test "GopDaemon initialization with valid framebuffer capability" {
    const allocator = std.testing.allocator;
    const fb_info = boot_info_mod.FramebufferInfo{
        .base_addr = 0xE000_0000,
        .size_bytes = 1280 * 800 * 4,
        .width = 1280,
        .height = 800,
        .stride = 1280,
        .format = .rgb_888,
    };
    const valid_cap = cap_mod.Capability{
        .cap_type = .framebuffer,
        .rights = cap_mod.Rights.WRITE | cap_mod.Rights.READ,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 1280 * 800 * 4,
    };

    var daemon = try GopDaemon.init(allocator, fb_info, valid_cap);
    defer daemon.deinit();

    try std.testing.expectEqual(DaemonState.active, daemon.state);
    try std.testing.expectEqual(@as(u32, 1280), daemon.canvas.width);
    try std.testing.expectEqual(@as(u32, 800), daemon.canvas.height);
    try std.testing.expectEqual(@as(u64, 0), daemon.frames_presented);
}

test "GopDaemon rejects unauthorized capability token" {
    const allocator = std.testing.allocator;
    const fb_info = boot_info_mod.FramebufferInfo{
        .base_addr = 0xE000_0000,
        .size_bytes = 1280 * 800 * 4,
        .width = 1280,
        .height = 800,
        .stride = 1280,
        .format = .rgb_888,
    };
    // Unauthorized capability (wrong cap_type and lacking WRITE rights)
    const read_only_cap = cap_mod.Capability{
        .cap_type = .memory_extent,
        .rights = cap_mod.Rights.READ,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 4096,
    };
    try std.testing.expectError(error.PermissionDenied, GopDaemon.init(allocator, fb_info, read_only_cap));
}

test "GopDaemon surface creation and window management" {
    const allocator = std.testing.allocator;
    const fb_info = boot_info_mod.FramebufferInfo{
        .base_addr = 0xE000_0000,
        .size_bytes = 1280 * 800 * 4,
        .width = 1280,
        .height = 800,
        .stride = 1280,
        .format = .rgb_888,
    };
    const valid_cap = cap_mod.Capability{
        .cap_type = .framebuffer,
        .rights = cap_mod.Rights.WRITE,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 1280 * 800 * 4,
    };

    var daemon = try GopDaemon.init(allocator, fb_info, valid_cap);
    defer daemon.deinit();

    const win_id = try daemon.createWindow(10, "Terminal", 400, 300, .tiled);
    try std.testing.expectEqual(@as(u32, 1), win_id);
    try std.testing.expectEqual(@as(usize, 1), daemon.wm.window_count);
}

test "GopDaemon PS/2 mouse packet processing and pointer movement" {
    const allocator = std.testing.allocator;
    const fb_info = boot_info_mod.FramebufferInfo{
        .base_addr = 0xE000_0000,
        .size_bytes = 1280 * 800 * 4,
        .width = 1280,
        .height = 800,
        .stride = 1280,
        .format = .rgb_888,
    };
    const valid_cap = cap_mod.Capability{
        .cap_type = .framebuffer,
        .rights = cap_mod.Rights.WRITE,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 1280 * 800 * 4,
    };

    var daemon = try GopDaemon.init(allocator, fb_info, valid_cap);
    defer daemon.deinit();

    // Standard PS/2 packet: bit 3 set, dx = +15, dy = +10
    const ev = daemon.handleMousePacket(0x08, 15, 10);
    try std.testing.expect(ev != null);
    try std.testing.expectEqual(@as(u64, 1), daemon.input_events_processed);
}

test "GopDaemon double-buffered damage flush to VRAM slice" {
    const allocator = std.testing.allocator;
    const fb_info = boot_info_mod.FramebufferInfo{
        .base_addr = 0xE000_0000,
        .size_bytes = 100 * 100 * 4,
        .width = 100,
        .height = 100,
        .stride = 100,
        .format = .rgb_888,
    };
    const valid_cap = cap_mod.Capability{
        .cap_type = .framebuffer,
        .rights = cap_mod.Rights.WRITE,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 100 * 100 * 4,
    };

    var daemon = try GopDaemon.init(allocator, fb_info, valid_cap);
    defer daemon.deinit();

    // Draw a small 10x10 red square on canvas
    daemon.canvas.drawRect(10, 10, 10, 10, 0x00FF_0000);
    try std.testing.expect(!daemon.canvas.damage.isEmpty());

    var mock_vram: [100 * 100]u32 = [_]u32{0} ** (100 * 100);
    const copied = daemon.presentFrame(&mock_vram);
    try std.testing.expectEqual(@as(usize, 100), copied);
    try std.testing.expect(daemon.canvas.damage.isEmpty());
    try std.testing.expectEqual(@as(u64, 1), daemon.frames_presented);
    try std.testing.expectEqual(@as(u32, 0x00FF_0000), mock_vram[10 * 100 + 10]);
}
