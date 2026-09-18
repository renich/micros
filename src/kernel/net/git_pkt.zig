// MicrOS (µOS) Git Packet-Line (pkt-line) Protocol Parser & Formatter
// Freestanding, zero libc implementation of the Git pkt-line wire protocol.

const std = @import("std");

pub const PKT_FLUSH: []const u8 = "0000";
pub const PKT_DELIM: []const u8 = "0001";
pub const PKT_RESPONSE_END: []const u8 = "0002";
pub const PKT_MAX_SIZE: usize = 65520;
pub const PKT_HEADER_SIZE: usize = 4;

pub const PktType = enum {
    data,
    flush,
    delim,
    response_end,
};

pub const PktLine = struct {
    pkt_type: PktType,
    payload: []const u8,
    total_len: usize,
};

pub const RefLine = struct {
    old_id: []const u8,
    new_id: []const u8,
    ref_name: []const u8,
    capabilities: []const u8,
};

fn hexDigitValue(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

pub fn parseHex4(hex: *const [4]u8) ?u16 {
    var val: u16 = 0;
    for (hex) |c| {
        const d = hexDigitValue(c) orelse return null;
        val = (val << 4) | d;
    }
    return val;
}

pub fn formatHex4(val: u16, out: *[4]u8) void {
    const chars = "0123456789abcdef";
    out[0] = chars[(val >> 12) & 0xF];
    out[1] = chars[(val >> 8) & 0xF];
    out[2] = chars[(val >> 4) & 0xF];
    out[3] = chars[val & 0xF];
}

pub fn writePktLine(out_buf: []u8, payload: []const u8) !usize {
    const total = payload.len + PKT_HEADER_SIZE;
    if (total > PKT_MAX_SIZE) return error.PacketTooLarge;
    if (out_buf.len < total) return error.BufferTooSmall;

    var hex_hdr: [4]u8 = undefined;
    formatHex4(@intCast(total), &hex_hdr);
    @memcpy(out_buf[0..4], &hex_hdr);
    @memcpy(out_buf[4..total], payload);
    return total;
}

pub fn writeFlush(out_buf: []u8) !usize {
    if (out_buf.len < PKT_HEADER_SIZE) return error.BufferTooSmall;
    @memcpy(out_buf[0..4], PKT_FLUSH);
    return PKT_HEADER_SIZE;
}

pub fn writeDelim(out_buf: []u8) !usize {
    if (out_buf.len < PKT_HEADER_SIZE) return error.BufferTooSmall;
    @memcpy(out_buf[0..4], PKT_DELIM);
    return PKT_HEADER_SIZE;
}

pub fn parsePktLine(data: []const u8) ?PktLine {
    if (data.len < PKT_HEADER_SIZE) return null;
    const raw_hex: *const [4]u8 = data[0..4];
    const len_val = parseHex4(raw_hex) orelse return null;

    if (len_val == 0) {
        return PktLine{ .pkt_type = .flush, .payload = "", .total_len = 4 };
    }
    if (len_val == 1) {
        return PktLine{ .pkt_type = .delim, .payload = "", .total_len = 4 };
    }
    if (len_val == 2) {
        return PktLine{ .pkt_type = .response_end, .payload = "", .total_len = 4 };
    }
    if (len_val < PKT_HEADER_SIZE or len_val > PKT_MAX_SIZE) return null;
    if (data.len < len_val) return null;

    return PktLine{
        .pkt_type = .data,
        .payload = data[PKT_HEADER_SIZE..len_val],
        .total_len = len_val,
    };
}

pub fn parsePushCommand(payload: []const u8) ?RefLine {
    // Format: "<old_sha> <new_sha> <ref_name>\0<capabilities>\n" or without \0
    if (payload.len < 82) return null; // 40 + 1 + 40 + 1
    const old_id = payload[0..40];
    if (payload[40] != ' ') return null;
    const new_id = payload[41..81];
    if (payload[81] != ' ') return null;

    const rest = payload[82..];
    var nul_idx: ?usize = null;
    var newline_idx: ?usize = null;

    for (rest, 0..) |c, i| {
        if (c == 0 and nul_idx == null) {
            nul_idx = i;
        } else if (c == '\n' and newline_idx == null) {
            newline_idx = i;
            break;
        }
    }

    const end_idx = newline_idx orelse rest.len;
    if (nul_idx) |n_idx| {
        return RefLine{
            .old_id = old_id,
            .new_id = new_id,
            .ref_name = rest[0..n_idx],
            .capabilities = rest[n_idx + 1 .. end_idx],
        };
    }

    return RefLine{
        .old_id = old_id,
        .new_id = new_id,
        .ref_name = rest[0..end_idx],
        .capabilities = "",
    };
}

// === Colocated Unit Tests ===

test "pkt-line formatting and parsing roundtrip" {
    var buf: [256]u8 = undefined;
    const payload = "# service=git-receive-pack\n";
    const written = try writePktLine(&buf, payload);
    try std.testing.expectEqual(@as(usize, payload.len + 4), written);
    try std.testing.expectEqualStrings("001f", buf[0..4]);

    const parsed = parsePktLine(buf[0..written]).?;
    try std.testing.expectEqual(PktType.data, parsed.pkt_type);
    try std.testing.expectEqualStrings(payload, parsed.payload);
    try std.testing.expectEqual(written, parsed.total_len);
}

test "pkt-line flush and delimiter handling" {
    var buf: [64]u8 = undefined;
    const flush_len = try writeFlush(&buf);
    try std.testing.expectEqual(@as(usize, 4), flush_len);

    const flush_pkt = parsePktLine(buf[0..flush_len]).?;
    try std.testing.expectEqual(PktType.flush, flush_pkt.pkt_type);
    try std.testing.expectEqualStrings("", flush_pkt.payload);

    const delim_len = try writeDelim(&buf);
    try std.testing.expectEqual(@as(usize, 4), delim_len);

    const delim_pkt = parsePktLine(buf[0..delim_len]).?;
    try std.testing.expectEqual(PktType.delim, delim_pkt.pkt_type);
}

test "pkt-line push command parsing" {
    const raw = "0000000000000000000000000000000000000000 1234567890abcdef1234567890abcdef12345678 refs/heads/master\x00report-status side-band-64k\n";
    const parsed = parsePushCommand(raw).?;
    try std.testing.expectEqualStrings("0000000000000000000000000000000000000000", parsed.old_id);
    try std.testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", parsed.new_id);
    try std.testing.expectEqualStrings("refs/heads/master", parsed.ref_name);
    try std.testing.expectEqualStrings("report-status side-band-64k", parsed.capabilities);
}
