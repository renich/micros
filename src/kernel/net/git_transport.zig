// MicrOS (µOS) Git Smart HTTP Transport Protocol Engine
// Generates Git ref advertisements and report-status responses.
// Zero libc, freestanding.

const std = @import("std");
const git_pkt = @import("git_pkt.zig");

pub const ZERO_OID: []const u8 = "0000000000000000000000000000000000000000";
pub const DEFAULT_BRANCH: []const u8 = "refs/heads/master";
pub const GIT_CAPABILITIES: []const u8 = "report-status delete-refs agent=micros/0.15.0";
pub const SERVICE_RECEIVE_PACK: []const u8 = "# service=git-receive-pack\n";

pub const CONTENT_TYPE_ADVERTISEMENT: []const u8 = "application/x-git-receive-pack-advertisement";
pub const CONTENT_TYPE_RESULT: []const u8 = "application/x-git-receive-pack-result";

pub fn buildAdvertisementBody(head_sha: ?[]const u8, branch: []const u8, out_buf: []u8) !usize {
    var offset: usize = 0;

    // 1. # service=git-receive-pack\n
    offset += try git_pkt.writePktLine(out_buf[offset..], SERVICE_RECEIVE_PACK);

    // 2. Flush-pkt (0000)
    offset += try git_pkt.writeFlush(out_buf[offset..]);

    // 3. Ref line or empty capabilities^{}\0...
    var line_buf: [256]u8 = undefined;
    const sha = head_sha orelse ZERO_OID;
    const is_empty = (head_sha == null);

    const ref_target = if (is_empty) "capabilities^{}" else branch;
    const line_content = std.fmt.bufPrint(
        &line_buf,
        "{s} {s}\x00{s}\n",
        .{ sha, ref_target, GIT_CAPABILITIES },
    ) catch return error.BufferTooSmall;

    offset += try git_pkt.writePktLine(out_buf[offset..], line_content);

    // 4. Flush-pkt (0000)
    offset += try git_pkt.writeFlush(out_buf[offset..]);

    return offset;
}

pub fn buildReportStatusBody(ref_name: []const u8, success: bool, err_msg: ?[]const u8, out_buf: []u8) !usize {
    var offset: usize = 0;

    if (success) {
        offset += try git_pkt.writePktLine(out_buf[offset..], "unpack ok\n");
        var ok_buf: [256]u8 = undefined;
        const ok_line = std.fmt.bufPrint(&ok_buf, "ok {s}\n", .{ref_name}) catch return error.BufferTooSmall;
        offset += try git_pkt.writePktLine(out_buf[offset..], ok_line);
    } else {
        const reason = err_msg orelse "failed";
        var err_buf: [256]u8 = undefined;
        const unpack_line = std.fmt.bufPrint(&err_buf, "unpack {s}\n", .{reason}) catch return error.BufferTooSmall;
        offset += try git_pkt.writePktLine(out_buf[offset..], unpack_line);

        var ng_buf: [256]u8 = undefined;
        const ng_line = std.fmt.bufPrint(&ng_buf, "ng {s} {s}\n", .{ ref_name, reason }) catch return error.BufferTooSmall;
        offset += try git_pkt.writePktLine(out_buf[offset..], ng_line);
    }

    offset += try git_pkt.writeFlush(out_buf[offset..]);
    return offset;
}

pub fn formatHttpGitResponse(content_type: []const u8, body: []const u8, out_buf: []u8) !usize {
    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nCache-Control: no-cache\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{ content_type, body.len },
    ) catch return error.BufferTooSmall;

    if (out_buf.len < hdr.len + body.len) return error.BufferTooSmall;
    @memcpy(out_buf[0..hdr.len], hdr);
    @memcpy(out_buf[hdr.len .. hdr.len + body.len], body);
    return hdr.len + body.len;
}

// === Colocated Unit Tests ===

test "git advertisement body generation for empty repository" {
    var body_buf: [512]u8 = undefined;
    const body_len = try buildAdvertisementBody(null, DEFAULT_BRANCH, &body_buf);
    try std.testing.expect(body_len > 0);

    const body = body_buf[0..body_len];
    try std.testing.expect(std.mem.startsWith(u8, body, "001f# service=git-receive-pack\n0000"));
    try std.testing.expect(std.mem.indexOf(u8, body, "0000000000000000000000000000000000000000 capabilities^{}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "report-status") != null);
    try std.testing.expect(std.mem.endsWith(u8, body, "0000"));
}

test "git advertisement body generation for existing commit" {
    var body_buf: [512]u8 = undefined;
    const commit_sha = "abcdef1234567890abcdef1234567890abcdef12";
    const body_len = try buildAdvertisementBody(commit_sha, "refs/heads/master", &body_buf);
    const body = body_buf[0..body_len];

    try std.testing.expect(std.mem.indexOf(u8, body, "abcdef1234567890abcdef1234567890abcdef12 refs/heads/master") != null);
}

test "git report-status generation" {
    var ok_buf: [256]u8 = undefined;
    const ok_len = try buildReportStatusBody("refs/heads/master", true, null, &ok_buf);
    const ok_body = ok_buf[0..ok_len];
    try std.testing.expect(std.mem.indexOf(u8, ok_body, "unpack ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ok_body, "ok refs/heads/master\n") != null);

    var ng_buf: [256]u8 = undefined;
    const ng_len = try buildReportStatusBody("refs/heads/master", false, "corrupt packfile", &ng_buf);
    const ng_body = ng_buf[0..ng_len];
    try std.testing.expect(std.mem.indexOf(u8, ng_body, "unpack corrupt packfile\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ng_body, "ng refs/heads/master corrupt packfile\n") != null);
}
