pub const lexer = @import("macros/lexer.zig");
pub const ast = @import("macros/ast.zig");
pub const parser = @import("macros/parser.zig");
pub const eval = @import("macros/eval.zig");
pub const immix = @import("macros/immix.zig");
pub const fiber = @import("macros/fiber.zig");
pub const chunk = @import("macros/chunk.zig");
pub const vm = @import("macros/vm.zig");

test "macros module tests" {
    _ = @import("macros/lexer.zig");
    _ = @import("macros/ast.zig");
    _ = @import("macros/parser.zig");
    _ = @import("macros/eval.zig");
    _ = @import("macros/immix.zig");
    _ = @import("macros/fiber.zig");
    _ = @import("macros/chunk.zig");
    _ = @import("macros/vm.zig");
}
pub const gc = @import("macros/gc.zig");
pub const compiler = @import("macros/compiler.zig");
pub const tracer = @import("macros/tracer.zig");
pub const serializer = @import("macros/serializer.zig");
pub const codegen_x86_64 = @import("macros/codegen_x86_64.zig");
pub const module = @import("macros/module.zig");
pub const builtins = @import("macros/builtins.zig");

test "macros module tests 2" {
    _ = @import("macros/gc.zig");
    _ = @import("macros/compiler.zig");
    _ = @import("macros/tracer.zig");
    _ = @import("macros/serializer.zig");
    _ = @import("macros/codegen_x86_64.zig");
    _ = @import("macros/module.zig");
    _ = @import("macros/builtins.zig");
}

test "macros full mathematical pipeline end-to-end" {
    const testing = @import("std").testing;
    const source =
        \\fn compute() {
        \\    x = 10;
        \\    y = 3;
        \\    mult = x * y;
        \\    div = mult / 5;
        \\    mod = div % 4;
        \\    shl = mod << 3;
        \\    masked = (shl | 1) & 15;
        \\    neg = -masked;
        \\    return neg;
        \\}
        \\return compute();
    ;
    var p = parser.Parser.init(testing.allocator, source);
    var ch = chunk.Chunk.init();
    defer ch.deinit(testing.allocator);
    var comp = compiler.Compiler.init(testing.allocator, &ch);

    while (p.current_token.token_type != .eof) {
        const stmt = try p.parseStatement();
        defer stmt.deinit(testing.allocator);
        try comp.compile(stmt);
    }

    var v = try vm.VM.init(testing.allocator, &ch);
    defer v.deinit();
    try v.run(0);

    const res = try v.pop();
    try testing.expectEqual(eval.Value{ .integer = -1 }, res);
}
