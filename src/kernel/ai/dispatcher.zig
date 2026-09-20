// MicrOS (µOS) Sovereign Tool Dispatcher & CSpace Security Gate
// Object-capability authorized execution of AI system tools.

const std = @import("std");
const tools = @import("tools.zig");
const cap_mod = @import("../cap/capability.zig");
const CapType = cap_mod.CapType;
const Rights = cap_mod.Rights;
const cspace_mod = @import("../cap/cspace.zig");
const CSpace = cspace_mod.CSpace;
const catalog_abi = @import("../storage/catalog_abi.zig");

pub const DispatcherContext = struct {
    spawn_fn: ?*const fn (allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 = null,
    grant_fn: ?*const fn (target_actor: u32, source_slot: u32, rights_mask: u16) anyerror!bool = null,
    cas_put_fn: ?*const fn (data: []const u8, out_hex: *[64]u8) anyerror!void = null,
    cas_get_fn: ?*const fn (hex_hash: []const u8, out_buf: []u8) anyerror!usize = null,
    telemetry_fn: ?*const fn () tools.TelemetrySnapshot = null,
    bundle_read_fn: ?*const fn (name: []const u8) ?[]const u8 = null,
    bundle_list_fn: ?*const fn (prefix: []const u8, out_buf: []u8) usize = null,
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
        return self.caller_cspace.hasCap(cap_type, required_right);
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

    fn dispatchTelemetry(self: *const ToolDispatcher) tools.ToolResult {
        if (!self.hasCap(.actor_control, Rights.READ)) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: actor_control.READ required" };
        }
        if (self.ctx.telemetry_fn) |telem| {
            return tools.ToolResult{ .telemetry = telem() };
        }
        return tools.ToolResult{ .error_msg = "NotImplemented: query_telemetry" };
    }

    fn dispatchRunCommand(self: *const ToolDispatcher, args: tools.RunCommandArgs) tools.ToolResult {
        if (!self.hasCap(.actor_control, Rights.EXECUTE)) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: actor_control.EXECUTE required" };
        }
        const spawn = self.ctx.spawn_fn orelse {
            return tools.ToolResult{ .error_msg = "NotImplemented: run_command" };
        };
        const trimmed = std.mem.trim(u8, args.command, " \t\r\n");
        if (self.ctx.bundle_read_fn) |bread| {
            var name_buf: [32]u8 = undefined;
            const full_name = blk: {
                if (std.mem.endsWith(u8, trimmed, ".mx")) break :blk trimmed;
                if (trimmed.len + 3 > name_buf.len) break :blk trimmed;
                @memcpy(name_buf[0..trimmed.len], trimmed);
                @memcpy(name_buf[trimmed.len .. trimmed.len + 3], ".mx");
                break :blk name_buf[0 .. trimmed.len + 3];
            };
            if (bread(full_name)) |src| {
                _ = spawn(self.allocator, full_name, src) catch {
                    return tools.ToolResult{ .error_msg = "SpawnFailed" };
                };
                return tools.ToolResult{ .command_executed = "Spawned system application from bundle" };
            }
        }
        _ = spawn(self.allocator, "harness_exec", args.command) catch {
            return tools.ToolResult{ .command_executed = "Command dispatched" };
        };
        return tools.ToolResult{ .command_executed = "Command spawned as actor" };
    }

    fn dispatchViewFile(self: *const ToolDispatcher, args: tools.ViewFileArgs) tools.ToolResult {
        if (!self.hasCap(.storage_device, Rights.READ)) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: storage_device.READ required" };
        }
        const read_len = catalog_abi.global_catalog.readBlob(args.path, self.storage_buf) catch blk: {
            if (self.ctx.bundle_read_fn) |b_fn| {
                if (b_fn(args.path)) |bundle_data| {
                    const copy_len = @min(bundle_data.len, self.storage_buf.len);
                    @memcpy(self.storage_buf[0..copy_len], bundle_data[0..copy_len]);
                    break :blk copy_len;
                }
            }
            return tools.ToolResult{ .error_msg = "FileNotFound" };
        };
        return tools.ToolResult{ .file_viewed = self.storage_buf[0..read_len] };
    }

    fn dispatchWriteFile(self: *const ToolDispatcher, args: tools.WriteFileArgs) tools.ToolResult {
        if (!self.hasCap(.storage_device, Rights.WRITE)) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: storage_device.WRITE required" };
        }
        var hex_buf: [64]u8 = undefined;
        catalog_abi.global_catalog.writeBlob(args.path, args.content, &hex_buf) catch {
            return tools.ToolResult{ .error_msg = "WriteFailed" };
        };
        return tools.ToolResult{ .file_written = args.content.len };
    }

    fn dispatchReplaceContent(self: *const ToolDispatcher, args: tools.ReplaceContentArgs) tools.ToolResult {
        if (!self.hasCap(.storage_device, Rights.WRITE)) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: storage_device.WRITE required" };
        }
        var read_scratch: [4096]u8 = undefined;
        const read_len = catalog_abi.global_catalog.readBlob(args.path, &read_scratch) catch {
            return tools.ToolResult{ .error_msg = "FileNotFound" };
        };
        const src = read_scratch[0..read_len];
        const match_pos = std.mem.indexOf(u8, src, args.target) orelse {
            return tools.ToolResult{ .error_msg = "TargetNotFound" };
        };
        const new_len = src.len - args.target.len + args.replacement.len;
        if (new_len > self.storage_buf.len) return tools.ToolResult{ .error_msg = "BufferTooSmall" };
        @memcpy(self.storage_buf[0..match_pos], src[0..match_pos]);
        @memcpy(self.storage_buf[match_pos .. match_pos + args.replacement.len], args.replacement);
        const rest_start = match_pos + args.target.len;
        const out_rest_start = match_pos + args.replacement.len;
        @memcpy(self.storage_buf[out_rest_start..new_len], src[rest_start..]);

        var hex_buf: [64]u8 = undefined;
        catalog_abi.global_catalog.writeBlob(args.path, self.storage_buf[0..new_len], &hex_buf) catch {
            return tools.ToolResult{ .error_msg = "WriteFailed" };
        };
        return tools.ToolResult{ .content_replaced = true };
    }

    fn dispatchListDir(self: *const ToolDispatcher, args: tools.ListDirArgs) tools.ToolResult {
        if (!self.hasCap(.storage_device, Rights.READ)) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: storage_device.READ required" };
        }
        var len = catalog_abi.global_catalog.formatList(args.prefix, self.storage_buf) catch 0;
        if (len == 0 and self.ctx.bundle_list_fn != null) {
            len = self.ctx.bundle_list_fn.?(args.prefix, self.storage_buf);
        }
        return tools.ToolResult{ .dir_listed = self.storage_buf[0..len] };
    }

    fn dispatchGrepSearch(self: *const ToolDispatcher, args: tools.GrepSearchArgs) tools.ToolResult {
        if (!self.hasCap(.storage_device, Rights.READ)) {
            return tools.ToolResult{ .error_msg = "PermissionDenied: storage_device.READ required" };
        }
        var offset: usize = 0;
        for (0..catalog_abi.global_catalog.workspace.header.entry_count) |i| {
            const entry = &catalog_abi.global_catalog.workspace.entries[i];
            const name = entry.getName();
            var file_buf: [1024]u8 = undefined;
            const flen = catalog_abi.global_catalog.readBlob(name, &file_buf) catch continue;
            if (std.mem.indexOf(u8, file_buf[0..flen], args.query) != null) {
                if (offset + name.len + 1 < self.storage_buf.len) {
                    @memcpy(self.storage_buf[offset .. offset + name.len], name);
                    self.storage_buf[offset + name.len] = '\n';
                    offset += name.len + 1;
                }
            }
        }
        return tools.ToolResult{ .search_results = self.storage_buf[0..offset] };
    }

    pub fn dispatch(self: *const ToolDispatcher, call: tools.ToolCall) tools.ToolResult {
        return switch (call) {
            .run_command => |args| self.dispatchRunCommand(args),
            .view_file => |args| self.dispatchViewFile(args),
            .write_to_file => |args| self.dispatchWriteFile(args),
            .replace_file_content => |args| self.dispatchReplaceContent(args),
            .list_dir => |args| self.dispatchListDir(args),
            .grep_search => |args| self.dispatchGrepSearch(args),
            .spawn_actor => |args| self.dispatchSpawn(args),
            .grant_capability => |args| self.dispatchGrant(args),
            .write_storage => |args| self.dispatchWrite(args),
            .read_storage => |args| self.dispatchRead(args),
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
