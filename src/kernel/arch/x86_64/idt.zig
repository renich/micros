// x86_64 Interrupt Descriptor Table (IDT) & Exception Dispatcher
// Eradicates uncontained panics: traps child actor faults into supervisor frames.

const std = @import("std");
const builtin = @import("builtin");
const serial = @import("../../serial.zig");
const fiber = @import("../../../macros/fiber.zig");
const ring_mod = @import("../../ipc/ring.zig");
const events_mod = @import("../../ipc/events.zig");
const ps2_kbd = @import("../../drivers/ps2_kbd.zig");
const supervisor_mod = @import("../../supervisor.zig");
const apic = @import("apic.zig");
const smp = @import("../../sched/smp.zig");

const io = @import("io.zig");

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
var input_ring_lock: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var kbd_driver: ps2_kbd.Ps2Keyboard = ps2_kbd.Ps2Keyboard.init();
var event_sequence: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

pub fn nextSequence() u32 {
    return event_sequence.fetchAdd(1, .monotonic) +% 1;
}

fn pushInputMessage(msg: ring_mod.MessageFrame) bool {
    const flags = io.pushfqAndCli();
    defer io.popfq(flags);
    while (input_ring_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        if (!builtin.is_test) io.pause();
    }
    defer input_ring_lock.store(0, .release);

    if (input_ring_ptr) |ring| {
        return ring.push(msg);
    }
    return false;
}

pub fn setInputRing(ring: *ring_mod.RingBuffer) void {
    const flags = io.pushfqAndCli();
    defer io.popfq(flags);
    while (input_ring_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
        if (!builtin.is_test) io.pause();
    }
    defer input_ring_lock.store(0, .release);
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

pub const ExceptionStackFrame = extern struct {
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

export fn childFaultTrampoline() noreturn {
    serial.writeString("[kernel] Child actor safely caught by supervisor trampoline. Terminating fiber.\n");
    fiber.terminateCurrent();
}

fn handleRootPanic(cr2: u64, frame: *const ExceptionStackFrame) noreturn {
    serial.writeString("\n[FATAL CPU EXCEPTION IN ACTOR 0]\n");
    serial.writeString("[exception] VEC: 0x");
    serial.writeHex(frame.vector);
    serial.writeString(" CR2: 0x");
    serial.writeHex(cr2);
    serial.writeString("\n[exception] RIP: 0x");
    serial.writeHex(frame.rip);
    serial.writeString("\n[exception] RSP: 0x");
    serial.writeHex(frame.rsp);
    serial.writeString("\n[exception] ERR: 0x");
    serial.writeHex(frame.error_code);
    serial.writeString("\n");
    while (true) {
        asm volatile ("hlt");
    }
}

fn logSupervisorTrap(actor_id: u32, rip: u64, cr2: u64, frame: *const ExceptionStackFrame) void {
    serial.writeString("\n[SUPERVISOR TRAP] Intercepted fault in Child Actor ");
    serial.writeHex(actor_id);
    serial.writeString(" (vector: 0x");
    serial.writeHex(frame.vector);
    serial.writeString(") at RIP 0x");
    serial.writeHex(rip);
    serial.writeString(" (CR2: 0x");
    serial.writeHex(cr2);
    serial.writeString(" err: 0x");
    serial.writeHex(frame.error_code);
    serial.writeString(" rsp: 0x");
    serial.writeHex(frame.rsp);
    serial.writeString(")\n");
}

export fn exceptionHandlerZig(frame: *ExceptionStackFrame) void {
    const rip = frame.rip;
    const cr2 = if (builtin.is_test) 0 else asm volatile ("mov %%cr2, %[ret]"
        : [ret] "=r" (-> u64),
    );

    const core = smp.global_topology.getCurrentCore();
    const actor_id = if (builtin.is_test and current_actor_id != 0) current_actor_id else core.current_actor_id;

    if (actor_id == 0) {
        handleRootPanic(cr2, frame);
    }

    logSupervisorTrap(actor_id, rip, cr2, frame);

    const fault = supervisor_mod.FaultFrame{
        .actor_id = actor_id,
        .vector = @truncate(frame.vector),
        .error_code = @truncate(frame.error_code),
        .rip = rip,
        .rsp = frame.rsp,
        .cr2 = cr2,
        .rflags = frame.rflags,
    };

    const seq = nextSequence();
    const msg = supervisor_mod.toMessageFrame(fault, seq);
    _ = pushInputMessage(msg);

    frame.rip = @intFromPtr(&childFaultTrampoline);
    frame.cs = 0x08;
    frame.ss = 0x10;
    frame.rflags &= ~@as(u64, 0x200);
    core.current_actor_id = 0;
    current_actor_id = 0;
}

fn isErrorCodeVector(vec: u8) bool {
    return switch (vec) {
        8, 10, 11, 12, 13, 14, 17, 21 => true,
        else => false,
    };
}

fn makeIsr(comptime vec: u8) *const fn () callconv(.naked) void {
    if (comptime isErrorCodeVector(vec)) {
        const Gen = struct {
            fn isr() callconv(.naked) void {
                asm volatile (
                    \\ pushq %[v]
                    \\ jmp *%[handler]
                    :
                    : [v] "n" (@as(u64, vec)),
                      [handler] "r" (&commonExceptionHandler),
                );
            }
        };
        return &Gen.isr;
    } else {
        const Gen = struct {
            fn isr() callconv(.naked) void {
                asm volatile (
                    \\ pushq $0
                    \\ pushq %[v]
                    \\ jmp *%[handler]
                    :
                    : [v] "n" (@as(u64, vec)),
                      [handler] "r" (&commonExceptionHandler),
                );
            }
        };
        return &Gen.isr;
    }
}

export fn commonExceptionHandler() callconv(.naked) void {
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
        \\ movq %%rdi, %%rcx
        \\ subq $40, %%rsp
        \\ call *%[handler]
        \\ addq $40, %%rsp
        \\ pop %%r11
        \\ pop %%r10
        \\ pop %%r9
        \\ pop %%r8
        \\ pop %%rdi
        \\ pop %%rsi
        \\ pop %%rdx
        \\ pop %%rcx
        \\ pop %%rax
        \\ addq $16, %%rsp
        \\ iretq
        :
        : [handler] "r" (&exceptionHandlerZig),
    );
}

export fn kbdHandlerZig() void {
    const scancode = ps2_kbd.readScancode();
    if (kbd_driver.processScancode(scancode)) |event| {
        const seq = nextSequence();
        const frame = events_mod.toMessageFrame(event, seq);
        _ = pushInputMessage(frame);
    }

    fiber.unpark(1);
    if (!builtin.is_test) {
        asm volatile (
            \\ movb $0x20, %%al
            \\ outb %%al, $0x20
        );
    }
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
        \\ subq $40, %%rsp
        \\ call *%[handler]
        \\ addq $40, %%rsp
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
        :
        : [handler] "r" (&kbdHandlerZig),
    );
}

export fn apicTimerHandlerZig() void {
    apic.total_ticks +%= 1;
    const core = smp.global_topology.getCurrentCore();
    _ = smp.global_topology.tick(core.core_id);
    apic.eoi();
}

fn apicTimerInterruptHandler() callconv(.naked) void {
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
        \\ subq $40, %%rsp
        \\ call *%[handler]
        \\ addq $40, %%rsp
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
        :
        : [handler] "r" (&apicTimerHandlerZig),
    );
}

pub fn getGate(vec: u8) IdtEntry {
    return idt_entries[vec];
}

pub fn init() void {
    for (&idt_entries) |*entry| {
        entry.* = std.mem.zeroes(IdtEntry);
    }

    inline for (0..32) |i| {
        setGate(i, @intFromPtr(makeIsr(i)), 0x8E);
    }

    const apic_timer_addr = @intFromPtr(&apicTimerInterruptHandler);
    setGate(32, apic_timer_addr, 0x8E);

    const kbd_handler_addr = @intFromPtr(&keyboardInterruptHandler);
    setGate(33, kbd_handler_addr, 0x8E);

    idt_ptr.limit = @sizeOf(@TypeOf(idt_entries)) - 1;
    idt_ptr.base = @intFromPtr(&idt_entries);

    if (!builtin.is_test) {
        asm volatile ("lidt (%[ptr])"
            :
            : [ptr] "r" (&idt_ptr),
        );
    }
}

test "IDT APIC timer gate 32 and interrupt vector layout" {
    const apic_timer_addr = @intFromPtr(&apicTimerInterruptHandler);
    setGate(32, apic_timer_addr, 0x8E);
    const gate32 = getGate(32);
    try std.testing.expectEqual(@as(u8, 0x8E), gate32.type_attr);
    try std.testing.expectEqual(@as(u16, 0x08), gate32.selector);

    const full_offset: u64 = @as(u64, gate32.offset_low) |
        (@as(u64, gate32.offset_mid) << 16) |
        (@as(u64, gate32.offset_high) << 32);
    try std.testing.expectEqual(apic_timer_addr, full_offset);
}

test "IDT exception gates have distinct vector ISR handlers" {
    init();
    const de_isr = @intFromPtr(makeIsr(0));
    const ud_isr = @intFromPtr(makeIsr(6));
    const gp_isr = @intFromPtr(makeIsr(13));
    const pf_isr = @intFromPtr(makeIsr(14));

    try std.testing.expect(de_isr != ud_isr);
    try std.testing.expect(gp_isr != pf_isr);
    try std.testing.expect(ud_isr != pf_isr);
}
