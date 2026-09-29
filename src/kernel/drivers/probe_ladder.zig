// MicrOS (µOS) Autonomous Driver Synthesis & Anti-Bricking Probe Ladder
// Implements SPEC-TECH-DRV-001: STG_0..STG_5 state machine, AUDIT_RO write-trip,
// ACTIVE_PROBE bounded whitelist, Token Triad promotion, and QUARANTINE CAS sealing.
// Freestanding, libc-free, zero ambient authority.

const std = @import("std");
const builtin = @import("builtin");
const capability_mod = @import("../cap/capability.zig");
const Capability = capability_mod.Capability;
const CapType = capability_mod.CapType;
const Rights = capability_mod.Rights;
const cspace_mod = @import("../cap/cspace.zig");
const CSpace = cspace_mod.CSpace;
const serial = @import("../serial.zig");
const io = @import("../arch/x86_64/io.zig");

pub const ProbeStage = enum(u8) {
    stg_0_detect = 0,
    stg_1_passive_enum = 1,
    stg_2_offline_synth = 2,
    stg_3_audit_ro = 3,
    stg_4_active_probe = 4,
    stg_5_operational = 5,
    quarantine = 6,
};

pub const ProbeOpType = enum(u8) {
    pci_cfg_read = 0x01,
    mmio_read = 0x02,
    mmio_write = 0x03,
    port_read = 0x04,
    port_write = 0x05,
    irq_wait = 0x06,
    irq_received = 0x07,
    stage_transition = 0x08,
    violation_trip = 0x09,
};

pub const ProbeTranscriptEntry = extern struct {
    timestamp_cycles: u64,
    stage: u8,
    op: ProbeOpType,
    reserved: u8 = 0,
    address: u64,
    value: u64,
    status_code: u32,
};

pub const MAX_TRANSCRIPT_ENTRIES: usize = 64;
pub const MAX_ACTIVE_PROBE_OPS: usize = 16;

pub const ProbeTranscript = struct {
    probe_id: u32,
    vendor_id: u16,
    device_id: u16,
    final_stage: ProbeStage = .stg_0_detect,
    is_quarantined: bool = false,
    entry_count: usize = 0,
    entries: [MAX_TRANSCRIPT_ENTRIES]ProbeTranscriptEntry = [_]ProbeTranscriptEntry{.{
        .timestamp_cycles = 0,
        .stage = 0,
        .op = .pci_cfg_read,
        .address = 0,
        .value = 0,
        .status_code = 0,
    }} ** MAX_TRANSCRIPT_ENTRIES,
    blake3_hash: [32]u8 = [_]u8{0} ** 32,

    pub fn append(self: *ProbeTranscript, stage: ProbeStage, op: ProbeOpType, addr: u64, val: u64, status: u32) void {
        if (self.entry_count < MAX_TRANSCRIPT_ENTRIES) {
            const cycles: u64 = if (builtin.is_test) @intCast(self.entry_count) else io.rdtsc();
            self.entries[self.entry_count] = ProbeTranscriptEntry{
                .timestamp_cycles = cycles,
                .stage = @intFromEnum(stage),
                .op = op,
                .address = addr,
                .value = val,
                .status_code = status,
            };
            self.entry_count += 1;
        }
    }

    pub fn seal(self: *ProbeTranscript) [32]u8 {
        var hasher = std.crypto.hash.Blake3.init(.{});
        const raw_entries = std.mem.sliceAsBytes(self.entries[0..self.entry_count]);
        hasher.update(raw_entries);
        hasher.final(&self.blake3_hash);
        return self.blake3_hash;
    }
};

pub const DeviceDescriptor = struct {
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    bar0_addr: u64,
    bar0_size: u64,
    irq_line: u8,
    // P0-C5: Whitelist addresses are descriptor constants, never actor-supplied
    scratch_reg_offset: ?u64 = null,
    irq_trigger_offset: ?u64 = null,
};

pub const MAX_DMA_REGIONS: usize = 4;

pub const DmaRegion = struct {
    phys_addr: u64,
    size_bytes: u64,
};

pub const TokenTriad = struct {
    hardware_cap_handle: u32,
    irq_cap_handle: u32,
    dma_cap_handle: u32,
    dma_cap_handles: [MAX_DMA_REGIONS]u32 = [_]u32{0} ** MAX_DMA_REGIONS,
    dma_region_count: usize = 0,
};

pub const ProbeError = error{
    InvalidStageTransition,
    AuditRoWriteViolation,
    ActiveProbeCeilingExceeded,
    AddressNotWhitelisted,
    LadderStageViolation,
    DeviceQuarantined,
};

pub var active_probe_session: ?*ProbeSession = null;
pub var cas_put_transcript_fn: ?*const fn (hash: *const [32]u8, data: []const u8) bool = null;

pub const ProbeSession = struct {
    probe_id: u32,
    device: DeviceDescriptor,
    stage: ProbeStage = .stg_0_detect,
    active_write_count: usize = 0,
    transcript: ProbeTranscript,
    probe_cap_handle: ?u32 = null,
    cspace: ?*CSpace = null,
    token_triad: ?TokenTriad = null,

    pub fn init(probe_id: u32, desc: DeviceDescriptor, cspace: ?*CSpace) ProbeSession {
        return ProbeSession{
            .probe_id = probe_id,
            .device = desc,
            .stage = .stg_0_detect,
            .active_write_count = 0,
            .transcript = ProbeTranscript{
                .probe_id = probe_id,
                .vendor_id = desc.vendor_id,
                .device_id = desc.device_id,
            },
            .cspace = cspace,
        };
    }

    pub fn advanceToPassiveEnum(self: *ProbeSession) ProbeError!void {
        if (self.stage != .stg_0_detect) return ProbeError.InvalidStageTransition;
        self.stage = .stg_1_passive_enum;
        self.transcript.append(self.stage, .stage_transition, 0, @intFromEnum(self.stage), 0);
    }

    pub fn advanceToOfflineSynth(self: *ProbeSession) ProbeError!void {
        if (self.stage != .stg_1_passive_enum) return ProbeError.InvalidStageTransition;
        self.stage = .stg_2_offline_synth;
        self.transcript.append(self.stage, .stage_transition, 0, @intFromEnum(self.stage), 0);
    }

    pub fn advanceToAuditRo(self: *ProbeSession) ProbeError!void {
        if (self.stage != .stg_2_offline_synth) return ProbeError.InvalidStageTransition;
        self.stage = .stg_3_audit_ro;
        self.transcript.append(self.stage, .stage_transition, 0, @intFromEnum(self.stage), 0);

        // Grant attenuated read-only hardware probe token
        if (self.cspace) |cs| {
            const probe_cap = Capability{
                .cap_type = .hardware_device,
                .rights = Rights.READ | Rights.REVOKE,
                .object_id = self.device.device_id,
                .data_addr = self.device.bar0_addr,
                .data_size = self.device.bar0_size,
            };
            self.probe_cap_handle = cs.insert(probe_cap) catch null;
        }
    }

    pub fn advanceToActiveProbe(self: *ProbeSession) ProbeError!void {
        if (self.stage != .stg_3_audit_ro) return ProbeError.InvalidStageTransition;
        self.stage = .stg_4_active_probe;
        self.transcript.append(self.stage, .stage_transition, 0, @intFromEnum(self.stage), 0);

        // Attenuate token to allow bounded writes
        if (self.cspace) |cs| {
            if (self.probe_cap_handle) |h| {
                cs.revoke(h) catch {};
            }
            const active_cap = Capability{
                .cap_type = .hardware_device,
                .rights = Rights.READ | Rights.WRITE | Rights.REVOKE,
                .object_id = self.device.device_id,
                .data_addr = self.device.bar0_addr,
                .data_size = self.device.bar0_size,
            };
            self.probe_cap_handle = cs.insert(active_cap) catch null;
        }
    }

    fn mintDmaTokens(self: *ProbeSession, cs: *CSpace, regions: []const DmaRegion, triad: *TokenTriad) ProbeError!void {
        const count = @min(regions.len, MAX_DMA_REGIONS);
        for (regions[0..count], 0..) |reg, i| {
            const dma_cap = Capability{
                .cap_type = .dma_buffer,
                .rights = Rights.READ | Rights.WRITE | Rights.REVOKE,
                .object_id = self.device.device_id,
                .data_addr = reg.phys_addr,
                .data_size = reg.size_bytes,
            };
            const dma_h = cs.insert(dma_cap) catch return ProbeError.InvalidStageTransition;
            triad.dma_cap_handles[i] = dma_h;
            if (i == 0) triad.dma_cap_handle = dma_h;
            triad.dma_region_count += 1;
        }
    }

    fn mintOperationalTriad(self: *ProbeSession, cs: *CSpace, regions: []const DmaRegion) ProbeError!TokenTriad {
        const hw_cap = Capability{
            .cap_type = .hardware_device,
            .rights = Rights.READ | Rights.WRITE | Rights.REVOKE,
            .object_id = self.device.device_id,
            .data_addr = self.device.bar0_addr,
            .data_size = self.device.bar0_size,
        };
        const irq_cap = Capability{
            .cap_type = .irq_endpoint,
            .rights = Rights.READ | Rights.REVOKE,
            .object_id = self.device.irq_line,
            .data_addr = 0,
            .data_size = 0,
        };

        const hw_h = cs.insert(hw_cap) catch return ProbeError.InvalidStageTransition;
        const irq_h = cs.insert(irq_cap) catch return ProbeError.InvalidStageTransition;

        var triad = TokenTriad{
            .hardware_cap_handle = hw_h,
            .irq_cap_handle = irq_h,
            .dma_cap_handle = 0,
        };
        try self.mintDmaTokens(cs, regions, &triad);
        return triad;
    }

    pub fn advanceToOperational(self: *ProbeSession, dma_phys: u64, dma_size: u64) ProbeError!TokenTriad {
        const regions = [_]DmaRegion{.{ .phys_addr = dma_phys, .size_bytes = dma_size }};
        return self.advanceToOperationalRegions(&regions);
    }

    pub fn advanceToOperationalRegions(self: *ProbeSession, regions: []const DmaRegion) ProbeError!TokenTriad {
        if (self.stage != .stg_4_active_probe) return ProbeError.InvalidStageTransition;
        const cs = self.cspace orelse return ProbeError.InvalidStageTransition;

        if (self.probe_cap_handle) |h| {
            cs.revoke(h) catch {};
            self.probe_cap_handle = null;
        }

        const triad = try self.mintOperationalTriad(cs, regions);
        self.token_triad = triad;
        self.stage = .stg_5_operational;
        self.transcript.final_stage = .stg_5_operational;
        self.transcript.append(self.stage, .stage_transition, 0, @intFromEnum(self.stage), 0);
        _ = self.transcript.seal();
        self.commitTranscriptToCas();
        return triad;
    }

    pub fn tripQuarantine(self: *ProbeSession, reason: []const u8, addr: u64, val: u64) void {
        self.stage = .quarantine;
        self.transcript.is_quarantined = true;
        self.transcript.final_stage = .quarantine;
        self.transcript.append(self.stage, .violation_trip, addr, val, 1);

        if (self.cspace) |cs| {
            if (self.probe_cap_handle) |h| {
                cs.revoke(h) catch {};
                self.probe_cap_handle = null;
            }
            if (self.token_triad) |triad| {
                cs.revoke(triad.hardware_cap_handle) catch {};
                cs.revoke(triad.irq_cap_handle) catch {};
                for (triad.dma_cap_handles[0..triad.dma_region_count]) |h| {
                    if (h != 0) cs.revoke(h) catch {};
                }
                self.token_triad = null;
            }
        }

        _ = self.transcript.seal();
        self.commitTranscriptToCas();

        if (!builtin.is_test) {
            serial.writeString("[probe] Hardware violation: ");
            serial.writeString(reason);
            serial.writeString(" -> QUARANTINE (tokens revoked, seal ");
            serial.writeBytesHex(self.transcript.blake3_hash[0..8]);
            serial.writeString(" committed to CAS)\n");
        }
    }

    pub fn executeMmioRead(self: *ProbeSession, offset: u64) ProbeError!u64 {
        if (self.stage == .quarantine) return ProbeError.DeviceQuarantined;
        if (self.stage != .stg_3_audit_ro and self.stage != .stg_4_active_probe and self.stage != .stg_5_operational) {
            self.tripQuarantine("Premature MMIO read before STG_3", self.device.bar0_addr + offset, 0);
            return ProbeError.LadderStageViolation;
        }

        self.transcript.append(self.stage, .mmio_read, self.device.bar0_addr + offset, 0, 0);
        return 0; // Simulated readback in unit tests
    }

    pub fn executeMmioWrite(self: *ProbeSession, offset: u64, value: u64) ProbeError!void {
        if (self.stage == .quarantine) return ProbeError.DeviceQuarantined;

        if (self.stage == .stg_3_audit_ro) {
            // ANY write attempt in STG_3 aborts probe and trips capability fault + quarantine
            self.tripQuarantine("Write attempted in AUDIT_RO sandbox", self.device.bar0_addr + offset, value);
            return ProbeError.AuditRoWriteViolation;
        }

        if (self.stage == .stg_4_active_probe) {
            // Enforce maximum 16 operations
            if (self.active_write_count >= MAX_ACTIVE_PROBE_OPS) {
                self.tripQuarantine("Active probe write count ceiling exceeded (>16 ops)", self.device.bar0_addr + offset, value);
                return ProbeError.ActiveProbeCeilingExceeded;
            }

            // P0-C5: whitelist addresses are descriptor constants, NEVER actor-supplied
            const is_scratch = if (self.device.scratch_reg_offset) |sc| sc == offset else false;
            const is_irq = if (self.device.irq_trigger_offset) |irq| irq == offset else false;
            if (!is_scratch and !is_irq) {
                self.tripQuarantine("Write to non-whitelisted address in ACTIVE_PROBE", self.device.bar0_addr + offset, value);
                return ProbeError.AddressNotWhitelisted;
            }

            self.active_write_count += 1;
            self.transcript.append(self.stage, .mmio_write, self.device.bar0_addr + offset, value, 0);
            return;
        }

        // In STG_0, STG_1, STG_2: writing MMIO is a strict ladder violation
        self.tripQuarantine("Premature MMIO write before STG_4", self.device.bar0_addr + offset, value);
        return ProbeError.LadderStageViolation;
    }

    fn commitTranscriptToCas(self: *ProbeSession) void {
        if (cas_put_transcript_fn) |put_fn| {
            const raw_entries = std.mem.sliceAsBytes(self.transcript.entries[0..self.transcript.entry_count]);
            _ = put_fn(&self.transcript.blake3_hash, raw_entries);
        }
    }
};

// P0-C2 (#PF hook scope): Vector-14 hook range-checks faulting address against active MMIO window
pub fn handlePageFaultTrip(cr2: u64, error_code: u64, rip: u64) bool {
    _ = rip;
    if (active_probe_session) |session| {
        if (session.stage == .stg_3_audit_ro) {
            const bar_start = session.device.bar0_addr;
            const bar_end = bar_start + session.device.bar0_size;
            // Check if faulting address is within the active probe MMIO window
            if (cr2 >= bar_start and cr2 < bar_end) {
                session.tripQuarantine("Write attempted in AUDIT_RO MMIO sandbox", cr2, error_code);
                return true;
            }
        }
    }
    return false; // Fault outside active probe MMIO window -> legacy path bit-for-bit
}

test "D1: probe ladder STG_0 to STG_5 operational progression and Token Triad" {
    const allocator = std.testing.allocator;
    var space = try CSpace.init(allocator, 16);
    defer space.deinit(allocator);

    const desc = DeviceDescriptor{
        .vendor_id = 0x1AF4,
        .device_id = 0x1000,
        .class_code = 0x02,
        .subclass = 0x00,
        .prog_if = 0x00,
        .bar0_addr = 0xFEB0_0000,
        .bar0_size = 4096,
        .irq_line = 11,
        .scratch_reg_offset = 0x14,
        .irq_trigger_offset = 0x18,
    };

    var session = ProbeSession.init(1, desc, space);
    active_probe_session = &session;
    defer active_probe_session = null;

    try session.advanceToPassiveEnum();
    try std.testing.expectEqual(ProbeStage.stg_1_passive_enum, session.stage);

    try session.advanceToOfflineSynth();
    try std.testing.expectEqual(ProbeStage.stg_2_offline_synth, session.stage);

    try session.advanceToAuditRo();
    try std.testing.expectEqual(ProbeStage.stg_3_audit_ro, session.stage);
    // Verified: probe token granted with READ only
    const probe_h = session.probe_cap_handle.?;
    const cap_ro = space.get(probe_h).?;
    try std.testing.expect(cap_ro.hasRight(Rights.READ));
    try std.testing.expect(!cap_ro.hasRight(Rights.WRITE));

    // Valid MMIO read in AUDIT_RO
    _ = try session.executeMmioRead(0x00);

    try session.advanceToActiveProbe();
    try std.testing.expectEqual(ProbeStage.stg_4_active_probe, session.stage);

    // Whitelisted scratch writes succeed up to 16
    var write_idx: usize = 0;
    while (write_idx < 16) : (write_idx += 1) {
        try session.executeMmioWrite(0x14, 0xCAFE);
    }
    try std.testing.expectEqual(@as(usize, 16), session.active_write_count);

    // Operational promotion grants Token Triad
    const triad = try session.advanceToOperational(0x0020_0000, 65536);
    try std.testing.expectEqual(ProbeStage.stg_5_operational, session.stage);

    const hw_token = space.get(triad.hardware_cap_handle).?;
    try std.testing.expectEqual(CapType.hardware_device, hw_token.cap_type);
    try std.testing.expect(hw_token.hasRight(Rights.READ | Rights.WRITE | Rights.REVOKE));

    const irq_token = space.get(triad.irq_cap_handle).?;
    try std.testing.expectEqual(CapType.irq_endpoint, irq_token.cap_type);
    try std.testing.expect(irq_token.hasRight(Rights.READ | Rights.REVOKE));

    const dma_token = space.get(triad.dma_cap_handle).?;
    try std.testing.expectEqual(CapType.dma_buffer, dma_token.cap_type);
    try std.testing.expect(dma_token.hasRight(Rights.READ | Rights.WRITE | Rights.REVOKE));

    // Transcript is sealed with BLAKE3 hash
    try std.testing.expect(!std.mem.allEqual(u8, &session.transcript.blake3_hash, 0));
}

test "D1: STG_3 AUDIT_RO write-trip immediately aborts to QUARANTINE and seals CAS transcript" {
    const allocator = std.testing.allocator;
    var space = try CSpace.init(allocator, 16);
    defer space.deinit(allocator);

    const desc = DeviceDescriptor{
        .vendor_id = 0x8086,
        .device_id = 0x100E,
        .class_code = 0x02,
        .subclass = 0x00,
        .prog_if = 0x00,
        .bar0_addr = 0xFEA0_0000,
        .bar0_size = 4096,
        .irq_line = 10,
        .scratch_reg_offset = 0x20,
    };

    var session = ProbeSession.init(2, desc, space);
    active_probe_session = &session;
    defer active_probe_session = null;

    try session.advanceToPassiveEnum();
    try session.advanceToOfflineSynth();
    try session.advanceToAuditRo();

    const probe_h = session.probe_cap_handle.?;
    try std.testing.expect(space.get(probe_h) != null);

    // Write attempt in AUDIT_RO trips quarantine
    const res = session.executeMmioWrite(0x00, 0xDEAD);
    try std.testing.expectError(ProbeError.AuditRoWriteViolation, res);

    try std.testing.expectEqual(ProbeStage.quarantine, session.stage);
    try std.testing.expect(session.transcript.is_quarantined);

    // Fail-closed: probe tokens revoked via G6
    try std.testing.expect(space.get(probe_h) == null);

    // Sealed CAS transcript
    try std.testing.expect(!std.mem.allEqual(u8, &session.transcript.blake3_hash, 0));
}

test "P0-C2: vector-14 page fault hook range-checks active MMIO window vs legacy path" {
    const desc = DeviceDescriptor{
        .vendor_id = 0x1234,
        .device_id = 0x5678,
        .class_code = 0xFF,
        .subclass = 0x00,
        .prog_if = 0x00,
        .bar0_addr = 0xFEE0_0000,
        .bar0_size = 0x1000,
        .irq_line = 5,
    };

    var session = ProbeSession.init(3, desc, null);
    active_probe_session = &session;
    defer active_probe_session = null;

    session.stage = .stg_3_audit_ro;

    // 1. In-window write fault -> intercepted and shifts device to QUARANTINE
    const in_window_handled = handlePageFaultTrip(0xFEE0_0010, 0x02, 0x1000);
    try std.testing.expect(in_window_handled);
    try std.testing.expectEqual(ProbeStage.quarantine, session.stage);
    try std.testing.expect(session.transcript.is_quarantined);

    // 2. Out-of-window page fault -> returns false, keeping legacy path bit-for-bit
    session.stage = .stg_3_audit_ro; // reset stage for test
    const out_of_window_handled = handlePageFaultTrip(0x7FFF_0000, 0x02, 0x1000);
    try std.testing.expect(!out_of_window_handled);
}

test "P0-C5: active probe 16-op ceiling and non-whitelisted address rejection" {
    const desc = DeviceDescriptor{
        .vendor_id = 0x1AF4,
        .device_id = 0x1000,
        .class_code = 0x02,
        .subclass = 0x00,
        .prog_if = 0x00,
        .bar0_addr = 0xFEB0_0000,
        .bar0_size = 4096,
        .irq_line = 11,
        .scratch_reg_offset = 0x14,
        .irq_trigger_offset = 0x18,
    };

    var session = ProbeSession.init(4, desc, null);
    session.stage = .stg_4_active_probe;

    // 1. Write to non-whitelisted offset rejected
    const bad_addr_res = session.executeMmioWrite(0x20, 0x1234);
    try std.testing.expectError(ProbeError.AddressNotWhitelisted, bad_addr_res);
    try std.testing.expectEqual(ProbeStage.quarantine, session.stage);

    // Reset session for ceiling test
    var session2 = ProbeSession.init(5, desc, null);
    session2.stage = .stg_4_active_probe;

    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try session2.executeMmioWrite(0x14, 0x55);
    }
    // 17th write trips ceiling error
    const ceiling_res = session2.executeMmioWrite(0x14, 0x55);
    try std.testing.expectError(ProbeError.ActiveProbeCeilingExceeded, ceiling_res);
    try std.testing.expectEqual(ProbeStage.quarantine, session2.stage);
}

test "O4: advanceToOperationalRegions covers all 4 DMA regions (rx+tx+rings+bufs)" {
    const allocator = std.testing.allocator;
    var space = try CSpace.init(allocator, 16);
    defer space.deinit(allocator);

    const desc = DeviceDescriptor{
        .vendor_id = 0x1AF4,
        .device_id = 0x1000,
        .class_code = 0x02,
        .subclass = 0x00,
        .prog_if = 0x00,
        .bar0_addr = 0xFEB0_0000,
        .bar0_size = 4096,
        .irq_line = 11,
        .scratch_reg_offset = 0x14,
        .irq_trigger_offset = 0x18,
    };

    var session = ProbeSession.init(6, desc, space);
    try session.advanceToPassiveEnum();
    try session.advanceToOfflineSynth();
    try session.advanceToAuditRo();
    try session.advanceToActiveProbe();

    const regions = [_]DmaRegion{
        .{ .phys_addr = 0x0020_0000, .size_bytes = 16384 },
        .{ .phys_addr = 0x0021_0000, .size_bytes = 16384 },
        .{ .phys_addr = 0x0022_0000, .size_bytes = 65536 },
        .{ .phys_addr = 0x0023_0000, .size_bytes = 4096 },
    };

    const triad = try session.advanceToOperationalRegions(&regions);
    try std.testing.expectEqual(@as(usize, 4), triad.dma_region_count);

    for (triad.dma_cap_handles[0..4], 0..) |h, idx| {
        const token = space.get(h).?;
        try std.testing.expectEqual(CapType.dma_buffer, token.cap_type);
        try std.testing.expectEqual(regions[idx].phys_addr, token.data_addr);
        try std.testing.expectEqual(regions[idx].size_bytes, token.data_size);
        try std.testing.expect(token.hasRight(Rights.READ | Rights.WRITE | Rights.REVOKE));
    }

    session.tripQuarantine("Post-operational fault", 0xFEB0_0000, 0);
    try std.testing.expectEqual(ProbeStage.quarantine, session.stage);
    for (triad.dma_cap_handles[0..4]) |h| {
        try std.testing.expect(space.get(h) == null);
    }
}
