// MicrOS (µOS) Sovereign Catalog Broker & Workspace Syscall ABI
// Manages flat semantic file workspaces backed by BLAKE3 Content-Addressed Storage.
// Enforces capability isolation and OCC commit semantics. Zero libc, freestanding.

const std = @import("std");
const eval = @import("../../macros/eval.zig");
const Value = eval.Value;
const vm_mod = @import("../../macros/vm.zig");
const VM = vm_mod.VM;
const chunk_mod = @import("chunk.zig");
const cas_mod = @import("cas.zig");
const manifest_mod = @import("manifest.zig");
const WorkspaceManifest = manifest_mod.WorkspaceManifest;
const WorkspaceEntry = manifest_mod.WorkspaceEntry;
const cap_mod = @import("../cap/capability.zig");
const CapType = cap_mod.CapType;
const Rights = cap_mod.Rights;

pub const MAX_SERIALIZED_MANIFEST_SIZE: usize = manifest_mod.FULL_MANIFEST_SIZE;
var manifest_serialize_scratch: [MAX_SERIALIZED_MANIFEST_SIZE]u8 = undefined;
var catalog_read_scratch: [64 * 1024]u8 = undefined;
var catalog_list_scratch: [manifest_mod.MAX_WORKSPACE_ENTRIES * 160]u8 = undefined;

pub const MAX_SNAPSHOT_GENERATIONS: usize = 16;

pub const GenerationSnapshot = struct {
    generation: u64 = 0,
    manifest_cas_hash: [chunk_mod.HASH_SIZE]u8 = [_]u8{0} ** chunk_mod.HASH_SIZE,
    manifest: WorkspaceManifest = .{},
    valid: bool = false,
};

pub const SnapshotRing = struct {
    snapshots: [MAX_SNAPSHOT_GENERATIONS]GenerationSnapshot = [_]GenerationSnapshot{.{}} ** MAX_SNAPSHOT_GENERATIONS,
    head: usize = 0,
    count: usize = 0,

    pub fn push(self: *SnapshotRing, manifest: *const WorkspaceManifest, cas_hash: *const [chunk_mod.HASH_SIZE]u8) void {
        const slot = self.head;
        self.snapshots[slot] = .{
            .generation = manifest.header.generation,
            .manifest_cas_hash = cas_hash.*,
            .manifest = manifest.*,
            .valid = true,
        };
        self.head = (self.head + 1) % MAX_SNAPSHOT_GENERATIONS;
        if (self.count < MAX_SNAPSHOT_GENERATIONS) {
            self.count += 1;
        }
    }

    pub fn getOldestLiveGeneration(self: *const SnapshotRing) u64 {
        if (self.count == 0) return 1;
        if (self.count < MAX_SNAPSHOT_GENERATIONS) {
            return self.snapshots[0].generation;
        }
        return self.snapshots[self.head].generation;
    }

    pub fn findSnapshot(self: *const SnapshotRing, gen: u64) ?*const GenerationSnapshot {
        if (self.count == 0) return null;
        for (0..self.count) |i| {
            const idx = if (self.count < MAX_SNAPSHOT_GENERATIONS)
                i
            else
                (self.head + i) % MAX_SNAPSHOT_GENERATIONS;
            if (self.snapshots[idx].valid and self.snapshots[idx].generation == gen) {
                return &self.snapshots[idx];
            }
        }
        return null;
    }

    pub fn getPreviousSnapshot(self: *const SnapshotRing) ?*const GenerationSnapshot {
        if (self.count <= 1) return null;
        const prev_idx = (self.head + MAX_SNAPSHOT_GENERATIONS - 2) % MAX_SNAPSHOT_GENERATIONS;
        if (self.snapshots[prev_idx].valid) {
            return &self.snapshots[prev_idx];
        }
        return null;
    }
};

pub const CatalogBroker = struct {
    workspace: WorkspaceManifest = WorkspaceManifest.init(1, &([_]u8{0} ** chunk_mod.HASH_SIZE)),
    active_manifest_hash: [chunk_mod.HASH_SIZE]u8 = [_]u8{0} ** chunk_mod.HASH_SIZE,
    ring: SnapshotRing = .{},

    pub fn ensureGenesisSnapshot(self: *CatalogBroker) void {
        if (self.ring.count == 0) {
            self.ring.push(&self.workspace, &self.active_manifest_hash);
        }
    }

    pub fn writeBlob(
        self: *CatalogBroker,
        path: []const u8,
        content: []const u8,
        out_hex: *[chunk_mod.HEX_HASH_SIZE]u8,
    ) !void {
        if (!manifest_mod.validatePath(path)) return error.InvalidPath;
        const put_fn = cas_put_fn orelse return error.NoStorage;

        self.ensureGenesisSnapshot();

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
        self.workspace.header.generation += 1;

        const len = try self.workspace.serialize(&manifest_serialize_scratch);
        var manifest_hex: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
        try put_fn(manifest_serialize_scratch[0..len], &manifest_hex);
        try chunk_mod.parseHexHash(&manifest_hex, &self.active_manifest_hash);

        self.ring.push(&self.workspace, &self.active_manifest_hash);
    }

    pub fn readBlobGen(
        self: *const CatalogBroker,
        path: []const u8,
        maybe_gen: ?u64,
        out_buf: []u8,
    ) !usize {
        if (!manifest_mod.validatePath(path)) return error.InvalidPath;

        if (maybe_gen) |gen| {
            if (gen == self.workspace.header.generation) {
                return self.readBlobCurrent(path, out_buf);
            }
            if (gen < self.ring.getOldestLiveGeneration()) {
                return error.GenerationEvicted;
            }
            if (gen > self.workspace.header.generation) {
                return error.FileNotFound;
            }
            const snap = self.ring.findSnapshot(gen) orelse {
                if (gen < self.workspace.header.generation) {
                    return error.GenerationEvicted;
                }
                return error.FileNotFound;
            };
            const entry = snap.manifest.lookup(path) orelse return error.FileNotFound;
            if (entry.isTombstone()) return error.FileNotFound;

            const get_fn = cas_get_fn orelse return error.NoStorage;
            var hex_buf: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
            chunk_mod.formatHexHash(&entry.hash, &hex_buf);
            return try get_fn(&hex_buf, out_buf);
        }

        return self.readBlobCurrent(path, out_buf);
    }

    fn readBlobCurrent(self: *const CatalogBroker, path: []const u8, out_buf: []u8) !usize {
        const entry = self.workspace.lookup(path) orelse return error.FileNotFound;
        if (entry.isTombstone()) return error.FileNotFound;
        const get_fn = cas_get_fn orelse return error.NoStorage;

        var hex_buf: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
        chunk_mod.formatHexHash(&entry.hash, &hex_buf);
        return try get_fn(&hex_buf, out_buf);
    }

    pub fn readBlob(self: *const CatalogBroker, path_spec: []const u8, out_buf: []u8) !usize {
        var path = path_spec;
        var maybe_gen: ?u64 = null;
        if (std.mem.lastIndexOfScalar(u8, path_spec, '@')) |at_idx| {
            path = path_spec[0..at_idx];
            const gen_str = path_spec[at_idx + 1 ..];
            if (gen_str.len == 0) return error.InvalidPath;
            maybe_gen = std.fmt.parseInt(u64, gen_str, 10) catch return error.InvalidPath;
        }
        return self.readBlobGen(path, maybe_gen, out_buf);
    }

    pub fn deleteFile(self: *CatalogBroker, path: []const u8) bool {
        if (!manifest_mod.validatePath(path)) return false;
        self.ensureGenesisSnapshot();

        const ok = self.workspace.deleteEntry(path);
        if (ok) {
            self.workspace.header.generation += 1;
            if (cas_put_fn) |put_fn| {
                const len = self.workspace.serialize(&manifest_serialize_scratch) catch 0;
                if (len > 0) {
                    var manifest_hex: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
                    put_fn(manifest_serialize_scratch[0..len], &manifest_hex) catch {};
                    chunk_mod.parseHexHash(&manifest_hex, &self.active_manifest_hash) catch {};
                }
            }
            self.ring.push(&self.workspace, &self.active_manifest_hash);
        }
        return ok;
    }

    fn resolveGenerationManifest(self: *const CatalogBroker, maybe_gen: ?u64) !*const WorkspaceManifest {
        const gen = maybe_gen orelse return &self.workspace;
        if (gen == self.workspace.header.generation) return &self.workspace;
        if (gen < self.ring.getOldestLiveGeneration()) return error.GenerationEvicted;
        if (gen > self.workspace.header.generation) return error.FileNotFound;
        const snap = self.ring.findSnapshot(gen) orelse {
            if (gen < self.workspace.header.generation) return error.GenerationEvicted;
            return error.FileNotFound;
        };
        return &snap.manifest;
    }

    pub fn formatListGen(
        self: *const CatalogBroker,
        prefix: []const u8,
        maybe_gen: ?u64,
        out_buf: []u8,
    ) !usize {
        const target_manifest = try self.resolveGenerationManifest(maybe_gen);
        var offset: usize = 0;
        for (0..target_manifest.header.entry_count) |i| {
            const entry = &target_manifest.entries[i];
            if (entry.isTombstone()) continue;

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

    pub fn formatList(self: *const CatalogBroker, prefix_spec: []const u8, out_buf: []u8) !usize {
        var prefix = prefix_spec;
        var maybe_gen: ?u64 = null;
        if (std.mem.lastIndexOfScalar(u8, prefix_spec, '@')) |at_idx| {
            prefix = prefix_spec[0..at_idx];
            if (std.mem.eql(u8, prefix, "catalog")) {
                prefix = "";
            }
            const gen_str = prefix_spec[at_idx + 1 ..];
            if (gen_str.len > 0) {
                maybe_gen = std.fmt.parseInt(u64, gen_str, 10) catch null;
            }
        } else if (std.mem.eql(u8, prefix_spec, "catalog")) {
            prefix = "";
        }
        return self.formatListGen(prefix, maybe_gen, out_buf);
    }

    pub fn commit(self: *CatalogBroker, msg: []const u8, out_hex: *[chunk_mod.HEX_HASH_SIZE]u8) !void {
        const put_fn = cas_put_fn orelse return error.NoStorage;
        self.ensureGenesisSnapshot();

        self.workspace.setCommitMsg(msg);
        self.workspace.header.prev_manifest_hash = self.active_manifest_hash;

        const len = try self.workspace.serialize(&manifest_serialize_scratch);
        var hex_buf: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
        try put_fn(manifest_serialize_scratch[0..len], &hex_buf);
        @memcpy(out_hex, &hex_buf);

        try chunk_mod.parseHexHash(&hex_buf, &self.active_manifest_hash);
        self.workspace.header.generation += 1;

        self.ring.push(&self.workspace, &self.active_manifest_hash);
    }

    pub fn undo(self: *CatalogBroker) bool {
        self.ensureGenesisSnapshot();
        const prev_snap = self.ring.getPreviousSnapshot() orelse return false;

        var restored = prev_snap.manifest;
        restored.header.generation = self.workspace.header.generation + 1;
        restored.header.prev_manifest_hash = self.active_manifest_hash;

        if (cas_put_fn) |put_fn| {
            const len = restored.serialize(&manifest_serialize_scratch) catch return false;
            var hex_buf: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
            put_fn(manifest_serialize_scratch[0..len], &hex_buf) catch return false;
            chunk_mod.parseHexHash(&hex_buf, &self.active_manifest_hash) catch return false;
        }

        self.workspace = restored;
        self.ring.push(&self.workspace, &self.active_manifest_hash);
        return true;
    }

    pub fn formatStatus(self: *const CatalogBroker, out_buf: []u8) !usize {
        var hex_buf: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
        chunk_mod.formatHexHash(&self.active_manifest_hash, &hex_buf);
        const json = try std.fmt.bufPrint(
            out_buf,
            "{{\"generation\":{d},\"entries\":{d},\"total_bytes\":{d},\"root\":\"{s}\"}}",
            .{
                self.workspace.header.generation,
                self.workspace.activeEntryCount(),
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

pub fn writeProbeTranscript(raw_entries: []const u8) ?[chunk_mod.HASH_SIZE]u8 {
    var hex_buf: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
    global_catalog.writeBlob("probe.transcript", raw_entries, &hex_buf) catch return null;
    var bin_hash: [chunk_mod.HASH_SIZE]u8 = undefined;
    chunk_mod.parseHexHash(&hex_buf, &bin_hash) catch return null;
    return bin_hash;
}

fn checkCallerAuthority(cap_type: CapType, rights: u16) bool {
    if (caller_auth_fn) |auth| {
        return auth(cap_type, rights);
    }
    return false;
}

pub fn nativeSysCatalogWrite(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.storage_device, Rights.WRITE)) return Value{ .string = "" };

    var hex_buf: [chunk_mod.HEX_HASH_SIZE]u8 = undefined;
    global_catalog.writeBlob(args[0].string, args[1].string, &hex_buf) catch {
        return Value{ .string = "" };
    };
    const duped = try vm.gcAllocator().dupe(u8, &hex_buf);
    return Value{ .string = duped };
}

pub fn nativeSysCatalogRead(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len < 1 or args[0] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.storage_device, Rights.READ)) return Value{ .string = "" };

    const path_spec = args[0].string;
    const n = global_catalog.readBlob(path_spec, &catalog_read_scratch) catch |err| {
        if (err == error.GenerationEvicted) {
            var target_gen: u64 = 0;
            if (std.mem.lastIndexOfScalar(u8, path_spec, '@')) |at_idx| {
                target_gen = std.fmt.parseInt(u64, path_spec[at_idx + 1 ..], 10) catch 0;
            }
            var err_buf: [128]u8 = undefined;
            const oldest = global_catalog.ring.getOldestLiveGeneration();
            const msg = std.fmt.bufPrint(
                &err_buf,
                "[catalog] Generation {d} evicted (ring bound: {d}, oldest live: {d})\n",
                .{ target_gen, MAX_SNAPSHOT_GENERATIONS, oldest },
            ) catch "[catalog] Generation evicted\n";
            const duped = try vm.gcAllocator().dupe(u8, msg);
            return Value{ .string = duped };
        }
        return Value{ .string = "" };
    };
    const duped = try vm.gcAllocator().dupe(u8, catalog_read_scratch[0..n]);
    return Value{ .string = duped };
}

pub fn nativeSysCatalogList(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    const prefix_spec = if (args.len >= 1 and args[0] == .string) args[0].string else "";
    if (!checkCallerAuthority(.storage_device, Rights.READ)) return Value{ .string = "" };

    const n = global_catalog.formatList(prefix_spec, &catalog_list_scratch) catch |err| {
        if (err == error.GenerationEvicted) {
            var target_gen: u64 = 0;
            if (std.mem.lastIndexOfScalar(u8, prefix_spec, '@')) |at_idx| {
                target_gen = std.fmt.parseInt(u64, prefix_spec[at_idx + 1 ..], 10) catch 0;
            }
            var err_buf: [128]u8 = undefined;
            const oldest = global_catalog.ring.getOldestLiveGeneration();
            const msg = std.fmt.bufPrint(
                &err_buf,
                "[catalog] Generation {d} evicted (ring bound: {d}, oldest live: {d})\n",
                .{ target_gen, MAX_SNAPSHOT_GENERATIONS, oldest },
            ) catch "[catalog] Generation evicted\n";
            const duped = try vm.gcAllocator().dupe(u8, msg);
            return Value{ .string = duped };
        }
        return Value{ .string = "" };
    };
    const duped = try vm.gcAllocator().dupe(u8, catalog_list_scratch[0..n]);
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
    const duped = try vm.gcAllocator().dupe(u8, &hex_buf);
    return Value{ .string = duped };
}

pub fn nativeSysCatalogUndo(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    if (!checkCallerAuthority(.storage_device, Rights.WRITE)) return Value{ .boolean = false };

    const ok = global_catalog.undo();
    return Value{ .boolean = ok };
}

pub fn nativeSysCatalogStatus(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    if (!checkCallerAuthority(.storage_device, Rights.READ)) return Value{ .string = "" };

    var buf: [256]u8 = undefined;
    const n = global_catalog.formatStatus(&buf) catch return Value{ .string = "" };
    const duped = try vm.gcAllocator().dupe(u8, buf[0..n]);
    return Value{ .string = duped };
}

pub fn registerCatalogSyscalls(vm: *VM) !void {
    try vm.globals.put("sys_catalog_write", Value{ .native = nativeSysCatalogWrite });
    try vm.globals.put("sys_catalog_read", Value{ .native = nativeSysCatalogRead });
    try vm.globals.put("sys_catalog_list", Value{ .native = nativeSysCatalogList });
    try vm.globals.put("sys_catalog_delete", Value{ .native = nativeSysCatalogDelete });
    try vm.globals.put("sys_catalog_commit", Value{ .native = nativeSysCatalogCommit });
    try vm.globals.put("sys_catalog_undo", Value{ .native = nativeSysCatalogUndo });
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
    try std.testing.expectEqual(@as(usize, 1), global_catalog.workspace.activeEntryCount());
    try std.testing.expect(global_catalog.workspace.entries[global_catalog.workspace.findEntryIndex("docs/readme.txt").?].isTombstone());
    try std.testing.expectError(error.FileNotFound, global_catalog.readBlob("docs/readme.txt", &read_buf));
}

fn testAllowAuth(cap_type: CapType, rights: u16) bool {
    _ = cap_type;
    _ = rights;
    return true;
}

fn testRejectAuth(cap_type: CapType, rights: u16) bool {
    _ = cap_type;
    _ = rights;
    return false;
}

test "catalog syscall registration and execution" {
    clearCatalogContext();
    defer clearCatalogContext();

    setStorageContext(testMockCasPut, testMockCasGet, testAllowAuth);

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
    defer vm.gcAllocator().free(write_val.string);
    try std.testing.expectEqual(@as(usize, 64), write_val.string.len);

    var list_args = [_]Value{Value{ .string = "" }};
    const list_val = try nativeSysCatalogList(&vm, &list_args);
    defer vm.gcAllocator().free(list_val.string);
    try std.testing.expect(std.mem.indexOf(u8, list_val.string, "notes.txt") != null);

    const status_val = try nativeSysCatalogStatus(&vm, &[_]Value{});
    defer vm.gcAllocator().free(status_val.string);
    try std.testing.expect(std.mem.indexOf(u8, status_val.string, "\"entries\":1") != null);

    var read_args = [_]Value{Value{ .string = "notes.txt" }};
    const read_val = try nativeSysCatalogRead(&vm, &read_args);
    defer vm.gcAllocator().free(read_val.string);
    try std.testing.expect(read_val.string.len > 0);

    var commit_args = [_]Value{Value{ .string = "test commit" }};
    const commit_val = try nativeSysCatalogCommit(&vm, &commit_args);
    defer vm.gcAllocator().free(commit_val.string);
    try std.testing.expectEqual(@as(usize, 64), commit_val.string.len);

    var del_args = [_]Value{Value{ .string = "notes.txt" }};
    const del_val = try nativeSysCatalogDelete(&vm, &del_args);
    try std.testing.expect(del_val.boolean);
}

test "catalog syscall unauthorized caller rejection" {
    clearCatalogContext();
    defer clearCatalogContext();

    const allocator = std.testing.allocator;
    var chunk = @import("../../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    // 1. When auth callback is null -> fails closed
    setStorageContext(testMockCasPut, testMockCasGet, null);
    var write_args = [_]Value{ Value{ .string = "notes.txt" }, Value{ .string = "secret" } };
    const write_val = try nativeSysCatalogWrite(&vm, &write_args);
    try std.testing.expectEqualStrings("", write_val.string);

    // 2. When auth callback explicitly rejects -> fails closed
    setStorageContext(testMockCasPut, testMockCasGet, testRejectAuth);
    const write_val_rejected = try nativeSysCatalogWrite(&vm, &write_args);
    try std.testing.expectEqualStrings("", write_val_rejected.string);
}

test "catalog tags MVP: human-legible tags to BLAKE3, generation advances on write and delete, tag CRUD" {
    clearCatalogContext();
    defer clearCatalogContext();

    setStorageContext(testMockCasPut, testMockCasGet, testAllowAuth);

    const allocator = std.testing.allocator;
    var chunk = @import("../../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    try registerCatalogSyscalls(&vm);

    // Initial generation is 1
    try std.testing.expectEqual(@as(u64, 1), global_catalog.workspace.header.generation);

    // 1. Create tag 'home.notes' -> advances generation to 2
    var write_notes = [_]Value{ Value{ .string = "home.notes" }, Value{ .string = "Grocery list and sovereign ideas" } };
    const hash1 = try nativeSysCatalogWrite(&vm, &write_notes);
    defer vm.gcAllocator().free(hash1.string);
    try std.testing.expectEqual(@as(usize, 64), hash1.string.len);
    try std.testing.expectEqual(@as(u64, 2), global_catalog.workspace.header.generation);

    // 2. Create tag 'app.desk' -> advances generation to 3
    var write_app = [_]Value{ Value{ .string = "app.desk" }, Value{ .string = "print(\"Desk App\");" } };
    const hash2 = try nativeSysCatalogWrite(&vm, &write_app);
    defer vm.gcAllocator().free(hash2.string);
    try std.testing.expectEqual(@as(usize, 64), hash2.string.len);
    try std.testing.expectEqual(@as(u64, 3), global_catalog.workspace.header.generation);

    // 3. Read tag 'home.notes' -> verify content retrieved
    var read_notes = [_]Value{Value{ .string = "home.notes" }};
    const content1 = try nativeSysCatalogRead(&vm, &read_notes);
    defer vm.gcAllocator().free(content1.string);
    try std.testing.expectEqualStrings("Hello Sovereign Workspace!\n", content1.string);

    // 4. Update tag 'home.notes' -> advances generation to 4
    var update_notes = [_]Value{ Value{ .string = "home.notes" }, Value{ .string = "Updated notes content" } };
    const hash3 = try nativeSysCatalogWrite(&vm, &update_notes);
    defer vm.gcAllocator().free(hash3.string);
    try std.testing.expectEqual(@as(u64, 4), global_catalog.workspace.header.generation);

    // 5. Delete tag 'app.desk' -> advances generation to 5
    var del_app = [_]Value{Value{ .string = "app.desk" }};
    const del_res = try nativeSysCatalogDelete(&vm, &del_app);
    try std.testing.expect(del_res.boolean);
    try std.testing.expectEqual(@as(u64, 5), global_catalog.workspace.header.generation);

    // 6. Verify status reflects generation 5 and 1 entry remaining
    const status_val = try nativeSysCatalogStatus(&vm, &[_]Value{});
    defer vm.gcAllocator().free(status_val.string);
    try std.testing.expect(std.mem.indexOf(u8, status_val.string, "\"generation\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_val.string, "\"entries\":1") != null);
}

var test_real_cas: ?*cas_mod.CasEngine = null;
fn testRealCasPut(data: []const u8, out_hex: *[chunk_mod.HEX_HASH_SIZE]u8) anyerror!void {
    const hash = try test_real_cas.?.putChunk(.raw_blob, data, null);
    chunk_mod.formatHexHash(&hash, out_hex);
}
fn testRealCasGet(hex_hash: []const u8, out_buf: []u8) anyerror!usize {
    var raw_hash: [chunk_mod.HASH_SIZE]u8 = undefined;
    try chunk_mod.parseHexHash(hex_hash, &raw_hash);
    return try test_real_cas.?.getChunk(&raw_hash, out_buf, null);
}

test "catalog broker with real CasEngine write and read roundtrip" {
    clearCatalogContext();
    defer clearCatalogContext();

    var cache = try @import("block_cache.zig").BlockCache.init(std.testing.allocator);
    defer cache.deinit();

    var cas = try cas_mod.CasEngine.init(&cache, null, 1000);
    test_real_cas = &cas;
    defer {
        test_real_cas = null;
    }

    setStorageContext(testRealCasPut, testRealCasGet, testAllowAuth);

    var hex_out: [64]u8 = undefined;
    const test_content = "print(\"Sovereign Desktop running.\");";
    try global_catalog.writeBlob("desk", test_content, &hex_out);

    var read_buf: [256]u8 = undefined;
    const read_len = try global_catalog.readBlob("desk", &read_buf);
    try std.testing.expectEqualStrings(test_content, read_buf[0..read_len]);
}

var test_store_hashes: [64][64]u8 = undefined;
var test_store_data: [64][256]u8 = undefined;
var test_store_lens: [64]usize = undefined;
var test_store_count: usize = 0;

fn testMapCasPut(data: []const u8, out_hex: *[64]u8) anyerror!void {
    const hash = chunk_mod.computeBlake3Hash(data);
    chunk_mod.formatHexHash(&hash, out_hex);
    if (test_store_count < 64) {
        @memcpy(&test_store_hashes[test_store_count], out_hex);
        const len = @min(data.len, 256);
        @memcpy(test_store_data[test_store_count][0..len], data[0..len]);
        test_store_lens[test_store_count] = len;
        test_store_count += 1;
    }
}

fn testMapCasGet(hex_hash: []const u8, out_buf: []u8) anyerror!usize {
    for (0..test_store_count) |i| {
        if (std.mem.eql(u8, hex_hash, &test_store_hashes[i])) {
            const len = test_store_lens[i];
            @memcpy(out_buf[0..len], test_store_data[i][0..len]);
            return len;
        }
    }
    return error.FileNotFound;
}

test "workspace: write-write-undo-readbackidentity" {
    clearCatalogContext();
    defer clearCatalogContext();

    test_store_count = 0;
    setStorageContext(testMapCasPut, testMapCasGet, testAllowAuth);

    var hex_out: [64]u8 = undefined;
    try global_catalog.writeBlob("app.state", "state_payload_version_1", &hex_out);
    const hash_a = hex_out;
    try std.testing.expectEqual(@as(u64, 2), global_catalog.workspace.header.generation);

    var read_buf: [128]u8 = undefined;
    var len = try global_catalog.readBlob("app.state", &read_buf);
    try std.testing.expectEqualStrings("state_payload_version_1", read_buf[0..len]);

    // Mutate to version 2
    try global_catalog.writeBlob("app.state", "state_payload_version_2", &hex_out);
    const hash_b = hex_out;
    try std.testing.expect(!std.mem.eql(u8, &hash_a, &hash_b));
    try std.testing.expectEqual(@as(u64, 3), global_catalog.workspace.header.generation);

    len = try global_catalog.readBlob("app.state", &read_buf);
    try std.testing.expectEqualStrings("state_payload_version_2", read_buf[0..len]);

    // Execute :undo -> generation advances forward to 4, restoring state from generation 2
    try std.testing.expect(global_catalog.undo());
    try std.testing.expectEqual(@as(u64, 4), global_catalog.workspace.header.generation);

    // Prove byte-identical readback identity: content and hash match hash_a
    len = try global_catalog.readBlob("app.state", &read_buf);
    try std.testing.expectEqualStrings("state_payload_version_1", read_buf[0..len]);

    const entry = global_catalog.workspace.lookup("app.state").?;
    var hex_check: [64]u8 = undefined;
    chunk_mod.formatHexHash(&entry.hash, &hex_check);
    try std.testing.expectEqualStrings(&hash_a, &hex_check);
}

test "workspace: delete-tombstone-resurrect" {
    clearCatalogContext();
    defer clearCatalogContext();

    test_store_count = 0;
    setStorageContext(testMapCasPut, testMapCasGet, testAllowAuth);

    var hex_out: [64]u8 = undefined;
    try global_catalog.writeBlob("app.doc", "important contract", &hex_out);
    try std.testing.expectEqual(@as(u64, 2), global_catalog.workspace.header.generation);
    try std.testing.expect(global_catalog.workspace.lookup("app.doc") != null);

    // Delete tag -> tombstones record in generation 3
    try std.testing.expect(global_catalog.deleteFile("app.doc"));
    try std.testing.expectEqual(@as(u64, 3), global_catalog.workspace.header.generation);
    try std.testing.expect(global_catalog.workspace.lookup("app.doc") == null);
    const idx = global_catalog.workspace.findEntryIndex("app.doc").?;
    try std.testing.expect(global_catalog.workspace.entries[idx].isTombstone());

    // Execute :undo -> generation 4 restores active tag from generation 2
    try std.testing.expect(global_catalog.undo());
    try std.testing.expectEqual(@as(u64, 4), global_catalog.workspace.header.generation);
    try std.testing.expect(global_catalog.workspace.lookup("app.doc") != null);
    try std.testing.expect(!global_catalog.workspace.entries[global_catalog.workspace.findEntryIndex("app.doc").?].isTombstone());

    var read_buf: [128]u8 = undefined;
    const len = try global_catalog.readBlob("app.doc", &read_buf);
    try std.testing.expectEqualStrings("important contract", read_buf[0..len]);
}

test "workspace: @gen-pinned read vs current" {
    clearCatalogContext();
    defer clearCatalogContext();

    test_store_count = 0;
    setStorageContext(testMapCasPut, testMapCasGet, testAllowAuth);

    var hex_out: [64]u8 = undefined;
    try global_catalog.writeBlob("config.val", "version_one", &hex_out);
    const hash_v1 = hex_out; // gen 2
    try global_catalog.writeBlob("config.val", "version_two", &hex_out);
    const hash_v2 = hex_out; // gen 3
    try global_catalog.writeBlob("config.val", "version_three", &hex_out);
    const hash_v3 = hex_out; // gen 4

    // Verify current lookup is gen 4
    const cur_entry = global_catalog.workspace.lookup("config.val").?;
    var hex_cur: [64]u8 = undefined;
    chunk_mod.formatHexHash(&cur_entry.hash, &hex_cur);
    try std.testing.expectEqualStrings(&hash_v3, &hex_cur);

    // Verify pinned lookups at @2, @3, @4
    const snap2 = global_catalog.ring.findSnapshot(2).?;
    const entry2 = snap2.manifest.lookup("config.val").?;
    var hex_snap2: [64]u8 = undefined;
    chunk_mod.formatHexHash(&entry2.hash, &hex_snap2);
    try std.testing.expectEqualStrings(&hash_v1, &hex_snap2);

    const snap3 = global_catalog.ring.findSnapshot(3).?;
    const entry3 = snap3.manifest.lookup("config.val").?;
    var hex_snap3: [64]u8 = undefined;
    chunk_mod.formatHexHash(&entry3.hash, &hex_snap3);
    try std.testing.expectEqualStrings(&hash_v2, &hex_snap3);

    // Verify readBlob parsing @gen returns byte-identical data
    var read_buf: [128]u8 = undefined;
    var len = try global_catalog.readBlob("config.val@2", &read_buf);
    try std.testing.expectEqualStrings("version_one", read_buf[0..len]);

    len = try global_catalog.readBlob("config.val@3", &read_buf);
    try std.testing.expectEqualStrings("version_two", read_buf[0..len]);

    len = try global_catalog.readBlob("config.val@4", &read_buf);
    try std.testing.expectEqualStrings("version_three", read_buf[0..len]);

    len = try global_catalog.readBlob("config.val", &read_buf);
    try std.testing.expectEqualStrings("version_three", read_buf[0..len]);
}

test "workspace: undo-at-genesis is clean no-op" {
    clearCatalogContext();
    defer clearCatalogContext();

    test_store_count = 0;
    setStorageContext(testMapCasPut, testMapCasGet, testAllowAuth);

    // At genesis (generation 1), undo safely returns false and does not mutate state
    try std.testing.expectEqual(@as(u64, 1), global_catalog.workspace.header.generation);
    try std.testing.expect(!global_catalog.undo());
    try std.testing.expectEqual(@as(u64, 1), global_catalog.workspace.header.generation);
}

test "workspace: ring-overflow evicts oldest generation" {
    clearCatalogContext();
    defer clearCatalogContext();

    test_store_count = 0;
    setStorageContext(testMapCasPut, testMapCasGet, testAllowAuth);

    // Write 17 generations (gen 2 to gen 18)
    var hex_out: [64]u8 = undefined;
    for (0..17) |i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "item_{d}.txt", .{i});
        try global_catalog.writeBlob(name, "data", &hex_out);
    }

    try std.testing.expectEqual(@as(u64, 18), global_catalog.workspace.header.generation);
    try std.testing.expectEqual(@as(usize, 16), global_catalog.ring.count);

    // Ring holds 16 snapshots. Generation 1 and 2 were evicted; oldest live is 3
    const oldest = global_catalog.ring.getOldestLiveGeneration();
    try std.testing.expectEqual(@as(u64, 3), oldest);

    // Querying evicted generation 1 or 2 yields error.GenerationEvicted
    var read_buf: [128]u8 = undefined;
    try std.testing.expectError(error.GenerationEvicted, global_catalog.readBlob("item_0.txt@1", &read_buf));
    try std.testing.expectError(error.GenerationEvicted, global_catalog.readBlob("item_0.txt@2", &read_buf));

    // Querying live generation 3 succeeds
    _ = try global_catalog.readBlob("item_0.txt@3", &read_buf);

    // Prove P0-C4: nativeSysCatalogRead returns honest eviction message
    const allocator = std.testing.allocator;
    var chunk = @import("../../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    var read_args = [_]Value{Value{ .string = "item_0.txt@1" }};
    const evicted_val = try nativeSysCatalogRead(&vm, &read_args);
    defer vm.gcAllocator().free(evicted_val.string);
    try std.testing.expect(std.mem.indexOf(u8, evicted_val.string, "Generation 1 evicted (ring bound: 16, oldest live: 3)") != null);
}

test "O5: writeProbeTranscript indexes transcript under probe.transcript tag" {
    clearCatalogContext();
    defer clearCatalogContext();

    test_store_count = 0;
    setStorageContext(testMapCasPut, testMapCasGet, testAllowAuth);

    const dummy_data = "probe transcript test entry 0123456789";
    const maybe_hash = writeProbeTranscript(dummy_data);
    try std.testing.expect(maybe_hash != null);

    const entry = global_catalog.workspace.lookup("probe.transcript");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u32, dummy_data.len), entry.?.size);
    try std.testing.expectEqual(maybe_hash.?, entry.?.hash);
}
