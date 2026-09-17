// MicrOS (µOS) Sovereign Tool Dispatcher & CSpace Security Gate
// Object-capability authorized execution of AI system tools.

const std = @import("std");
const tools = @import("tools.zig");
const cap_mod = @import("../cap/capability.zig");
const CapType = cap_mod.CapType;
const Rights = cap_mod.Rights;
const cspace_mod = @import("../cap/cspace.zig");
const CSpace = cspace_mod.CSpace;

pub const DispatcherContext = struct {
    spawn_fn: ?*const fn (allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 = null,
    grant_fn: ?*const fn (target_actor: u32, source_slot: u32, rights_mask: u16) anyerror!bool = null,
    cas_put_fn: ?*const fn (data: []const u8, out_hex: *[64]u8) anyerror!void = null,
    cas_get_fn: ?*const fn (hex_hash: []const u8, out_buf: []u8) anyerror!usize = null,
    draw_canvas_fn: ?*const fn (x: u32, y: u32, w: u32, h: u32, color: u32) void = null,
    telemetry_fn: ?*const fn () tools.TelemetrySnapshot = null,
};

pub const ToolDispatcher = struct {
    caller_cspace: *const CSpace,
    allocator: std.mem.Allocator,
    ctx: DispatcherContext,
    storage_buf: []u8,

    pub fn init(
        caller_cspace: *const CSpace,
        allocator: std.mem.Allocator,
        ctx: DispatcherContext,
        storage_buf: []u8,
    ) ToolDispatcher {
        return ToolDispatcher{
            .caller_cspace = caller_cspace,
            .allocator = allocator,
            .ctx = ctx,
            .storage_buf = storage_buf,
        };
    }

    pub fn hasCap(self: *const ToolDispatcher, cap_type: CapType, required_right: u16) bool {
        var i: usize = 0;
        while (i < self.caller_cspace.capacity) : (i += 1) {
            const entry = self.caller_cspace.entries[i];
            if (entry.isValid() and entry.cap_type == cap_type and entry.hasRight(required_right)) {
                return true;
            }
        }
        return false;
    }

    fn dispatchSpawn(self: *const ToolDispatcher, args: tools.SpawnActorArgs) tools.ToolResult {
        if (!self.hasCap(.actor_control, Rights.EXECUTE)) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: actor_control.EXECUTE required" };
        }
        const spawn = self.ctx.spawn_fn orelse {
            return tools.ToolResult{ .error_msg = "NotImplemented: spawn_actor" };
        };
        const id = spawn(self.allocator, args.name, args.source) catch {
            return tools.ToolResult{ .error_msg = "SpawnFailed" };
        };
        return tools.ToolResult{ .actor_spawned = id };
    }

    fn dispatchGrant(self: *const ToolDispatcher, args: tools.GrantCapArgs) tools.ToolResult {
        const src_cap = self.caller_cspace.get(args.source_slot) orelse {
            return tools.ToolResult{ .error_msg = "InvalidHandle: source_slot" };
        };
        if (!src_cap.hasRight(Rights.GRANT)) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: source cap missing GRANT right" };
        }
        if ((args.rights_mask & ~src_cap.rights) != 0) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: escalation forbidden" };
        }
        if ((src_cap.rights & args.rights_mask) == 0) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: empty rights" };
        }
        const grant = self.ctx.grant_fn orelse {
            return tools.ToolResult{ .error_msg = "NotImplemented: grant_capability" };
        };
        const ok = grant(args.target_actor, args.source_slot, args.rights_mask) catch {
            return tools.ToolResult{ .error_msg = "GrantFailed" };
        };
        return tools.ToolResult{ .capability_granted = ok };
    }

    fn dispatchWrite(self: *const ToolDispatcher, args: tools.WriteStorageArgs) tools.ToolResult {
        if (!self.hasCap(.storage_device, Rights.WRITE)) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: storage_device.WRITE required" };
        }
        const put_fn = self.ctx.cas_put_fn orelse {
            return tools.ToolResult{ .error_msg = "NotImplemented: write_storage" };
        };
        var hex_hash: [tools.MAX_HEX_HASH_LEN]u8 = undefined;
        put_fn(args.payload, &hex_hash) catch {
            return tools.ToolResult{ .error_msg = "StorageWriteFailed" };
        };
        return tools.ToolResult{ .storage_written = hex_hash };
    }

    fn dispatchRead(self: *const ToolDispatcher, args: tools.ReadStorageArgs) tools.ToolResult {
        if (!self.hasCap(.storage_device, Rights.READ)) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: storage_device.READ required" };
        }
        const get_fn = self.ctx.cas_get_fn orelse {
            return tools.ToolResult{ .error_msg = "NotImplemented: read_storage" };
        };
        const read_len = get_fn(&args.hex_hash, self.storage_buf) catch {
            return tools.ToolResult{ .error_msg = "StorageReadFailed" };
        };
        return tools.ToolResult{ .storage_read = self.storage_buf[0..read_len] };
    }

    fn dispatchDraw(self: *const ToolDispatcher, args: tools.DrawCanvasArgs) tools.ToolResult {
        if (!self.hasCap(.framebuffer, Rights.WRITE)) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: framebuffer.WRITE required" };
        }
        if (self.ctx.draw_canvas_fn) |draw| {
            draw(args.x, args.y, args.w, args.h, args.color);
            return tools.ToolResult{ .canvas_drawn = {} };
        }
        return tools.ToolResult{ .error_msg = "NotImplemented: draw_canvas" };
    }

    fn dispatchTelemetry(self: *const ToolDispatcher) tools.ToolResult {
        if (!self.hasCap(.actor_control, Rights.READ)) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: actor_control.READ required" };
        }
        if (self.ctx.telemetry_fn) |telem| {
            return tools.ToolResult{ .telemetry = telem() };
        }
        return tools.ToolResult{ .error_msg = "NotImplemented: query_telemetry" };
    }

    pub fn dispatch(self: *const ToolDispatcher, call: tools.ToolCall) tools.ToolResult {
        return switch (call) {
            .spawn_actor => |args| self.dispatchSpawn(args),
            .grant_capability => |args| self.dispatchGrant(args),
            .write_storage => |args| self.dispatchWrite(args),
            .read_storage => |args| self.dispatchRead(args),
            .draw_canvas => |args| self.dispatchDraw(args),
            .query_telemetry => self.dispatchTelemetry(),
        };
    }
};

fn mockSpawn(allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 {
    _ = allocator;
    _ = name;
    _ = source;
    return 42;
}

fn mockGrant(target: u32, slot: u32, rights: u16) anyerror!bool {
    _ = target;
    _ = slot;
    _ = rights;
    return true;
}

fn mockCasPut(data: []const u8, out_hex: *[64]u8) anyerror!void {
    _ = data;
    @memcpy(out_hex, "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789");
}

fn mockCasGet(hex: []const u8, out_buf: []u8) anyerror!usize {
    _ = hex;
    const s = "stored payload";
    @memcpy(out_buf[0..s.len], s);
    return s.len;
}

var test_drawn: bool = false;
fn mockDraw(x: u32, y: u32, w: u32, h: u32, color: u32) void {
    _ = x;
    _ = y;
    _ = w;
    _ = h;
    _ = color;
    test_drawn = true;
}

const TelemetrySnapshot = tools.TelemetrySnapshot;

fn mockTelemetry() TelemetrySnapshot {
    return TelemetrySnapshot{
        .active_actors = 3,
        .total_faults = 0,
        .free_ram_pages = 1000,
        .uptime_ticks = 500,
    };
}

test "tool dispatcher spawn and telemetry" {
    const allocator = std.testing.allocator;
    var cspace = try CSpace.init(allocator, 16);
    defer cspace.deinit(allocator);

    var storage_buf: [1024]u8 = undefined;
    const ctx = DispatcherContext{
        .spawn_fn = mockSpawn,
        .telemetry_fn = mockTelemetry,
    };
    const dispatcher = ToolDispatcher.init(cspace, allocator, ctx, &storage_buf);

    const unauth = dispatcher.dispatch(tools.ToolCall{
        .spawn_actor = .{ .name = "t", .source = "sys_actor_count();" },
    });
    try std.testing.expect(std.mem.indexOf(u8, unauth.error_msg, "PermissionDenied") != null);

    _ = try cspace.insert(cap_mod.Capability{
        .cap_type = .actor_control,
        .rights = Rights.READ | Rights.EXECUTE | Rights.GRANT,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 0,
    });

    const auth = dispatcher.dispatch(tools.ToolCall{
        .spawn_actor = .{ .name = "t", .source = "sys_actor_count();" },
    });
    try std.testing.expectEqual(@as(u32, 42), auth.actor_spawned);

    const telem = dispatcher.dispatch(tools.ToolCall{ .query_telemetry = .{} });
    try std.testing.expectEqual(@as(u32, 3), telem.telemetry.active_actors);
}

test "tool dispatcher grant capability attenuation" {
    const allocator = std.testing.allocator;
    var cspace = try CSpace.init(allocator, 16);
    defer cspace.deinit(allocator);

    var storage_buf: [1024]u8 = undefined;
    const ctx = DispatcherContext{ .grant_fn = mockGrant };
    const dispatcher = ToolDispatcher.init(cspace, allocator, ctx, &storage_buf);

    _ = try cspace.insert(cap_mod.Capability{
        .cap_type = .actor_control,
        .rights = Rights.READ | Rights.EXECUTE | Rights.GRANT,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 0,
    });

    const ok_grant = dispatcher.dispatch(tools.ToolCall{
        .grant_capability = .{ .target_actor = 2, .source_slot = 0, .rights_mask = Rights.READ },
    });
    try std.testing.expect(ok_grant.capability_granted);

    const esc_grant = dispatcher.dispatch(tools.ToolCall{
        .grant_capability = .{ .target_actor = 2, .source_slot = 0, .rights_mask = Rights.WRITE },
    });
    try std.testing.expect(std.mem.indexOf(u8, esc_grant.error_msg, "PermissionDenied") != null);
}
