// MicrOS (µOS) Git Transport & Content-Addressed Ingestion ABI
// Maps Git Smart HTTP push transfers directly to BLAKE3 CAS objects.
// Enforces CSpace capability isolation. Zero libc, freestanding.

const std = @import("std");
const eval = @import("../../macros/eval.zig");
const Value = eval.Value;
const vm_mod = @import("../../macros/vm.zig");
const VM = vm_mod.VM;
const git_pkt = @import("git_pkt.zig");
const git_pack = @import("git_pack.zig");
const git_transport = @import("git_transport.zig");
const cap_mod = @import("../cap/capability.zig");
const CapType = cap_mod.CapType;
const Rights = cap_mod.Rights;

pub const MAX_PATH_LEN: usize = 128;
pub const MAX_REPO_NAME_LEN: usize = 64;
pub const MAX_BRANCH_LEN: usize = 64;
pub const MAX_TRACKED_FILES: usize = 32;
pub const MAX_REPOSITORIES: usize = 8;
pub const MAX_OBJECTS_PER_PACK: usize = 64;
pub const MAX_GIT_BUFFER_SIZE: usize = 16384;

pub const GitFileEntry = struct {
    path: [MAX_PATH_LEN]u8 = [_]u8{0} ** MAX_PATH_LEN,
    path_len: usize = 0,
    cas_hash: [64]u8 = [_]u8{0} ** 64,
    git_oid: [20]u8 = [_]u8{0} ** 20,
};

pub const GitRepository = struct {
    name: [MAX_REPO_NAME_LEN]u8 = [_]u8{0} ** MAX_REPO_NAME_LEN,
    name_len: usize = 0,
    branch: [MAX_BRANCH_LEN]u8 = [_]u8{0} ** MAX_BRANCH_LEN,
    branch_len: usize = 0,
    tip_sha: [40]u8 = [_]u8{'0'} ** 40,
    has_commits: bool = false,
    files: [MAX_TRACKED_FILES]GitFileEntry = [_]GitFileEntry{.{}} ** MAX_TRACKED_FILES,
    file_count: usize = 0,

    pub fn setTip(self: *GitRepository, branch: []const u8, sha: []const u8) void {
        const blen = @min(branch.len, MAX_BRANCH_LEN);
        @memcpy(self.branch[0..blen], branch[0..blen]);
        self.branch_len = blen;

        const slen = @min(sha.len, 40);
        @memcpy(self.tip_sha[0..slen], sha[0..slen]);
        self.has_commits = true;
    }

    pub fn addOrUpdateFile(
        self: *GitRepository,
        path: []const u8,
        cas_hash: []const u8,
        git_oid: *const [20]u8,
    ) void {
        const hlen = @min(cas_hash.len, 64);
        for (0..self.file_count) |i| {
            if (std.mem.eql(u8, self.files[i].path[0..self.files[i].path_len], path)) {
                @memcpy(self.files[i].cas_hash[0..hlen], cas_hash[0..hlen]);
                self.files[i].git_oid = git_oid.*;
                return;
            }
        }
        if (self.file_count < MAX_TRACKED_FILES) {
            const idx = self.file_count;
            const plen = @min(path.len, MAX_PATH_LEN);
            @memcpy(self.files[idx].path[0..plen], path[0..plen]);
            self.files[idx].path_len = plen;
            @memcpy(self.files[idx].cas_hash[0..hlen], cas_hash[0..hlen]);
            self.files[idx].git_oid = git_oid.*;
            self.file_count += 1;
        }
    }

    pub fn findFileCasHash(self: *const GitRepository, path: []const u8) ?[]const u8 {
        for (0..self.file_count) |i| {
            if (std.mem.eql(u8, self.files[i].path[0..self.files[i].path_len], path)) {
                return &self.files[i].cas_hash;
            }
        }
        return null;
    }
};

pub const RepoRegistry = struct {
    repos: [MAX_REPOSITORIES]GitRepository = [_]GitRepository{.{}} ** MAX_REPOSITORIES,
    repo_count: usize = 0,

    pub fn getOrCreate(self: *RepoRegistry, name: []const u8) ?*GitRepository {
        for (0..self.repo_count) |i| {
            if (std.mem.eql(u8, self.repos[i].name[0..self.repos[i].name_len], name)) {
                return &self.repos[i];
            }
        }
        if (self.repo_count < MAX_REPOSITORIES) {
            const idx = self.repo_count;
            const nlen = @min(name.len, MAX_REPO_NAME_LEN);
            @memcpy(self.repos[idx].name[0..nlen], name[0..nlen]);
            self.repos[idx].name_len = nlen;
            self.repo_count += 1;
            return &self.repos[idx];
        }
        return null;
    }

    pub fn get(self: *const RepoRegistry, name: []const u8) ?*const GitRepository {
        if (name.len == 0 and self.repo_count > 0) {
            return &self.repos[0];
        }
        for (0..self.repo_count) |i| {
            if (std.mem.eql(u8, self.repos[i].name[0..self.repos[i].name_len], name)) {
                return &self.repos[i];
            }
        }
        return null;
    }
};

pub var global_repos: RepoRegistry = .{};
pub var cas_put_fn: ?*const fn (data: []const u8, out_hex: *[64]u8) anyerror!void = null;
pub var cas_get_fn: ?*const fn (hex_hash: []const u8, out_buf: []u8) anyerror!usize = null;
pub var caller_auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool = null;

pub fn setCasContext(
    put_fn: ?*const fn (data: []const u8, out_hex: *[64]u8) anyerror!void,
    get_fn: ?*const fn (hex_hash: []const u8, out_buf: []u8) anyerror!usize,
) void {
    cas_put_fn = put_fn;
    cas_get_fn = get_fn;
}

pub fn setCallerAuth(auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool) void {
    caller_auth_fn = auth_fn;
}

pub fn clearGitContext() void {
    cas_put_fn = null;
    cas_get_fn = null;
    caller_auth_fn = null;
    global_repos = .{};
}

fn checkCallerAuthority(cap_type: CapType, rights: u16) bool {
    if (caller_auth_fn) |auth| {
        return auth(cap_type, rights);
    }
    return true;
}

fn parseHexNibble(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

fn parseHexOid(hex: []const u8, out_bin: *[20]u8) bool {
    if (hex.len < 40) return false;
    for (0..20) |i| {
        const hi = parseHexNibble(hex[i * 2]) orelse return false;
        const lo = parseHexNibble(hex[i * 2 + 1]) orelse return false;
        out_bin[i] = (@as(u8, hi) << 4) | @as(u8, lo);
    }
    return true;
}

fn computeGitOid(obj_type: git_pack.GitObjectType, payload: []const u8) [20]u8 {
    const type_str = switch (obj_type) {
        .commit => "commit",
        .tree => "tree",
        .blob => "blob",
        .tag => "tag",
        else => "unknown",
    };
    var hdr_buf: [32]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "{s} {d}\x00", .{ type_str, payload.len }) catch "";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(hdr);
    hasher.update(payload);
    var oid: [20]u8 = undefined;
    hasher.final(&oid);
    return oid;
}

const ParsedPackObject = struct {
    obj_type: git_pack.GitObjectType,
    oid: [20]u8,
    cas_hash: [64]u8,
    data: []u8,
};

fn findPackOffset(payload: []const u8) ?usize {
    return std.mem.indexOf(u8, payload, "PACK");
}

fn processTreeObject(
    repo: *GitRepository,
    tree_data: []const u8,
    objects: []const ParsedPackObject,
) void {
    var offset: usize = 0;
    while (offset < tree_data.len) {
        const res = git_pack.parseTreeEntry(tree_data[offset..]) orelse break;
        for (objects) |obj| {
            if (obj.obj_type == .blob and std.mem.eql(u8, &obj.oid, &res.entry.oid)) {
                repo.addOrUpdateFile(res.entry.name, &obj.cas_hash, &res.entry.oid);
                break;
            }
        }
        offset += res.consumed;
    }
}

fn unpackObjects(
    allocator: std.mem.Allocator,
    pack_data: []const u8,
    obj_count: u32,
    parsed_objs: *[MAX_OBJECTS_PER_PACK]ParsedPackObject,
) !usize {
    var offset: usize = git_pack.PACK_HEADER_SIZE;
    var count: usize = 0;
    while (count < obj_count and count < MAX_OBJECTS_PER_PACK) {
        if (offset >= pack_data.len) break;
        const obj_hdr = git_pack.parseObjectHeader(pack_data[offset..]) orelse return error.BadObjectHeader;
        offset += obj_hdr.header_bytes;

        const decomp = try git_pack.decompressObject(allocator, pack_data[offset..], obj_hdr.uncompressed_size);
        offset += decomp.consumed_bytes;

        const oid = computeGitOid(obj_hdr.obj_type, decomp.data);
        var cas_hash: [64]u8 = [_]u8{'0'} ** 64;
        if (obj_hdr.obj_type == .blob) {
            if (cas_put_fn) |put| {
                try put(decomp.data, &cas_hash);
            }
        }

        parsed_objs[count] = ParsedPackObject{
            .obj_type = obj_hdr.obj_type,
            .oid = oid,
            .cas_hash = cas_hash,
            .data = decomp.data,
        };
        count += 1;
    }
    return count;
}

fn mapCommitAndTree(
    repo: *GitRepository,
    objects: []const ParsedPackObject,
    count: usize,
) void {
    var commit_idx: ?usize = null;
    for (0..count) |i| {
        if (objects[i].obj_type == .commit) {
            commit_idx = i;
            break;
        }
    }
    const c_idx = commit_idx orelse return;
    const tree_hex = git_pack.parseCommitTreeSha(objects[c_idx].data) orelse return;
    var tree_bin: [20]u8 = undefined;
    if (!parseHexOid(&tree_hex, &tree_bin)) return;

    for (0..count) |i| {
        if (objects[i].obj_type == .tree and std.mem.eql(u8, &objects[i].oid, &tree_bin)) {
            processTreeObject(repo, objects[i].data, objects[0..count]);
            break;
        }
    }
}

pub fn processReceivePack(
    allocator: std.mem.Allocator,
    repo_name: []const u8,
    payload: []const u8,
    out_buf: []u8,
) !usize {
    const first_pkt = git_pkt.parsePktLine(payload) orelse {
        return try git_transport.buildReportStatusBody("refs/heads/master", false, "bad pkt-line", out_buf);
    };
    const push_cmd = git_pkt.parsePushCommand(first_pkt.payload) orelse {
        return try git_transport.buildReportStatusBody("refs/heads/master", false, "bad command", out_buf);
    };
    const pack_start = findPackOffset(payload) orelse {
        return try git_transport.buildReportStatusBody(push_cmd.ref_name, false, "missing PACK", out_buf);
    };

    const pack_data = payload[pack_start..];
    const pack_hdr = git_pack.parsePackHeader(pack_data) orelse {
        return try git_transport.buildReportStatusBody(push_cmd.ref_name, false, "bad pack header", out_buf);
    };

    var objects: [MAX_OBJECTS_PER_PACK]ParsedPackObject = undefined;
    const count = try unpackObjects(allocator, pack_data, pack_hdr.object_count, &objects);
    defer {
        for (0..count) |i| allocator.free(objects[i].data);
    }

    const repo = global_repos.getOrCreate(repo_name) orelse {
        return try git_transport.buildReportStatusBody(push_cmd.ref_name, false, "repo limit", out_buf);
    };
    mapCommitAndTree(repo, &objects, count);
    repo.setTip(push_cmd.ref_name, push_cmd.new_id);

    return try git_transport.buildReportStatusBody(push_cmd.ref_name, true, null, out_buf);
}

pub fn nativeSysGitAdvertiseRefs(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.network_device, Rights.READ)) return Value{ .string = "" };

    const repo_name = args[0].string;
    const repo = global_repos.get(repo_name);

    var adv_buf: [2048]u8 = undefined;
    const head_sha: ?[]const u8 = if (repo != null and repo.?.has_commits) &repo.?.tip_sha else null;
    const branch: []const u8 = if (repo != null and repo.?.branch_len > 0) repo.?.branch[0..repo.?.branch_len] else "refs/heads/master";

    const len = git_transport.buildAdvertisementBody(head_sha, branch, &adv_buf) catch return Value{ .string = "" };
    const duped = try vm.allocator.dupe(u8, adv_buf[0..len]);
    return Value{ .string = duped };
}

pub fn nativeSysGitReceivePack(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.network_device, Rights.WRITE) or
        !checkCallerAuthority(.storage_device, Rights.WRITE))
    {
        return Value{ .string = "" };
    }

    var resp_buf: [2048]u8 = undefined;
    const len = processReceivePack(vm.allocator, args[0].string, args[1].string, &resp_buf) catch {
        return Value{ .string = "" };
    };
    const duped = try vm.allocator.dupe(u8, resp_buf[0..len]);
    return Value{ .string = duped };
}

pub fn nativeSysGitGetHead(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const repo = global_repos.get(args[0].string);
    if (repo == null or !repo.?.has_commits) return Value{ .string = "" };
    const duped = try vm.allocator.dupe(u8, &repo.?.tip_sha);
    return Value{ .string = duped };
}

pub fn nativeSysGitCatFile(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.InvalidArgs;
    const repo = global_repos.get(args[0].string) orelse return Value{ .string = "" };
    const cas_hash = repo.findFileCasHash(args[1].string) orelse return Value{ .string = "" };

    const get_fn = cas_get_fn orelse return Value{ .string = "" };
    var scratch: [8192]u8 = undefined;
    const n = get_fn(cas_hash, &scratch) catch return Value{ .string = "" };
    const duped = try vm.allocator.dupe(u8, scratch[0..n]);
    return Value{ .string = duped };
}

pub fn registerGitSyscalls(vm: *VM) !void {
    try vm.globals.put("sys_git_advertise_refs", Value{ .native = nativeSysGitAdvertiseRefs });
    try vm.globals.put("sys_git_receive_pack", Value{ .native = nativeSysGitReceivePack });
    try vm.globals.put("sys_git_get_head", Value{ .native = nativeSysGitGetHead });
    try vm.globals.put("sys_git_cat_file", Value{ .native = nativeSysGitCatFile });
}

// === Colocated Unit Tests ===

fn mockCasPut(data: []const u8, out_hex: *[64]u8) anyerror!void {
    _ = data;
    @memcpy(out_hex, "aa112233445566778899aabbccddeeff00112233445566778899aabbccddeeff");
}

fn mockCasGet(hex_hash: []const u8, out_buf: []u8) anyerror!usize {
    _ = hex_hash;
    const content = "<h1>Deployed via MicrOS Sovereign Git</h1>\n";
    @memcpy(out_buf[0..content.len], content);
    return content.len;
}

test "git repository registry add and lookup" {
    clearGitContext();
    defer clearGitContext();

    const repo = global_repos.getOrCreate("site.git").?;
    repo.setTip("refs/heads/master", "1234567890123456789012345678901234567890");

    const oid = [_]u8{0xBB} ** 20;
    repo.addOrUpdateFile("index.html", "mock_cas_hash_1234", &oid);

    const lookup = global_repos.get("site.git").?;
    try std.testing.expectEqualStrings("1234567890123456789012345678901234567890", &lookup.tip_sha);
    const hash = lookup.findFileCasHash("index.html").?;
    try std.testing.expect(std.mem.startsWith(u8, hash, "mock_cas_hash_1234"));
}

test "git syscall registration and advertisement" {
    clearGitContext();
    defer clearGitContext();

    const allocator = std.testing.allocator;
    var chunk = @import("../../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    try registerGitSyscalls(&vm);
    try std.testing.expect(vm.globals.contains("sys_git_advertise_refs"));
    try std.testing.expect(vm.globals.contains("sys_git_receive_pack"));
    try std.testing.expect(vm.globals.contains("sys_git_get_head"));
    try std.testing.expect(vm.globals.contains("sys_git_cat_file"));

    var adv_args = [_]Value{Value{ .string = "new_repo.git" }};
    const adv_val = try nativeSysGitAdvertiseRefs(&vm, &adv_args);
    defer vm.allocator.free(adv_val.string);

    try std.testing.expect(std.mem.indexOf(u8, adv_val.string, "# service=git-receive-pack\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, adv_val.string, "capabilities^{}") != null);
}

test "git cat file syscall with mock cas" {
    clearGitContext();
    defer clearGitContext();

    setCasContext(mockCasPut, mockCasGet);

    const repo = global_repos.getOrCreate("site.git").?;
    const oid = [_]u8{0xCC} ** 20;
    repo.addOrUpdateFile("index.html", "aa112233445566778899aabbccddeeff00112233445566778899aabbccddeeff", &oid);

    const allocator = std.testing.allocator;
    var chunk = @import("../../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    try registerGitSyscalls(&vm);

    var cat_args = [_]Value{ Value{ .string = "site.git" }, Value{ .string = "index.html" } };
    const cat_val = try nativeSysGitCatFile(&vm, &cat_args);
    defer vm.allocator.free(cat_val.string);

    try std.testing.expectEqualStrings("<h1>Deployed via MicrOS Sovereign Git</h1>\n", cat_val.string);
}

test "git receive pack end-to-end processing with real packfile" {
    clearGitContext();
    defer clearGitContext();

    var recorded_cas_data: [1024]u8 = undefined;
    var recorded_cas_len: usize = 0;

    const TestCas = struct {
        var rec_data: *[1024]u8 = undefined;
        var rec_len: *usize = undefined;

        fn put(data: []const u8, out_hex: *[64]u8) anyerror!void {
            @memcpy(rec_data[0..data.len], data);
            rec_len.* = data.len;
            @memcpy(out_hex, "bb2233445566778899aabbccddeeff00112233445566778899aabbccddeeff11");
        }
    };
    TestCas.rec_data = &recorded_cas_data;
    TestCas.rec_len = &recorded_cas_len;

    setCasContext(TestCas.put, null);

    const hex_payload =
        "3030373630303030303030303030303030303030303030303030303030303030303030303030303030303030" ++
        "2064663365343737613362616530643233373630613035373162393631323761333539636434643437207265" ++
        "66732f68656164732f6d6173746572007265706f72742d7374617475730a303030305041434b000000020000" ++
        "00039c18789c8d90bb7282400045fbfd8aed1913608175676226bce4a508f88ae9605d1011515945fe3e639c" ++
        "499522b7b8c599db9ccb2f8c4122d28c4844a5748831ceb092238665454579b6a5728e9044582e5204d22bdf" ++
        "3517b8602d876f9cb5fce3512fb4a9dfa1848744234491091c889a2802dad475c939fbefbe38156d59c0c123" ++
        "86ed78218c9c08ce3d27d417cbc4fee1000258ba4b5b3736816e886b2f8e2da44eefcccd2702735574d32ec1" ++
        "89f833fb75efeb4b333df787af580fccc4fce500fac67da347ca55d8eeb01cb0d0ba5b9fabca3349251cd75e" ++
        "549deab35bdc5a2de182e66629ea3b8b8c31c37bedc69d64e60358574d154d33a54b72b49e97d23844b3bedd" ++
        "8d57bdb0a071370270d4093a034f1b3bb4fe7201deb1e4657a80cfa7c03782e074dca602789c333430303331" ++
        "51c8cc4b49add0cb28c9cd61483b20b994e33427eb896ec345dd1f5697e966bc680100f4040ed3b601789cb3" ++
        "c930b4f348cdc9c957f0cd4c2ef20fb6d1cf30b4e30200508706a15f9fef170c478d660b6634645f1b0a1f50" ++
        "7dc63b";

    var bin_payload: [531]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bin_payload, hex_payload);

    var resp_buf: [512]u8 = undefined;
    const resp_len = try processReceivePack(std.testing.allocator, "site.git", &bin_payload, &resp_buf);

    const resp_str = resp_buf[0..resp_len];
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "unpack ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp_str, "ok refs/heads/master\n") != null);

    const repo = global_repos.get("site.git").?;
    try std.testing.expectEqualStrings("df3e477a3bae0d23760a0571b96127a359cd4d47", &repo.tip_sha);

    const hash = repo.findFileCasHash("index.html").?;
    try std.testing.expect(std.mem.startsWith(u8, hash, "bb2233445566778899"));
    try std.testing.expectEqualStrings("<h1>Hello MicrOS</h1>\n", recorded_cas_data[0..recorded_cas_len]);
}
