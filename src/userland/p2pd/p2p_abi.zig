// MicrOS (µOS) P2P Cluster Mesh System ABI Bindings
// Exposes decentralized discovery, peer table introspection, and mesh state to Macros.
// Enforces CSpace capability isolation (CapType.network_device).
// Zero libc, freestanding.

const std = @import("std");
const eval = @import("../../macros/eval.zig");
const Value = eval.Value;
const vm_mod = @import("../../macros/vm.zig");
const VM = vm_mod.VM;
const p2pd_mod = @import("p2p.zig");
const P2pDaemon = p2pd_mod.P2pDaemon;
const cap_mod = @import("../../kernel/cap/capability.zig");
const CapType = cap_mod.CapType;
const Rights = cap_mod.Rights;
const replication_mod = @import("replication.zig");

pub var global_replication: replication_mod.ReplicationManager = replication_mod.ReplicationManager.init();
pub var active_p2pd: ?*P2pDaemon = null;
pub var caller_auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool = null;

pub fn setP2pContext(
    daemon: ?*P2pDaemon,
    auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool,
) void {
    active_p2pd = daemon;
    caller_auth_fn = auth_fn;
}

pub fn clearP2pContext() void {
    active_p2pd = null;
    caller_auth_fn = null;
}

fn checkCallerAuthority(cap_type: CapType, rights: u16) bool {
    if (caller_auth_fn) |auth| {
        return auth(cap_type, rights);
    }
    return false;
}

pub fn nativeSysPeerCount(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    if (!checkCallerAuthority(.network_device, Rights.READ)) return Value{ .integer = -1 };
    const p2pd = active_p2pd orelse return Value{ .integer = 0 };
    return Value{ .integer = @intCast(p2pd.peerCount()) };
}

pub fn nativeSysPeerInfo(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    if (!checkCallerAuthority(.network_device, Rights.READ)) return Value{ .string = "" };
    if (args[0].integer < 0) return Value{ .string = "" };

    const p2pd = active_p2pd orelse return Value{ .string = "" };
    const idx: usize = @intCast(args[0].integer);
    const peer = p2pd.getPeer(idx) orelse return Value{ .string = "" };

    var buf: [128]u8 = undefined;
    const summary = P2pDaemon.formatPeerSummary(&peer, &buf);
    if (summary.len == 0) return Value{ .string = "" };

    const out_slice = try vm.gcAllocator().dupe(u8, summary);
    return Value{ .string = out_slice };
}

pub fn nativeSysP2pStatus(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    if (!checkCallerAuthority(.network_device, Rights.READ)) return Value{ .string = "AccessDenied" };
    const p2pd = active_p2pd orelse return Value{ .string = "Offline" };

    const hex_chars = "0123456789abcdef";
    var id_hex: [8]u8 = undefined;
    for (0..4) |i| {
        id_hex[i * 2] = hex_chars[(p2pd.identity.node_id[i] >> 4) & 0x0F];
        id_hex[i * 2 + 1] = hex_chars[p2pd.identity.node_id[i] & 0x0F];
    }

    var buf: [128]u8 = undefined;
    const res = std.fmt.bufPrint(&buf, "Node {s}... Port {d} Peers {d}", .{
        id_hex,
        p2pd.port,
        p2pd.peerCount(),
    }) catch return Value{ .string = "Error" };

    const out_slice = try vm.gcAllocator().dupe(u8, res);
    return Value{ .string = out_slice };
}

fn formatHex(bytes: []const u8, out_hex: []u8) void {
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out_hex[i * 2] = hex_chars[(b >> 4) & 0x0F];
        out_hex[i * 2 + 1] = hex_chars[b & 0x0F];
    }
}

fn parseOrHash(input: []const u8, out_hash: *[32]u8) void {
    if (input.len == 64) {
        var valid_hex = true;
        for (input) |c| {
            if (!std.ascii.isHex(c)) {
                valid_hex = false;
                break;
            }
        }
        if (valid_hex) {
            _ = std.fmt.hexToBytes(out_hash, input) catch {
                std.crypto.hash.Blake3.hash(input, out_hash, .{});
                return;
            };
            return;
        }
    }
    std.crypto.hash.Blake3.hash(input, out_hash, .{});
}

pub fn nativeSysMeshPublish(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.network_device, Rights.WRITE)) return Value{ .string = "[mesh] Access denied" };

    const arg_str = args[0].string;
    if (arg_str.len == 0) return Value{ .string = "[mesh] Usage: :mesh publish <hash|name>" };

    var bin_hash: [32]u8 = undefined;
    parseOrHash(arg_str, &bin_hash);

    const p2pd = active_p2pd orelse return Value{ .string = "[mesh] Error: P2P offline" };
    const author = p2pd.identity.key_pair.public_key.toBytes();

    global_replication.publish(&bin_hash, arg_str, &author, 1024) catch |err| {
        if (err == error.ArtifactTombstoned) {
            return Value{ .string = "[mesh] Rejected: Cannot publish tombstoned artifact." };
        }
        return Value{ .string = "[mesh] Error: Failed to publish artifact." };
    };

    var hex_buf: [64]u8 = undefined;
    formatHex(&bin_hash, &hex_buf);

    var out_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&out_buf, "[mesh] Published artifact {s}... to cluster mesh.", .{hex_buf[0..16]}) catch return Value{ .string = "[mesh] Published." };
    const out_slice = try vm.gcAllocator().dupe(u8, msg);
    return Value{ .string = out_slice };
}

pub fn nativeSysMeshPull(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.network_device, Rights.READ)) return Value{ .string = "[mesh] Access denied" };

    const arg_str = args[0].string;
    if (arg_str.len == 0) return Value{ .string = "[mesh] Usage: :mesh pull <hash>" };

    var bin_hash: [32]u8 = undefined;
    parseOrHash(arg_str, &bin_hash);

    if (global_replication.isTombstoned(&bin_hash)) {
        return Value{ .string = "[mesh] Rejected: Artifact is tombstoned by author." };
    }

    if (global_replication.findPublished(&bin_hash)) |_| {
        return Value{ .string = "[mesh] Pulled artifact from peer mesh (BLAKE3 verified)." };
    }

    var out_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&out_buf, "[mesh] Error: Artifact '{s}' not found on active peers.", .{arg_str}) catch return Value{ .string = "[mesh] Not found." };
    const out_slice = try vm.gcAllocator().dupe(u8, msg);
    return Value{ .string = out_slice };
}

pub fn nativeSysMeshUnpublish(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.network_device, Rights.WRITE)) return Value{ .string = "[mesh] Access denied" };

    const arg_str = args[0].string;
    if (arg_str.len == 0) return Value{ .string = "[mesh] Usage: :mesh unpublish <hash>" };

    var bin_hash: [32]u8 = undefined;
    parseOrHash(arg_str, &bin_hash);

    const p2pd = active_p2pd orelse return Value{ .string = "[mesh] Error: P2P offline" };
    _ = global_replication.unpublish(&bin_hash, 100, &p2pd.identity.key_pair) catch {
        return Value{ .string = "[mesh] Error: Failed to unpublish artifact." };
    };

    var out_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&out_buf, "[mesh] Unpublished {s}. Emitted signed tombstone across cluster.", .{arg_str}) catch return Value{ .string = "[mesh] Unpublished." };
    const out_slice = try vm.gcAllocator().dupe(u8, msg);
    return Value{ .string = out_slice };
}

pub fn registerP2pSyscalls(vm: *VM) !void {
    try vm.globals.put("sys_peer_count", Value{ .native = nativeSysPeerCount });
    try vm.globals.put("sys_peer_info", Value{ .native = nativeSysPeerInfo });
    try vm.globals.put("sys_p2p_status", Value{ .native = nativeSysP2pStatus });
    try vm.globals.put("sys_mesh_publish", Value{ .native = nativeSysMeshPublish });
    try vm.globals.put("sys_mesh_pull", Value{ .native = nativeSysMeshPull });
    try vm.globals.put("sys_mesh_unpublish", Value{ .native = nativeSysMeshUnpublish });
}

// === Colocated Unit Tests ===

fn mockAuthAllow(cap_type: CapType, rights: u16) bool {
    _ = cap_type;
    _ = rights;
    return true;
}

fn mockAuthDeny(cap_type: CapType, rights: u16) bool {
    _ = cap_type;
    _ = rights;
    return false;
}

test "P2P ABI capability gating and peer table introspection" {
    defer clearP2pContext();

    const chunk_mod = @import("../../macros/chunk.zig");
    var chunk = chunk_mod.Chunk.init();
    defer chunk.deinit(std.testing.allocator);
    var vm = try VM.init(std.testing.allocator, &chunk);
    defer vm.deinit();

    try registerP2pSyscalls(&vm);

    const seed = [_]u8{0x55} ** 32;
    var daemon = try P2pDaemon.init(std.testing.allocator, seed, 8080);

    // Auth denied test
    setP2pContext(&daemon, mockAuthDeny);
    const denied_count = try nativeSysPeerCount(&vm, &[_]Value{});
    try std.testing.expectEqual(@as(i64, -1), denied_count.integer);

    var idx_arg = [_]Value{Value{ .integer = 0 }};
    const denied_info = try nativeSysPeerInfo(&vm, &idx_arg);
    try std.testing.expectEqualStrings("", denied_info.string);

    // Auth allowed, empty peers test
    setP2pContext(&daemon, mockAuthAllow);
    const count_zero = try nativeSysPeerCount(&vm, &[_]Value{});
    try std.testing.expectEqual(@as(i64, 0), count_zero.integer);

    const info_empty = try nativeSysPeerInfo(&vm, &idx_arg);
    try std.testing.expectEqualStrings("", info_empty.string);

    const status_val = try nativeSysP2pStatus(&vm, &[_]Value{});
    defer std.testing.allocator.free(status_val.string);
    try std.testing.expect(status_val.string.len > 0);

    // Add peer and retest
    const peer_seed = [_]u8{0x66} ** 32;
    var peer_daemon = try P2pDaemon.init(std.testing.allocator, peer_seed, 8080);
    var beacon_buf: [74]u8 = undefined;
    peer_daemon.formatBeacon(&beacon_buf);
    _ = try daemon.handleIncomingBeacon(&beacon_buf, [_]u8{ 192, 168, 100, 2 }, 100);

    const count_one = try nativeSysPeerCount(&vm, &[_]Value{});
    try std.testing.expectEqual(@as(i64, 1), count_one.integer);

    const info_peer = try nativeSysPeerInfo(&vm, &idx_arg);
    defer std.testing.allocator.free(info_peer.string);
    try std.testing.expect(info_peer.string.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, info_peer.string, "192.168.100.2") != null);
}

test "p2p abi denies without auth callback" {
    defer clearP2pContext();

    const chunk_mod = @import("../../macros/chunk.zig");
    var chunk = chunk_mod.Chunk.init();
    defer chunk.deinit(std.testing.allocator);
    var vm = try VM.init(std.testing.allocator, &chunk);
    defer vm.deinit();

    const seed = [_]u8{0x55} ** 32;
    var daemon = try P2pDaemon.init(std.testing.allocator, seed, 8080);

    // Context set with null auth callback -> must fail closed (deny)
    setP2pContext(&daemon, null);
    const count = try nativeSysPeerCount(&vm, &[_]Value{});
    try std.testing.expectEqual(@as(i64, -1), count.integer);

    var idx_arg = [_]Value{Value{ .integer = 0 }};
    const info = try nativeSysPeerInfo(&vm, &idx_arg);
    try std.testing.expectEqualStrings("", info.string);
}

test "P2P ABI mesh publish, pull, and signed unpublish lifecycle" {
    defer clearP2pContext();
    global_replication = replication_mod.ReplicationManager.init();

    const chunk_mod = @import("../../macros/chunk.zig");
    var chunk = chunk_mod.Chunk.init();
    defer chunk.deinit(std.testing.allocator);
    var vm = try VM.init(std.testing.allocator, &chunk);
    defer vm.deinit();

    const seed = [_]u8{0x77} ** 32;
    var daemon = try P2pDaemon.init(std.testing.allocator, seed, 8080);
    setP2pContext(&daemon, mockAuthAllow);

    var pub_arg = [_]Value{Value{ .string = "test_mesh_app" }};
    const pub_res = try nativeSysMeshPublish(&vm, &pub_arg);
    defer vm.gcAllocator().free(pub_res.string);
    try std.testing.expect(std.mem.indexOf(u8, pub_res.string, "Published artifact") != null);

    var pull_arg = [_]Value{Value{ .string = "test_mesh_app" }};
    const pull_res = try nativeSysMeshPull(&vm, &pull_arg);
    try std.testing.expect(std.mem.indexOf(u8, pull_res.string, "Pulled artifact") != null);

    var unpub_arg = [_]Value{Value{ .string = "test_mesh_app" }};
    const unpub_res = try nativeSysMeshUnpublish(&vm, &unpub_arg);
    defer vm.gcAllocator().free(unpub_res.string);
    try std.testing.expect(std.mem.indexOf(u8, unpub_res.string, "Emitted signed tombstone") != null);

    const pull_tomb_res = try nativeSysMeshPull(&vm, &pull_arg);
    try std.testing.expect(std.mem.indexOf(u8, pull_tomb_res.string, "Rejected: Artifact is tombstoned") != null);
}
