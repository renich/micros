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

pub fn generateResponse(user_prompt: []const u8, out_buf: []u8) !usize {
    _ = user_prompt;
    if (out_buf.len < MOCK_RESPONSE.len) return error.BufferTooSmall;
    @memcpy(out_buf[0..MOCK_RESPONSE.len], MOCK_RESPONSE);
    return MOCK_RESPONSE.len;
}

test "mock ai response generation" {
    var buf: [512]u8 = undefined;
    const len = try generateResponse("status", &buf);
    try std.testing.expect(len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "MOCK-0001") != null);
}
