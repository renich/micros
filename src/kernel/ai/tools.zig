// MicrOS (µOS) Freestanding AI Tool Definition & Schema Registry
// Strictly zero-libc compile-time schemas and type-safe tool declarations.

const std = @import("std");

pub const MAX_TOOL_NAME_LEN: usize = 32;
pub const MAX_HEX_HASH_LEN: usize = 64;

pub const ToolType = enum {
    run_command,
    view_file,
    write_to_file,
    replace_file_content,
    list_dir,
    grep_search,
    spawn_actor,
    grant_capability,
    write_storage,
    read_storage,
    draw_canvas,
    query_telemetry,
};

pub const RunCommandArgs = struct {
    command: []const u8,
};

pub const ViewFileArgs = struct {
    path: []const u8,
};

pub const WriteFileArgs = struct {
    path: []const u8,
    content: []const u8,
};

pub const ReplaceContentArgs = struct {
    path: []const u8,
    target: []const u8,
    replacement: []const u8,
};

pub const ListDirArgs = struct {
    prefix: []const u8,
};

pub const GrepSearchArgs = struct {
    query: []const u8,
};

pub const SpawnActorArgs = struct {
    name: []const u8,
    source: []const u8,
};

pub const GrantCapArgs = struct {
    target_actor: u32,
    source_slot: u32,
    rights_mask: u16,
};

pub const WriteStorageArgs = struct {
    payload: []const u8,
};

pub const ReadStorageArgs = struct {
    hex_hash: [MAX_HEX_HASH_LEN]u8,
};

pub const DrawCanvasArgs = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    color: u32,
};

pub const QueryTelemetryArgs = struct {};

pub const ToolCall = union(ToolType) {
    run_command: RunCommandArgs,
    view_file: ViewFileArgs,
    write_to_file: WriteFileArgs,
    replace_file_content: ReplaceContentArgs,
    list_dir: ListDirArgs,
    grep_search: GrepSearchArgs,
    spawn_actor: SpawnActorArgs,
    grant_capability: GrantCapArgs,
    write_storage: WriteStorageArgs,
    read_storage: ReadStorageArgs,
    draw_canvas: DrawCanvasArgs,
    query_telemetry: QueryTelemetryArgs,
};

pub const TelemetrySnapshot = struct {
    active_actors: u32,
    total_faults: u32,
    free_ram_pages: u32,
    uptime_ticks: u64,
};

pub const ToolResult = union(enum) {
    command_executed: []const u8,
    file_viewed: []const u8,
    file_written: usize,
    content_replaced: bool,
    dir_listed: []const u8,
    search_results: []const u8,
    actor_spawned: u32,
    capability_granted: bool,
    storage_written: [MAX_HEX_HASH_LEN]u8,
    storage_read: []const u8,
    canvas_drawn: void,
    telemetry: TelemetrySnapshot,
    error_msg: []const u8,
};

pub fn parseToolType(name: []const u8) ?ToolType {
    if (std.mem.eql(u8, name, "run_command")) return .run_command;
    if (std.mem.eql(u8, name, "view_file")) return .view_file;
    if (std.mem.eql(u8, name, "write_to_file")) return .write_to_file;
    if (std.mem.eql(u8, name, "replace_file_content")) return .replace_file_content;
    if (std.mem.eql(u8, name, "list_dir")) return .list_dir;
    if (std.mem.eql(u8, name, "grep_search")) return .grep_search;
    if (std.mem.eql(u8, name, "spawn_actor")) return .spawn_actor;
    if (std.mem.eql(u8, name, "grant_capability")) return .grant_capability;
    if (std.mem.eql(u8, name, "write_storage")) return .write_storage;
    if (std.mem.eql(u8, name, "read_storage")) return .read_storage;
    if (std.mem.eql(u8, name, "draw_canvas")) return .draw_canvas;
    if (std.mem.eql(u8, name, "query_telemetry")) return .query_telemetry;
    return null;
}

pub fn toolTypeName(tt: ToolType) []const u8 {
    return switch (tt) {
        .run_command => "run_command",
        .view_file => "view_file",
        .write_to_file => "write_to_file",
        .replace_file_content => "replace_file_content",
        .list_dir => "list_dir",
        .grep_search => "grep_search",
        .spawn_actor => "spawn_actor",
        .grant_capability => "grant_capability",
        .write_storage => "write_storage",
        .read_storage => "read_storage",
        .draw_canvas => "draw_canvas",
        .query_telemetry => "query_telemetry",
    };
}

pub const GEMINI_TOOLS_JSON: []const u8 =
    "[{\"functionDeclarations\":[" ++
    "{\"name\":\"run_command\",\"description\":\"Execute MicroShell command or Macros code snippet\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"command\":{\"type\":\"STRING\",\"description\":\"Command to execute\"}},\"required\":[\"command\"]}}," ++
    "{\"name\":\"view_file\",\"description\":\"View file contents in the sovereign workspace or bundle\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"path\":{\"type\":\"STRING\",\"description\":\"Path to file\"}},\"required\":[\"path\"]}}," ++
    "{\"name\":\"write_to_file\",\"description\":\"Create or overwrite a file in the sovereign workspace\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"path\":{\"type\":\"STRING\",\"description\":\"Target file path\"},\"content\":{\"type\":\"STRING\",\"description\":\"File content to write\"}},\"required\":[\"path\",\"content\"]}}," ++
    "{\"name\":\"replace_file_content\",\"description\":\"Replace target text with replacement text in a workspace file\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"path\":{\"type\":\"STRING\",\"description\":\"File path\"},\"target\":{\"type\":\"STRING\",\"description\":\"Exact text to replace\"},\"replacement\":{\"type\":\"STRING\",\"description\":\"Replacement text\"}},\"required\":[\"path\",\"target\",\"replacement\"]}}," ++
    "{\"name\":\"list_dir\",\"description\":\"List files in the workspace catalog or genesis bundle\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"prefix\":{\"type\":\"STRING\",\"description\":\"Directory prefix or empty string\"}},\"required\":[]}}," ++
    "{\"name\":\"grep_search\",\"description\":\"Search for text pattern in workspace files\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"query\":{\"type\":\"STRING\",\"description\":\"Pattern to search for\"}},\"required\":[\"query\"]}}," ++
    "{\"name\":\"spawn_actor\",\"description\":\"Spawn isolated child actor with Macros source code\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"name\":{\"type\":\"STRING\",\"description\":\"Actor name identifier\"},\"source\":{\"type\":\"STRING\",\"description\":\"Macros source code\"}},\"required\":[\"name\",\"source\"]}}," ++
    "{\"name\":\"grant_capability\",\"description\":\"Attenuate and delegate capability to target actor\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"target_actor\":{\"type\":\"INTEGER\",\"description\":\"Target actor ID\"},\"source_slot\":{\"type\":\"INTEGER\",\"description\":\"Caller source capability slot\"},\"rights_mask\":{\"type\":\"INTEGER\",\"description\":\"Sub-rights mask to grant\"}},\"required\":[\"target_actor\",\"source_slot\",\"rights_mask\"]}}," ++
    "{\"name\":\"write_storage\",\"description\":\"Store immutable payload in Content-Addressed Storage\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"payload\":{\"type\":\"STRING\",\"description\":\"Content to persist\"}},\"required\":[\"payload\"]}}," ++
    "{\"name\":\"read_storage\",\"description\":\"Retrieve payload from Content-Addressed Storage\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"hex_hash\":{\"type\":\"STRING\",\"description\":\"64-character BLAKE3 hex hash\"}},\"required\":[\"hex_hash\"]}}," ++
    "{\"name\":\"draw_canvas\",\"description\":\"Draw solid rectangle on GOP framebuffer\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"x\":{\"type\":\"INTEGER\"},\"y\":{\"type\":\"INTEGER\"},\"w\":{\"type\":\"INTEGER\"},\"h\":{\"type\":\"INTEGER\"},\"color\":{\"type\":\"INTEGER\",\"description\":\"32-bit RGB color\"}},\"required\":[\"x\",\"y\",\"w\",\"h\",\"color\"]}}," ++
    "{\"name\":\"query_telemetry\",\"description\":\"Query active actors, fault count, memory, and uptime\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{}}}" ++
    "]}]";

pub const OPENAI_TOOLS_JSON: []const u8 =
    "[" ++
    "{\"type\":\"function\",\"function\":{\"name\":\"run_command\",\"description\":\"Execute MicroShell command or Macros code snippet\",\"parameters\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"view_file\",\"description\":\"View file contents in the sovereign workspace or bundle\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"write_to_file\",\"description\":\"Create or overwrite a file in the sovereign workspace\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"replace_file_content\",\"description\":\"Replace target text with replacement text in a workspace file\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"target\":{\"type\":\"string\"},\"replacement\":{\"type\":\"string\"}},\"required\":[\"path\",\"target\",\"replacement\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"list_dir\",\"description\":\"List files in the workspace catalog or genesis bundle\",\"parameters\":{\"type\":\"object\",\"properties\":{\"prefix\":{\"type\":\"string\"}},\"required\":[]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"grep_search\",\"description\":\"Search for text pattern in workspace files\",\"parameters\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"spawn_actor\",\"description\":\"Spawn isolated child actor with Macros source code\",\"parameters\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"source\":{\"type\":\"string\"}},\"required\":[\"name\",\"source\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"grant_capability\",\"description\":\"Attenuate and delegate capability to target actor\",\"parameters\":{\"type\":\"object\",\"properties\":{\"target_actor\":{\"type\":\"integer\"},\"source_slot\":{\"type\":\"integer\"},\"rights_mask\":{\"type\":\"integer\"}},\"required\":[\"target_actor\",\"source_slot\",\"rights_mask\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"write_storage\",\"description\":\"Store immutable payload in Content-Addressed Storage\",\"parameters\":{\"type\":\"object\",\"properties\":{\"payload\":{\"type\":\"string\"}},\"required\":[\"payload\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"read_storage\",\"description\":\"Retrieve payload from Content-Addressed Storage\",\"parameters\":{\"type\":\"object\",\"properties\":{\"hex_hash\":{\"type\":\"string\"}},\"required\":[\"hex_hash\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"draw_canvas\",\"description\":\"Draw solid rectangle on GOP framebuffer\",\"parameters\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"integer\"},\"y\":{\"type\":\"integer\"},\"w\":{\"type\":\"integer\"},\"h\":{\"type\":\"integer\"},\"color\":{\"type\":\"integer\"}},\"required\":[\"x\",\"y\",\"w\",\"h\",\"color\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"query_telemetry\",\"description\":\"Query active actors, fault count, memory, and uptime\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}" ++
    "]";

test "tool type parsing and name formatting roundtrip" {
    const ttypes = [_]ToolType{
        .run_command,
        .view_file,
        .write_to_file,
        .replace_file_content,
        .list_dir,
        .grep_search,
        .spawn_actor,
        .grant_capability,
        .write_storage,
        .read_storage,
        .draw_canvas,
        .query_telemetry,
    };
    for (ttypes) |tt| {
        const name = toolTypeName(tt);
        const parsed = parseToolType(name);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(tt, parsed.?);
    }
    try std.testing.expect(parseToolType("non_existent_tool") == null);
}

test "comptime tool schemas structure and validity" {
    try std.testing.expect(GEMINI_TOOLS_JSON.len > 0);
    try std.testing.expect(OPENAI_TOOLS_JSON.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, GEMINI_TOOLS_JSON, "functionDeclarations") != null);
    try std.testing.expect(std.mem.indexOf(u8, GEMINI_TOOLS_JSON, "run_command") != null);
    try std.testing.expect(std.mem.indexOf(u8, GEMINI_TOOLS_JSON, "view_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, GEMINI_TOOLS_JSON, "write_to_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, GEMINI_TOOLS_JSON, "spawn_actor") != null);
    try std.testing.expect(std.mem.indexOf(u8, OPENAI_TOOLS_JSON, "run_command") != null);
    try std.testing.expect(std.mem.indexOf(u8, OPENAI_TOOLS_JSON, "query_telemetry") != null);
}

test "tool call tagged union initialization" {
    const call = ToolCall{
        .draw_canvas = .{
            .x = 10,
            .y = 20,
            .w = 100,
            .h = 50,
            .color = 0xFF00FF,
        },
    };
    try std.testing.expectEqual(ToolType.draw_canvas, @as(ToolType, call));
    try std.testing.expectEqual(@as(u32, 10), call.draw_canvas.x);
    try std.testing.expectEqual(@as(u32, 20), call.draw_canvas.y);
    try std.testing.expectEqual(@as(u32, 100), call.draw_canvas.w);
    try std.testing.expectEqual(@as(u32, 50), call.draw_canvas.h);
    try std.testing.expectEqual(@as(u32, 0xFF00FF), call.draw_canvas.color);
}
