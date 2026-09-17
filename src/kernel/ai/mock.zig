// MicrOS (µOS) Freestanding Mock Resident AI Driver
// Deterministic offline cognitive supervisor for air-gapped systems and CI testing.

const std = @import("std");

pub const MOCK_RESPONSE: []const u8 =
    "Sovereign Directive: MOCK-0001 Offline Mode\n" ++
    "===========================================\n\n" ++
    "Operating system parameters verified in air-gapped mode.\n\n" ++
    ".. code-block:: macros\n\n" ++
    "   sys_serial_write(\"[MockAi] Autonomous sovereign directive active.\\n\");\n" ++
    "   sys_fb_draw_string(50, 50, \"MICROS OFFLINE SOVEREIGN HARNESS\", 65280, 0);\n";

pub const MOCK_TOOL_RESPONSE: []const u8 =
    "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"spawn_actor\"," ++
    "\"args\":{\"name\":\"mock_actor\",\"source\":\"sys_actor_count();\"}}}]}}]}";

pub fn generateResponse(user_prompt: []const u8, out_buf: []u8) !usize {
    const resp = if (std.mem.indexOf(u8, user_prompt, "tool") != null)
        MOCK_TOOL_RESPONSE
    else
        MOCK_RESPONSE;
    if (out_buf.len < resp.len) return error.BufferTooSmall;
    @memcpy(out_buf[0..resp.len], resp);
    return resp.len;
}

test "mock ai response generation" {
    var buf: [512]u8 = undefined;
    const len = try generateResponse("status", &buf);
    try std.testing.expect(len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "MOCK-0001") != null);

    const tool_len = try generateResponse("call tool now", &buf);
    try std.testing.expect(tool_len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..tool_len], "functionCall") != null);
}
