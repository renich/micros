// x86_64 Interrupt Descriptor Table (IDT) & Exception Dispatcher
// Eradicates uncontained panics: traps child actor faults into supervisor frames.

const std = @import("std");
const serial = @import("../../serial.zig");
const fiber = @import("../../../macros/fiber.zig");
const ring_mod = @import("../../ipc/ring.zig");
const events_mod = @import("../../ipc/events.zig");
const ps2_kbd = @import("../../drivers/ps2_kbd.zig");
const supervisor_mod = @import("../../supervisor.zig");

pub const IdtEntry = extern struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    zero: u32,
};

pub const IdtPointer = packed struct {
    limit: u16,
    base: u64,
};

pub const InterruptFrame = extern struct {
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

var idt_entries: [256]IdtEntry = undefined;
var idt_ptr: IdtPointer = undefined;

pub var current_actor_id: u32 = 0;
pub var input_ring_ptr: ?*ring_mod.RingBuffer = null;
var kbd_driver: ps2_kbd.Ps2Keyboard = ps2_kbd.Ps2Keyboard.init();
var event_sequence: u32 = 0;

pub fn setInputRing(ring: *ring_mod.RingBuffer) void {
    input_ring_ptr = ring;
}

fn setGate(vec: u8, isr_addr: u64, flags: u8) void {
    idt_entries[vec] = IdtEntry{
        .offset_low = @intCast(isr_addr & 0xFFFF),
        .selector = 0x08,
        .ist = 0,
        .type_attr = flags,
        .offset_mid = @intCast((isr_addr >> 16) & 0xFFFF),
        .offset_high = @intCast((isr_addr >> 32) & 0xFFFFFFFF),
        .zero = 0,
    };
}

export fn childFaultTrampoline() void {
    serial.writeString("[kernel] Child actor safely caught by supervisor trampoline.\n");
    fiber.yield();
}

fn handleRootPanic(cr2: u64, stack_ptr: [*]u64) noreturn {
    serial.writeString("\n[FATAL CPU EXCEPTION IN ACTOR 0]\n");
    serial.writeString("[exception] CR2: 0x");
    serial.writeHex(cr2);
    serial.writeString("\n[exception] frame[0]: 0x");
    serial.writeHex(stack_ptr[0]);
    serial.writeString("\n[exception] frame[1]: 0x");
    serial.writeHex(stack_ptr[1]);
    serial.writeString("\n[exception] frame[2]: 0x");
    serial.writeHex(stack_ptr[2]);
    serial.writeString("\n[exception] frame[3]: 0x");
    serial.writeHex(stack_ptr[3]);
    serial.writeString("\n");
    while (true) {
        asm volatile ("hlt");
    }
}

export fn exceptionHandlerZig(saved_rip_ptr: *u64) void {
    const rip = saved_rip_ptr.*;
    const cr2 = asm volatile ("mov %%cr2, %[ret]"
        : [ret] "=r" (-> u64),
    );

    if (current_actor_id == 0) {
        handleRootPanic(cr2, @ptrCast(saved_rip_ptr));
    }

    serial.writeString("\n[SUPERVISOR TRAP] Intercepted fault in Child Actor ");
    serial.writeHex(current_actor_id);
    serial.writeString(" at RIP 0x");
    serial.writeHex(rip);
    serial.writeString(" (CR2: 0x");
    serial.writeHex(cr2);
    serial.writeString(")\n");

    const fault = supervisor_mod.FaultFrame{
        .actor_id = current_actor_id,
        .vector = supervisor_mod.FaultVector.PAGE_FAULT,
        .error_code = 0,
        .rip = rip,
        .rsp = 0,
        .cr2 = cr2,
        .rflags = 0,
    };

    if (input_ring_ptr) |ring| {
        event_sequence +%= 1;
        const frame = supervisor_mod.toMessageFrame(fault, event_sequence);
        _ = ring.push(frame);
    }

    saved_rip_ptr.* = @intFromPtr(&childFaultTrampoline);
    current_actor_id = 0;
}

fn genericExceptionHandler() callconv(.naked) void {
    asm volatile (
        \\ push %%rax
        \\ push %%rcx
        \\ push %%rdx
        \\ push %%rsi
        \\ push %%rdi
        \\ push %%r8
        \\ push %%r9
        \\ push %%r10
        \\ push %%r11
        \\ leaq 72(%%rsp), %%rdi
        \\ call exceptionHandlerZig
        \\ pop %%r11
        \\ pop %%r10
        \\ pop %%r9
        \\ pop %%r8
        \\ pop %%rdi
        \\ pop %%rsi
        \\ pop %%rdx
        \\ pop %%rcx
        \\ pop %%rax
        \\ iretq
    );
}

export fn kbdHandlerZig() void {
    const scancode = ps2_kbd.readScancode();
    if (kbd_driver.processScancode(scancode)) |event| {
        if (input_ring_ptr) |ring| {
            event_sequence +%= 1;
            const frame = events_mod.toMessageFrame(event, event_sequence);
            _ = ring.push(frame);
        }
    }

    fiber.unpark(1);
    asm volatile (
        \\ movb $0x20, %al
        \\ outb %al, $0x20
    );
}

fn keyboardInterruptHandler() callconv(.naked) void {
    asm volatile (
        \\ push %%rax
        \\ push %%rcx
        \\ push %%rdx
        \\ push %%rsi
        \\ push %%rdi
        \\ push %%r8
        \\ push %%r9
        \\ push %%r10
        \\ push %%r11
        \\ call kbdHandlerZig
        \\ pop %%r11
        \\ pop %%r10
        \\ pop %%r9
        \\ pop %%r8
        \\ pop %%rdi
        \\ pop %%rsi
        \\ pop %%rdx
        \\ pop %%rcx
        \\ pop %%rax
        \\ iretq
    );
}

pub fn init() void {
    for (&idt_entries) |*entry| {
        entry.* = std.mem.zeroes(IdtEntry);
    }

    const handler_addr = @intFromPtr(&genericExceptionHandler);
    var i: u8 = 0;
    while (i < 32) : (i += 1) {
        setGate(i, handler_addr, 0x8E);
    }

    const kbd_handler_addr = @intFromPtr(&keyboardInterruptHandler);
    setGate(33, kbd_handler_addr, 0x8E);

    idt_ptr.limit = @sizeOf(@TypeOf(idt_entries)) - 1;
    idt_ptr.base = @intFromPtr(&idt_entries);

    asm volatile ("lidt (%[ptr])"
        :
        : [ptr] "r" (&idt_ptr),
    );
}
