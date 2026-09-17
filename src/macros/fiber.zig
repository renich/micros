const std = @import("std");
const builtin = @import("builtin");

pub const STACK_SIZE: usize = 512 * 1024; // 512 KB stack per fiber (accommodates TLS 1.3 cryptographic state)

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

    pub fn init(allocator: std.mem.Allocator, id: usize, entry: FiberFn, user_data: ?*anyopaque) !*Fiber {
        const stack_slice = try allocator.alloc(u8, STACK_SIZE);
        errdefer allocator.free(stack_slice);

        const fiber = try allocator.create(Fiber);
        fiber.* = Fiber{
            .id = id,
            .stack = stack_slice,
            .rsp = 0,
            .state = .ready,
            .entry = entry,
            .user_data = user_data,
            .next = null,
        };
        fiber.initStack();
        return fiber;
    }

    pub fn deinit(self: *Fiber, allocator: std.mem.Allocator) void {
        allocator.free(self.stack);
        allocator.destroy(self);
    }

    fn initStack(self: *Fiber) void {
        const top = @intFromPtr(self.stack.ptr) + self.stack.len;
        var sp = std.mem.alignBackward(usize, top, 16);

        // Position trampoline return address so that after ret, rsp % 16 == 8
        sp -= 16;
        const trampoline_ptr = @intFromPtr(&fiberTrampoline);
        @as(*usize, @ptrFromInt(sp)).* = trampoline_ptr;

        const reg_count: usize = if (builtin.os.tag == .uefi) 8 else 6;
        var i: usize = 0;
        while (i < reg_count) : (i += 1) {
            sp -= 8;
            @as(*usize, @ptrFromInt(sp)).* = 0;
        }

        self.rsp = sp;
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

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return Scheduler{
            .allocator = allocator,
            .main_rsp = 0,
            .current = null,
            .head = null,
            .tail = null,
            .next_id = 1,
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
        switchContext(&self.main_rsp, fib.rsp);

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
