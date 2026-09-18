// Macros Content-Addressed & Workspace Module Protocol (module.zig)
// Resolves modules via 256-bit BLAKE3 content hashes, Merkle workspace catalog, and Genesis bundles.
// Implements SPEC-TECH-LANG-003.

const std = @import("std");
const eval = @import("eval.zig");
const chunk_mod = @import("chunk.zig");
const parser_mod = @import("parser.zig");
const compiler_mod = @import("compiler.zig");
const vm_mod = @import("vm.zig");
const ast = @import("ast.zig");
const sys = @import("../sys.zig");

const Value = eval.Value;
const Chunk = chunk_mod.Chunk;
const Allocator = std.mem.Allocator;

pub const HASH_SIZE: usize = 32;
pub const HEX_HASH_SIZE: usize = 64;
pub const MAX_PATH_LEN: usize = 255;
pub const FILE_READ_BUF_SIZE: usize = 65536;

pub const ModuleError = error{
    InvalidSpecifier,
    InvalidHexHash,
    CorruptChunk,
    ModuleNotFound,
    CompileError,
    CircularDependency,
    OutOfMemory,
};

pub const ModuleState = enum(u8) {
    compiling,
    ready,
};

pub const ModuleEntry = struct {
    state: ModuleState,
    dict: *eval.Dict,
    chunk: *Chunk,
};

pub const ModuleResolver = struct {
    allocator: Allocator,
    entries: std.AutoHashMapUnmanaged([HASH_SIZE]u8, ModuleEntry) = .empty,
    virtual_sources: std.StringHashMapUnmanaged([]const u8) = .empty,
    dynamic_chunks: std.ArrayListUnmanaged(*Chunk) = .empty,
    allocated_dicts: std.ArrayListUnmanaged(*eval.Dict) = .empty,
    allocated_sources: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(allocator: Allocator) ModuleResolver {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModuleResolver) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == .ready and entry.value_ptr.dict.entries.len > 0) {
                self.allocator.free(entry.value_ptr.dict.entries);
            }
        }
        self.entries.deinit(self.allocator);
        for (self.allocated_dicts.items) |d| {
            self.allocator.destroy(d);
        }
        self.allocated_dicts.deinit(self.allocator);
        for (self.dynamic_chunks.items) |ch| {
            ch.deinit(self.allocator);
            self.allocator.destroy(ch);
        }
        self.dynamic_chunks.deinit(self.allocator);
        for (self.allocated_sources.items) |src| {
            self.allocator.free(src);
        }
        self.allocated_sources.deinit(self.allocator);
        self.virtual_sources.deinit(self.allocator);
    }

    pub fn registerVirtualSource(self: *ModuleResolver, path: []const u8, source: []const u8) !void {
        try self.virtual_sources.put(self.allocator, path, source);
    }

    pub fn parseCasHex(hex_str: []const u8) ! [HASH_SIZE]u8 {
        if (hex_str.len != HEX_HASH_SIZE) return ModuleError.InvalidHexHash;
        var out: [HASH_SIZE]u8 = undefined;
        _ = std.fmt.hexToBytes(&out, hex_str) catch return ModuleError.InvalidHexHash;
        return out;
    }

    pub fn formatHexHash(hash: *const [HASH_SIZE]u8, out_hex: *[HEX_HASH_SIZE]u8) void {
        const hex_chars = "0123456789abcdef";
        for (hash, 0..) |b, i| {
            out_hex[i * 2] = hex_chars[(b >> 4) & 0x0F];
            out_hex[i * 2 + 1] = hex_chars[b & 0x0F];
        }
    }

    pub fn importModule(self: *ModuleResolver, vm: *vm_mod.VM, specifier: []const u8) anyerror!Value {
        if (std.mem.startsWith(u8, specifier, "b3/") or std.mem.startsWith(u8, specifier, "b3:")) {
            return self.resolveCas(vm, specifier[3..]);
        }
        return self.resolvePath(vm, specifier);
    }

    fn resolveCas(self: *ModuleResolver, vm: *vm_mod.VM, hex_str: []const u8) anyerror!Value {
        const hash = try parseCasHex(hex_str);
        if (self.entries.get(hash)) |entry| {
            return switch (entry.state) {
                .compiling => ModuleError.CircularDependency,
                .ready => Value{ .dict = entry.dict },
            };
        }
        const source = self.fetchCasSource(hex_str, hash) orelse return ModuleError.ModuleNotFound;
        return self.compileAndExecute(vm, hash, source);
    }

    fn resolvePath(self: *ModuleResolver, vm: *vm_mod.VM, path: []const u8) anyerror!Value {
        const source = self.fetchPathSource(path) orelse return ModuleError.ModuleNotFound;
        var hash: [HASH_SIZE]u8 = undefined;
        std.crypto.hash.Blake3.hash(source, &hash, .{});
        if (self.entries.get(hash)) |entry| {
            return switch (entry.state) {
                .compiling => ModuleError.CircularDependency,
                .ready => Value{ .dict = entry.dict },
            };
        }
        return self.compileAndExecute(vm, hash, source);
    }

    fn fetchPathSource(self: *ModuleResolver, path: []const u8) ?[]const u8 {
        if (self.virtual_sources.get(path)) |src| return src;
        if (vm_mod.builtins.active_bundle_data) |bundle_bytes| {
            const bundle_mod = @import("../kernel/bundle.zig");
            if (bundle_mod.BundleReader.init(bundle_bytes)) |reader| {
                if (reader.findData(path)) |data| return data;
            } else |_| {}
        }
        return self.readFileFromDisk(path);
    }

    fn fetchCasSource(self: *ModuleResolver, hex: []const u8, hash: [HASH_SIZE]u8) ?[]const u8 {
        _ = hash;
        if (self.virtual_sources.get(hex)) |src| return src;
        var b3_buf: [HEX_HASH_SIZE + 3]u8 = undefined;
        const b3_key = std.fmt.bufPrint(&b3_buf, "b3/{s}", .{hex}) catch return null;
        return self.virtual_sources.get(b3_key);
    }

    fn readFileFromDisk(self: *ModuleResolver, path: []const u8) ?[]const u8 {
        var path_z: [MAX_PATH_LEN + 1:0]u8 = undefined;
        if (path.len >= MAX_PATH_LEN) return null;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const fd = sys.io.open(&path_z, sys.io.OpenFlags.rdonly, 0) catch return null;
        defer sys.io.close(fd) catch {};

        var buf: [FILE_READ_BUF_SIZE]u8 = undefined;
        const n = sys.io.read(fd, &buf) catch return null;
        if (n == 0) return null;

        const duped = self.allocator.dupe(u8, buf[0..n]) catch return null;
        self.allocated_sources.append(self.allocator, duped) catch {
            self.allocator.free(duped);
            return null;
        };
        return duped;
    }

    fn compileStatements(self: *ModuleResolver, source: []const u8, ch: *Chunk) !void {
        var parser = parser_mod.Parser.init(self.allocator, source);
        var stmts: std.ArrayList(*ast.Node) = .empty;
        defer {
            for (stmts.items) |stmt| stmt.deinit(self.allocator);
            stmts.deinit(self.allocator);
        }
        while (parser.current_token.token_type != .eof) {
            const stmt = parser.parseStatement() catch return ModuleError.CompileError;
            try stmts.append(self.allocator, stmt);
        }
        var compiler = compiler_mod.Compiler.init(self.allocator, ch);
        for (stmts.items) |stmt| {
            compiler.compile(stmt) catch return ModuleError.CompileError;
        }
        try ch.writeChunk(self.allocator, @intFromEnum(chunk_mod.OpCode.return_op));
    }

    fn compileAndExecute(self: *ModuleResolver, vm: *vm_mod.VM, hash: [HASH_SIZE]u8, source: []const u8) anyerror!Value {
        const dict = try self.allocator.create(eval.Dict);
        dict.* = eval.Dict{ .entries = &[_]eval.Dict.Entry{} };
        try self.allocated_dicts.append(self.allocator, dict);

        const ch = try self.allocator.create(Chunk);
        ch.* = Chunk.init();
        try self.dynamic_chunks.append(self.allocator, ch);

        try self.entries.put(self.allocator, hash, .{
            .state = .compiling,
            .dict = dict,
            .chunk = ch,
        });

        try self.compileStatements(source, ch);

        var exports_list: std.ArrayList(eval.Dict.Entry) = .empty;
        defer exports_list.deinit(self.allocator);

        const prev_exports = vm.current_exports;
        vm.current_exports = &exports_list;
        defer vm.current_exports = prev_exports;

        vm.executeChunk(ch) catch |err| {
            _ = self.entries.remove(hash);
            return err;
        };

        dict.entries = try exports_list.toOwnedSlice(self.allocator);
        try self.entries.put(self.allocator, hash, .{
            .state = .ready,
            .dict = dict,
            .chunk = ch,
        });

        return Value{ .dict = dict };
    }
};

test "ModuleResolver basic exports and import via virtual source" {
    const testing = std.testing;
    var resolver = ModuleResolver.init(testing.allocator);
    defer resolver.deinit();

    const math_src =
        \\export fn square(x) { return x * x; }
        \\export answer = 42;
    ;
    try resolver.registerVirtualSource("math.mx", math_src);

    var main_ch = Chunk.init();
    defer main_ch.deinit(testing.allocator);

    var vm = try vm_mod.VM.init(testing.allocator, &main_ch);
    defer vm.deinit();
    vm.setModuleResolver(&resolver);

    const m = try resolver.importModule(&vm, "math.mx");
    try testing.expect(m == .dict);

    var found_answer = false;
    for (m.dict.entries) |entry| {
        if (std.mem.eql(u8, entry.key, "answer")) {
            try testing.expectEqual(@as(i64, 42), entry.value.integer);
            found_answer = true;
        }
    }
    try testing.expect(found_answer);
}

test "ModuleResolver circular dependency containment" {
    const testing = std.testing;
    var resolver = ModuleResolver.init(testing.allocator);
    defer resolver.deinit();

    try resolver.registerVirtualSource("mod_a.mx", "b = import \"mod_b.mx\"; export val_a = 1;");
    try resolver.registerVirtualSource("mod_b.mx", "a = import \"mod_a.mx\"; export val_b = 2;");

    var main_ch = Chunk.init();
    defer main_ch.deinit(testing.allocator);

    var vm = try vm_mod.VM.init(testing.allocator, &main_ch);
    defer vm.deinit();
    vm.setModuleResolver(&resolver);

    const res = resolver.importModule(&vm, "mod_a.mx");
    try testing.expectError(ModuleError.CircularDependency, res);
}

test "ModuleResolver deduplication returns identical instance" {
    const testing = std.testing;
    var resolver = ModuleResolver.init(testing.allocator);
    defer resolver.deinit();

    try resolver.registerVirtualSource("shared.mx", "export count = 100;");

    var main_ch = Chunk.init();
    defer main_ch.deinit(testing.allocator);

    var vm = try vm_mod.VM.init(testing.allocator, &main_ch);
    defer vm.deinit();
    vm.setModuleResolver(&resolver);

    const m1 = try resolver.importModule(&vm, "shared.mx");
    const m2 = try resolver.importModule(&vm, "shared.mx");
    try testing.expectEqual(m1.dict, m2.dict);
}

test "ModuleResolver direct CAS hash import" {
    const testing = std.testing;
    var resolver = ModuleResolver.init(testing.allocator);
    defer resolver.deinit();

    const cas_src = "export val = 999;";
    var hash: [HASH_SIZE]u8 = undefined;
    std.crypto.hash.Blake3.hash(cas_src, &hash, .{});

    var hex_buf: [HEX_HASH_SIZE]u8 = undefined;
    ModuleResolver.formatHexHash(&hash, &hex_buf);

    var spec_buf: [HEX_HASH_SIZE + 3]u8 = undefined;
    const spec = try std.fmt.bufPrint(&spec_buf, "b3/{s}", .{hex_buf});

    try resolver.registerVirtualSource(spec, cas_src);

    var main_ch = Chunk.init();
    defer main_ch.deinit(testing.allocator);

    var vm = try vm_mod.VM.init(testing.allocator, &main_ch);
    defer vm.deinit();
    vm.setModuleResolver(&resolver);

    const m = try resolver.importModule(&vm, spec);
    try testing.expect(m == .dict);
    try testing.expectEqual(@as(i64, 999), m.dict.entries[0].value.integer);
}

test "ModuleResolver end-to-end import and method invocation" {
    const testing = std.testing;
    var resolver = ModuleResolver.init(testing.allocator);
    defer resolver.deinit();

    const calc_src =
        \\export fn add(a, b) { return a + b; }
    ;
    try resolver.registerVirtualSource("calc.mx", calc_src);

    const main_src =
        \\calc = import "calc.mx";
        \\res = calc.add(15, 27);
    ;

    var parser = parser_mod.Parser.init(testing.allocator, main_src);
    var main_ch = Chunk.init();
    defer main_ch.deinit(testing.allocator);

    var comp = compiler_mod.Compiler.init(testing.allocator, &main_ch);
    while (parser.current_token.token_type != .eof) {
        const stmt = try parser.parseStatement();
        defer stmt.deinit(testing.allocator);
        try comp.compile(stmt);
    }
    try main_ch.writeChunk(testing.allocator, @intFromEnum(chunk_mod.OpCode.return_op));

    var vm = try vm_mod.VM.init(testing.allocator, &main_ch);
    defer vm.deinit();
    vm.setModuleResolver(&resolver);

    try vm.run(0);

    const res = vm.globals.get("res");
    try testing.expect(res != null);
    try testing.expectEqual(@as(i64, 42), res.?.integer);
}
