// MicrOS (µOS) Sovereign Catalog Broker & Workspace Syscall ABI
// Manages flat semantic file workspaces backed by BLAKE3 Content-Addressed Storage.
// Enforces capability isolation and OCC commit semantics. Zero libc, freestanding.

const std = @import("std");
const eval = @import("../../macros/eval.zig");
const Value = eval.Value;
const vm_mod = @import("../../macros/vm.zig");
const VM = vm_mod.VM;
const chunk_mod = @import("chunk.zig");
const manifest_mod = @import("manifest.zig");
const WorkspaceManifest = manifest_mod.WorkspaceManifest;
const WorkspaceEntry = manifest_mod.WorkspaceEntry;
const cap_mod = @import("../cap/capability.zig");
const CapType = cap_mod.CapType;
const Rights = cap_mod.Rights;

pub const MAX_SERIALIZED_MANIFEST_SIZE: usize = manifest_mod.FULL_MANIFEST_SIZE;
var manifest_serialize_scratch: [MAX_SERIALIZED_MANIFEST_SIZE]u8 = undefined;

pub const CatalogBroker = struct {
    workspace: WorkspaceManifest = WorkspaceManifest.init(1, &([_]u8{0} ** chunk_mod.HASH_SIZE)),
    active_manifest_hash: [chunk_mod.HASH_SIZE]u8 = [_]u8{0} ** chunk_mod.HASH_SIZE,

    pub fn writeBlob(
        self: *CatalogBroker,
        path: []const u8,
        content: []const u8,
        out_hex: *[chunk_mod.HEX_HASH_SIZE]u8,
    ) !void {
        if (!manifest_mod.validatePath(path)) return error.InvalidPath;
        const put_fn = cas_put_fn orelse return error.NoStorage;

        var hex_buf: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
        try put_fn(content, &hex_buf);
        @memcpy(out_hex, &hex_buf);

        var bin_hash: [chunk_mod.HASH_SIZE]u8 = undefined;
        try chunk_mod.parseHexHash(&hex_buf, &bin_hash);

        var entry = WorkspaceEntry{
            .size = @intCast(content.len),
            .hash = bin_hash,
            .name_len = @intCast(path.len),
        };
        @memcpy(entry.name[0..path.len], path);
        try self.workspace.putEntry(entry);
    }

    pub fn readBlob(self: *const CatalogBroker, path: []const u8, out_buf: []u8) !usize {
        if (!manifest_mod.validatePath(path)) return error.InvalidPath;
        const entry = self.workspace.lookup(path) orelse return error.FileNotFound;
        const get_fn = cas_get_fn orelse return error.NoStorage;

        var hex_buf: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
        chunk_mod.formatHexHash(&entry.hash, &hex_buf);
        return try get_fn(&hex_buf, out_buf);
    }

    pub fn deleteFile(self: *CatalogBroker, path: []const u8) bool {
        if (!manifest_mod.validatePath(path)) return false;
        return self.workspace.deleteEntry(path);
    }

    pub fn formatList(self: *const CatalogBroker, prefix: []const u8, out_buf: []u8) !usize {
        var offset: usize = 0;
        for (0..self.workspace.header.entry_count) |i| {
            const entry = &self.workspace.entries[i];
            const name = entry.getName();
            if (prefix.len > 0 and !std.mem.startsWith(u8, name, prefix)) continue;

            var hex_buf: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
            chunk_mod.formatHexHash(&entry.hash, &hex_buf);

            var line_buf: [160]u8 = undefined;
            const line = std.fmt.bufPrint(
                &line_buf,
                "{s}\t{d}\t{s}\n",
                .{ name, entry.size, hex_buf[0..16] },
            ) catch return error.BufferTooSmall;

            if (offset + line.len > out_buf.len) return error.BufferTooSmall;
            @memcpy(out_buf[offset .. offset + line.len], line);
            offset += line.len;
        }
        return offset;
    }

    pub fn commit(self: *CatalogBroker, msg: []const u8, out_hex: *[chunk_mod.HEX_HASH_SIZE]u8) !void {
        const put_fn = cas_put_fn orelse return error.NoStorage;
        self.workspace.setCommitMsg(msg);
        self.workspace.header.prev_manifest_hash = self.active_manifest_hash;

        const len = try self.workspace.serialize(&manifest_serialize_scratch);
        var hex_buf: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
        try put_fn(manifest_serialize_scratch[0..len], &hex_buf);
        @memcpy(out_hex, &hex_buf);

        try chunk_mod.parseHexHash(&hex_buf, &self.active_manifest_hash);
        self.workspace.header.generation += 1;
    }

    pub fn formatStatus(self: *const CatalogBroker, out_buf: []u8) !usize {
        var hex_buf: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
        chunk_mod.formatHexHash(&self.active_manifest_hash, &hex_buf);
        const json = try std.fmt.bufPrint(
            out_buf,
            "{{\"generation\":{d},\"entries\":{d},\"total_bytes\":{d},\"root\":\"{s}\"}}",
            .{
                self.workspace.header.generation,
                self.workspace.header.entry_count,
                self.workspace.header.total_bytes,
                hex_buf[0..16],
            },
        );
        return json.len;
    }
};

pub var global_catalog: CatalogBroker = .{};
pub var cas_put_fn: ?*const fn (data: []const u8, out_hex: *[64]u8) anyerror!void = null;
pub var cas_get_fn: ?*const fn (hex_hash: []const u8, out_buf: []u8) anyerror!usize = null;
pub var caller_auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool = null;

pub fn setStorageContext(
    put_fn: ?*const fn (data: []const u8, out_hex: *[64]u8) anyerror!void,
    get_fn: ?*const fn (hex_hash: []const u8, out_buf: []u8) anyerror!usize,
    auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool,
) void {
    cas_put_fn = put_fn;
    cas_get_fn = get_fn;
    caller_auth_fn = auth_fn;
}

pub fn clearCatalogContext() void {
    cas_put_fn = null;
    cas_get_fn = null;
    caller_auth_fn = null;
    global_catalog = .{};
}

fn checkCallerAuthority(cap_type: CapType, rights: u16) bool {
    if (caller_auth_fn) |auth| {
        return auth(cap_type, rights);
    }
    return true;
}

pub fn nativeSysCatalogWrite(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.storage_device, Rights.WRITE)) return Value{ .string = "" };

    var hex_buf: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
    global_catalog.writeBlob(args[0].string, args[1].string, &hex_buf) catch {
        return Value{ .string = "" };
    };
    const duped = try vm.allocator.dupe(u8, &hex_buf);
    return Value{ .string = duped };
}

pub fn nativeSysCatalogRead(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.storage_device, Rights.READ)) return Value{ .string = "" };

    var scratch: [16384]u8 = undefined;
    const n = global_catalog.readBlob(args[0].string, &scratch) catch return Value{ .string = "" };
    const duped = try vm.allocator.dupe(u8, scratch[0..n]);
    return Value{ .string = duped };
}

pub fn nativeSysCatalogList(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    const prefix = if (args.len >= 1 and args[0] == .string) args[0].string else "";
    if (!checkCallerAuthority(.storage_device, Rights.READ)) return Value{ .string = "" };

    var scratch: [8192]u8 = undefined;
    const n = global_catalog.formatList(prefix, &scratch) catch return Value{ .string = "" };
    const duped = try vm.allocator.dupe(u8, scratch[0..n]);
    return Value{ .string = duped };
}

pub fn nativeSysCatalogDelete(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.storage_device, Rights.WRITE)) return Value{ .boolean = false };

    const ok = global_catalog.deleteFile(args[0].string);
    return Value{ .boolean = ok };
}

pub fn nativeSysCatalogCommit(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    const msg = if (args.len >= 1 and args[0] == .string) args[0].string else "workspace snapshot";
    if (!checkCallerAuthority(.storage_device, Rights.WRITE)) return Value{ .string = "" };

    var hex_buf: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
    global_catalog.commit(msg, &hex_buf) catch return Value{ .string = "" };
    const duped = try vm.allocator.dupe(u8, &hex_buf);
    return Value{ .string = duped };
}

pub fn nativeSysCatalogStatus(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    if (!checkCallerAuthority(.storage_device, Rights.READ)) return Value{ .string = "" };

    var buf: [256]u8 = undefined;
    const n = global_catalog.formatStatus(&buf) catch return Value{ .string = "" };
    const duped = try vm.allocator.dupe(u8, buf[0..n]);
    return Value{ .string = duped };
}

pub fn registerCatalogSyscalls(vm: *VM) !void {
    try vm.globals.put("sys_catalog_write", Value{ .native = nativeSysCatalogWrite });
    try vm.globals.put("sys_catalog_read", Value{ .native = nativeSysCatalogRead });
    try vm.globals.put("sys_catalog_list", Value{ .native = nativeSysCatalogList });
    try vm.globals.put("sys_catalog_delete", Value{ .native = nativeSysCatalogDelete });
    try vm.globals.put("sys_catalog_commit", Value{ .native = nativeSysCatalogCommit });
    try vm.globals.put("sys_catalog_status", Value{ .native = nativeSysCatalogStatus });
}

// === Colocated Unit Tests ===

fn testMockCasPut(data: []const u8, out_hex: *[64]u8) anyerror!void {
    const hash = chunk_mod.computeBlake3Hash(data);
    chunk_mod.formatHexHash(&hash, out_hex);
}

fn testMockCasGet(hex_hash: []const u8, out_buf: []u8) anyerror!usize {
    _ = hex_hash;
    const mock_content = "Hello Sovereign Workspace!\n";
    @memcpy(out_buf[0..mock_content.len], mock_content);
    return mock_content.len;
}

test "catalog broker write, lookup, list and delete" {
    clearCatalogContext();
    defer clearCatalogContext();

    setStorageContext(testMockCasPut, testMockCasGet, null);

    var hex_out: [64]u8 = undefined;
    try global_catalog.writeBlob("docs/readme.txt", "Document Content Here", &hex_out);
    try global_catalog.writeBlob("src/app.mx", "fn main() { return 0; }", &hex_out);

    try std.testing.expectEqual(@as(u32, 2), global_catalog.workspace.header.entry_count);

    var list_buf: [512]u8 = undefined;
    const n = try global_catalog.formatList("", &list_buf);
    const list_str = list_buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, list_str, "docs/readme.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_str, "src/app.mx") != null);

    var read_buf: [128]u8 = undefined;
    const read_len = try global_catalog.readBlob("docs/readme.txt", &read_buf);
    try std.testing.expectEqualStrings("Hello Sovereign Workspace!\n", read_buf[0..read_len]);

    try std.testing.expect(global_catalog.deleteFile("docs/readme.txt"));
    try std.testing.expectEqual(@as(u32, 1), global_catalog.workspace.header.entry_count);
    try std.testing.expectError(error.FileNotFound, global_catalog.readBlob("docs/readme.txt", &read_buf));
}

test "catalog syscall registration and execution" {
    clearCatalogContext();
    defer clearCatalogContext();

    setStorageContext(testMockCasPut, testMockCasGet, null);

    const allocator = std.testing.allocator;
    var chunk = @import("../../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    try registerCatalogSyscalls(&vm);
    try std.testing.expect(vm.globals.contains("sys_catalog_write"));
    try std.testing.expect(vm.globals.contains("sys_catalog_read"));
    try std.testing.expect(vm.globals.contains("sys_catalog_list"));
    try std.testing.expect(vm.globals.contains("sys_catalog_delete"));
    try std.testing.expect(vm.globals.contains("sys_catalog_commit"));
    try std.testing.expect(vm.globals.contains("sys_catalog_status"));

    var write_args = [_]Value{ Value{ .string = "notes.txt" }, Value{ .string = "Remember to buy milk" } };
    const write_val = try nativeSysCatalogWrite(&vm, &write_args);
    defer vm.allocator.free(write_val.string);
    try std.testing.expectEqual(@as(usize, 64), write_val.string.len);

    var list_args = [_]Value{Value{ .string = "" }};
    const list_val = try nativeSysCatalogList(&vm, &list_args);
    defer vm.allocator.free(list_val.string);
    try std.testing.expect(std.mem.indexOf(u8, list_val.string, "notes.txt") != null);

    const status_val = try nativeSysCatalogStatus(&vm, &[_]Value{});
    defer vm.allocator.free(status_val.string);
    try std.testing.expect(std.mem.indexOf(u8, status_val.string, "\"entries\":1") != null);

    var read_args = [_]Value{Value{ .string = "notes.txt" }};
    const read_val = try nativeSysCatalogRead(&vm, &read_args);
    defer vm.allocator.free(read_val.string);
    try std.testing.expect(read_val.string.len > 0);

    var commit_args = [_]Value{Value{ .string = "test commit" }};
    const commit_val = try nativeSysCatalogCommit(&vm, &commit_args);
    defer vm.allocator.free(commit_val.string);
    try std.testing.expectEqual(@as(usize, 64), commit_val.string.len);

    var del_args = [_]Value{Value{ .string = "notes.txt" }};
    const del_val = try nativeSysCatalogDelete(&vm, &del_args);
    try std.testing.expect(del_val.boolean);
}
