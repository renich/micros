// MicrOS (µOS) Freestanding AI Tool Definition & Schema Registry
// Strictly zero-libc compile-time schemas and type-safe tool declarations.

const std = @import("std");

pub const MAX_TOOL_NAME_LEN: usize = 32;
pub const MAX_HEX_HASH_LEN: usize = 64;

pub const ToolType = enum {
    spawn_actor,
    grant_capability,
    write_storage,
    read_storage,
    draw_canvas,
    query_telemetry,
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
    actor_spawned: u32,
    capability_granted: bool,
    storage_written: [MAX_HEX_HASH_LEN]u8,
    storage_read: []const u8,
    canvas_drawn: void,
    telemetry: TelemetrySnapshot,
    error_msg: []const u8,
};

pub fn parseToolType(name: []const u8) ?ToolType {
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
    "{\"name\":\"spawn_actor\",\"description\":\"Spawn isolated child actor with Macros source code\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"name\":{\"type\":\"STRING\",\"description\":\"Actor name identifier\"},\"source\":{\"type\":\"STRING\",\"description\":\"Macros source code\"}},\"required\":[\"name\",\"source\"]}}," ++
    "{\"name\":\"grant_capability\",\"description\":\"Attenuate and delegate capability to target actor\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"target_actor\":{\"type\":\"INTEGER\",\"description\":\"Target actor ID\"},\"source_slot\":{\"type\":\"INTEGER\",\"description\":\"Caller source capability slot\"},\"rights_mask\":{\"type\":\"INTEGER\",\"description\":\"Sub-rights mask to grant\"}},\"required\":[\"target_actor\",\"source_slot\",\"rights_mask\"]}}," ++
    "{\"name\":\"write_storage\",\"description\":\"Store immutable payload in Content-Addressed Storage\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"payload\":{\"type\":\"STRING\",\"description\":\"Content to persist\"}},\"required\":[\"payload\"]}}," ++
    "{\"name\":\"read_storage\",\"description\":\"Retrieve payload from Content-Addressed Storage\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"hex_hash\":{\"type\":\"STRING\",\"description\":\"64-character BLAKE3 hex hash\"}},\"required\":[\"hex_hash\"]}}," ++
    "{\"name\":\"draw_canvas\",\"description\":\"Draw solid rectangle on GOP framebuffer\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{\"x\":{\"type\":\"INTEGER\"},\"y\":{\"type\":\"INTEGER\"},\"w\":{\"type\":\"INTEGER\"},\"h\":{\"type\":\"INTEGER\"},\"color\":{\"type\":\"INTEGER\",\"description\":\"32-bit RGB color\"}},\"required\":[\"x\",\"y\",\"w\",\"h\",\"color\"]}}," ++
    "{\"name\":\"query_telemetry\",\"description\":\"Query active actors, fault count, memory, and uptime\",\"parameters\":{\"type\":\"OBJECT\",\"properties\":{}}}" ++
    "]}]";

pub const OPENAI_TOOLS_JSON: []const u8 =
    "[" ++
    "{\"type\":\"function\",\"function\":{\"name\":\"spawn_actor\",\"description\":\"Spawn isolated child actor with Macros source code\",\"parameters\":{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"source\":{\"type\":\"string\"}},\"required\":[\"name\",\"source\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"grant_capability\",\"description\":\"Attenuate and delegate capability to target actor\",\"parameters\":{\"type\":\"object\",\"properties\":{\"target_actor\":{\"type\":\"integer\"},\"source_slot\":{\"type\":\"integer\"},\"rights_mask\":{\"type\":\"integer\"}},\"required\":[\"target_actor\",\"source_slot\",\"rights_mask\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"write_storage\",\"description\":\"Store immutable payload in Content-Addressed Storage\",\"parameters\":{\"type\":\"object\",\"properties\":{\"payload\":{\"type\":\"string\"}},\"required\":[\"payload\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"read_storage\",\"description\":\"Retrieve payload from Content-Addressed Storage\",\"parameters\":{\"type\":\"object\",\"properties\":{\"hex_hash\":{\"type\":\"string\"}},\"required\":[\"hex_hash\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"draw_canvas\",\"description\":\"Draw solid rectangle on GOP framebuffer\",\"parameters\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"integer\"},\"y\":{\"type\":\"integer\"},\"w\":{\"type\":\"integer\"},\"h\":{\"type\":\"integer\"},\"color\":{\"type\":\"integer\"}},\"required\":[\"x\",\"y\",\"w\",\"h\",\"color\"]}}}," ++
    "{\"type\":\"function\",\"function\":{\"name\":\"query_telemetry\",\"description\":\"Query active actors, fault count, memory, and uptime\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}" ++
    "]";

test "tool type parsing and name formatting roundtrip" {
    const ttypes = [_]ToolType{
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
    try std.testing.expect(std.mem.indexOf(u8, GEMINI_TOOLS_JSON, "spawn_actor") != null);
    try std.testing.expect(std.mem.indexOf(u8, GEMINI_TOOLS_JSON, "draw_canvas") != null);
    try std.testing.expect(std.mem.indexOf(u8, OPENAI_TOOLS_JSON, "spawn_actor") != null);
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
