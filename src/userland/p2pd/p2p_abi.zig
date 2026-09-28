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
    return true;
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

pub fn registerP2pSyscalls(vm: *VM) !void {
    try vm.globals.put("sys_peer_count", Value{ .native = nativeSysPeerCount });
    try vm.globals.put("sys_peer_info", Value{ .native = nativeSysPeerInfo });
    try vm.globals.put("sys_p2p_status", Value{ .native = nativeSysP2pStatus });
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
