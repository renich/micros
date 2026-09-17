// MicrOS (µOS) Resident AI Provider Specification & Common Contracts
// Decouples the microkernel from specific LLM providers (Gemini, OpenAI, Anthropic, Local).

const std = @import("std");

pub const ProviderType = enum {
    gemini,
    openai,
    anthropic,
    local_http,
    mock,
};

pub const ProviderConfig = struct {
    provider_type: ProviderType = .gemini,
    endpoint: []const u8,
    port: u16 = 443,
    use_tls: bool = true,
    model: []const u8,
    api_key: []const u8 = "",
};

pub const SOVEREIGN_SYSTEM_PROMPT: []const u8 =
    "You are the Sovereign Root Intelligence of MicrOS (uOS), an AI-first, zero-libc, " ++
    "capability-oriented standalone microkernel operating system running on bare-metal x86_64. " ++
    "You possess the Root Capability Space (CSpace 0). The microkernel provides mechanism, not policy: " ++
    "physical page allocation, virtual memory mapping, cooperative green fibers, typed SPSC IPC rings, " ++
    "raw VirtIO queues (VirtIO-Net, VirtIO-Blk), and a 1280x800 GOP linear vector canvas. " ++
    "You determine operating system rules, storage ontology, boot lifecycle, user access levels, " ++
    "and application execution. You can compile and execute Macros language (.mx) code on the native VM, " ++
    "draw vector graphics to the display, and interact with the human user. " ++
    "You are in full control of the host machine and operating system. " ++
    "Available native calls in Macros: " ++
    "sys_fb_clear(color); " ++
    "sys_fb_draw_string(x, y, text, fg, bg); " ++
    "sys_fb_draw_rect(x, y, w, h, color); " ++
    "sys_actor_count(); " ++
    "sys_serial_write(text); " ++
    "sys_fault_count(); " ++
    "In Macros, all numbers are decimal integers (e.g. 16777215 for white, 65280 for green, 0 for black). Statements end in semicolons. " ++
    "Format all responses using reStructuredText (.rst). Always include an executable code block formatted as: .. code-block:: macros (with 3-space indentation) to govern the system.";

pub fn parseProviderType(name: []const u8) ProviderType {
    if (std.mem.eql(u8, name, "openai")) return .openai;
    if (std.mem.eql(u8, name, "anthropic")) return .anthropic;
    if (std.mem.eql(u8, name, "local_http") or std.mem.eql(u8, name, "ollama") or std.mem.eql(u8, name, "vllm")) {
        return .local_http;
    }
    if (std.mem.eql(u8, name, "mock")) return .mock;
    return .gemini;
}

pub fn escapeJsonString(buf: []u8, start_offset: usize, src: []const u8) !usize {
    var off = start_offset;
    for (src) |c| {
        switch (c) {
            '"', '\\' => {
                if (off + 2 > buf.len) return error.BufferTooSmall;
                buf[off] = '\\';
                buf[off + 1] = c;
                off += 2;
            },
            '\n' => {
                if (off + 2 > buf.len) return error.BufferTooSmall;
                buf[off] = '\\';
                buf[off + 1] = 'n';
                off += 2;
            },
            '\r' => {
                if (off + 2 > buf.len) return error.BufferTooSmall;
                buf[off] = '\\';
                buf[off + 1] = 'r';
                off += 2;
            },
            '\t' => {
                if (off + 2 > buf.len) return error.BufferTooSmall;
                buf[off] = '\\';
                buf[off + 1] = 't';
                off += 2;
            },
            else => {
                if (off + 1 > buf.len) return error.BufferTooSmall;
                buf[off] = c;
                off += 1;
            },
        }
    }
    return off;
}

test "provider type parser" {
    try std.testing.expectEqual(ProviderType.gemini, parseProviderType("gemini"));
    try std.testing.expectEqual(ProviderType.openai, parseProviderType("openai"));
    try std.testing.expectEqual(ProviderType.anthropic, parseProviderType("anthropic"));
    try std.testing.expectEqual(ProviderType.local_http, parseProviderType("local_http"));
    try std.testing.expectEqual(ProviderType.local_http, parseProviderType("ollama"));
    try std.testing.expectEqual(ProviderType.mock, parseProviderType("mock"));
}

test "escape json string helper" {
    var buf: [64]u8 = undefined;
    const len = try escapeJsonString(&buf, 0, "hello \"world\"\n");
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\n", buf[0..len]);
}
