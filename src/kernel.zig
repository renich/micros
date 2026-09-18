// MicrOS Freestanding Microkernel Root (kernel.elf)
pub const kmain = @import("kernel/main.zig").kmain;
pub const cap = @import("kernel/cap/capability.zig");
pub const cspace = @import("kernel/cap/cspace.zig");
pub const actor = @import("kernel/actor.zig");
pub const ipc = @import("kernel/ipc/ring.zig");
pub const bundle = @import("kernel/bundle.zig");
pub const events = @import("kernel/ipc/events.zig");
pub const ps2_kbd = @import("kernel/drivers/ps2_kbd.zig");
pub const supervisor = @import("kernel/supervisor.zig");
pub const abi = @import("kernel/abi.zig");
pub const harness_bindings = @import("kernel/harness_bindings.zig");
pub const io = @import("kernel/arch/x86_64/io.zig");
pub const pci = @import("kernel/drivers/pci.zig");
pub const virtio_net = @import("kernel/drivers/virtio_net.zig");
pub const virtio_blk = @import("kernel/drivers/virtio_blk.zig");
pub const block = @import("kernel/drivers/block.zig");
pub const gpt = @import("kernel/drivers/gpt.zig");
pub const nvme = @import("kernel/drivers/nvme.zig");
pub const block_cache = @import("kernel/storage/block_cache.zig");
pub const cas_chunk = @import("kernel/storage/chunk.zig");
pub const cas = @import("kernel/storage/cas.zig");
pub const fat32 = @import("kernel/storage/fat32.zig");
pub const rebuild = @import("kernel/storage/rebuild.zig");
pub const bundle_writer = @import("kernel/storage/bundle_writer.zig");
pub const kernel_synthesizer = @import("kernel/storage/kernel_synthesizer.zig");
pub const storage_abi = @import("kernel/storage/storage_abi.zig");
pub const pe_emitter = @import("boot/pe_emitter.zig");
pub const net = @import("kernel/net.zig");
pub const ai = @import("kernel/ai.zig");
pub const compositor = @import("kernel/compositor.zig");

test "kernel module tests" {
    _ = @import("kernel/cap/capability.zig");
    _ = @import("kernel/cap/cspace.zig");
    _ = @import("kernel/actor.zig");
    _ = @import("kernel/ipc/ring.zig");
    _ = @import("kernel/ipc/events.zig");
    _ = @import("kernel/drivers/ps2_kbd.zig");
    _ = @import("kernel/bundle.zig");
    _ = @import("kernel/fb.zig");
    _ = @import("kernel/supervisor.zig");
    _ = @import("kernel/abi.zig");
    _ = @import("kernel/harness_bindings.zig");
    _ = @import("kernel/arch/x86_64/io.zig");
    _ = @import("kernel/drivers/pci.zig");
    _ = @import("kernel/drivers/virtio_net.zig");
    _ = @import("kernel/drivers/virtio_blk.zig");
    _ = @import("kernel/drivers/block.zig");
    _ = @import("kernel/drivers/gpt.zig");
    _ = @import("kernel/drivers/nvme.zig");
    _ = @import("kernel/storage/block_cache.zig");
    _ = @import("kernel/storage/chunk.zig");
    _ = @import("kernel/storage/cas.zig");
    _ = @import("kernel/storage/fat32.zig");
    _ = @import("kernel/storage/rebuild.zig");
    _ = @import("kernel/storage/bundle_writer.zig");
    _ = @import("kernel/storage/kernel_synthesizer.zig");
    _ = @import("kernel/storage/storage_abi.zig");
    _ = @import("boot/pe_emitter.zig");
    _ = @import("kernel/net.zig");
    _ = @import("kernel/ai.zig");
    _ = @import("kernel/compositor.zig");
}

test "Genesis Bundle contains and compiles init.mx" {
    const std_mod = @import("std");
    const raw_bundle = @embedFile("kernel/genesis.mcb");
    const reader = try @import("kernel/bundle.zig").BundleReader.init(raw_bundle);
    const init_source = reader.findData("init.mx").?;

    var chunk = @import("macros/chunk.zig").Chunk.init();
    defer chunk.deinit(std_mod.testing.allocator);

    var compiler = @import("macros/compiler.zig").Compiler.init(std_mod.testing.allocator, &chunk);
    var p = @import("macros/parser.zig").Parser.init(std_mod.testing.allocator, init_source);
    while (p.current_token.token_type != .eof) {
        const stmt = try p.parseStatement();
        defer stmt.deinit(std_mod.testing.allocator);
        try compiler.compile(stmt);
    }
    try chunk.writeChunk(std_mod.testing.allocator, @intFromEnum(@import("macros/chunk.zig").OpCode.return_op));
    try std_mod.testing.expect(chunk.code.items.len > 0);
}

test "Genesis Bundle contains and compiles msh.mx" {
    const std_mod = @import("std");
    const raw_bundle = @embedFile("kernel/genesis.mcb");
    const reader = try @import("kernel/bundle.zig").BundleReader.init(raw_bundle);
    const msh_source = reader.findData("msh.mx").?;

    var chunk = @import("macros/chunk.zig").Chunk.init();
    defer chunk.deinit(std_mod.testing.allocator);

    var compiler = @import("macros/compiler.zig").Compiler.init(std_mod.testing.allocator, &chunk);
    var p = @import("macros/parser.zig").Parser.init(std_mod.testing.allocator, msh_source);
    while (p.current_token.token_type != .eof) {
        const stmt = try p.parseStatement();
        defer stmt.deinit(std_mod.testing.allocator);
        try compiler.compile(stmt);
    }
    try chunk.writeChunk(std_mod.testing.allocator, @intFromEnum(@import("macros/chunk.zig").OpCode.return_op));
    try std_mod.testing.expect(chunk.code.items.len > 0);
}

test "Genesis Bundle contains and compiles harness.mx" {
    const std_mod = @import("std");
    const raw_bundle = @embedFile("kernel/genesis.mcb");
    const reader = try @import("kernel/bundle.zig").BundleReader.init(raw_bundle);
    const harness_source = reader.findData("harness.mx").?;

    var chunk = @import("macros/chunk.zig").Chunk.init();
    defer chunk.deinit(std_mod.testing.allocator);

    var compiler = @import("macros/compiler.zig").Compiler.init(std_mod.testing.allocator, &chunk);
    var p = @import("macros/parser.zig").Parser.init(std_mod.testing.allocator, harness_source);
    while (p.current_token.token_type != .eof) {
        const stmt = try p.parseStatement();
        defer stmt.deinit(std_mod.testing.allocator);
        try compiler.compile(stmt);
    }
    try chunk.writeChunk(std_mod.testing.allocator, @intFromEnum(@import("macros/chunk.zig").OpCode.return_op));
    try std_mod.testing.expect(chunk.code.items.len > 0);
}

test "Genesis Bundle contains and compiles installer.mx" {
    const std_mod = @import("std");
    const raw_bundle = @embedFile("kernel/genesis.mcb");
    const reader = try @import("kernel/bundle.zig").BundleReader.init(raw_bundle);
    const installer_source = reader.findData("installer.mx").?;

    var chunk = @import("macros/chunk.zig").Chunk.init();
    defer chunk.deinit(std_mod.testing.allocator);

    var compiler = @import("macros/compiler.zig").Compiler.init(std_mod.testing.allocator, &chunk);
    var p = @import("macros/parser.zig").Parser.init(std_mod.testing.allocator, installer_source);
    while (p.current_token.token_type != .eof) {
        const stmt = try p.parseStatement();
        defer stmt.deinit(std_mod.testing.allocator);
        try compiler.compile(stmt);
    }
    try chunk.writeChunk(std_mod.testing.allocator, @intFromEnum(@import("macros/chunk.zig").OpCode.return_op));
    try std_mod.testing.expect(chunk.code.items.len > 0);
}

test "Genesis Bundle contains and compiles bundle.mx" {
    const std_mod = @import("std");
    const raw_bundle = @embedFile("kernel/genesis.mcb");
    const reader = try @import("kernel/bundle.zig").BundleReader.init(raw_bundle);
    const bundle_source = reader.findData("bundle.mx").?;

    var chunk = @import("macros/chunk.zig").Chunk.init();
    defer chunk.deinit(std_mod.testing.allocator);

    var compiler = @import("macros/compiler.zig").Compiler.init(std_mod.testing.allocator, &chunk);
    var p = @import("macros/parser.zig").Parser.init(std_mod.testing.allocator, bundle_source);
    while (p.current_token.token_type != .eof) {
        const stmt = try p.parseStatement();
        defer stmt.deinit(std_mod.testing.allocator);
        try compiler.compile(stmt);
    }
    try chunk.writeChunk(std_mod.testing.allocator, @intFromEnum(@import("macros/chunk.zig").OpCode.return_op));
    try std_mod.testing.expect(chunk.code.items.len > 0);
}

test "Genesis Bundle contains and compiles rebuild.mx" {
    const std_mod = @import("std");
    const raw_bundle = @embedFile("kernel/genesis.mcb");
    const reader = try @import("kernel/bundle.zig").BundleReader.init(raw_bundle);
    const rebuild_source = reader.findData("rebuild.mx").?;

    var chunk = @import("macros/chunk.zig").Chunk.init();
    defer chunk.deinit(std_mod.testing.allocator);

    var compiler = @import("macros/compiler.zig").Compiler.init(std_mod.testing.allocator, &chunk);
    var p = @import("macros/parser.zig").Parser.init(std_mod.testing.allocator, rebuild_source);
    while (p.current_token.token_type != .eof) {
        const stmt = try p.parseStatement();
        defer stmt.deinit(std_mod.testing.allocator);
        try compiler.compile(stmt);
    }
    try chunk.writeChunk(std_mod.testing.allocator, @intFromEnum(@import("macros/chunk.zig").OpCode.return_op));
    try std_mod.testing.expect(chunk.code.items.len > 0);
}

test "Genesis Bundle contains and compiles http_server.mx" {
    const std_mod = @import("std");
    const raw_bundle = @embedFile("kernel/genesis.mcb");
    const reader = try @import("kernel/bundle.zig").BundleReader.init(raw_bundle);
    const http_source = reader.findData("http_server.mx").?;

    var chunk = @import("macros/chunk.zig").Chunk.init();
    defer chunk.deinit(std_mod.testing.allocator);

    var compiler = @import("macros/compiler.zig").Compiler.init(std_mod.testing.allocator, &chunk);
    var p = @import("macros/parser.zig").Parser.init(std_mod.testing.allocator, http_source);
    while (p.current_token.token_type != .eof) {
        const stmt = try p.parseStatement();
        defer stmt.deinit(std_mod.testing.allocator);
        try compiler.compile(stmt);
    }
    try chunk.writeChunk(std_mod.testing.allocator, @intFromEnum(@import("macros/chunk.zig").OpCode.return_op));
    try std_mod.testing.expect(chunk.code.items.len > 0);
}

test "Compiles and executes MOCK_RESPONSE code block" {
    const std_mod = @import("std");
    const source =
        \\sys_serial_write("[MockAi] System ready.\n");
        \\sys_fb_draw_string(50, 50, "MICROS OFFLINE HARNESS", 65280, 0);
    ;
    var chunk = @import("macros/chunk.zig").Chunk.init();
    defer chunk.deinit(std_mod.testing.allocator);

    var compiler = @import("macros/compiler.zig").Compiler.init(std_mod.testing.allocator, &chunk);
    var p = @import("macros/parser.zig").Parser.init(std_mod.testing.allocator, source);
    while (p.current_token.token_type != .eof) {
        const stmt = try p.parseStatement();
        defer stmt.deinit(std_mod.testing.allocator);
        try compiler.compile(stmt);
    }
    try chunk.writeChunk(std_mod.testing.allocator, @intFromEnum(@import("macros/chunk.zig").OpCode.return_op));

    var vm = try @import("macros/vm.zig").VM.init(std_mod.testing.allocator, &chunk);
    defer vm.deinit();
    try @import("kernel/harness_bindings.zig").registerBindings(&vm);
    try vm.run(0);
}

var test_serial_input: []const u8 = "ai spawn worker\rexit\r";
var test_serial_idx: usize = 0;

fn testSerialRead(vm_ptr: *anyopaque, args: []@import("macros/eval.zig").Value) anyerror!@import("macros/eval.zig").Value {
    _ = vm_ptr;
    _ = args;
    if (test_serial_idx < test_serial_input.len) {
        const c = test_serial_input[test_serial_idx];
        test_serial_idx += 1;
        return @import("macros/eval.zig").Value{ .integer = @as(i64, c) };
    }
    return @import("macros/eval.zig").Value{ .integer = -1 };
}

fn testAiPromptMock(vm_ptr: *anyopaque, args: []@import("macros/eval.zig").Value) anyerror!@import("macros/eval.zig").Value {
    _ = vm_ptr;
    _ = args;
    const resp =
        "Status: MOCK-0001\n\n" ++
        ".. code-block:: macros\n\n" ++
        "   sys_serial_write(\"[MockAi] Hello\\n\");\n" ++
        "   sys_fb_draw_string(50, 50, \"MICROS\", 65280, 0);\n";
    return @import("macros/eval.zig").Value{ .string = resp };
}

fn testSpawnCodeMock(allocator: @import("std").mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 {
    _ = allocator;
    _ = name;
    _ = source;
    return 1;
}

test "Harness VM stack depth tracking with simulated commands" {
    const std_mod = @import("std");
    const raw_bundle = @embedFile("kernel/genesis.mcb");
    const reader = try @import("kernel/bundle.zig").BundleReader.init(raw_bundle);
    const harness_source = reader.findData("harness.mx").?;

    var chunk = @import("macros/chunk.zig").Chunk.init();
    defer chunk.deinit(std_mod.heap.page_allocator);

    var compiler = @import("macros/compiler.zig").Compiler.init(std_mod.heap.page_allocator, &chunk);
    var p = @import("macros/parser.zig").Parser.init(std_mod.heap.page_allocator, harness_source);
    while (p.current_token.token_type != .eof) {
        const stmt = try p.parseStatement();
        defer stmt.deinit(std_mod.heap.page_allocator);
        try compiler.compile(stmt);
    }
    try chunk.writeChunk(std_mod.heap.page_allocator, @intFromEnum(@import("macros/chunk.zig").OpCode.return_op));

    var vm = try @import("macros/vm.zig").VM.init(std_mod.heap.page_allocator, &chunk);
    defer vm.deinit();

    var registry = @import("kernel/actor.zig").ActorRegistry.init();
    var sup_actor = try @import("kernel/actor.zig").Actor.init(std_mod.heap.page_allocator, 0, "genesis", 16, 0);
    defer sup_actor.deinit(std_mod.heap.page_allocator);

    var ctx = @import("kernel/harness_bindings.zig").HarnessContext{
        .registry = &registry,
        .supervisor = sup_actor,
        .framebuffer = null,
        .ipc_ring = null,
        .supervisor_ctrl = null,
        .spawn_code_fn = testSpawnCodeMock,
    };
    @import("kernel/harness_bindings.zig").setContext(&ctx);
    defer @import("kernel/harness_bindings.zig").clearContext();
    try @import("kernel/harness_bindings.zig").registerBindings(&vm);
    try vm.globals.put("sys_serial_read", @import("macros/eval.zig").Value{ .native = testSerialRead });
    try vm.globals.put("sys_ai_prompt", @import("macros/eval.zig").Value{ .native = testAiPromptMock });
    try vm.run(0);
    try std_mod.testing.expect(vm.sp <= 48);
}

test "Tokenize mock extracted code" {
    const std_mod = @import("std");
    const source = "\n   sys_serial_write(\"[MockAi] System ready.\");\n   sys_fb_draw_string(50, 50, \"MICROS OFFLINE HARNESS\", 65280, 0);\n";
    var lex = @import("macros/lexer.zig").Lexer.init(source);
    const first_tok = lex.nextToken();
    try std_mod.testing.expectEqualStrings("sys_serial_write", first_tok.lexeme);
}

test "Tool call dispatch with actor_control capability succeeds" {
    const std_mod = @import("std");
    const allocator = std_mod.testing.allocator;

    var chunk = @import("macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try @import("macros/vm.zig").VM.init(allocator, &chunk);
    defer vm.deinit();

    var registry = @import("kernel/actor.zig").ActorRegistry.init();
    var harness_actor = try @import("kernel/actor.zig").Actor.init(allocator, 2, "harness", 16, 0);
    defer harness_actor.deinit(allocator);

    _ = try harness_actor.insertCap(@import("kernel/cap/capability.zig").Capability{
        .cap_type = .actor_control,
        .rights = @import("kernel/cap/capability.zig").Rights.ALL,
        .object_id = 6,
        .data_addr = 0,
        .data_size = 0,
    });

    var ctx = @import("kernel/abi.zig").AbiContext{
        .registry = &registry,
        .supervisor = harness_actor,
        .spawn_code_fn = testSpawnCodeMock,
    };
    @import("kernel/abi.zig").setContext(&ctx);
    defer @import("kernel/abi.zig").clearContext();

    try @import("kernel/abi.zig").registerSyscalls(&vm);

    const tool_call_json =
        "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"spawn_actor\",\"args\":{\"name\":\"worker\",\"source\":\"print(1);\"}}}]}}]}";
    var tool_args = [_]@import("macros/eval.zig").Value{
        @import("macros/eval.zig").Value{ .string = tool_call_json },
    };
    const res = try vm.globals.get("sys_ai_tool_call").?.native(&vm, &tool_args);
    defer allocator.free(res.string);

    try std_mod.testing.expect(std_mod.mem.indexOf(u8, res.string, "\"status\":\"ok\"") != null);
    try std_mod.testing.expect(std_mod.mem.indexOf(u8, res.string, "\"actor_id\":1") != null);
}

test "Tool call dispatch without actor_control capability fails with PermissionDenied" {
    const std_mod = @import("std");
    const allocator = std_mod.testing.allocator;

    var chunk = @import("macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try @import("macros/vm.zig").VM.init(allocator, &chunk);
    defer vm.deinit();

    var registry = @import("kernel/actor.zig").ActorRegistry.init();
    var unpriv_actor = try @import("kernel/actor.zig").Actor.init(allocator, 5, "untrusted", 16, 0);
    defer unpriv_actor.deinit(allocator);

    var ctx = @import("kernel/abi.zig").AbiContext{
        .registry = &registry,
        .supervisor = unpriv_actor,
        .spawn_code_fn = testSpawnCodeMock,
    };
    @import("kernel/abi.zig").setContext(&ctx);
    defer @import("kernel/abi.zig").clearContext();

    try @import("kernel/abi.zig").registerSyscalls(&vm);

    const tool_call_json =
        "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"spawn_actor\",\"args\":{\"name\":\"worker\",\"source\":\"print(1);\"}}}]}}]}";
    var tool_args = [_]@import("macros/eval.zig").Value{
        @import("macros/eval.zig").Value{ .string = tool_call_json },
    };
    const res = try vm.globals.get("sys_ai_tool_call").?.native(&vm, &tool_args);
    defer allocator.free(res.string);

    try std_mod.testing.expect(std_mod.mem.indexOf(u8, res.string, "PermissionDenied: actor_control.EXECUTE required") != null);
}
