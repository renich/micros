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
