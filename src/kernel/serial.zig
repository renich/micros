// UART 16550 Serial Driver for x86_64 Kernel Early Boot & Telemetry

pub const COM1: u16 = 0x3F8;

pub inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
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
    outb(COM1 + 2, 0xC7); // Enable FIFO, clear them, with 14-byte threshold
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
