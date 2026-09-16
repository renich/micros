const std = @import("std");

pub const Severity = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    fatal = 4,
};

pub const Subsystem = enum(u16) {
    kernel = 0x0001,
    pmm = 0x0002,
    vmm = 0x0003,
    scheduler = 0x0004,
    ipc = 0x0005,
    macros = 0x0006,
    msh = 0x0007,
    _,
};

pub const TelemetryToken = extern struct {
    timestamp_ns: u64,
    sequence_num: u64,
    event_type: u16,
    subsystem_id: u16,
    cpu_id: u8,
    severity: u8,
    reserved: u16,
    caller_rip: u64,
    payload: [32]u8,

    pub fn format(
        self: TelemetryToken,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const sub: Subsystem = @enumFromInt(self.subsystem_id);
        const sev: Severity = @enumFromInt(self.severity);
        try writer.print(
            "[{d}ns][seq:{d}][{s}][{s}][cpu:{d}][rip:0x{x}] event:0x{x}",
            .{ self.timestamp_ns, self.sequence_num, @tagName(sub), @tagName(sev), self.cpu_id, self.caller_rip, self.event_type },
        );
    }
};

comptime {
    if (@sizeOf(TelemetryToken) != 64) {
        @compileError("TelemetryToken must be exactly 64 bytes.");
    }
}

pub fn generateSampleToken(seq: u64, sev: Severity, sub: Subsystem, event: u16, rip: u64) TelemetryToken {
    var tok = TelemetryToken{
        .timestamp_ns = 1789589200000000,
        .sequence_num = seq,
        .event_type = event,
        .subsystem_id = @intFromEnum(sub),
        .cpu_id = 0,
        .severity = @intFromEnum(sev),
        .reserved = 0,
        .caller_rip = rip,
        .payload = [_]u8{0} ** 32,
    };
    @memcpy(tok.payload[0..13], "SubstrateInit");
    return tok;
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.skip(); // skip exe

    var format_json = false;
    var generate_sample = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            format_json = true;
        } else if (std.mem.eql(u8, arg, "--generate")) {
            generate_sample = true;
        }
    }

    if (generate_sample) {
        const tok = generateSampleToken(1, .info, .kernel, 0x1001, 0x002014d4);
        if (format_json) {
            std.debug.print(
                "{{\"timestamp_ns\":{},\"seq\":{},\"severity\":{},\"subsystem\":{},\"rip\":\"0x{x}\"}}\n",
                .{ tok.timestamp_ns, tok.sequence_num, tok.severity, tok.subsystem_id, tok.caller_rip },
            );
        } else {
            std.debug.print("{}\n", .{tok});
        }
        return;
    }

    std.debug.print("[micros-telem] Telemetry Decoder ready (64-byte ABI).\n", .{});
}

const testing = std.testing;

test "TelemetryToken 64-byte ABI and formatting" {
    try testing.expectEqual(@as(usize, 64), @sizeOf(TelemetryToken));

    const tok = generateSampleToken(42, .warn, .vmm, 0x0E, 0x002018c2);
    try testing.expectEqual(@as(u64, 42), tok.sequence_num);
    try testing.expectEqual(@as(u8, 2), tok.severity);
    try testing.expectEqual(@as(u16, 0x0003), tok.subsystem_id);
}
