// MicrOS (µOS) Sovereign Package & Module Federation Registry (package.zig)
// SPEC-TECH-PKG-001: Decentralized package manifests, Ed25519 author signing, and dependency resolution.
// Zero libc, freestanding, capability-safe, bounded execution.

const std = @import("std");

pub const PACKAGE_MAGIC: u32 = 0x53504B31; // 'SPK1'
pub const PACKAGE_VERSION: u16 = 1;
pub const MAX_PACKAGE_NAME: usize = 48;
pub const MAX_VERSION_STR: usize = 16;
pub const MAX_DEPENDENCIES: usize = 8;
pub const SIGNABLE_HEADER_SIZE: usize = 416;
pub const PACKAGE_HEADER_SIZE: usize = 512;
pub const MAX_REGISTRY_PACKAGES: usize = 64;

pub const PackageHeader = extern struct {
    magic: u32 align(1) = PACKAGE_MAGIC,
    version: u16 align(1) = PACKAGE_VERSION,
    flags: u16 align(1) = 0,
    name_len: u16 align(1) = 0,
    name: [MAX_PACKAGE_NAME]u8 align(1) = [_]u8{0} ** MAX_PACKAGE_NAME,
    semver_len: u16 align(1) = 0,
    semver: [MAX_VERSION_STR]u8 align(1) = [_]u8{0} ** MAX_VERSION_STR,
    author_pubkey: [32]u8 align(1),
    manifest_hash: [32]u8 align(1),
    required_capabilities: u64 align(1),
    timestamp_epoch: u64 align(1),
    dependency_count: u32 align(1) = 0,
    dependencies: [MAX_DEPENDENCIES][32]u8 align(1) = [_][32]u8{[_]u8{0} ** 32} ** MAX_DEPENDENCIES,
    signature: [64]u8 align(1) = [_]u8{0} ** 64,
    padding: [32]u8 align(1) = [_]u8{0} ** 32,

    pub fn init(
        name_str: []const u8,
        ver_str: []const u8,
        author_pubkey: *const [32]u8,
        manifest_hash: *const [32]u8,
        caps: u64,
        epoch: u64,
    ) !PackageHeader {
        if (name_str.len > MAX_PACKAGE_NAME) return error.NameTooLong;
        if (ver_str.len > MAX_VERSION_STR) return error.VersionTooLong;

        var hdr = PackageHeader{
            .author_pubkey = author_pubkey.*,
            .manifest_hash = manifest_hash.*,
            .required_capabilities = caps,
            .timestamp_epoch = epoch,
        };
        hdr.name_len = @intCast(name_str.len);
        @memcpy(hdr.name[0..name_str.len], name_str);

        hdr.semver_len = @intCast(ver_str.len);
        @memcpy(hdr.semver[0..ver_str.len], ver_str);

        return hdr;
    }

    pub fn getName(self: *const PackageHeader) []const u8 {
        const len = @min(@as(usize, self.name_len), MAX_PACKAGE_NAME);
        return self.name[0..len];
    }

    pub fn getVersion(self: *const PackageHeader) []const u8 {
        const len = @min(@as(usize, self.semver_len), MAX_VERSION_STR);
        return self.semver[0..len];
    }

    pub fn addDependency(self: *PackageHeader, dep_hash: *const [32]u8) !void {
        if (self.dependency_count >= MAX_DEPENDENCIES) return error.TooManyDependencies;
        self.dependencies[self.dependency_count] = dep_hash.*;
        self.dependency_count += 1;
    }

    pub fn sign(self: *PackageHeader, key_pair: *const std.crypto.sign.Ed25519.KeyPair) !void {
        const raw_bytes: [*]const u8 = @ptrCast(self);
        const signable = raw_bytes[0..SIGNABLE_HEADER_SIZE];
        const sig = try key_pair.sign(signable, null);
        self.signature = sig.toBytes();
    }

    pub fn verify(self: *const PackageHeader) !void {
        if (self.magic != PACKAGE_MAGIC) return error.InvalidMagic;
        if (self.version != PACKAGE_VERSION) return error.UnsupportedVersion;
        if (self.dependency_count > MAX_DEPENDENCIES) return error.CorruptDependencies;

        const pubkey = try std.crypto.sign.Ed25519.PublicKey.fromBytes(self.author_pubkey);
        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(self.signature);

        const raw_bytes: [*]const u8 = @ptrCast(self);
        const signable = raw_bytes[0..SIGNABLE_HEADER_SIZE];
        try sig.verify(signable, pubkey);
    }
};

pub const PackageRegistry = struct {
    count: usize,
    packages: [MAX_REGISTRY_PACKAGES]PackageHeader,

    pub fn init() PackageRegistry {
        return PackageRegistry{
            .count = 0,
            .packages = undefined,
        };
    }

    pub fn registerPackage(self: *PackageRegistry, hdr: *const PackageHeader) !void {
        try hdr.verify();
        if (self.count >= MAX_REGISTRY_PACKAGES) return error.RegistryFull;
        self.packages[self.count] = hdr.*;
        self.count += 1;
    }

    pub fn findPackage(self: *const PackageRegistry, manifest_hash: *const [32]u8) ?*const PackageHeader {
        for (self.packages[0..self.count]) |*p| {
            if (std.mem.eql(u8, &p.manifest_hash, manifest_hash)) return p;
        }
        return null;
    }

    pub fn findByName(self: *const PackageRegistry, name_str: []const u8) ?*const PackageHeader {
        for (self.packages[0..self.count]) |*p| {
            if (std.mem.eql(u8, p.getName(), name_str)) return p;
        }
        return null;
    }

    pub fn resolveLoadOrder(
        self: *const PackageRegistry,
        root_hash: *const [32]u8,
        out_order: *[MAX_REGISTRY_PACKAGES][32]u8,
    ) !usize {
        var order_count: usize = 0;
        var visited_path: [MAX_REGISTRY_PACKAGES][32]u8 = undefined;
        try self.resolveDfs(root_hash, out_order, &order_count, &visited_path, 0);
        return order_count;
    }

    fn resolveDfs(
        self: *const PackageRegistry,
        current_hash: *const [32]u8,
        out_order: *[MAX_REGISTRY_PACKAGES][32]u8,
        order_count: *usize,
        visited_path: *[MAX_REGISTRY_PACKAGES][32]u8,
        depth: usize,
    ) !void {
        if (self.isHashInSlice(visited_path[0..depth], current_hash)) {
            return error.CircularDependency;
        }
        if (self.isHashInSlice(out_order[0..order_count.*], current_hash)) return;

        const pkg = self.findPackage(current_hash) orelse return error.MissingDependency;
        visited_path[depth] = current_hash.*;

        for (pkg.dependencies[0..pkg.dependency_count]) |*dep_hash| {
            try self.resolveDfs(dep_hash, out_order, order_count, visited_path, depth + 1);
        }

        if (order_count.* < MAX_REGISTRY_PACKAGES) {
            out_order[order_count.*] = current_hash.*;
            order_count.* += 1;
        }
    }

    fn isHashInSlice(self: *const PackageRegistry, slice: []const [32]u8, target: *const [32]u8) bool {
        _ = self;
        for (slice) |*h| {
            if (std.mem.eql(u8, h, target)) return true;
        }
        return false;
    }
};

pub const PackageDaemon = struct {
    registry: PackageRegistry,
    active: bool,

    pub fn init() PackageDaemon {
        return PackageDaemon{
            .registry = PackageRegistry.init(),
            .active = true,
        };
    }

    pub fn packageCount(self: *const PackageDaemon) usize {
        return self.registry.count;
    }
};

test "PackageDaemon lifecycle" {
    var daemon = PackageDaemon.init();
    try std.testing.expect(daemon.active);
    try std.testing.expectEqual(@as(usize, 0), daemon.packageCount());
}

test "PackageHeader size and alignment invariant" {
    try std.testing.expectEqual(PACKAGE_HEADER_SIZE, @sizeOf(PackageHeader));
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(PackageHeader));
}

test "PackageHeader initialization, signing, and verification" {
    const seed = [_]u8{0x88} ** 32;
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    const manifest_hash = [_]u8{0x33} ** 32;
    var pkg = try PackageHeader.init(
        "evalinux/http_tools",
        "1.0.0",
        &kp.public_key.bytes,
        &manifest_hash,
        0x07,
        1720000000,
    );

    const dep1 = [_]u8{0x11} ** 32;
    try pkg.addDependency(&dep1);

    try pkg.sign(&kp);
    try pkg.verify();

    try std.testing.expectEqualStrings("evalinux/http_tools", pkg.getName());
    try std.testing.expectEqualStrings("1.0.0", pkg.getVersion());
    try std.testing.expectEqual(@as(u32, 1), pkg.dependency_count);

    // Tampered payload fails verification
    pkg.manifest_hash[0] ^= 0xFF;
    try std.testing.expectError(error.SignatureVerificationFailed, pkg.verify());
}

test "PackageRegistry registration, lookup, and dependency topological resolution" {
    var reg = PackageRegistry.init();

    const seed = [_]u8{0x12} ** 32;
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    const hash_dep = [_]u8{0xAA} ** 32;
    var pkg_dep = try PackageHeader.init("core/net", "1.0.0", &kp.public_key.bytes, &hash_dep, 1, 100);
    try pkg_dep.sign(&kp);
    try reg.registerPackage(&pkg_dep);

    const hash_app = [_]u8{0xBB} ** 32;
    var pkg_app = try PackageHeader.init("apps/chat", "2.1.0", &kp.public_key.bytes, &hash_app, 3, 200);
    try pkg_app.addDependency(&hash_dep);
    try pkg_app.sign(&kp);
    try reg.registerPackage(&pkg_app);

    try std.testing.expectEqual(@as(usize, 2), reg.count);
    try std.testing.expect(reg.findByName("core/net") != null);
    try std.testing.expect(reg.findPackage(&hash_app) != null);

    var load_order: [MAX_REGISTRY_PACKAGES][32]u8 = undefined;
    const count = try reg.resolveLoadOrder(&hash_app, &load_order);

    try std.testing.expectEqual(@as(usize, 2), count);
    // Dependency loaded first, app loaded second
    try std.testing.expectEqualStrings(&hash_dep, &load_order[0]);
    try std.testing.expectEqualStrings(&hash_app, &load_order[1]);
}

test "PackageRegistry circular dependency rejection" {
    var reg = PackageRegistry.init();
    const seed = [_]u8{0x34} ** 32;
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    const hash_a = [_]u8{0x0A} ** 32;
    const hash_b = [_]u8{0x0B} ** 32;

    var pkg_a = try PackageHeader.init("pkg/a", "1.0", &kp.public_key.bytes, &hash_a, 0, 10);
    try pkg_a.addDependency(&hash_b);
    try pkg_a.sign(&kp);
    try reg.registerPackage(&pkg_a);

    var pkg_b = try PackageHeader.init("pkg/b", "1.0", &kp.public_key.bytes, &hash_b, 0, 20);
    try pkg_b.addDependency(&hash_a);
    try pkg_b.sign(&kp);
    try reg.registerPackage(&pkg_b);

    var load_order: [MAX_REGISTRY_PACKAGES][32]u8 = undefined;
    const err = reg.resolveLoadOrder(&hash_a, &load_order);
    try std.testing.expectError(error.CircularDependency, err);
}
