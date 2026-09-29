// MicrOS (µOS) x86_64 Local APIC & Hardware Preemption Timer
// Manages LAPIC discovery, periodic 1000Hz preemption timer, and INIT-SIPI multicore bringup.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("io.zig");

pub const ApicRegister = enum(u32) {
    id = 0x0020,
    version = 0x0030,
    tpr = 0x0080,
    eoi = 0x00B0,
    ldr = 0x00D0,
    dfr = 0x00E0,
    sivr = 0x00F0,
    esr = 0x0280,
    icr_low = 0x0300,
    icr_high = 0x0310,
    lvt_timer = 0x0320,
    lvt_lint0 = 0x0350,
    lvt_lint1 = 0x0360,
    lvt_error = 0x0370,
    timer_init = 0x0380,
    timer_curr = 0x0390,
    timer_div = 0x03E0,
};

pub const LAPIC_ID: u32 = @intFromEnum(ApicRegister.id);
pub const LAPIC_VER: u32 = @intFromEnum(ApicRegister.version);
pub const LAPIC_TPR: u32 = @intFromEnum(ApicRegister.tpr);
pub const LAPIC_EOI: u32 = @intFromEnum(ApicRegister.eoi);
pub const LAPIC_LDR: u32 = @intFromEnum(ApicRegister.ldr);
pub const LAPIC_DFR: u32 = @intFromEnum(ApicRegister.dfr);
pub const LAPIC_SIVR: u32 = @intFromEnum(ApicRegister.sivr);
pub const LAPIC_ESR: u32 = @intFromEnum(ApicRegister.esr);
pub const LAPIC_ICR_LOW: u32 = @intFromEnum(ApicRegister.icr_low);
pub const LAPIC_ICR_HIGH: u32 = @intFromEnum(ApicRegister.icr_high);
pub const LAPIC_LVT_TIMER: u32 = @intFromEnum(ApicRegister.lvt_timer);
pub const LAPIC_LVT_LINT0: u32 = @intFromEnum(ApicRegister.lvt_lint0);
pub const LAPIC_LVT_LINT1: u32 = @intFromEnum(ApicRegister.lvt_lint1);
pub const LAPIC_LVT_ERROR: u32 = @intFromEnum(ApicRegister.lvt_error);
pub const LAPIC_TIMER_INIT: u32 = @intFromEnum(ApicRegister.timer_init);
pub const LAPIC_TIMER_CURR: u32 = @intFromEnum(ApicRegister.timer_curr);
pub const LAPIC_TIMER_DIV: u32 = @intFromEnum(ApicRegister.timer_div);

pub const MSR_APIC_BASE: u32 = 0x001B;
pub const APIC_BASE_BSP: u64 = 1 << 8;
pub const APIC_BASE_ENABLE: u64 = 1 << 11;
pub const APIC_SW_ENABLE: u32 = 1 << 8;
pub const TIMER_PERIODIC: u32 = 1 << 17;
pub const TIMER_VECTOR: u8 = 0x20; // IDT vector 32
pub const DEFAULT_LAPIC_BASE: u64 = 0xFEE0_0000;
pub const DEFAULT_QUANTUM_TICKS: u32 = 100_000; // Calibrated 1ms quantum (~1000Hz)

pub const ICR_DELIVERY_INIT: u32 = 0b101 << 8;
pub const ICR_DELIVERY_STARTUP: u32 = 0b110 << 8;
pub const ICR_LEVEL_ASSERT: u32 = 1 << 14;
pub const ICR_TRIGGER_EDGE: u32 = 0 << 15;

pub var lapic_virt_base: u64 = DEFAULT_LAPIC_BASE;
pub var lapic_enabled: bool = false;
pub var total_ticks = std.atomic.Value(u64).init(0);

pub inline fn getTicks() u64 {
    return total_ticks.load(.monotonic);
}

pub fn readReg(reg: ApicRegister) u32 {
    if (builtin.is_test or !lapic_enabled) return 0;
    const offset = @intFromEnum(reg);
    const ptr: *volatile u32 = @ptrFromInt(lapic_virt_base + offset);
    return ptr.*;
}

pub fn writeReg(reg: ApicRegister, val: u32) void {
    if (builtin.is_test or !lapic_enabled) return;
    const offset = @intFromEnum(reg);
    const ptr: *volatile u32 = @ptrFromInt(lapic_virt_base + offset);
    ptr.* = val;
}

pub fn getApicBasePhys() u64 {
    if (builtin.is_test) return DEFAULT_LAPIC_BASE;
    const msr_val = io.rdmsr(MSR_APIC_BASE);
    const base = msr_val & 0x000F_FFFF_FFFF_F000;
    if (base == 0) return DEFAULT_LAPIC_BASE;
    return base;
}

pub fn enableLapic(hhdm_base: u64) void {
    const phys_base = getApicBasePhys();
    lapic_virt_base = phys_base + hhdm_base;
    lapic_enabled = true;

    if (!builtin.is_test) {
        // Ensure APIC enabled in MSR
        const msr_val = io.rdmsr(MSR_APIC_BASE);
        if ((msr_val & APIC_BASE_ENABLE) == 0) {
            io.wrmsr(MSR_APIC_BASE, msr_val | APIC_BASE_ENABLE);
        }

        // Program SIVR: enable software APIC + spurious vector 0xFF
        writeReg(.sivr, APIC_SW_ENABLE | 0xFF);
        // Clear TPR: accept all interrupt priorities
        writeReg(.tpr, 0);
    }
}

pub fn initTimer(quantum_ticks: u32) void {
    if (!lapic_enabled and !builtin.is_test) return;

    // Divide by 16: value 0x03
    writeReg(.timer_div, 0x03);

    // LVT Timer: Periodic mode | vector 0x20
    const lvt_val: u32 = TIMER_PERIODIC | @as(u32, TIMER_VECTOR);
    writeReg(.lvt_timer, lvt_val);

    // Initial count
    writeReg(.timer_init, quantum_ticks);
}

pub fn eoi() void {
    if (!lapic_enabled and !builtin.is_test) return;
    writeReg(.eoi, 0);
}

pub fn getApicId() u32 {
    if (builtin.is_test or !lapic_enabled) return 0;
    return (readReg(.id) >> 24) & 0xFF;
}

pub fn sendInitIpi(target_apic_id: u32) void {
    if (!lapic_enabled and !builtin.is_test) return;
    writeReg(.icr_high, target_apic_id << 24);
    writeReg(.icr_low, ICR_DELIVERY_INIT | ICR_LEVEL_ASSERT | ICR_TRIGGER_EDGE);
}

pub fn sendStartupIpi(target_apic_id: u32, trampoline_vector: u8) void {
    if (!lapic_enabled and !builtin.is_test) return;
    writeReg(.icr_high, target_apic_id << 24);
    writeReg(.icr_low, ICR_DELIVERY_STARTUP | ICR_TRIGGER_EDGE | @as(u32, trampoline_vector));
}

test "apic register offsets and bitmask calculations" {
    try std.testing.expectEqual(@as(u32, 0x0020), LAPIC_ID);
    try std.testing.expectEqual(@as(u32, 0x00B0), LAPIC_EOI);
    try std.testing.expectEqual(@as(u32, 0x00F0), LAPIC_SIVR);
    try std.testing.expectEqual(@as(u32, 0x0320), LAPIC_LVT_TIMER);
    try std.testing.expectEqual(@as(u32, 0x0380), LAPIC_TIMER_INIT);
    try std.testing.expectEqual(@as(u32, 0x03E0), LAPIC_TIMER_DIV);

    try std.testing.expectEqual(ApicRegister.id, @as(ApicRegister, @enumFromInt(0x0020)));
    try std.testing.expectEqual(ApicRegister.eoi, @as(ApicRegister, @enumFromInt(0x00B0)));
    try std.testing.expectEqual(ApicRegister.sivr, @as(ApicRegister, @enumFromInt(0x00F0)));
    try std.testing.expectEqual(ApicRegister.lvt_timer, @as(ApicRegister, @enumFromInt(0x0320)));

    const periodic_lvt = TIMER_PERIODIC | @as(u32, TIMER_VECTOR);
    try std.testing.expectEqual(@as(u32, 0x00020020), periodic_lvt);

    const init_icr = ICR_DELIVERY_INIT | ICR_LEVEL_ASSERT | ICR_TRIGGER_EDGE;
    try std.testing.expectEqual(@as(u32, 0x00004500), init_icr);

    const sipi_icr = ICR_DELIVERY_STARTUP | ICR_TRIGGER_EDGE | 0x08;
    try std.testing.expectEqual(@as(u32, 0x00000608), sipi_icr);
}

test "apic initialization and timer configuration in host test mode" {
    enableLapic(0);
    try std.testing.expect(lapic_enabled);
    initTimer(DEFAULT_QUANTUM_TICKS);
    eoi();
    try std.testing.expectEqual(@as(u32, 0), getApicId());
    sendInitIpi(1);
    sendStartupIpi(1, 0x08);
}
