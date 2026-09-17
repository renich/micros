const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // MicrOS Init (PID 1 Sandbox)
    const init_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    init_mod.addAssemblyFile(b.path("src/macros/context_switch.s"));
    const init_exe = b.addExecutable(.{
        .name = "micros-init",
        .root_module = init_mod,
    });
    b.installArtifact(init_exe);

    // MicroShell (msh)
    const msh_mod = b.createModule(.{
        .root_source_file = b.path("src/msh_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    msh_mod.addAssemblyFile(b.path("src/macros/context_switch.s"));
    const msh_exe = b.addExecutable(.{
        .name = "msh",
        .root_module = msh_mod,
    });
    b.installArtifact(msh_exe);

    // Macros Language Runner (macros)
    const macros_runner_mod = b.createModule(.{
        .root_source_file = b.path("src/macros_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    macros_runner_mod.addAssemblyFile(b.path("src/macros/context_switch.s"));
    const macros_runner_exe = b.addExecutable(.{
        .name = "macros",
        .root_module = macros_runner_mod,
    });
    b.installArtifact(macros_runner_exe);

    // Resident AI Provider Options
    const ai_provider_str = b.option([]const u8, "ai-provider", "Resident AI Provider: gemini, openai, anthropic, local_http, mock") orelse "gemini";
    const ai_api_key = b.option([]const u8, "ai-api-key", "Resident AI API Key") orelse
        (b.option([]const u8, "gemini-api-key", "Legacy Gemini API Key alias") orelse "");
    const ai_model = b.option([]const u8, "ai-model", "Resident AI Model name") orelse
        (if (std.mem.eql(u8, ai_provider_str, "openai")) "gpt-4o" else if (std.mem.eql(u8, ai_provider_str, "anthropic")) "claude-3-7-sonnet" else if (std.mem.eql(u8, ai_provider_str, "local_http")) "llama3.3:70b" else "gemini-3.8-flash");
    const ai_endpoint = b.option([]const u8, "ai-endpoint", "Resident AI endpoint host") orelse
        (if (std.mem.eql(u8, ai_provider_str, "openai")) "api.openai.com" else if (std.mem.eql(u8, ai_provider_str, "anthropic")) "api.anthropic.com" else if (std.mem.eql(u8, ai_provider_str, "local_http")) "10.0.2.2" else "generativelanguage.googleapis.com");
    const ai_port = b.option(u16, "ai-port", "Resident AI port (default: 443)") orelse
        (if (std.mem.eql(u8, ai_provider_str, "local_http")) @as(u16, 11434) else @as(u16, 443));
    const ai_use_tls = b.option(bool, "ai-use-tls", "Enable TLS 1.3 encryption (default: true)") orelse
        (!std.mem.eql(u8, ai_provider_str, "local_http") and !std.mem.eql(u8, ai_provider_str, "mock"));

    const kernel_options = b.addOptions();
    kernel_options.addOption([]const u8, "ai_provider", ai_provider_str);
    kernel_options.addOption([]const u8, "ai_api_key", ai_api_key);
    kernel_options.addOption([]const u8, "ai_model", ai_model);
    kernel_options.addOption([]const u8, "ai_endpoint", ai_endpoint);
    kernel_options.addOption(u16, "ai_port", ai_port);
    kernel_options.addOption(bool, "ai_use_tls", ai_use_tls);
    kernel_options.addOption([]const u8, "gemini_api_key", ai_api_key);

    // Stage 1 UEFI Bootloader (boot.efi)
    const uefi_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
    });
    const boot_mod = b.createModule(.{
        .root_source_file = b.path("src/boot.zig"),
        .target = uefi_target,
        .optimize = optimize,
    });
    boot_mod.addAssemblyFile(b.path("src/macros/context_switch.s"));
    boot_mod.addOptions("config", kernel_options);
    const boot_exe = b.addExecutable(.{
        .name = "boot",
        .root_module = boot_mod,
    });
    b.installArtifact(boot_exe);

    // Bare-Metal Microkernel (kernel.elf)
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel.zig"),
        .target = kernel_target,
        .optimize = optimize,
    });
    kernel_mod.addAssemblyFile(b.path("src/macros/context_switch.s"));
    kernel_mod.addOptions("config", kernel_options);
    const kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = kernel_mod,
    });
    b.installArtifact(kernel_exe);

    // Substrate Toolchain
    const ToolDef = struct {
        name: []const u8,
        src: []const u8,
    };
    const tools = [_]ToolDef{
        .{ .name = "micros-bundle", .src = "tools/src/bundle.zig" },
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

    const macros_mod = b.createModule(.{
        .root_source_file = b.path("src/macros.zig"),
        .target = target,
        .optimize = optimize,
    });
    macros_mod.addAssemblyFile(b.path("src/macros/context_switch.s"));
    const macros_test = b.addTest(.{
        .root_module = macros_mod,
    });
    const run_macros_test = b.addRunArtifact(macros_test);
    test_step.dependOn(&run_macros_test.step);

    const msh_test_mod = b.createModule(.{
        .root_source_file = b.path("src/msh.zig"),
        .target = target,
        .optimize = optimize,
    });
    msh_test_mod.addAssemblyFile(b.path("src/macros/context_switch.s"));
    const msh_test = b.addTest(.{
        .root_module = msh_test_mod,
    });
    const run_msh_test = b.addRunArtifact(msh_test);
    test_step.dependOn(&run_msh_test.step);

    const kernel_test_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel.zig"),
        .target = target,
        .optimize = optimize,
    });
    kernel_test_mod.addAssemblyFile(b.path("src/macros/context_switch.s"));
    kernel_test_mod.addOptions("config", kernel_options);
    const kernel_test = b.addTest(.{
        .root_module = kernel_test_mod,
    });
    const run_kernel_test = b.addRunArtifact(kernel_test);
    test_step.dependOn(&run_kernel_test.step);
}
