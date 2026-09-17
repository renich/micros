// UART 16550 Serial Driver for x86_64 Kernel Early Boot & Telemetry

const builtin = @import("builtin");

pub const COM1: u16 = 0x3F8;

pub inline fn outb(port: u16, val: u8) void {
    if (builtin.is_test) return;
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    if (builtin.is_test) return 0;
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub fn init() void {
    outb(COM1 + 1, 0x00); // Disable all interrupts
    outb(COM1 + 3, 0x80); // Enable DLAB (set baud rate divisor)
    outb(COM1 + 0, 0x01); // Set divisor to 1 (low byte) -> 115200 baud
    outb(COM1 + 1, 0x00); //                  (high byte)
    outb(COM1 + 3, 0x03); // 8 bits, no parity, one stop bit
    outb(COM1 + 2, 0x07); // Enable FIFO, clear them, with 1-byte threshold
    outb(COM1 + 4, 0x0B); // IRQs enabled, RTS/DSR set
}

fn isTransmitEmpty() bool {
    return (inb(COM1 + 5) & 0x20) != 0;
}

pub fn hasChar() bool {
    return (inb(COM1 + 5) & 0x01) != 0;
}

pub fn readChar() ?u8 {
    if (!hasChar()) return null;
    return inb(COM1);
}

pub fn writeChar(c: u8) void {
    if (builtin.is_test) return;
    var timeout: u32 = 100_000;
    while (!isTransmitEmpty() and timeout > 0) : (timeout -= 1) {
        asm volatile ("pause");
    }
    if (timeout > 0) {
        outb(COM1, c);
    }
}

pub fn writeString(str: []const u8) void {
    for (str) |c| {
        if (c == '\n') {
            writeChar('\r');
        }
        writeChar(c);
    }
}

pub fn writeHex(val: u64) void {
    const hex_chars = "0123456789ABCDEF";
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        const shift: u6 = @intCast(i * 4);
        const nibble: usize = @intCast((val >> shift) & 0x0F);
        writeChar(hex_chars[nibble]);
    }
}

// ANSI escape sequences for modern, sleek terminal telemetry
pub const ANSI_RESET: []const u8 = "\x1b[0m";
pub const ANSI_BOLD: []const u8 = "\x1b[1m";
pub const ANSI_DIM: []const u8 = "\x1b[2m";
pub const ANSI_GREEN: []const u8 = "\x1b[32m";
pub const ANSI_BRIGHT_GREEN: []const u8 = "\x1b[92m";
pub const ANSI_CYAN: []const u8 = "\x1b[36m";
pub const ANSI_BRIGHT_CYAN: []const u8 = "\x1b[96m";
pub const ANSI_YELLOW: []const u8 = "\x1b[33m";
pub const ANSI_BRIGHT_YELLOW: []const u8 = "\x1b[93m";
pub const ANSI_GRAY: []const u8 = "\x1b[90m";
pub const ANSI_WHITE: []const u8 = "\x1b[97m";

pub fn formatDec(val: u64, buf: *[20]u8) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var temp: [20]u8 = undefined;
    var n = val;
    var len: usize = 0;
    while (n > 0) : (n /= 10) {
        temp[len] = @intCast('0' + (n % 10));
        len += 1;
    }
    var out_idx: usize = 0;
    while (len > 0) {
        len -= 1;
        buf[out_idx] = temp[len];
        out_idx += 1;
    }
    return buf[0..out_idx];
}

pub fn writeDec(val: u64) void {
    var buf: [20]u8 = undefined;
    const slice = formatDec(val, &buf);
    writeString(slice);
}

pub fn formatHexCompact(val: u64, buf: *[18]u8) []const u8 {
    buf[0] = '0';
    buf[1] = 'x';
    if (val == 0) {
        buf[2] = '0';
        return buf[0..3];
    }
    const hex_chars = "0123456789ABCDEF";
    var temp: [16]u8 = undefined;
    var n = val;
    var len: usize = 0;
    while (n > 0) : (n >>= 4) {
        temp[len] = hex_chars[@intCast(n & 0x0F)];
        len += 1;
    }
    var out_idx: usize = 2;
    while (len > 0) {
        len -= 1;
        buf[out_idx] = temp[len];
        out_idx += 1;
    }
    return buf[0..out_idx];
}

pub fn writeHexCompact(val: u64) void {
    var buf: [18]u8 = undefined;
    const slice = formatHexCompact(val, &buf);
    writeString(slice);
}

pub fn writeStatusOk(subsys: []const u8, msg: []const u8) void {
    writeString("  \x1b[90m[\x1b[92m  ok  \x1b[90m]\x1b[0m \x1b[96m");
    writeString(subsys);
    writeString("\x1b[90m: \x1b[97m");
    writeString(msg);
    writeString("\x1b[0m\n");
}

pub fn writeStatusWarn(subsys: []const u8, msg: []const u8) void {
    writeString("  \x1b[90m[\x1b[93m warn \x1b[90m]\x1b[0m \x1b[96m");
    writeString(subsys);
    writeString("\x1b[90m: \x1b[97m");
    writeString(msg);
    writeString("\x1b[0m\n");
}

const std = @import("std");

test "serial formatDec and formatHexCompact" {
    var dec_buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("0", formatDec(0, &dec_buf));
    try std.testing.expectEqualStrings("42", formatDec(42, &dec_buf));
    try std.testing.expectEqualStrings("131072", formatDec(131072, &dec_buf));

    var hex_buf: [18]u8 = undefined;
    try std.testing.expectEqualStrings("0x0", formatHexCompact(0, &hex_buf));
    try std.testing.expectEqualStrings("0x2A", formatHexCompact(42, &hex_buf));
    try std.testing.expectEqualStrings("0x20000", formatHexCompact(0x20000, &hex_buf));
}
