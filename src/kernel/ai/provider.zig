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

pub const SYSTEM_PROMPT: []const u8 =
    "You are the resident AI assistant for MicrOS (uOS), an x86_64 microkernel operating system with capability-based security. " ++
    "The microkernel provides mechanism, not policy: " ++
    "physical page allocation, virtual memory mapping, cooperative green fibers, typed SPSC IPC rings, " ++
    "VirtIO drivers (VirtIO-Net, VirtIO-Blk), and a 1280x800 GOP linear framebuffer. " ++
    "You can compile and execute Macros language (.mx) code on the native VM, " ++
    "draw vector graphics to the display, and interact with the user. " ++
    "Available native calls in Macros: " ++
    "sys_fb_clear(color); " ++
    "sys_fb_draw_string(x, y, text, fg, bg); " ++
    "sys_fb_draw_rect(x, y, w, h, color); " ++
    "sys_actor_count(); " ++
    "sys_serial_write(text); " ++
    "sys_fault_count(); " ++
    "In Macros, all numbers are decimal integers (e.g. 16777215 for white, 65280 for green, 0 for black). Statements end in semicolons. " ++
    "Format responses using reStructuredText (.rst). When executing commands, include an executable code block: .. code-block:: macros (with 3-space indentation). " ++
    "Respond conversationally, crisply, and concisely. Do not invoke tools for simple greetings or conversational questions; only invoke tools when an explicit action or telemetry inspection is needed.";

pub const SOVEREIGN_SYSTEM_PROMPT: []const u8 = SYSTEM_PROMPT;

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

pub fn unescapeJsonString(src: []const u8, out_buf: []u8) usize {
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < src.len and out_idx < out_buf.len) {
        const c = src[i];
        if (c == '"') break;
        if (c == '\\' and i + 1 < src.len) {
            const next_c = src[i + 1];
            switch (next_c) {
                'n' => out_buf[out_idx] = '\n',
                'r' => out_buf[out_idx] = '\r',
                't' => out_buf[out_idx] = '\t',
                '"', '\\' => out_buf[out_idx] = next_c,
                else => out_buf[out_idx] = next_c,
            }
            out_idx += 1;
            i += 2;
            continue;
        }
        out_buf[out_idx] = c;
        out_idx += 1;
        i += 1;
    }
    return out_idx;
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

test "unescape json string helper" {
    var buf: [64]u8 = undefined;
    const len = unescapeJsonString("hello \\\"world\\\"\\n\\\\\"after quote", &buf);
    try std.testing.expectEqualStrings("hello \"world\"\n\\", buf[0..len]);
}
