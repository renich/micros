const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Substrate Toolchain
    const tools = [_][]const u8{
        "fb_verify",
        "lint",
        "sym",
        "telem",
    };

    const tools_step = b.step("tools", "Build the MicrOS substrate toolchain");

    for (tools) |tool_name| {
        const src_path = b.fmt("tools/src/{s}.zig", .{tool_name});
        const exe_name = b.fmt("micros-{s}", .{tool_name});

        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(src_path),
                .target = target,
                .optimize = optimize,
            }),
        });

        b.installArtifact(exe);
        tools_step.dependOn(&exe.step);
    }

    // Tests
    const test_step = b.step("test", "Run unit tests");

    const sys_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sys/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_sys_test = b.addRunArtifact(sys_test);
    test_step.dependOn(&run_sys_test.step);

    const lexer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/macros/lexer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lexer_tests = b.addRunArtifact(lexer_tests);
    test_step.dependOn(&run_lexer_tests.step);

    const ast_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/macros/ast.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_ast_tests = b.addRunArtifact(ast_tests);
    test_step.dependOn(&run_ast_tests.step);
}
