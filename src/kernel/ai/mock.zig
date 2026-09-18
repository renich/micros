// MicrOS (µOS) Freestanding Mock Resident AI Driver
// Deterministic offline cognitive supervisor for air-gapped systems and CI testing.

const std = @import("std");

pub const MOCK_RESPONSE: []const u8 =
    "Status: MOCK-0001 Offline Mode\n" ++
    "==============================\n\n" ++
    "Operating system parameters verified in air-gapped mode.\n\n" ++
    ".. code-block:: macros\n\n" ++
    "   sys_serial_write(\"[MockAi] System ready.\\n\");\n" ++
    "   sys_fb_draw_string(50, 50, \"MICROS OFFLINE HARNESS\", 65280, 0);\n";

pub const MOCK_TOOL_RESPONSE: []const u8 =
    "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"spawn_actor\"," ++
    "\"args\":{\"name\":\"mock_actor\",\"source\":\"sys_actor_count();\"}}}]}}]}";

pub const MOCK_LIST_DIR_RESPONSE: []const u8 =
    "{\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"list_dir\"," ++
    "\"args\":{\"prefix\":\"\"}}}]}}]}";

pub const MOCK_GREETING_RESPONSE: []const u8 =
    "Status: MOCK-0001 (agy offline mode)\n" ++
    "Hello! I am your Resident AI agent (agy mode). I have tools to inspect your workspace (view_file, list_dir, grep_search), edit code (write_to_file, replace_file_content), run commands (run_command), and manage actors (spawn_actor). How can I help you with MicrOS today?";

pub const MOCK_TOOL_FOLLOWUP_RESPONSE: []const u8 =
    "Tool execution completed successfully. Workspace catalog and system state verified.";

pub fn generateResponse(user_prompt: []const u8, out_buf: []u8) !usize {
    const resp = if (std.mem.indexOf(u8, user_prompt, "Tool result:") != null)
        MOCK_TOOL_FOLLOWUP_RESPONSE
    else if (std.mem.indexOf(u8, user_prompt, "tool") != null)
        MOCK_TOOL_RESPONSE
    else if (std.mem.indexOf(u8, user_prompt, "list") != null or std.mem.indexOf(u8, user_prompt, "ls") != null)
        MOCK_LIST_DIR_RESPONSE
    else if (std.mem.indexOf(u8, user_prompt, "hello") != null or std.mem.indexOf(u8, user_prompt, "Hello") != null or
        std.mem.indexOf(u8, user_prompt, "hi") != null or std.mem.indexOf(u8, user_prompt, "Hi") != null)
        MOCK_GREETING_RESPONSE
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
