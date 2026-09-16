pub const lexer = @import("macros/lexer.zig");
pub const ast = @import("macros/ast.zig");

test "macros module tests" {
    _ = @import("macros/lexer.zig");
    _ = @import("macros/ast.zig");
}
