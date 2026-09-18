// MicrOS (µOS) Network Stack System ABI Bindings
// Exposes fast-path TCP listening, accepting, streaming I/O, and teardown to Macros.
// Enforces CSpace capability isolation (CapType.network_device).
// Zero libc, freestanding.

const std = @import("std");
const eval = @import("../../macros/eval.zig");
const Value = eval.Value;
const vm_mod = @import("../../macros/vm.zig");
const VM = vm_mod.VM;
const net_stack_mod = @import("stack.zig");
const NetworkStack = net_stack_mod.NetworkStack;
const cap_mod = @import("../cap/capability.zig");
const CapType = cap_mod.CapType;
const Rights = cap_mod.Rights;

pub const NET_RECV_SCRATCH_SIZE: usize = 16384;
var net_recv_scratch: [NET_RECV_SCRATCH_SIZE]u8 = undefined;

pub var active_net_stack: ?*NetworkStack = null;
pub var caller_auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool = null;
pub var caller_id_fn: ?*const fn () u32 = null;

pub fn setNetworkContext(
    stack: ?*NetworkStack,
    auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool,
    id_fn: ?*const fn () u32,
) void {
    active_net_stack = stack;
    caller_auth_fn = auth_fn;
    caller_id_fn = id_fn;
}

pub fn clearNetworkContext() void {
    active_net_stack = null;
    caller_auth_fn = null;
    caller_id_fn = null;
}

fn checkCallerAuthority(cap_type: CapType, rights: u16) bool {
    if (caller_auth_fn) |auth| {
        return auth(cap_type, rights);
    }
    return true;
}

fn getCallerActorId() u32 {
    if (caller_id_fn) |id_fn| {
        return id_fn();
    }
    return 0;
}

fn castToU32(val: i64) ?u32 {
    if (val < 0 or val > std.math.maxInt(u32)) return null;
    return @intCast(val);
}

pub fn nativeSysNetListen(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    if (!checkCallerAuthority(.network_device, Rights.WRITE)) return Value{ .integer = -1 };
    const net_stack = active_net_stack orelse return Value{ .integer = -1 };
    const port = castToU32(args[0].integer) orelse return Value{ .integer = -1 };
    if (port == 0 or port > 65535) return Value{ .integer = -1 };
    const caller_id = getCallerActorId();
    const id = net_stack.listen(@intCast(port), caller_id) catch return Value{ .integer = -1 };
    return Value{ .integer = @as(i64, id) };
}

pub fn nativeSysNetAccept(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    if (!checkCallerAuthority(.network_device, Rights.READ)) return Value{ .integer = -1 };
    const net_stack = active_net_stack orelse return Value{ .integer = -1 };
    const listener_id = castToU32(args[0].integer) orelse return Value{ .integer = -1 };
    const caller_id = getCallerActorId();
    const conn_id = net_stack.accept(listener_id, caller_id) orelse return Value{ .integer = -1 };
    return Value{ .integer = @as(i64, conn_id) };
}

pub fn nativeSysNetRecv(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .integer or args[1] != .integer) return error.InvalidArgs;
    if (!checkCallerAuthority(.network_device, Rights.READ)) return Value{ .string = "" };
    const net_stack = active_net_stack orelse return Value{ .string = "" };
    const conn_id = castToU32(args[0].integer) orelse return Value{ .string = "" };
    const max_len_val = castToU32(args[1].integer) orelse return Value{ .string = "" };
    const to_read = @min(@as(usize, max_len_val), net_recv_scratch.len);
    const caller_id = getCallerActorId();
    const n = net_stack.recvServer(conn_id, caller_id, net_recv_scratch[0..to_read]);
    if (n == 0) return Value{ .string = "" };
    const duped = try vm.allocator.dupe(u8, net_recv_scratch[0..n]);
    return Value{ .string = duped };
}

pub fn nativeSysNetSend(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 2 or args[0] != .integer or args[1] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.network_device, Rights.WRITE)) return Value{ .integer = -1 };
    const net_stack = active_net_stack orelse return Value{ .integer = -1 };
    const conn_id = castToU32(args[0].integer) orelse return Value{ .integer = -1 };
    const caller_id = getCallerActorId();
    const sent = net_stack.sendServer(conn_id, caller_id, args[1].string) catch return Value{ .integer = -1 };
    return Value{ .integer = @as(i64, @intCast(sent)) };
}

pub fn nativeSysNetClose(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    if (!checkCallerAuthority(.network_device, Rights.WRITE)) return Value{ .boolean = false };
    const net_stack = active_net_stack orelse return Value{ .boolean = false };
    const conn_id = castToU32(args[0].integer) orelse return Value{ .boolean = false };
    const caller_id = getCallerActorId();
    net_stack.closeServer(conn_id, caller_id) catch return Value{ .boolean = false };
    return Value{ .boolean = true };
}

pub fn registerNetworkSyscalls(vm: *VM) !void {
    try vm.globals.put("sys_net_listen", Value{ .native = nativeSysNetListen });
    try vm.globals.put("sys_net_accept", Value{ .native = nativeSysNetAccept });
    try vm.globals.put("sys_net_recv", Value{ .native = nativeSysNetRecv });
    try vm.globals.put("sys_net_send", Value{ .native = nativeSysNetSend });
    try vm.globals.put("sys_net_close", Value{ .native = nativeSysNetClose });
}

// === Colocated Unit Tests ===

fn testRejectAuth(cap_type: CapType, rights: u16) bool {
    _ = cap_type;
    _ = rights;
    return false;
}

fn testAllowAuth(cap_type: CapType, rights: u16) bool {
    _ = cap_type;
    _ = rights;
    return true;
}

test "network abi registration and unauthorized caller rejection" {
    const allocator = std.testing.allocator;
    var chunk = @import("../../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    try registerNetworkSyscalls(&vm);
    try std.testing.expect(vm.globals.contains("sys_net_listen"));
    try std.testing.expect(vm.globals.contains("sys_net_accept"));
    try std.testing.expect(vm.globals.contains("sys_net_recv"));
    try std.testing.expect(vm.globals.contains("sys_net_send"));
    try std.testing.expect(vm.globals.contains("sys_net_close"));

    setNetworkContext(null, testRejectAuth, null);
    defer clearNetworkContext();

    var listen_args = [_]Value{Value{ .integer = 8080 }};
    const listen_res = try nativeSysNetListen(&vm, &listen_args);
    try std.testing.expectEqual(@as(i64, -1), listen_res.integer);

    var accept_args = [_]Value{Value{ .integer = 1 }};
    const accept_res = try nativeSysNetAccept(&vm, &accept_args);
    try std.testing.expectEqual(@as(i64, -1), accept_res.integer);

    var send_args = [_]Value{ Value{ .integer = 1 }, Value{ .string = "hello" } };
    const send_res = try nativeSysNetSend(&vm, &send_args);
    try std.testing.expectEqual(@as(i64, -1), send_res.integer);

    var recv_args = [_]Value{ Value{ .integer = 1 }, Value{ .integer = 100 } };
    const recv_res = try nativeSysNetRecv(&vm, &recv_args);
    try std.testing.expectEqualStrings("", recv_res.string);

    var close_args = [_]Value{Value{ .integer = 1 }};
    const close_res = try nativeSysNetClose(&vm, &close_args);
    try std.testing.expectEqual(false, close_res.boolean);
}

test "network abi listen and accept with dummy stack" {
    const allocator = std.testing.allocator;
    var chunk = @import("../../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    var dummy_dev: @import("../drivers/virtio_net.zig").VirtioNetDevice = undefined;
    var stack = NetworkStack.init(&dummy_dev);

    setNetworkContext(&stack, testAllowAuth, null);
    defer clearNetworkContext();

    // Listen on 8080
    var listen_args = [_]Value{Value{ .integer = 8080 }};
    const listen_res = try nativeSysNetListen(&vm, &listen_args);
    try std.testing.expect(listen_res.integer >= 0);

    // Accept when no connections exist -> returns -1
    var accept_args = [_]Value{listen_res};
    const accept_res = try nativeSysNetAccept(&vm, &accept_args);
    try std.testing.expectEqual(@as(i64, -1), accept_res.integer);

    // Invalid port -> returns -1
    var invalid_port = [_]Value{Value{ .integer = 70000 }};
    const invalid_res = try nativeSysNetListen(&vm, &invalid_port);
    try std.testing.expectEqual(@as(i64, -1), invalid_res.integer);
}
