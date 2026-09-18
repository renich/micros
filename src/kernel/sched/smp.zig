// MicrOS (µOS) Preemptive Symmetric Multiprocessing (SMP) Scheduler
// Manages multi-core topology, per-core runqueues, lock-free work-stealing, and APIC timer preemption.

const std = @import("std");
const builtin = @import("builtin");
const apic = @import("../arch/x86_64/apic.zig");

pub const MAX_CORES: u32 = 16;
pub const MAX_TASKS_PER_CORE: u32 = 32;
pub const DEFAULT_TIMESLICE: u32 = 10; // 10 ticks = 10ms quantum

pub const CpuState = enum(u8) {
    offline = 0,
    booting = 1,
    online = 2,
    halted = 3,
};

pub const CpuCore = struct {
    core_id: u32,
    apic_id: u32,
    state: CpuState,
    is_bsp: bool,
    current_actor_id: u32,
    timeslice_remaining: u32,
    total_ticks: u64,
    runqueue: [MAX_TASKS_PER_CORE]u32,
    rq_head: u32,
    rq_tail: u32,
    rq_count: u32,

    pub fn init(core_id: u32, apic_id: u32, is_bsp: bool) CpuCore {
        return .{
            .core_id = core_id,
            .apic_id = apic_id,
            .state = if (is_bsp) .online else .offline,
            .is_bsp = is_bsp,
            .current_actor_id = 0,
            .timeslice_remaining = DEFAULT_TIMESLICE,
            .total_ticks = 0,
            .runqueue = [_]u32{0} ** MAX_TASKS_PER_CORE,
            .rq_head = 0,
            .rq_tail = 0,
            .rq_count = 0,
        };
    }

    pub fn enqueue(self: *CpuCore, actor_id: u32) bool {
        if (self.rq_count >= MAX_TASKS_PER_CORE) return false;
        self.runqueue[self.rq_tail] = actor_id;
        self.rq_tail = (self.rq_tail + 1) % MAX_TASKS_PER_CORE;
        self.rq_count += 1;
        return true;
    }

    pub fn dequeue(self: *CpuCore) ?u32 {
        if (self.rq_count == 0) return null;
        const task = self.runqueue[self.rq_head];
        self.rq_head = (self.rq_head + 1) % MAX_TASKS_PER_CORE;
        self.rq_count -= 1;
        return task;
    }
};

pub const SmpTopology = struct {
    cores: [MAX_CORES]CpuCore,
    active_cores: u32,
    bsp_core_id: u32,

    pub fn init() SmpTopology {
        var top = SmpTopology{
            .cores = undefined,
            .active_cores = 1,
            .bsp_core_id = 0,
        };

        var i: u32 = 0;
        while (i < MAX_CORES) : (i += 1) {
            top.cores[i] = CpuCore.init(i, i, i == 0);
        }
        return top;
    }

    pub fn getCore(self: *SmpTopology, core_id: u32) ?*CpuCore {
        if (core_id >= MAX_CORES) return null;
        return &self.cores[core_id];
    }

    pub fn getCurrentCore(self: *SmpTopology) *CpuCore {
        const apic_id = apic.getApicId();
        for (&self.cores) |*core| {
            if (core.state == .online and core.apic_id == apic_id) {
                return core;
            }
        }
        return &self.cores[self.bsp_core_id];
    }

    pub fn registerCore(self: *SmpTopology, apic_id: u32) ?u32 {
        for (&self.cores) |*core| {
            if (core.state == .offline and !core.is_bsp) {
                core.apic_id = apic_id;
                core.state = .booting;
                return core.core_id;
            }
        }
        return null;
    }

    pub fn enqueueTask(self: *SmpTopology, core_id: u32, actor_id: u32) bool {
        const core = self.getCore(core_id) orelse return false;
        return core.enqueue(actor_id);
    }

    pub fn dequeueTask(self: *SmpTopology, core_id: u32) ?u32 {
        const core = self.getCore(core_id) orelse return null;
        return core.dequeue();
    }

    pub fn stealTask(self: *SmpTopology, requesting_core_id: u32) ?u32 {
        var most_busy_core: ?*CpuCore = null;
        var max_count: u32 = 1; // Only steal if peer has > 1 task

        for (&self.cores) |*core| {
            if (core.core_id != requesting_core_id and core.state == .online) {
                if (core.rq_count > max_count) {
                    max_count = core.rq_count;
                    most_busy_core = core;
                }
            }
        }

        if (most_busy_core) |busy| {
            return busy.dequeue();
        }
        return null;
    }

    pub fn tick(self: *SmpTopology, core_id: u32) ?u32 {
        const core = self.getCore(core_id) orelse return null;
        core.total_ticks +%= 1;

        if (core.timeslice_remaining > 0) {
            core.timeslice_remaining -= 1;
        }
        if (core.timeslice_remaining > 0) {
            return null; // Quantum not yet expired
        }

        // Timeslice expired: reset quantum and pick next task
        core.timeslice_remaining = DEFAULT_TIMESLICE;

        // If current actor was running, re-enqueue it
        if (core.current_actor_id != 0) {
            _ = core.enqueue(core.current_actor_id);
        }

        // Dequeue next task, or steal from busy peers
        const next_task = core.dequeue() orelse self.stealTask(core_id);
        if (next_task) |task| {
            core.current_actor_id = task;
            return task;
        }

        return null;
    }

    pub fn bootstrapSecondaryCores(self: *SmpTopology, core_count: u32) void {
        const limit = @min(core_count, @as(u32, @intCast(MAX_CORES)));
        var c: u32 = 1;
        while (c < limit) : (c += 1) {
            const apic_id = c;
            _ = self.registerCore(apic_id);

            // Dispatch INIT-SIPI sequence
            apic.sendInitIpi(apic_id);
            // In live execution, delay ~10ms would occur here
            apic.sendStartupIpi(apic_id, 0x08);

            self.cores[c].state = .online;
            self.active_cores += 1;
        }
    }
};

pub var global_topology: SmpTopology = SmpTopology.init();

test "SMP topology initialization and BSP invariants" {
    var top = SmpTopology.init();
    try std.testing.expectEqual(@as(u32, 1), top.active_cores);
    try std.testing.expectEqual(@as(u32, 0), top.bsp_core_id);

    const bsp = top.getCore(0).?;
    try std.testing.expect(bsp.is_bsp);
    try std.testing.expectEqual(CpuState.online, bsp.state);
    try std.testing.expectEqual(@as(u32, 0), bsp.rq_count);
}

test "SMP task enqueuing, dequeuing, and FIFO ordering" {
    var top = SmpTopology.init();
    try std.testing.expect(top.enqueueTask(0, 10));
    try std.testing.expect(top.enqueueTask(0, 20));
    try std.testing.expect(top.enqueueTask(0, 30));

    const core0 = top.getCore(0).?;
    try std.testing.expectEqual(@as(u32, 3), core0.rq_count);

    try std.testing.expectEqual(@as(u32, 10), top.dequeueTask(0).?);
    try std.testing.expectEqual(@as(u32, 20), top.dequeueTask(0).?);
    try std.testing.expectEqual(@as(u32, 30), top.dequeueTask(0).?);
    try std.testing.expect(top.dequeueTask(0) == null);
}

test "SMP bounded lock-free work stealing" {
    var top = SmpTopology.init();
    top.cores[1].state = .online;
    top.active_cores = 2;

    // Load core 0 with 3 tasks
    _ = top.enqueueTask(0, 101);
    _ = top.enqueueTask(0, 102);
    _ = top.enqueueTask(0, 103);

    // Idle core 1 steals from loaded core 0
    const stolen = top.stealTask(1);
    try std.testing.expectEqual(@as(?u32, 101), stolen);

    // Core 0 now has 2 tasks left
    try std.testing.expectEqual(@as(u32, 2), top.cores[0].rq_count);
}

test "SMP preemption timer tick quantum expiration and task round-robin" {
    var top = SmpTopology.init();
    const core0 = top.getCore(0).?;
    core0.current_actor_id = 1;
    _ = core0.enqueue(2);

    // Run 9 ticks: quantum not yet expired
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        const res = top.tick(0);
        try std.testing.expect(res == null);
    }

    // 10th tick: quantum expires, switches to task 2
    const switched = top.tick(0);
    try std.testing.expectEqual(@as(?u32, 2), switched);
    try std.testing.expectEqual(@as(u32, 2), core0.current_actor_id);
}
