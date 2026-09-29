// MicrOS (µOS) Package Registry ABI Bindings (pkg_abi.zig)
// SPEC-TECH-P2P-002 & DELIB-STAGE4-DECOUPLE-001
// Exposes decentralized package manifests, dependency resolution, and artifact queries to Macros.
// Enforces CSpace capability isolation (CapType.storage_device).
// Zero libc, freestanding.

const std = @import("std");
const eval = @import("../../macros/eval.zig");
const Value = eval.Value;
const vm_mod = @import("../../macros/vm.zig");
const VM = vm_mod.VM;
const package = @import("package.zig");
const cap_mod = @import("../../kernel/cap/capability.zig");
const CapType = cap_mod.CapType;
const Rights = cap_mod.Rights;

pub var global_registry: package.PackageRegistry = package.PackageRegistry.init();
pub var caller_auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool = null;

pub fn setPkgContext(auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool) void {
    caller_auth_fn = auth_fn;
}

pub fn clearPkgContext() void {
    caller_auth_fn = null;
    global_registry = package.PackageRegistry.init();
}

fn checkCallerAuthority(cap_type: CapType, rights: u16) bool {
    if (caller_auth_fn) |auth| {
        return auth(cap_type, rights);
    }
    return false;
}

pub fn nativeSysPkgCount(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    if (!checkCallerAuthority(.storage_device, Rights.READ)) return Value{ .integer = -1 };
    return Value{ .integer = @intCast(global_registry.count) };
}

pub fn nativeSysPkgQuery(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.storage_device, Rights.READ)) return Value{ .string = "" };

    const name_str = args[0].string;
    const pkg = global_registry.findByName(name_str) orelse return Value{ .string = "" };

    const ver = pkg.getVersion();
    const duped = try vm.gcAllocator().dupe(u8, ver);
    return Value{ .string = duped };
}

pub fn nativeSysPkgRegister(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len < 2 or args[0] != .string or args[1] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.storage_device, Rights.WRITE)) return Value{ .boolean = false };

    const name = args[0].string;
    const semver = args[1].string;

    const seed = [_]u8{0x88} ** 32;
    const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    const pubkey = key_pair.public_key.toBytes();
    var mock_manifest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(name, &mock_manifest, .{});

    var hdr = try package.PackageHeader.init(name, semver, &pubkey, &mock_manifest, 0, 1000);
    try hdr.sign(&key_pair);

    global_registry.registerPackage(&hdr) catch return Value{ .boolean = false };
    return Value{ .boolean = true };
}

pub fn nativeSysPkgResolve(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    if (!checkCallerAuthority(.storage_device, Rights.READ)) return Value{ .integer = -1 };

    const name = args[0].string;
    const pkg = global_registry.findByName(name) orelse return Value{ .integer = 0 };

    var out_order: [package.MAX_REGISTRY_PACKAGES][32]u8 = undefined;
    const count = global_registry.resolveLoadOrder(&pkg.manifest_hash, &out_order) catch return Value{ .integer = -1 };
    return Value{ .integer = @intCast(count) };
}

pub fn registerPkgSyscalls(vm: *VM) !void {
    try vm.globals.put("sys_pkg_count", Value{ .native = nativeSysPkgCount });
    try vm.globals.put("sys_pkg_query", Value{ .native = nativeSysPkgQuery });
    try vm.globals.put("sys_pkg_register", Value{ .native = nativeSysPkgRegister });
    try vm.globals.put("sys_pkg_resolve", Value{ .native = nativeSysPkgResolve });
}

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

test "pkg_abi: capability gating and package registry operations" {
    clearPkgContext();
    defer clearPkgContext();

    setPkgContext(mockAuthDeny);
    var dummy: usize = 0;
    var args = [_]Value{ Value{ .string = "core.net" }, Value{ .string = "1.0.0" } };

    // 1. Unprivileged actor denied registration
    const res_denied = try nativeSysPkgRegister(&dummy, &args);
    try std.testing.expectEqual(false, res_denied.boolean);

    // 2. Privileged actor authorized for registration
    setPkgContext(mockAuthAllow);
    const res_allowed = try nativeSysPkgRegister(&dummy, &args);
    try std.testing.expectEqual(true, res_allowed.boolean);

    // 3. Query count
    const count_res = try nativeSysPkgCount(&dummy, &[_]Value{});
    try std.testing.expectEqual(@as(i64, 1), count_res.integer);

    // 4. Query package version
    var query_args = [_]Value{Value{ .string = "core.net" }};
    var chunk = @import("../../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(std.testing.allocator);
    var vm = try VM.init(std.testing.allocator, &chunk);
    defer vm.deinit();

    const query_res = try nativeSysPkgQuery(&vm, &query_args);
    defer std.testing.allocator.free(query_res.string);
    try std.testing.expectEqualStrings("1.0.0", query_res.string);
}

test "pkg_abi: registration into Macros VM globals" {
    clearPkgContext();
    defer clearPkgContext();

    var chunk = @import("../../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(std.testing.allocator);
    var vm = try VM.init(std.testing.allocator, &chunk);
    defer vm.deinit();

    try registerPkgSyscalls(&vm);
    try std.testing.expect(vm.globals.contains("sys_pkg_count"));
    try std.testing.expect(vm.globals.contains("sys_pkg_query"));
    try std.testing.expect(vm.globals.contains("sys_pkg_register"));
    try std.testing.expect(vm.globals.contains("sys_pkg_resolve"));
}
