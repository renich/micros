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
pub const harness_bindings = @import("kernel/harness_bindings.zig");
pub const io = @import("kernel/arch/x86_64/io.zig");
pub const pci = @import("kernel/drivers/pci.zig");
pub const virtio_net = @import("kernel/drivers/virtio_net.zig");
pub const net = @import("kernel/net.zig");
pub const ai = @import("kernel/ai.zig");

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
    _ = @import("kernel/harness_bindings.zig");
    _ = @import("kernel/arch/x86_64/io.zig");
    _ = @import("kernel/drivers/pci.zig");
    _ = @import("kernel/drivers/virtio_net.zig");
    _ = @import("kernel/net.zig");
    _ = @import("kernel/ai.zig");
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

test "Compiles and executes MOCK_RESPONSE code block" {
    const std_mod = @import("std");
    const source =
        \\sys_serial_write("[MockAi] Autonomous sovereign directive active.\n");
        \\sys_fb_draw_string(50, 50, "MICROS OFFLINE SOVEREIGN HARNESS", 65280, 0);
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
        "Sovereign Directive: MOCK-0001\n\n" ++
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
    try std_mod.testing.expect(vm.sp <= 32);
}

test "Tokenize mock extracted code" {
    const std_mod = @import("std");
    const source = "\n   sys_serial_write(\"[MockAi] Autonomous sovereign directive active.\");\n   sys_fb_draw_string(50, 50, \"MICROS OFFLINE SOVEREIGN HARNESS\", 65280, 0);\n";
    var lex = @import("macros/lexer.zig").Lexer.init(source);
    const first_tok = lex.nextToken();
    try std_mod.testing.expectEqualStrings("sys_serial_write", first_tok.lexeme);
}

