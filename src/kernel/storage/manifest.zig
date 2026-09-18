// MicrOS (µOS) Merkle Workspace Manifest Substrate
// Flat, bounded, content-addressed workspace manifest with OCC commit protocol.
// Enforces zero-POSIX flat semantic keys. Zero libc, freestanding.

const std = @import("std");
const chunk_mod = @import("chunk.zig");

pub const MAX_FILENAME_LEN: usize = 64;
pub const MAX_WORKSPACE_ENTRIES: usize = 256;
pub const MAX_COMMIT_MSG_LEN: usize = 64;
pub const WORKSPACE_MANIFEST_MAGIC: u32 = 0x4D494357; // "MICW"
pub const WORKSPACE_MANIFEST_VERSION: u32 = 1;

pub const WorkspaceEntryFlags = struct {
    pub const DELETED: u16 = 0x0001;
    pub const EXECUTABLE: u16 = 0x0002;
    pub const SYSTEM: u16 = 0x0004;
};

pub const WorkspaceEntry = extern struct {
    name: [MAX_FILENAME_LEN]u8 = [_]u8{0} ** MAX_FILENAME_LEN,
    name_len: u16 = 0,
    flags: u16 = 0,
    size: u32 = 0,
    hash: [chunk_mod.HASH_SIZE]u8 = [_]u8{0} ** chunk_mod.HASH_SIZE,
    mtime: u64 = 0,
    reserved: [16]u8 = [_]u8{0} ** 16,

    pub fn getName(self: *const WorkspaceEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const WorkspaceManifestHeader = extern struct {
    magic: u32 = WORKSPACE_MANIFEST_MAGIC,
    version: u32 = WORKSPACE_MANIFEST_VERSION,
    generation: u64 = 0,
    entry_count: u32 = 0,
    reserved: u32 = 0,
    total_bytes: u64 = 0,
    prev_manifest_hash: [chunk_mod.HASH_SIZE]u8 = [_]u8{0} ** chunk_mod.HASH_SIZE,
    commit_msg: [MAX_COMMIT_MSG_LEN]u8 = [_]u8{0} ** MAX_COMMIT_MSG_LEN,
    checksum: [chunk_mod.HASH_SIZE]u8 = [_]u8{0} ** chunk_mod.HASH_SIZE,
};

pub const HEADER_SIZE: usize = @sizeOf(WorkspaceManifestHeader);
pub const ENTRY_SIZE: usize = @sizeOf(WorkspaceEntry);
pub const FULL_MANIFEST_SIZE: usize = HEADER_SIZE + (MAX_WORKSPACE_ENTRIES * ENTRY_SIZE);

pub fn validatePath(path: []const u8) bool {
    if (path.len == 0 or path.len > MAX_FILENAME_LEN) return false;
    if (path[0] == '/' or path[path.len - 1] == '/') return false;

    var prev: u8 = 0;
    for (path) |c| {
        if (c == '/' and prev == '/') return false;
        if (c == '.' and prev == '.') return false;
        const valid = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-' or c == '.' or c == '/';
        if (!valid) return false;
        prev = c;
    }
    return true;
}

pub const WorkspaceManifest = struct {
    header: WorkspaceManifestHeader = .{},
    entries: [MAX_WORKSPACE_ENTRIES]WorkspaceEntry = [_]WorkspaceEntry{.{}} ** MAX_WORKSPACE_ENTRIES,

    pub fn init(generation: u64, prev_hash: *const [chunk_mod.HASH_SIZE]u8) WorkspaceManifest {
        var m = WorkspaceManifest{};
        m.header.generation = generation;
        m.header.prev_manifest_hash = prev_hash.*;
        return m;
    }

    pub fn findEntryIndex(self: *const WorkspaceManifest, path: []const u8) ?usize {
        var low: usize = 0;
        var high: usize = self.header.entry_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const cur_name = self.entries[mid].getName();
            const cmp = std.mem.order(u8, path, cur_name);
            switch (cmp) {
                .eq => return mid,
                .lt => high = mid,
                .gt => low = mid + 1,
            }
        }
        return null;
    }

    pub fn lookup(self: *const WorkspaceManifest, path: []const u8) ?*const WorkspaceEntry {
        const idx = self.findEntryIndex(path) orelse return null;
        if ((self.entries[idx].flags & WorkspaceEntryFlags.DELETED) != 0) return null;
        return &self.entries[idx];
    }

    fn findInsertIndex(self: *const WorkspaceManifest, path: []const u8) usize {
        var low: usize = 0;
        var high: usize = self.header.entry_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const cur_name = self.entries[mid].getName();
            if (std.mem.order(u8, path, cur_name) == .lt) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return low;
    }

    pub fn putEntry(self: *WorkspaceManifest, entry: WorkspaceEntry) !void {
        const path = entry.getName();
        if (!validatePath(path)) return error.InvalidPath;

        if (self.findEntryIndex(path)) |existing_idx| {
            self.header.total_bytes -= self.entries[existing_idx].size;
            self.entries[existing_idx] = entry;
            self.header.total_bytes += entry.size;
            return;
        }

        if (self.header.entry_count >= MAX_WORKSPACE_ENTRIES) {
            return error.WorkspaceFull;
        }

        const ins_idx = self.findInsertIndex(path);
        var i: usize = self.header.entry_count;
        while (i > ins_idx) : (i -= 1) {
            self.entries[i] = self.entries[i - 1];
        }

        self.entries[ins_idx] = entry;
        self.header.entry_count += 1;
        self.header.total_bytes += entry.size;
    }

    pub fn deleteEntry(self: *WorkspaceManifest, path: []const u8) bool {
        const idx = self.findEntryIndex(path) orelse return false;
        if ((self.entries[idx].flags & WorkspaceEntryFlags.DELETED) != 0) return false;

        self.header.total_bytes -= self.entries[idx].size;
        var i: usize = idx;
        while (i + 1 < self.header.entry_count) : (i += 1) {
            self.entries[i] = self.entries[i + 1];
        }
        self.header.entry_count -= 1;
        return true;
    }

    pub fn setCommitMsg(self: *WorkspaceManifest, msg: []const u8) void {
        const mlen = @min(msg.len, MAX_COMMIT_MSG_LEN);
        @memset(&self.header.commit_msg, 0);
        @memcpy(self.header.commit_msg[0..mlen], msg[0..mlen]);
    }

    pub fn serialize(self: *WorkspaceManifest, out_buf: []u8) !usize {
        const active_size = HEADER_SIZE + (self.header.entry_count * ENTRY_SIZE);
        if (out_buf.len < active_size) return error.BufferTooSmall;

        self.header.checksum = [_]u8{0} ** chunk_mod.HASH_SIZE;
        const raw_hdr: [*]const u8 = @ptrCast(&self.header);
        @memcpy(out_buf[0..HEADER_SIZE], raw_hdr[0..HEADER_SIZE]);

        for (0..self.header.entry_count) |i| {
            const offset = HEADER_SIZE + (i * ENTRY_SIZE);
            const raw_entry: [*]const u8 = @ptrCast(&self.entries[i]);
            @memcpy(out_buf[offset .. offset + ENTRY_SIZE], raw_entry[0..ENTRY_SIZE]);
        }

        const hash = chunk_mod.computeBlake3Hash(out_buf[0..active_size]);
        self.header.checksum = hash;
        @memcpy(out_buf[0..HEADER_SIZE], raw_hdr[0..HEADER_SIZE]);

        return active_size;
    }

    pub fn deserialize(data: []const u8) !WorkspaceManifest {
        if (data.len < HEADER_SIZE) return error.CorruptManifest;
        var hdr: WorkspaceManifestHeader = undefined;
        const raw_hdr: [*]u8 = @ptrCast(&hdr);
        @memcpy(raw_hdr[0..HEADER_SIZE], data[0..HEADER_SIZE]);

        if (hdr.magic != WORKSPACE_MANIFEST_MAGIC) return error.InvalidMagic;
        if (hdr.version != WORKSPACE_MANIFEST_VERSION) return error.UnsupportedVersion;
        if (hdr.entry_count > MAX_WORKSPACE_ENTRIES) return error.CorruptManifest;

        const expected_len = HEADER_SIZE + (hdr.entry_count * ENTRY_SIZE);
        if (data.len < expected_len) return error.CorruptManifest;

        var m = WorkspaceManifest{ .header = hdr };
        for (0..hdr.entry_count) |i| {
            const offset = HEADER_SIZE + (i * ENTRY_SIZE);
            const raw_entry: [*]u8 = @ptrCast(&m.entries[i]);
            @memcpy(raw_entry[0..ENTRY_SIZE], data[offset .. offset + ENTRY_SIZE]);
        }
        return m;
    }
};

// === Colocated Unit Tests ===

test "path validation invariants" {
    try std.testing.expect(validatePath("index.html"));
    try std.testing.expect(validatePath("docs/notes.txt"));
    try std.testing.expect(validatePath("src/kernel/main.zig"));
    try std.testing.expect(validatePath("my-app_v1.0.tar.gz"));

    try std.testing.expect(!validatePath(""));
    try std.testing.expect(!validatePath("/leading_slash"));
    try std.testing.expect(!validatePath("trailing_slash/"));
    try std.testing.expect(!validatePath("double//slash"));
    try std.testing.expect(!validatePath("path/../traversal"));
    try std.testing.expect(!validatePath("path\\backslash"));
    try std.testing.expect(!validatePath("path with space"));
}

test "workspace manifest insert, sort, lookup and delete" {
    const prev = [_]u8{0} ** chunk_mod.HASH_SIZE;
    var ws = WorkspaceManifest.init(1, &prev);

    var e1 = WorkspaceEntry{ .size = 100, .name_len = 8 };
    @memcpy(e1.name[0..8], "file_b.c");
    var e2 = WorkspaceEntry{ .size = 200, .name_len = 8 };
    @memcpy(e2.name[0..8], "file_a.c");
    var e3 = WorkspaceEntry{ .size = 300, .name_len = 8 };
    @memcpy(e3.name[0..8], "file_c.c");

    try ws.putEntry(e1);
    try ws.putEntry(e2);
    try ws.putEntry(e3);

    try std.testing.expectEqual(@as(u32, 3), ws.header.entry_count);
    try std.testing.expectEqualStrings("file_a.c", ws.entries[0].getName());
    try std.testing.expectEqualStrings("file_b.c", ws.entries[1].getName());
    try std.testing.expectEqualStrings("file_c.c", ws.entries[2].getName());
    try std.testing.expectEqual(@as(u64, 600), ws.header.total_bytes);

    const found_b = ws.lookup("file_b.c").?;
    try std.testing.expectEqual(@as(u32, 100), found_b.size);

    try std.testing.expect(ws.lookup("nonexistent") == null);

    try std.testing.expect(ws.deleteEntry("file_b.c"));
    try std.testing.expectEqual(@as(u32, 2), ws.header.entry_count);
    try std.testing.expect(ws.lookup("file_b.c") == null);
    try std.testing.expectEqual(@as(u64, 500), ws.header.total_bytes);
}

test "workspace manifest serialization roundtrip" {
    const prev = [_]u8{0xAA} ** chunk_mod.HASH_SIZE;
    var ws = WorkspaceManifest.init(42, &prev);
    ws.setCommitMsg("initial workspace snapshot");

    var e = WorkspaceEntry{ .size = 1024, .name_len = 9 };
    @memcpy(e.name[0..9], "readme.md");
    @memcpy(&e.hash, "0123456789abcdef0123456789abcdef");
    try ws.putEntry(e);

    var buf: [FULL_MANIFEST_SIZE]u8 = undefined;
    const len = try ws.serialize(&buf);
    try std.testing.expect(len >= HEADER_SIZE + ENTRY_SIZE);

    const decoded = try WorkspaceManifest.deserialize(buf[0..len]);
    try std.testing.expectEqual(@as(u64, 42), decoded.header.generation);
    try std.testing.expectEqual(@as(u32, 1), decoded.header.entry_count);
    try std.testing.expectEqualStrings("readme.md", decoded.entries[0].getName());
    try std.testing.expectEqual(@as(u32, 1024), decoded.entries[0].size);
    try std.testing.expect(std.mem.startsWith(u8, &decoded.header.commit_msg, "initial workspace snapshot"));
}
