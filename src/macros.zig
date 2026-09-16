pub const lexer = @import("macros/lexer.zig");
pub const ast = @import("macros/ast.zig");
pub const parser = @import("macros/parser.zig");
pub const eval = @import("macros/eval.zig");

test "macros module tests" {
    _ = @import("macros/lexer.zig");
    _ = @import("macros/ast.zig");
    _ = @import("macros/parser.zig");
    _ = @import("macros/eval.zig");
}
