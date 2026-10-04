// MicrOS (µOS) Microkernel Boundary Enforcement Gate (arch_gate.zig)
// SPEC-TECH-ARCH-001 & DELIV-STAGE4-DECOUPLE-001
// Enforces strict architectural separation across Kernel, Userland, and Macros tiers.
// Discloses grandfathered exemptions and enforces the recorded edge baseline
// (--baseline), so admitting a new architectural edge requires an explicit,
// reviewable baseline update instead of an invisible code change.
// Zero libc, freestanding, explicit allocator.

const std = @import("std");

pub const MAX_VIOLATIONS: usize = 128;

pub const Edge = struct {
    importer: []const u8,
    line: usize,
    target: []const u8,
    violation_rule: ?[]const u8 = null,
};

/// Result of applying the tier boundary rules to a single import edge.
const EdgeVerdict = struct {
    kind: Kind,
    message: []const u8 = "",

    const Kind = enum { ok, grandfathered, violation };
};

fn parseImportPath(line: []const u8) ?[]const u8 {
    const code = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, code, "//")) return null;
    const import_token = "@import(\"";
    const start_idx = std.mem.indexOf(u8, line, import_token) orelse return null;
    const path_start = start_idx + import_token.len;
    if (path_start >= line.len) return null;
    const end_rel = std.mem.indexOfScalar(u8, line[path_start..], '"') orelse return null;
    return line[path_start .. path_start + end_rel];
}

fn isArchitecturalEdge(target: []const u8) bool {
    return std.mem.indexOf(u8, target, "userland") != null or std.mem.indexOf(u8, target, "kernel") != null;
}

fn matchesAny(target: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (std.mem.indexOf(u8, target, pattern) != null) return true;
    }
    return false;
}

/// The only substrate surface userland may reach directly, per
/// docs/project/deliberations/stage4/decoupling-design.md Section 2.1 Rule 2.
fn isPublicAbiImport(target: []const u8) bool {
    return matchesAny(target, &[_][]const u8{ "capability.zig", "ipc/ring.zig", "boot_info.zig" });
}

fn isGrandfathered(importer: []const u8, target: []const u8) bool {
    return isKernelSideExemption(importer, target) or isUserlandSideExemption(importer, target);
}

fn isKernelSideExemption(importer: []const u8, target: []const u8) bool {
    // Grandfathered legacy fiber daemon instantiations scheduled for M42 excision
    if (std.mem.endsWith(u8, importer, "src/kernel/main.zig")) {
        if (std.mem.indexOf(u8, target, "userland/netd/netd.zig") != null) return true;
        if (std.mem.indexOf(u8, target, "userland/aid/aid.zig") != null) return true;
        if (std.mem.indexOf(u8, target, "userland/gopd/gopd.zig") != null) return true;
        if (std.mem.indexOf(u8, target, "userland/storaged/storaged.zig") != null) return true;
        if (std.mem.indexOf(u8, target, "userland/p2pd/p2p.zig") != null) return true;
        // Notice: userland/pkgd/package.zig is NOT grandfathered (violating edge with teeth)
    }
    if (std.mem.endsWith(u8, importer, "src/kernel/abi.zig")) {
        if (std.mem.indexOf(u8, target, "userland/p2pd/p2p_abi.zig") != null) return true;
        if (std.mem.indexOf(u8, target, "userland/p2pd/p2p.zig") != null) return true;
        if (std.mem.indexOf(u8, target, "userland/pkgd/pkg_abi.zig") != null) return true;
    }
    if (std.mem.endsWith(u8, importer, "src/kernel/ai/ai_abi.zig")) {
        if (std.mem.indexOf(u8, target, "userland/aid/aid.zig") != null) return true;
    }
    return false;
}

/// Legacy daemon imports of kernel internals, scheduled for M42 Ring-3 excision
/// (docs/project/roadmaps/m42-ring3-activation.rst). Every edge is enumerated
/// individually: a previously unseen import by these daemons fails the gate
/// instead of being silently absorbed by a catch-all clause.
fn isUserlandSideExemption(importer: []const u8, target: []const u8) bool {
    if (std.mem.endsWith(u8, importer, "src/userland/aid/aid.zig")) {
        return matchesAny(target, &[_][]const u8{
            "kernel/ai.zig",
            "kernel/ai/gemini.zig",
            "kernel/ai/openai.zig",
            "kernel/net/tls_stream.zig",
            "kernel/net/http.zig",
            "kernel/serial.zig",
        });
    }
    if (std.mem.endsWith(u8, importer, "src/userland/netd/netd.zig")) {
        return matchesAny(target, &[_][]const u8{
            "kernel/drivers/virtio_net.zig",
            "kernel/net/stack.zig",
            "kernel/arch/x86_64/io.zig",
        });
    }
    if (std.mem.endsWith(u8, importer, "src/userland/gopd/gopd.zig")) {
        return matchesAny(target, &[_][]const u8{
            "kernel/compositor.zig",
            "kernel/fb.zig",
        });
    }
    if (std.mem.endsWith(u8, importer, "src/userland/storaged/storaged.zig")) {
        return matchesAny(target, &[_][]const u8{
            "kernel/drivers/block.zig",
            "kernel/storage/block_cache.zig",
            "kernel/storage/cas.zig",
            "kernel/storage/chunk.zig",
        });
    }
    return false;
}

fn checkBoundaryRule(importer: []const u8, target: []const u8) EdgeVerdict {
    // Rule 1: Downstream Isolation (src/kernel/ -> src/userland/)
    if (std.mem.indexOf(u8, importer, "src/kernel/") != null) {
        if (std.mem.indexOf(u8, target, "userland/") != null) {
            if (std.mem.indexOf(u8, target, "pkgd/package.zig") != null) {
                return .{ .kind = .violation, .message = "Rule 1 Violation: src/kernel must not import concrete pkgd daemon implementation" };
            }
            if (isGrandfathered(importer, target)) return .{ .kind = .grandfathered };
            return .{ .kind = .violation, .message = "Rule 1 Violation: unauthorized downstream import from kernel into userland" };
        }
    }

    // Rule 2: Upstream Isolation (src/userland/ -> src/kernel/)
    if (std.mem.indexOf(u8, importer, "src/userland/") != null and std.mem.indexOf(u8, target, "kernel/") != null) {
        if (isPublicAbiImport(target)) return .{ .kind = .ok };
        if (isGrandfathered(importer, target)) return .{ .kind = .grandfathered };
        return .{ .kind = .violation, .message = "Rule 2 Violation: userland must reach the substrate only through the public capability ABI (capability.zig, ipc/ring.zig, boot_info.zig)" };
    }

    // Rule 4: No Circular Substrate Bleed (src/macros/ -> drivers or arch)
    if (std.mem.indexOf(u8, importer, "src/macros/") != null) {
        if (std.mem.indexOf(u8, target, "kernel/drivers/") != null or
            std.mem.indexOf(u8, target, "kernel/arch/") != null)
        {
            return .{ .kind = .violation, .message = "Rule 4 Violation: macros VM imports hardware driver registers or arch state" };
        }
    }

    return .{ .kind = .ok };
}

/// Normalized identity of an architectural edge. Line numbers are deliberately
/// excluded so unrelated edits do not invalidate the recorded baseline.
fn edgeKey(allocator: std.mem.Allocator, importer: []const u8, target: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} -> {s}", .{ importer, target });
}

const ArchScanner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    violations_found: usize = 0,
    grandfathered_found: usize = 0,
    edges_found: usize = 0,
    edges: std.StringHashMapUnmanaged(void) = .empty,

    fn classifyEdge(self: *ArchScanner, file_path: []const u8, target: []const u8, line_no: usize) void {
        const verdict = checkBoundaryRule(file_path, target);
        switch (verdict.kind) {
            .ok => {},
            .grandfathered => self.grandfathered_found += 1,
            .violation => {
                self.violations_found += 1;
                std.debug.print("  [FAIL] {s}:{d} -> \"{s}\"\n         => {s}\n", .{
                    file_path,
                    line_no,
                    target,
                    verdict.message,
                });
            },
        }
    }

    fn recordEdge(self: *ArchScanner, file_path: []const u8, target: []const u8, line_no: usize, out_stream: ?*std.ArrayList(u8)) !void {
        if (!isArchitecturalEdge(target)) return;
        const key = try edgeKey(self.allocator, file_path, target);
        const entry = try self.edges.getOrPut(self.allocator, key);
        if (entry.found_existing) return;
        if (out_stream) |stream| {
            const line_str = try std.fmt.allocPrint(self.allocator, "{s}:{d}: @import(\"{s}\")\n", .{ file_path, line_no, target });
            try stream.appendSlice(self.allocator, line_str);
        }
    }

    fn scanFile(self: *ArchScanner, file_path: []const u8, out_stream: ?*std.ArrayList(u8)) !void {
        const content = std.Io.Dir.cwd().readFileAllocOptions(
            self.io,
            file_path,
            self.allocator,
            .limited(4 * 1024 * 1024),
            .of(u8),
            0,
        ) catch return;
        defer self.allocator.free(content);

        var line_it = std.mem.splitScalar(u8, content, '\n');
        var line_no: usize = 1;

        while (line_it.next()) |line| : (line_no += 1) {
            const target = parseImportPath(line) orelse continue;
            self.edges_found += 1;
            self.classifyEdge(file_path, target, line_no);
            try self.recordEdge(file_path, target, line_no, out_stream);
        }
    }

    fn scanTree(self: *ArchScanner, root_dir: []const u8, out_stream: ?*std.ArrayList(u8)) !void {
        var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), self.io, root_dir, .{ .iterate = true }) catch |err| {
            std.debug.print("Cannot open directory {s}: {s}\n", .{ root_dir, @errorName(err) });
            return;
        };
        defer dir.close(self.io);

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        const trimmed_root = std.mem.trimEnd(u8, root_dir, "/");

        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const full_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ trimmed_root, entry.path });
            try self.scanFile(full_path, out_stream);
        }
    }
};

fn printUsage() noreturn {
    std.debug.print("Usage: micros-arch-gate [options] <root-path>\n", .{});
    std.debug.print("Options:\n", .{});
    std.debug.print("  --baseline <path>       Fail when an architectural edge is absent from the recorded baseline\n", .{});
    std.debug.print("  --dump-baseline <path>  Write the current architectural edge set to a snapshot file\n", .{});
    std.debug.print("  -h, --help              Show this help message\n", .{});
    std.process.exit(1);
}

fn printBanner(root_path: []const u8) void {
    std.debug.print("========================================================\n", .{});
    std.debug.print("     MicrOS Architectural Boundary Gate (arch-gate)    \n", .{});
    std.debug.print("             SPEC-TECH-ARCH-001 Verification            \n", .{});
    std.debug.print("========================================================\n", .{});
    std.debug.print("Scanning path: {s}...\n\n", .{root_path});
}

fn baselineKey(allocator: std.mem.Allocator, line: []const u8) !?[]const u8 {
    const marker = ": @import(\"";
    const idx = std.mem.lastIndexOf(u8, line, marker) orelse return null;
    const head = line[0..idx];
    const path_end = std.mem.lastIndexOfScalar(u8, head, ':') orelse return null;
    const rest = line[idx + marker.len ..];
    const quote_end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return try edgeKey(allocator, head[0..path_end], rest[0..quote_end]);
}

fn parseBaselineContent(allocator: std.mem.Allocator, content: []const u8) !std.StringHashMapUnmanaged(void) {
    var edges: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const key = try baselineKey(allocator, line) orelse continue;
        try edges.put(allocator, key, {});
    }
    return edges;
}

fn enforceBaseline(scanner: *ArchScanner, baseline_path: []const u8) !void {
    const content = std.Io.Dir.cwd().readFileAllocOptions(scanner.io, baseline_path, scanner.allocator, .limited(4 * 1024 * 1024), .of(u8), 0) catch |err| {
        std.debug.print("[baseline] cannot read {s}: {s}\n", .{ baseline_path, @errorName(err) });
        std.process.exit(1);
    };
    defer scanner.allocator.free(content);

    var recorded = try parseBaselineContent(scanner.allocator, content);
    defer recorded.deinit(scanner.allocator);

    var new_edges: usize = 0;
    var current_it = scanner.edges.keyIterator();
    while (current_it.next()) |key| {
        if (recorded.get(key.*) != null) continue;
        new_edges += 1;
        std.debug.print("  [NEW] edge absent from baseline: {s}\n", .{key.*});
    }

    var removed_edges: usize = 0;
    var recorded_it = recorded.keyIterator();
    while (recorded_it.next()) |key| {
        if (scanner.edges.get(key.*) == null) removed_edges += 1;
    }

    std.debug.print("[baseline] recorded {d}, current {d}, new {d}, removed {d} ({s})\n", .{ recorded.count(), scanner.edges.count(), new_edges, removed_edges, baseline_path });
    if (new_edges > 0) {
        std.debug.print(" [FAIL] Baseline lock: {d} unauthorized new edge(s). Regenerate with --dump-baseline only after review.\n", .{new_edges});
        std.process.exit(1);
    }
}

fn handleDump(scanner: *ArchScanner, root_path: []const u8, dump_file: []const u8) !void {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(scanner.allocator);
    try scanner.scanTree(root_path, &buffer);

    const file = try std.Io.Dir.cwd().createFile(scanner.io, dump_file, .{});
    var f = file;
    defer f.close(scanner.io);
    try f.writeStreamingAll(scanner.io, buffer.items);
    std.debug.print("\nBaseline snapshot written to: {s} ({d} edges scanned, {d} recorded)\n", .{ dump_file, scanner.edges_found, scanner.edges.count() });
}

fn reportResults(scanner: *const ArchScanner) void {
    std.debug.print("========================================================\n", .{});
    if (scanner.violations_found > 0) {
        std.debug.print(" [FAIL] Gate Rejected: {d} architectural boundary violation(s) found!\n", .{scanner.violations_found});
        std.debug.print("        Scanned {d} import(s), {d} grandfathered.\n", .{ scanner.edges_found, scanner.grandfathered_found });
        std.debug.print("========================================================\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print(" [PASS] Gate Clear: 0 violations across {d} imports ({d} grandfathered).\n", .{ scanner.edges_found, scanner.grandfathered_found });
        std.debug.print("        Tier 1/2/3 Microkernel Boundary Invariant Verified.\n", .{});
        std.debug.print("========================================================\n", .{});
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = init.minimal.args.iterate();
    _ = args.skip(); // skip binary name

    var root_path: []const u8 = "src";
    var dump_baseline_path: ?[]const u8 = null;
    var baseline_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dump-baseline")) {
            dump_baseline_path = args.next();
        } else if (std.mem.eql(u8, arg, "--baseline")) {
            baseline_path = args.next();
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printUsage();
        } else {
            root_path = arg;
        }
    }

    printBanner(root_path);
    var scanner = ArchScanner{ .allocator = allocator, .io = init.io };

    if (dump_baseline_path) |dump_file| {
        try handleDump(&scanner, root_path, dump_file);
        return;
    }

    try scanner.scanTree(root_path, null);
    if (baseline_path) |path| try enforceBaseline(&scanner, path);
    reportResults(&scanner);
}

test "parseImportPath skips commented-out imports and reads real ones" {
    try std.testing.expect(parseImportPath("// @import(\"../kernel/main.zig\")") == null);
    try std.testing.expect(parseImportPath("   //! @import(\"foo.zig\")") == null);
    try std.testing.expect(parseImportPath("const x = 1;") == null);
    try std.testing.expectEqualStrings("../kernel/main.zig", parseImportPath("const x = @import(\"../kernel/main.zig\");").?);
}

test "isArchitecturalEdge filters to kernel and userland targets" {
    try std.testing.expect(isArchitecturalEdge("../kernel/main.zig"));
    try std.testing.expect(isArchitecturalEdge("../../userland/aid/aid.zig"));
    try std.testing.expect(!isArchitecturalEdge("./chunk.zig"));
}

test "checkBoundaryRule classifies grandfathered, unauthorized, and pkgd edges" {
    try std.testing.expectEqual(EdgeVerdict.Kind.grandfathered, checkBoundaryRule("src/kernel/main.zig", "../userland/aid/aid.zig").kind);
    try std.testing.expectEqual(EdgeVerdict.Kind.violation, checkBoundaryRule("src/kernel/main.zig", "../userland/pkgd/package.zig").kind);
    try std.testing.expectEqual(EdgeVerdict.Kind.violation, checkBoundaryRule("src/kernel/foo.zig", "../userland/bar/bar.zig").kind);
    try std.testing.expectEqual(EdgeVerdict.Kind.violation, checkBoundaryRule("src/macros/vm.zig", "../kernel/drivers/pci.zig").kind);
    try std.testing.expectEqual(EdgeVerdict.Kind.ok, checkBoundaryRule("src/macros/vm.zig", "./chunk.zig").kind);
}

test "rule 2 admits the public capability ABI and rejects unlisted internals" {
    try std.testing.expectEqual(EdgeVerdict.Kind.ok, checkBoundaryRule("src/userland/aid/aid.zig", "../../kernel/cap/capability.zig").kind);
    try std.testing.expectEqual(EdgeVerdict.Kind.ok, checkBoundaryRule("src/userland/netd/netd.zig", "../../kernel/ipc/ring.zig").kind);
    try std.testing.expectEqual(EdgeVerdict.Kind.ok, checkBoundaryRule("src/userland/aid/aid.zig", "../../kernel/boot_info.zig").kind);
    try std.testing.expectEqual(EdgeVerdict.Kind.violation, checkBoundaryRule("src/userland/pkgd/package.zig", "../../kernel/serial.zig").kind);
    try std.testing.expectEqual(EdgeVerdict.Kind.violation, checkBoundaryRule("src/userland/p2pd/p2p.zig", "../../kernel/sched/smp.zig").kind);
}

test "rule 2 exemption is enumerated per edge, not per daemon" {
    // aid.zig may import serial.zig (recorded M42 excision) ...
    try std.testing.expectEqual(EdgeVerdict.Kind.grandfathered, checkBoundaryRule("src/userland/aid/aid.zig", "../../kernel/serial.zig").kind);
    // ... but a new import by the same daemon of an unrecorded internal fails ...
    try std.testing.expectEqual(EdgeVerdict.Kind.violation, checkBoundaryRule("src/userland/aid/aid.zig", "../../kernel/storage/cas.zig").kind);
    // ... and one daemon cannot inherit another daemon's recorded exemption.
    try std.testing.expectEqual(EdgeVerdict.Kind.violation, checkBoundaryRule("src/userland/gopd/gopd.zig", "../../kernel/serial.zig").kind);
}

test "baseline keys normalize away line numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const key_a = (try baselineKey(allocator, "src/kernel/main.zig:49: @import(\"../userland/aid/aid.zig\")")).?;
    const key_b = (try baselineKey(allocator, "src/kernel/main.zig:512: @import(\"../userland/aid/aid.zig\")")).?;

    try std.testing.expectEqualStrings(key_a, key_b);
    try std.testing.expectEqualStrings("src/kernel/main.zig -> ../userland/aid/aid.zig", key_a);
    try std.testing.expect((try baselineKey(allocator, "not an edge line")) == null);
}

test "baseline parsing records one entry per unique edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const content =
        "src/kernel/main.zig:49: @import(\"../userland/aid/aid.zig\")\n" ++
        "src/kernel/main.zig:50: @import(\"../userland/aid/aid.zig\")\n" ++
        "src/kernel/main.zig:51: @import(\"../userland/gopd/gopd.zig\")\n" ++
        "\n";
    const edges = try parseBaselineContent(allocator, content);

    try std.testing.expectEqual(@as(usize, 2), edges.count());
}
