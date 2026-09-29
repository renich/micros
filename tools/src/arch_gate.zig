// MicrOS (µOS) Microkernel Boundary Enforcement Gate (arch_gate.zig)
// SPEC-TECH-ARCH-001 & DELIB-STAGE4-DECOUPLE-001
// Enforces strict architectural separation across Kernel, Userland, and Macros tiers.
// Zero libc, freestanding, explicit allocator.

const std = @import("std");

pub const MAX_VIOLATIONS: usize = 128;

pub const Edge = struct {
    importer: []const u8,
    line: usize,
    target: []const u8,
    violation_rule: ?[]const u8 = null,
};

fn parseImportPath(line: []const u8) ?[]const u8 {
    const import_token = "@import(\"";
    const start_idx = std.mem.indexOf(u8, line, import_token) orelse return null;
    const path_start = start_idx + import_token.len;
    if (path_start >= line.len) return null;
    const end_rel = std.mem.indexOfScalar(u8, line[path_start..], '"') orelse return null;
    return line[path_start .. path_start + end_rel];
}

fn isGrandfathered(importer: []const u8, target: []const u8) bool {
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
    // Grandfathered legacy userland daemon imports scheduled for M42 Ring-3 excision
    if (std.mem.indexOf(u8, importer, "src/userland/netd/") != null or
        std.mem.indexOf(u8, importer, "src/userland/aid/") != null or
        std.mem.indexOf(u8, importer, "src/userland/gopd/") != null or
        std.mem.indexOf(u8, importer, "src/userland/storaged/") != null)
    {
        return true;
    }
    return false;
}

fn checkBoundaryRule(importer: []const u8, target: []const u8) ?[]const u8 {
    // Rule 1: Downstream Isolation (src/kernel/ -> src/userland/)
    if (std.mem.indexOf(u8, importer, "src/kernel/") != null) {
        if (std.mem.indexOf(u8, target, "userland/") != null) {
            if (std.mem.indexOf(u8, target, "pkgd/package.zig") != null) {
                return "Rule 1 Violation: src/kernel must not import concrete pkgd daemon implementation";
            }
            if (!isGrandfathered(importer, target)) {
                return "Rule 1 Violation: unauthorized downstream import from kernel into userland";
            }
        }
    }

    // Rule 2: Upstream Isolation (src/userland/ -> internal src/kernel/)
    if (std.mem.indexOf(u8, importer, "src/userland/") != null) {
        if (!isGrandfathered(importer, target)) {
            if (std.mem.indexOf(u8, target, "kernel/mem/pmm.zig") != null or
                std.mem.indexOf(u8, target, "kernel/arch/") != null or
                std.mem.indexOf(u8, target, "kernel/sched/") != null)
            {
                return "Rule 2 Violation: userland actor imports internal kernel substrate directly";
            }
        }
    }

    // Rule 4: No Circular Substrate Bleed (src/macros/ -> drivers or arch)
    if (std.mem.indexOf(u8, importer, "src/macros/") != null) {
        if (std.mem.indexOf(u8, target, "kernel/drivers/") != null or
            std.mem.indexOf(u8, target, "kernel/arch/") != null)
        {
            return "Rule 4 Violation: macros VM imports hardware driver registers or arch state";
        }
    }

    return null;
}

const ArchScanner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    violations_found: usize = 0,
    edges_found: usize = 0,

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

            const violation = checkBoundaryRule(file_path, target);
            if (violation) |v_msg| {
                self.violations_found += 1;
                std.debug.print("  [FAIL] {s}:{d} -> \"{s}\"\n         => {s}\n", .{
                    file_path,
                    line_no,
                    target,
                    v_msg,
                });
            }

            if (out_stream) |stream| {
                if (std.mem.indexOf(u8, target, "userland") != null or
                    std.mem.indexOf(u8, target, "kernel") != null)
                {
                    const line_str = try std.fmt.allocPrint(self.allocator, "{s}:{d}: @import(\"{s}\")\n", .{ file_path, line_no, target });
                    defer self.allocator.free(line_str);
                    try stream.appendSlice(self.allocator, line_str);
                }
            }
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

fn printBanner(root_path: []const u8) void {
    std.debug.print("========================================================\n", .{});
    std.debug.print("     MicrOS Architectural Boundary Gate (arch-gate)    \n", .{});
    std.debug.print("             SPEC-TECH-ARCH-001 Verification            \n", .{});
    std.debug.print("========================================================\n", .{});
    std.debug.print("Scanning path: {s}...\n\n", .{root_path});
}

fn handleDump(scanner: *ArchScanner, root_path: []const u8, dump_file: []const u8) !void {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(scanner.allocator);
    try scanner.scanTree(root_path, &buffer);

    const file = try std.Io.Dir.cwd().createFile(scanner.io, dump_file, .{});
    var f = file;
    defer f.close(scanner.io);
    try f.writeStreamingAll(scanner.io, buffer.items);
    std.debug.print("\nBaseline snapshot written to: {s} ({d} edges scanned)\n", .{ dump_file, scanner.edges_found });
}

fn reportResults(scanner: *const ArchScanner) void {
    std.debug.print("========================================================\n", .{});
    if (scanner.violations_found > 0) {
        std.debug.print(" [FAIL] Gate Rejected: {d} architectural boundary violation(s) found!\n", .{scanner.violations_found});
        std.debug.print("========================================================\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print(" [PASS] Gate Clear: 0 violations across {d} imports.\n", .{scanner.edges_found});
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

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--dump-baseline")) {
            dump_baseline_path = args.next();
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            root_path = arg;
        }
    }

    printBanner(root_path);
    var scanner = ArchScanner{ .allocator = allocator, .io = init.io };

    if (dump_baseline_path) |dump_file| {
        try handleDump(&scanner, root_path, dump_file);
    } else {
        try scanner.scanTree(root_path, null);
    }

    reportResults(&scanner);
}
