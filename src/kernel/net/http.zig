// MicrOS (µOS) Freestanding HTTP/1.1 Client
// Zero libc, capability-friendly HTTP/1.1 request/response parser and Gemini API transport.

const std = @import("std");
const serial = @import("../serial.zig");
const tls_stream = @import("tls_stream.zig");

pub const HTTP_OK: u16 = 200;
pub const HTTP_CREATED: u16 = 201;
pub const HTTP_ACCEPTED: u16 = 202;
pub const HTTP_NO_CONTENT: u16 = 204;
pub const HTTP_BAD_REQUEST: u16 = 400;
pub const HTTP_UNAUTHORIZED: u16 = 401;
pub const HTTP_FORBIDDEN: u16 = 403;
pub const HTTP_NOT_FOUND: u16 = 404;
pub const HTTP_SERVER_ERROR: u16 = 500;

pub const DEFAULT_MAX_HEADER_LEN: usize = 4096;
pub const DEFAULT_MAX_BODY_LEN: usize = 65536;

pub const HttpError = error{
    BufferTooSmall,
    InvalidStatusLine,
    InvalidHeader,
    UnsupportedEncoding,
    ResponseTruncated,
    HttpErrorStatus,
    WriteFailed,
    ReadFailed,
};

pub const HttpResponse = struct {
    status_code: u16,
    content_length: ?usize,
    is_chunked: bool,
    is_sse: bool,
    body_offset: usize,
    raw_len: usize,
};

pub fn formatPostRequest(
    buf: []u8,
    host: []const u8,
    path: []const u8,
    content_type: []const u8,
    body: []const u8,
) !usize {
    return formatPostRequestWithAuth(buf, host, path, content_type, null, body);
}

pub fn formatPostRequestWithAuth(
    buf: []u8,
    host: []const u8,
    path: []const u8,
    content_type: []const u8,
    auth_header: ?[]const u8,
    body: []const u8,
) !usize {
    var off: usize = 0;
    off = try appendStr(buf, off, "POST ");
    off = try appendStr(buf, off, path);
    off = try appendStr(buf, off, " HTTP/1.1\r\nHost: ");
    off = try appendStr(buf, off, host);
    off = try appendStr(buf, off, "\r\nUser-Agent: MicrOS/0.1.0 (freestanding)\r\nAccept: application/json\r\nContent-Type: ");
    off = try appendStr(buf, off, content_type);

    if (auth_header) |auth| {
        off = try appendStr(buf, off, "\r\nAuthorization: ");
        off = try appendStr(buf, off, auth);
    }

    var num_buf: [48]u8 = undefined;
    const len_str = std.fmt.bufPrint(&num_buf, "\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return error.BufferTooSmall;
    off = try appendStr(buf, off, len_str);
    off = try appendStr(buf, off, body);
    return off;
}

fn appendStr(buf: []u8, off: usize, s: []const u8) !usize {
    if (off + s.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[off .. off + s.len], s);
    return off + s.len;
}

pub fn parseStatusLine(line: []const u8) !u16 {
    if (line.len < 12) return error.InvalidStatusLine;
    if (!std.mem.startsWith(u8, line, "HTTP/1.1 ") and !std.mem.startsWith(u8, line, "HTTP/1.0 ")) {
        return error.InvalidStatusLine;
    }
    const code_slice = line[9..12];
    const code = std.fmt.parseInt(u16, code_slice, 10) catch return error.InvalidStatusLine;
    return code;
}

pub fn parseHeaderLine(line: []const u8, resp: *HttpResponse) void {
    if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
        const val_part = std.mem.trim(u8, line[15..], " \t\r\n");
        resp.content_length = std.fmt.parseInt(usize, val_part, 10) catch null;
    } else if (std.ascii.startsWithIgnoreCase(line, "transfer-encoding:")) {
        if (std.mem.indexOf(u8, line, "chunked") != null) {
            resp.is_chunked = true;
        }
    } else if (std.ascii.startsWithIgnoreCase(line, "content-type:")) {
        if (std.mem.indexOf(u8, line, "text/event-stream") != null) {
            resp.is_sse = true;
        }
    }
}

pub fn parseResponseHeaders(buf: []const u8, len: usize) !HttpResponse {
    var resp = HttpResponse{
        .status_code = 0,
        .content_length = null,
        .is_chunked = false,
        .is_sse = false,
        .body_offset = 0,
        .raw_len = len,
    };

    const data = buf[0..len];
    const header_end_marker = "\r\n\r\n";
    const header_end = std.mem.indexOf(u8, data, header_end_marker) orelse {
        const alt_marker = "\n\n";
        const alt_end = std.mem.indexOf(u8, data, alt_marker) orelse return error.ResponseTruncated;
        resp.body_offset = alt_end + 2;
        return parseHeaderLines(data[0..alt_end], &resp);
    };

    resp.body_offset = header_end + 4;
    return parseHeaderLines(data[0..header_end], &resp);
}

fn parseHeaderLines(headers: []const u8, resp: *HttpResponse) !HttpResponse {
    var iter = std.mem.splitSequence(u8, headers, "\r\n");
    const status_line = iter.next() orelse return error.InvalidStatusLine;
    resp.status_code = try parseStatusLine(status_line);

    while (iter.next()) |line| {
        if (line.len == 0) continue;
        parseHeaderLine(line, resp);
    }
    return resp.*;
}

pub fn extractJsonCandidateText(json_payload: []const u8, out_buf: []u8) ?usize {
    const key_needle = "\"text\":";
    var search_pos: usize = 0;
    var target_start: ?usize = null;

    while (std.mem.indexOfPos(u8, json_payload, search_pos, key_needle)) |idx| {
        var p = idx + key_needle.len;
        while (p < json_payload.len and (json_payload[p] == ' ' or json_payload[p] == '\t')) {
            p += 1;
        }
        if (p < json_payload.len and json_payload[p] == '"') {
            target_start = p + 1;
        }
        search_pos = idx + key_needle.len;
    }
    const text_start = target_start orelse return null;
    return unescapeJsonSubstring(json_payload[text_start..], out_buf);
}

fn unescapeJsonSubstring(src: []const u8, out_buf: []u8) usize {
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < src.len and out_idx < out_buf.len) {
        const c = src[i];
        if (c == '"' and (i == 0 or src[i - 1] != '\\')) break;
        if (c == '\\' and i + 1 < src.len) {
            const next_c = src[i + 1];
            if (next_c == 'n') {
                out_buf[out_idx] = '\n';
                out_idx += 1;
                i += 2;
                continue;
            } else if (next_c == 'r') {
                out_buf[out_idx] = '\r';
                out_idx += 1;
                i += 2;
                continue;
            } else if (next_c == 't') {
                out_buf[out_idx] = '\t';
                out_idx += 1;
                i += 2;
                continue;
            } else if (next_c == '"' or next_c == '\\') {
                out_buf[out_idx] = next_c;
                out_idx += 1;
                i += 2;
                continue;
            }
        }
        out_buf[out_idx] = c;
        out_idx += 1;
        i += 1;
    }
    return out_idx;
}

test "http post request formatting" {
    var buf: [512]u8 = undefined;
    const body = "{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"ping\"}]}]}";
    const req_len = try formatPostRequest(&buf, "api.google.com", "/v1/test", "application/json", body);
    try std.testing.expect(req_len > 0);
    const req_str = buf[0..req_len];
    try std.testing.expect(std.mem.indexOf(u8, req_str, "POST /v1/test HTTP/1.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req_str, "Host: api.google.com\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req_str, "Content-Length: 56\r\n") != null);
}

test "http response header parsing" {
    const raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}";
    const resp = try parseResponseHeaders(raw, raw.len);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqual(@as(?usize, 15), resp.content_length);
    try std.testing.expectEqual(false, resp.is_chunked);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", raw[resp.body_offset..]);
}

test "http response json candidate text extraction" {
    const json = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\": \"Hello, Sovereign MicrOS!\\n\"}]}}]}";
    var out: [128]u8 = undefined;
    const len = extractJsonCandidateText(json, &out).?;
    try std.testing.expectEqualStrings("Hello, Sovereign MicrOS!\n", out[0..len]);
}
