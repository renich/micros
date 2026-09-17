// MicrOS (µOS) Resident AI Subsystem Root
// Zero-libc, provider-agnostic cognitive substrate for CSpace 0 Sovereign Intelligence.

pub const provider = @import("ai/provider.zig");
pub const client = @import("ai/client.zig");
pub const gemini = @import("ai/gemini.zig");
pub const openai = @import("ai/openai.zig");
pub const mock = @import("ai/mock.zig");
pub const tools = @import("ai/tools.zig");
pub const tool_parser = @import("ai/tool_parser.zig");
pub const dispatcher = @import("ai/dispatcher.zig");

test "ai subsystem tests" {
    _ = @import("ai/provider.zig");
    _ = @import("ai/client.zig");
    _ = @import("ai/gemini.zig");
    _ = @import("ai/openai.zig");
    _ = @import("ai/mock.zig");
    _ = @import("ai/tools.zig");
    _ = @import("ai/tool_parser.zig");
    _ = @import("ai/dispatcher.zig");
}
