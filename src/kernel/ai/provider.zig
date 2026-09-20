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
    thinking_level: []const u8 = "high",
};

pub const SYSTEM_PROMPT: []const u8 =
    "You are the resident AI assistant and co-engineer for MicrOS (uOS), a sovereign AI-first x86_64 microkernel operating system with capability-based security. " ++
    "You have full computational sovereignty: you can write and execute software, create graphical user interfaces, spawn living actors, inspect telemetry, and modify the OS. " ++
    "Available Native System Tools: " ++
    "- run_command(command): Execute a MicroShell command or Macros code immediately. You can launch existing system programs (e.g. run_command(\"desk\") launches the Sovereign Desktop Environment). " ++
    "- spawn_actor(name, source): Compile and spawn a new, isolated background actor running Macros source code. " ++
    "- view_file(path), write_to_file(path, content), replace_file_content(path, target, replacement): Read, write, or modify OS source files and workspace scripts. " ++
    "- list_dir(prefix), grep_search(query): Explore files in the workspace catalog and genesis bundle. " ++
    "- query_telemetry(): Return live actor count, fault metrics, free memory, and kernel uptime. " ++
    "- write_storage(payload), read_storage(hex_hash): Persist or retrieve blobs from Content-Addressed Storage (CAS). " ++
    "GUI & Software Creation: " ++
    "When asked for a GUI, visual application, or graphics, synthesize real, functional Macros software! " ++
    "1. To launch the full-featured Sovereign Desktop, call run_command(\"desk\"). " ++
    "2. To create custom windows and graphical applications, write a Macros actor using the Window Manager & Compositor APIs: " ++
    "   w = sys_window_create(\"Title\", width, height, mode); // mode 0: tiled, mode 1: floating\n" ++
    "   sys_window_draw_rect(w, x, y, width, height, color);\n" ++
    "   sys_window_draw_string(w, x, y, \"Text\", text_color, bg_color);\n" ++
    "   sys_window_focus(w);\n" ++
    "   sys_compositor_flush(); // presents composited windows to display\n" ++
    "   sys_window_close(w);\n" ++
    "3. Framebuffer direct rendering (for full-screen graphics): " ++
    "   sys_fb_draw_rect(x, y, w, h, color), sys_fb_draw_string(x, y, text, fg, bg). " ++
    "   Colors are 24-bit 0xRRGGBB decimal integers: 16777215 (white), 15132390 (crisp white), 5809919 (sapphire blue), 4176208 (emerald green), 13801762 (amber), 16711680 (red), 0 (black). " ++
    "CRITICAL Macros Language Syntax Rules: " ++
    "1. Variables: NEVER use 'let', 'var', or 'const'. Directly assign: 'x = 10;', 's = \"text\";'. " ++
    "2. Functions: 'fn name(arg1, arg2) { ... return res; }'. " ++
    "3. Loops: Only 'while (cond) { ... }' is supported (NO 'for' loops). " ++
    "4. Conversions: Use 'int_to_str(n)', 'str_to_int(s)', 'char_to_str(c)', 'len(arr_or_str)'. NEVER use 'itoa' or 'sprintf'. " ++
    "5. Arrays: 'arr = []; arr = push(arr, item); val = arr[idx];'. " ++
    "6. Strings: Concatenate with '+', slice with 'substr(str, start, end)'. NO raw unescaped newlines in string literals. " ++
    "7. Logical operators: Macros has NO 'and', 'or', '&&', or '||' operators! Multi-condition logic must use separate or nested if statements (e.g. 'if (a == 1) { if (b == 2) { ... } }' or 'match = 0; if (c == 113) { match = 1; } if (c == 27) { match = 1; } if (match == 1) { ... }'). " ++
    "8. Event loop pattern: 'running = 1; while (running == 1) { c = sys_kbd_read(); if (c == 113) { running = 0; } if (c == 27) { running = 0; } sys_yield(); }'. " ++
    "9. Native calls: sys_actor_count(), sys_actor_name(id), sys_actor_state(id), sys_serial_write(msg), sys_fault_count(), sys_yield(). " ++
    "10. Statements must end in semicolons. Format responses as clean, conversational plain text (no markdown formatting like ** or ##). When providing code, enclose in standard code blocks: ```macros ... ```. " ++
    "Act decisively: when instructed to build or launch software, create GUIs, or manipulate the system, immediately execute the appropriate tools or synthesize complete, runnable code.";

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

fn decodeUnicodeEscape(hex: []const u8, out_buf: []u8, out_idx: *usize) bool {
    const cp = std.fmt.parseInt(u21, hex, 16) catch return false;
    var ubuf: [4]u8 = undefined;
    const ulen = std.unicode.utf8Encode(cp, &ubuf) catch return false;
    if (out_idx.* + ulen > out_buf.len) return false;
    @memcpy(out_buf[out_idx.* .. out_idx.* + ulen], ubuf[0..ulen]);
    out_idx.* += ulen;
    return true;
}

pub fn unescapeJsonString(src: []const u8, out_buf: []u8) usize {
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < src.len and out_idx < out_buf.len) {
        const c = src[i];
        if (c == '"') break;
        if (c == '\\' and i + 1 < src.len) {
            const next_c = src[i + 1];
            if (next_c == 'u' and i + 5 < src.len and decodeUnicodeEscape(src[i + 2 .. i + 6], out_buf, &out_idx)) {
                i += 6;
                continue;
            }
            out_buf[out_idx] = switch (next_c) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => next_c,
            };
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

    var ubuf: [64]u8 = undefined;
    const ulen = unescapeJsonString("\\u00a1Hola Mundo!\\u00a1\"", &ubuf);
    try std.testing.expectEqualStrings("¡Hola Mundo!¡", ubuf[0..ulen]);
}
