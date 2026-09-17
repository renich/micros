// Macros Content-Addressed Module Protocol (module.zig)
// Resolves modules via 256-bit BLAKE3 cryptographic content hashes and Genesis bundles.
// Implements SPEC-TECH-LANG-002 Section 6.

const std = @import("std");
const eval = @import("eval.zig");
const chunk_mod = @import("chunk.zig");
const parser_mod = @import("parser.zig");
const compiler_mod = @import("compiler.zig");
const vm_mod = @import("vm.zig");
const sys = @import("../sys.zig");

const Value = eval.Value;
const Chunk = chunk_mod.Chunk;
const Allocator = std.mem.Allocator;

pub const ModuleError = error{
    InvalidSpecifier,
    InvalidHexHash,
    CorruptChunk,
    ModuleNotFound,
    CompileError,
    OutOfMemory,
};

pub const ModuleDomain = struct {
    hash: [32]u8,
    exports: std.StringHashMap(Value),
    chunk: Chunk,
    allocator: Allocator,

    pub fn init(allocator: Allocator, hash: [32]u8) ModuleDomain {
        return .{
            .hash = hash,
            .exports = std.StringHashMap(Value).init(allocator),
            .chunk = Chunk.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModuleDomain) void {
        var it = self.exports.keyIterator();
        while (it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.exports.deinit();
        self.chunk.deinit(self.allocator);
    }
};

pub const ModuleResolver = struct {
    cache: std.AutoHashMap([32]u8, *ModuleDomain),
    allocator: Allocator,

    pub fn init(allocator: Allocator) ModuleResolver {
        return .{
            .cache = std.AutoHashMap([32]u8, *ModuleDomain).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModuleResolver) void {
        var it = self.cache.valueIterator();
        while (it.next()) |domain_ptr| {
            domain_ptr.*.deinit();
            self.allocator.destroy(domain_ptr.*);
        }
        self.cache.deinit();
    }

    pub fn parseCasHex(hex_str: []const u8) ![32]u8 {
        if (hex_str.len != 64) return ModuleError.InvalidHexHash;
        var out: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, hex_str) catch return ModuleError.InvalidHexHash;
        return out;
    }

    pub fn resolve(self: *ModuleResolver, specifier: []const u8) !*ModuleDomain {
        if (std.mem.startsWith(u8, specifier, "b3:")) {
            return self.resolveCas(specifier[3..]);
        } else if (std.mem.startsWith(u8, specifier, "bundle:")) {
            return self.resolveBundle(specifier[7..]);
        }
        return ModuleError.InvalidSpecifier;
    }

    pub fn resolveCas(self: *ModuleResolver, hex_str: []const u8) !*ModuleDomain {
        const hash = try parseCasHex(hex_str);
        if (self.cache.get(hash)) |domain| {
            return domain;
        }
        return ModuleError.ModuleNotFound;
    }

    pub fn registerDirect(self: *ModuleResolver, code: []const u8) !*ModuleDomain {
        var hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(code, &hash, .{});
        if (self.cache.get(hash)) |domain| {
            return domain;
        }
        return self.compileAndCache(hash, code);
    }

    pub fn resolveBundle(self: *ModuleResolver, path: []const u8) !*ModuleDomain {
        var path_z: [256:0]u8 = undefined;
        if (path.len >= 255) return ModuleError.InvalidSpecifier;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const fd = sys.io.open(&path_z, sys.io.OpenFlags.rdonly, 0) catch {
            return ModuleError.ModuleNotFound;
        };
        defer sys.io.close(fd) catch {};

        var buf: [65536]u8 = undefined;
        const bytes_read = sys.io.read(fd, &buf) catch return ModuleError.ModuleNotFound;
        if (bytes_read == 0) return ModuleError.ModuleNotFound;

        return self.registerDirect(buf[0..bytes_read]);
    }

    fn compileAndCache(self: *ModuleResolver, hash: [32]u8, code: []const u8) !*ModuleDomain {
        const domain = try self.allocator.create(ModuleDomain);
        domain.* = ModuleDomain.init(self.allocator, hash);
        errdefer {
            domain.deinit();
            self.allocator.destroy(domain);
        }

        try self.compileModule(domain, code);
        try self.cache.put(hash, domain);
        return domain;
    }

    fn compileModule(self: *ModuleResolver, domain: *ModuleDomain, code: []const u8) !void {
        var parser = parser_mod.Parser.init(self.allocator, code);
        var compiler = compiler_mod.Compiler.init(self.allocator, &domain.chunk);

        while (parser.current_token.token_type != .eof) {
            const stmt = parser.parseStatement() catch return ModuleError.CompileError;
            compiler.compile(stmt) catch return ModuleError.CompileError;
            stmt.deinit(self.allocator);
        }

        var vm = try vm_mod.VM.init(self.allocator, &domain.chunk);
        defer vm.deinit();
        vm.run(0) catch return ModuleError.CompileError;

        var it = vm.globals.iterator();
        while (it.next()) |entry| {
            const key_dupe = try self.allocator.dupe(u8, entry.key_ptr.*);
            try domain.exports.put(key_dupe, entry.value_ptr.*);
        }
    }
};

test "ModuleResolver direct registration, caching and export binding" {
    const testing = std.testing;
    var resolver = ModuleResolver.init(testing.allocator);
    defer resolver.deinit();

    const code = "fn add(a, b) { return a + b; } val = 42;";
    const domain1 = try resolver.registerDirect(code);
    try testing.expect(domain1.exports.get("add") != null);
    try testing.expect(domain1.exports.get("val") != null);
    try testing.expectEqual(@as(i64, 42), domain1.exports.get("val").?.integer);

    // Second resolution returns identical cached domain
    const domain2 = try resolver.registerDirect(code);
    try testing.expectEqual(domain1, domain2);
}
