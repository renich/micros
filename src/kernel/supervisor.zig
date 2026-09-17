// MicrOS (µOS) Actor Supervisor & Fault Containment Subsystem
// Bare-metal Erlang-style fault supervision for child actors ("let it crash").
// Prevents child actor faults (#PF, #GP, #DE) from crashing the microkernel.

const std = @import("std");
const ring_mod = @import("ipc/ring.zig");
const MessageFrame = ring_mod.MessageFrame;
const MessageType = ring_mod.MessageType;
const actor_mod = @import("actor.zig");
const Actor = actor_mod.Actor;
const ActorRegistry = actor_mod.ActorRegistry;
const ActorState = actor_mod.ActorState;

pub const FAULT_FLAG: u16 = 0x0002;
pub const DEFAULT_MAX_RESTARTS: u32 = 5;

pub const FaultVector = struct {
    pub const DIVIDE_ERROR: u16 = 0;
    pub const DEBUG: u16 = 1;
    pub const NMI: u16 = 2;
    pub const BREAKPOINT: u16 = 3;
    pub const OVERFLOW: u16 = 4;
    pub const BOUND_RANGE: u16 = 5;
    pub const INVALID_OPCODE: u16 = 6;
    pub const DEVICE_NOT_AVAIL: u16 = 7;
    pub const DOUBLE_FAULT: u16 = 8;
    pub const GENERAL_PROTECTION: u16 = 13;
    pub const PAGE_FAULT: u16 = 14;
};

pub const RecoveryPolicy = enum(u8) {
    restart_immediate = 1,
    quarantine = 2,
    terminate_and_reclaim = 3,
};

pub const RecoveryAction = enum(u8) {
    restarted = 1,
    quarantined = 2,
    terminated = 3,
};

pub const FaultFrame = extern struct {
    actor_id: u32,
    vector: u16,
    error_code: u16,
    rip: u64,
    rsp: u64,
    cr2: u64,
    rflags: u64,

    pub const EMPTY = FaultFrame{
        .actor_id = 0,
        .vector = 0,
        .error_code = 0,
        .rip = 0,
        .rsp = 0,
        .cr2 = 0,
        .rflags = 0,
    };
};

comptime {
    std.debug.assert(@sizeOf(FaultFrame) == 40);
}

pub fn toMessageFrame(fault: FaultFrame, seq: u32) MessageFrame {
    var frame = MessageFrame.EMPTY;
    frame.msg_type = .event_signal;
    frame.flags = FAULT_FLAG;
    frame.sequence = seq;
    frame.payload_len = @sizeOf(FaultFrame);
    const bytes: *const [@sizeOf(FaultFrame)]u8 = @ptrCast(&fault);
    @memcpy(frame.payload[0..@sizeOf(FaultFrame)], bytes);
    return frame;
}

pub fn fromMessageFrame(frame: *const MessageFrame) ?FaultFrame {
    if (frame.msg_type != .event_signal) return null;
    if ((frame.flags & FAULT_FLAG) == 0) return null;
    if (frame.payload_len < @sizeOf(FaultFrame)) return null;

    var fault: FaultFrame = undefined;
    const dest: *[@sizeOf(FaultFrame)]u8 = @ptrCast(&fault);
    @memcpy(dest, frame.payload[0..@sizeOf(FaultFrame)]);
    return fault;
}

pub const Supervisor = struct {
    registry: *ActorRegistry,
    policy: RecoveryPolicy,
    max_restarts: u32,
    total_faults: u32,

    pub fn init(registry: *ActorRegistry, policy: RecoveryPolicy) Supervisor {
        return Supervisor{
            .registry = registry,
            .policy = policy,
            .max_restarts = DEFAULT_MAX_RESTARTS,
            .total_faults = 0,
        };
    }

    fn applyRestart(target: *Actor, max_allowed: u32) RecoveryAction {
        if (target.restart_count >= max_allowed) {
            target.state = .faulted;
            return .quarantined;
        }
        target.restart_count += 1;
        target.state = .ready;
        return .restarted;
    }

    pub fn handleFault(
        self: *Supervisor,
        allocator: std.mem.Allocator,
        fault: FaultFrame,
    ) actor_mod.ActorError!RecoveryAction {
        self.total_faults += 1;
        const target = self.registry.get(fault.actor_id) orelse return actor_mod.ActorError.ActorNotFound;
        target.state = .faulted;

        return switch (self.policy) {
            .restart_immediate => applyRestart(target, self.max_restarts),
            .quarantine => .quarantined,
            .terminate_and_reclaim => blk: {
                try self.registry.terminate(allocator, fault.actor_id);
                break :blk .terminated;
            },
        };
    }
};

test "FaultFrame memory size and round-trip serialization" {
    try std.testing.expectEqual(40, @sizeOf(FaultFrame));

    const fault = FaultFrame{
        .actor_id = 1,
        .vector = FaultVector.PAGE_FAULT,
        .error_code = 0x0002,
        .rip = 0x00104A20,
        .rsp = 0x00200000,
        .cr2 = 0x00000000,
        .rflags = 0x00000202,
    };

    const frame = toMessageFrame(fault, 101);
    try std.testing.expectEqual(MessageType.event_signal, frame.msg_type);
    try std.testing.expectEqual(FAULT_FLAG, frame.flags);
    try std.testing.expectEqual(101, frame.sequence);
    try std.testing.expectEqual(40, frame.payload_len);

    const recovered = fromMessageFrame(&frame).?;
    try std.testing.expectEqual(@as(u32, 1), recovered.actor_id);
    try std.testing.expectEqual(FaultVector.PAGE_FAULT, recovered.vector);
    try std.testing.expectEqual(@as(u64, 0x00104A20), recovered.rip);
    try std.testing.expectEqual(@as(u64, 0), recovered.cr2);
}

test "Supervisor restart_immediate policy and escalation to quarantine" {
    const allocator = std.testing.allocator;
    var registry = ActorRegistry.init();
    const child = try registry.spawn(allocator, 0, "test_child", 16, 0);
    defer registry.terminate(allocator, child.id) catch {};

    var supervisor = Supervisor.init(&registry, .restart_immediate);
    supervisor.max_restarts = 2;

    const fault = FaultFrame{
        .actor_id = child.id,
        .vector = FaultVector.GENERAL_PROTECTION,
        .error_code = 0,
        .rip = 0x1000,
        .rsp = 0x2000,
        .cr2 = 0,
        .rflags = 0x202,
    };

    // First fault -> restart
    const action1 = try supervisor.handleFault(allocator, fault);
    try std.testing.expectEqual(RecoveryAction.restarted, action1);
    try std.testing.expectEqual(ActorState.ready, child.state);
    try std.testing.expectEqual(@as(u32, 1), child.restart_count);

    // Second fault -> restart
    const action2 = try supervisor.handleFault(allocator, fault);
    try std.testing.expectEqual(RecoveryAction.restarted, action2);
    try std.testing.expectEqual(@as(u32, 2), child.restart_count);

    // Third fault -> exceeds max_restarts -> quarantined
    const action3 = try supervisor.handleFault(allocator, fault);
    try std.testing.expectEqual(RecoveryAction.quarantined, action3);
    try std.testing.expectEqual(ActorState.faulted, child.state);
}

test "Supervisor terminate_and_reclaim policy" {
    const allocator = std.testing.allocator;
    var registry = ActorRegistry.init();
    const child = try registry.spawn(allocator, 0, "victim_child", 16, 0);
    const child_id = child.id;

    var supervisor = Supervisor.init(&registry, .terminate_and_reclaim);

    const fault = FaultFrame{
        .actor_id = child_id,
        .vector = FaultVector.DIVIDE_ERROR,
        .error_code = 0,
        .rip = 0x500,
        .rsp = 0x600,
        .cr2 = 0,
        .rflags = 0x202,
    };

    const action = try supervisor.handleFault(allocator, fault);
    try std.testing.expectEqual(RecoveryAction.terminated, action);
    try std.testing.expectEqual(@as(usize, 0), registry.active_count);
    try std.testing.expect(registry.get(child_id) == null);
}
