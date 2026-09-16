const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // MicrOS Init (PID 1 Sandbox)
    const init_exe = b.addExecutable(.{
        .name = "micros-init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(init_exe);

    // Substrate Toolchain
    const ToolDef = struct {
        name: []const u8,
        src: []const u8,
    };
    const tools = [_]ToolDef{
        .{ .name = "micros-fb-verify", .src = "tools/src/fb_verify.zig" },
        .{ .name = "micros-lint", .src = "tools/src/lint.zig" },
        .{ .name = "micros-sym", .src = "tools/src/sym.zig" },
        .{ .name = "micros-telem", .src = "tools/src/telem.zig" },
    };

    const tools_step = b.step("tools", "Build the MicrOS substrate toolchain");

    for (tools) |tool| {
        const exe = b.addExecutable(.{
            .name = tool.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(tool.src),
                .target = target,
                .optimize = optimize,
            }),
        });

        const install_cmd = b.addInstallArtifact(exe, .{});
        tools_step.dependOn(&install_cmd.step);
    }

    // Tests
    const test_step = b.step("test", "Run unit tests");

    const sys_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sys.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_sys_test = b.addRunArtifact(sys_test);
    test_step.dependOn(&run_sys_test.step);

    const macros_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/macros.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_macros_test = b.addRunArtifact(macros_test);
    test_step.dependOn(&run_macros_test.step);
}
