const std = @import("std");
const builtin = @import("builtin");

pub const STACK_SIZE: usize = 2 * 1024 * 1024; // 2 MB stack per fiber (accommodates TLS 1.3 ML-KEM-768 cryptographic state)
pub const GUARD_SIZE: usize = 4096;
pub const SLOT_SIZE: usize = STACK_SIZE + GUARD_SIZE;

pub const CANARY_MAGIC: u64 = 0xDEADBEEFCAFEBABE;
pub const MAX_STACK_SLOTS: usize = 4;
var stack_pool: [MAX_STACK_SLOTS][SLOT_SIZE]u8 align(4096) = undefined;
var stack_used: [MAX_STACK_SLOTS]bool = [_]bool{false} ** MAX_STACK_SLOTS;

pub const FiberState = enum {
    ready,
    running,
    suspended,
    terminated,
};

pub const FiberFn = *const fn (ctx: ?*anyopaque) void;

pub const Fiber = struct {
    id: usize,
    stack: []u8,
    rsp: usize,
    state: FiberState,
    entry: ?FiberFn,
    user_data: ?*anyopaque,
    next: ?*Fiber,
    pool_slot: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, id: usize, entry: FiberFn, user_data: ?*anyopaque) !*Fiber {
        var slot_idx: ?usize = null;
        for (&stack_used, 0..) |*used, idx| {
            if (!used.*) {
                used.* = true;
                slot_idx = idx;
                break;
            }
        }

        if (slot_idx) |idx| {
            @memset(stack_pool[idx][0..GUARD_SIZE], 0xAA);
        }

        const stack_slice = if (slot_idx) |idx|
            stack_pool[idx][GUARD_SIZE..SLOT_SIZE]
        else
            try allocator.alloc(u8, STACK_SIZE);
        errdefer {
            if (slot_idx) |idx| {
                stack_used[idx] = false;
            } else {
                allocator.free(stack_slice);
            }
        }

        const fiber = try allocator.create(Fiber);
        fiber.* = Fiber{
            .id = id,
            .stack = stack_slice,
            .rsp = 0,
            .state = .ready,
            .entry = entry,
            .user_data = user_data,
            .next = null,
            .pool_slot = slot_idx,
        };
        fiber.initStack();
        return fiber;
    }

    pub fn deinit(self: *Fiber, allocator: std.mem.Allocator) void {
        if (self.pool_slot) |idx| {
            stack_used[idx] = false;
        } else {
            allocator.free(self.stack);
        }
        allocator.destroy(self);
    }

    fn initStack(self: *Fiber) void {
        @as(*u64, @ptrCast(@alignCast(self.stack.ptr))).* = CANARY_MAGIC;
        const top = @intFromPtr(self.stack.ptr) + self.stack.len;
        var sp = std.mem.alignBackward(usize, top, 16);

        // Win64/SysV ABI: function entry requires (RSP + 8) % 16 == 0.
        // Push 0 as dummy frame return address for fiberTrampoline
        sp -= 8;
        @as(*usize, @ptrFromInt(sp)).* = 0;

        // Push trampoline as return address popped by switchContext
        sp -= 8;
        @as(*usize, @ptrFromInt(sp)).* = @intFromPtr(&fiberTrampoline);

        // Non-volatile registers (Win64: 8 regs, SysV: 6 regs)
        const num_regs: usize = if (builtin.os.tag == .uefi) 8 else 6;
        var i: usize = 0;
        while (i < num_regs) : (i += 1) {
            sp -= 8;
            @as(*usize, @ptrFromInt(sp)).* = 0;
        }

        if (builtin.os.tag == .uefi) {
            sp -= 160;
            @memset(@as([*]u8, @ptrFromInt(sp))[0..160], 0);
        }

        self.rsp = sp;
    }

    pub fn checkCanary(self: *const Fiber) bool {
        const canary = @as(*const u64, @ptrCast(@alignCast(self.stack.ptr))).*;
        if (canary != CANARY_MAGIC) return false;
        if (self.pool_slot) |idx| {
            for (stack_pool[idx][0..GUARD_SIZE]) |byte| {
                if (byte != 0xAA) return false;
            }
        }
        return true;
    }
};

fn fiberTrampoline() callconv(.c) void {
    if (current_scheduler) |sched| {
        if (sched.current) |fib| {
            if (fib.entry) |entry_fn| {
                entry_fn(fib.user_data);
            }
            fib.state = .terminated;
            sched.yield();
        }
    }
    terminateCurrent();
}

pub fn terminateCurrent() noreturn {
    if (current_scheduler) |sched| {
        if (sched.current) |fib| {
            fib.state = .terminated;
            switchContext(&fib.rsp, sched.main_rsp);
        }
    }
    while (true) {
        asm volatile ("hlt");
    }
}

extern fn switchContextSysV(from_rsp: *usize, to_rsp: usize) void;
extern fn switchContextWin64(from_rsp: *usize, to_rsp: usize) void;

pub fn switchContext(from_rsp: *usize, to_rsp: usize) void {
    if (builtin.os.tag == .uefi) {
        switchContextWin64(from_rsp, to_rsp);
    } else {
        switchContextSysV(from_rsp, to_rsp);
    }
}

var current_scheduler: ?*Scheduler = null;

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    main_rsp: usize,
    current: ?*Fiber,
    head: ?*Fiber,
    tail: ?*Fiber,
    next_id: usize,
    on_context_switch: ?*const fn (fib: ?*Fiber) void,

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return Scheduler{
            .allocator = allocator,
            .main_rsp = 0,
            .current = null,
            .head = null,
            .tail = null,
            .next_id = 1,
            .on_context_switch = null,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        var cur = self.head;
        while (cur) |fib| {
            const next = fib.next;
            fib.deinit(self.allocator);
            cur = next;
        }
        self.head = null;
        self.tail = null;
    }

    pub fn spawn(self: *Scheduler, entry: FiberFn, user_data: ?*anyopaque) !*Fiber {
        const fib = try Fiber.init(self.allocator, self.next_id, entry, user_data);
        self.next_id += 1;
        self.enqueue(fib);
        return fib;
    }

    fn enqueue(self: *Scheduler, fib: *Fiber) void {
        fib.next = null;
        if (self.tail) |t| {
            t.next = fib;
            self.tail = fib;
        } else {
            self.head = fib;
            self.tail = fib;
        }
    }

    fn dequeue(self: *Scheduler) ?*Fiber {
        const first = self.head orelse return null;
        self.head = first.next;
        if (self.head == null) {
            self.tail = null;
        }
        first.next = null;
        return first;
    }

    fn checkFiberStates(self: *const Scheduler) struct { any_fibers: bool, all_suspended: bool } {
        var any_fibers = false;
        var all_suspended = true;
        var cur = self.head;
        while (cur) |fib| : (cur = fib.next) {
            any_fibers = true;
            if (fib.state == .ready) {
                all_suspended = false;
                break;
            }
        }
        return .{ .any_fibers = any_fibers, .all_suspended = all_suspended };
    }

    fn dispatchNextFiber(self: *Scheduler) void {
        const fib = self.dequeue() orelse return;
        if (fib.state == .terminated) {
            fib.deinit(self.allocator);
            return;
        }
        if (fib.state == .suspended) {
            self.enqueue(fib);
            return;
        }

        self.current = fib;
        fib.state = .running;
        if (self.on_context_switch) |hook| hook(fib);
        switchContext(&self.main_rsp, fib.rsp);
        if (self.on_context_switch) |hook| hook(null);

        if (!fib.checkCanary()) {
            fib.state = .terminated;
        }

        if (fib.state == .ready or fib.state == .suspended) {
            self.enqueue(fib);
        } else if (fib.state == .terminated) {
            fib.deinit(self.allocator);
        }
    }

    pub fn run(self: *Scheduler) void {
        current_scheduler = self;
        defer current_scheduler = null;

        while (true) {
            const states = self.checkFiberStates();
            if (!states.any_fibers) break;
            if (states.all_suspended) {
                asm volatile ("hlt");
                continue;
            }
            self.dispatchNextFiber();
        }
        self.current = null;
    }

    pub fn yield(self: *Scheduler) void {
        if (self.current) |fib| {
            if (fib.state == .running) {
                fib.state = .ready;
            }
            switchContext(&fib.rsp, self.main_rsp);
        }
    }

    pub fn park(self: *Scheduler) void {
        if (self.current) |fib| {
            if (fib.state == .running) {
                fib.state = .suspended;
            }
            switchContext(&fib.rsp, self.main_rsp);
        }
    }
};

pub fn unpark(id: usize) void {
    if (current_scheduler) |sched| {
        var cur = sched.head;
        while (cur) |fib| {
            if (fib.id == id and fib.state == .suspended) {
                fib.state = .ready;
            }
            cur = fib.next;
        }
    }
}

pub fn yield() void {
    if (current_scheduler) |sched| {
        sched.yield();
    }
}

const testing = std.testing;

var test_counter: usize = 0;

fn fiberTestTask(ctx: ?*anyopaque) void {
    _ = ctx;
    test_counter += 10;
    if (current_scheduler) |s| {
        s.yield();
    }
    test_counter += 5;
}

test "Fiber scheduler cooperative execution" {
    var sched = Scheduler.init(testing.allocator);
    defer sched.deinit();

    test_counter = 0;
    _ = try sched.spawn(fiberTestTask, null);
    _ = try sched.spawn(fiberTestTask, null);

    sched.run();
    try testing.expectEqual(@as(usize, 30), test_counter);
}
