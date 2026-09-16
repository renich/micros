const std = @import("std");
const eval = @import("eval.zig");
const Value = eval.Value;
const chunk_mod = @import("chunk.zig");

const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const gc = @import("gc.zig");
const tracer = @import("tracer.zig");

pub const InterpretError = error{
    CompileError,
    RuntimeError,
    StackOverflow,
    StackUnderflow,
};

fn nativePush(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2) return InterpretError.RuntimeError;
    if (args[0] != .array) return InterpretError.RuntimeError;
    try args[0].array.append(vm.allocator, args[1]);
    return args[0];
}

fn nativeLen(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1) return InterpretError.RuntimeError;
    if (args[0] == .array) {
        return Value{ .integer = @intCast(args[0].array.items.len) };
    } else if (args[0] == .string) {
        return Value{ .integer = @intCast(args[0].string.len) };
    }
    return InterpretError.RuntimeError;
}

fn nativeSubstr(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 3) return InterpretError.RuntimeError;
    if (args[0] != .string or args[1] != .integer or args[2] != .integer) return InterpretError.RuntimeError;
    const start: usize = @intCast(args[1].integer);
    const end: usize = @intCast(args[2].integer);
    if (start > end or end > args[0].string.len) return InterpretError.RuntimeError;
    return Value{ .string = args[0].string[start..end] };
}

pub const CallFrame = struct {
    function: eval.Function,
    ip: usize,
    slots_offset: usize,
};

pub const VM = struct {
    allocator: std.mem.Allocator,
    chunk: *chunk_mod.Chunk,
    ip: usize,
    stack: [256]Value,
    sp: usize,
    frames: [64]CallFrame,
    frame_count: usize,
    globals: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator, ch: *chunk_mod.Chunk) !VM {
        var vm = VM{
            .allocator = allocator,
            .chunk = ch,
            .ip = 0,
            .sp = 0,
            .frames = undefined,
            .frame_count = 0,
            .stack = undefined,
            .globals = std.StringHashMap(Value).init(allocator),
        };
        try vm.globals.put("push", Value{ .native = nativePush });
        try vm.globals.put("len", Value{ .native = nativeLen });
        try vm.globals.put("substr", Value{ .native = nativeSubstr });
        return vm;
    }

    pub fn deinit(self: *VM) void {
        self.globals.deinit();
    }

    pub fn collect(self: *VM, heap: *gc.Heap) void {
        heap.clearMarks();

        // Trace constants
        for (self.chunk.constants.items) |constant| {
            tracer.traceValue(heap, constant);
        }

        // Trace globals
        var it = self.globals.iterator();
        while (it.next()) |entry| {
            tracer.traceValue(heap, entry.value_ptr.*);
        }

        // Trace stack
        for (self.stack[0..self.sp]) |val| {
            tracer.traceValue(heap, val);
        }

        heap.sweep();
    }

    pub fn push(self: *VM, value: Value) !void {
        if (self.sp >= self.stack.len) return InterpretError.StackOverflow;
        self.stack[self.sp] = value;
        self.sp += 1;
    }

    pub fn pop(self: *VM) !Value {
        if (self.sp == 0) return InterpretError.StackUnderflow;
        self.sp -= 1;
        return self.stack[self.sp];
    }

    fn readByte(self: *VM) u8 {
        const byte = self.chunk.code.items[self.ip];
        self.ip += 1;
        return byte;
    }

    fn readShort(self: *VM) u16 {
        const high = self.readByte();
        const low = self.readByte();
        return (@as(u16, high) << 8) | @as(u16, low);
    }

    fn readConstant(self: *VM) Value {
        const idx = self.readShort();
        return self.chunk.constants.items[idx];
    }

    pub fn pushFrame(self: *VM, func: eval.Function, arg_count: usize) !void {
        if (self.frame_count >= self.frames.len) return InterpretError.StackOverflow;
        self.frames[self.frame_count] = CallFrame{
            .function = func,
            .ip = self.ip,
            .slots_offset = self.sp - arg_count,
        };
        self.frame_count += 1;
        std.debug.print("PUSH_FRAME: func={s}, arg_count={}, local_count={}\n", .{func.name, arg_count, func.local_count});
        var i: usize = arg_count;
        while (i < func.local_count) : (i += 1) {
            try self.push(Value{ .nil = {} });
        }
        self.ip = func.ip_start;
    }

    pub fn popFrame(self: *VM) void {
        self.frame_count -= 1;
        const frame = self.frames[self.frame_count];
        self.ip = frame.ip;
        self.sp = frame.slots_offset;
    }

    pub fn run(self: *VM) !void {
                while (true) {
            if (self.ip >= self.chunk.code.items.len) break;
            const ip_old = self.ip;
            const byte = self.readByte();
            if (self.frame_count > 0) {
                std.debug.print("EXEC IP={} BYTE={} SP={} FRAMES[{}] slots_offset={}\n", .{ip_old, byte, self.sp, self.frame_count-1, self.frames[self.frame_count-1].slots_offset});
            }
            const instruction: OpCode = @enumFromInt(byte);

            switch (instruction) {
                .get_local => {
                    const slot = self.readByte();
                    const frame = self.frames[self.frame_count - 1];
                    const val = self.stack[frame.slots_offset + slot];
                    std.debug.print("GET_LOCAL slot={}, value={any}\n", .{slot, val});
                    try self.push(val);
                },
                .constant => {
                    const constant = self.readConstant();
                    try self.push(constant);
                },
                .add => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a == .integer and b == .integer) {
                        try self.push(Value{ .integer = a.integer + b.integer });
                    } else {
                        {
                            std.debug.print("LESS ERROR: a={any}, b={any}\n", .{a, b});
                            std.debug.print("RuntimeError at line {}\n", .{@src().line});
                            return InterpretError.RuntimeError;
                        }
                    }
                },
                .sub => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a == .integer and b == .integer) {
                        try self.push(Value{ .integer = a.integer - b.integer });
                    } else {
                        std.debug.print("Sub error! a={any} b={any}\n", .{ a, b });
                        return InterpretError.RuntimeError;
                    }
                },
                .equal => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a == .integer and b == .integer) {
                        try self.push(Value{ .boolean = a.integer == b.integer });
                    } else {
                        {
                            std.debug.print("LESS ERROR: a={any}, b={any}\n", .{a, b});
                            std.debug.print("RuntimeError at line {}\n", .{@src().line});
                            return InterpretError.RuntimeError;
                        }
                    }
                },
                .not_equal => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a == .integer and b == .integer) {
                        try self.push(Value{ .boolean = a.integer != b.integer });
                    } else {
                        {
                            std.debug.print("LESS ERROR: a={any}, b={any}\n", .{a, b});
                            std.debug.print("RuntimeError at line {}\n", .{@src().line});
                            return InterpretError.RuntimeError;
                        }
                    }
                },
                .less => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a == .integer and b == .integer) {
                        try self.push(Value{ .boolean = a.integer < b.integer });
                    } else {
                        {
                            std.debug.print("LESS ERROR: a={any}, b={any}\n", .{a, b});
                            std.debug.print("RuntimeError at line {}\n", .{@src().line});
                            return InterpretError.RuntimeError;
                        }
                    }
                },
                .greater => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a == .integer and b == .integer) {
                        try self.push(Value{ .boolean = a.integer > b.integer });
                    } else {
                        {
                            std.debug.print("LESS ERROR: a={any}, b={any}\n", .{a, b});
                            std.debug.print("RuntimeError at line {}\n", .{@src().line});
                            return InterpretError.RuntimeError;
                        }
                    }
                },
                .less_equal => {
                    const b = try self.pop();
                    const a = try self.pop();
                    std.debug.print("LESS_EQUAL a={any} b={any}\n", .{a, b});
                    if (a == .integer and b == .integer) {
                        try self.push(Value{ .boolean = a.integer <= b.integer });
                    } else {
                        {
                            std.debug.print("LESS ERROR: a={any}, b={any}\n", .{a, b});
                            std.debug.print("RuntimeError at line {}\n", .{@src().line});
                            return InterpretError.RuntimeError;
                        }
                    }
                },
                .greater_equal => {
                    const b = try self.pop();
                    const a = try self.pop();
                    if (a == .integer and b == .integer) {
                        try self.push(Value{ .boolean = a.integer >= b.integer });
                    } else {
                        {
                            std.debug.print("LESS ERROR: a={any}, b={any}\n", .{a, b});
                            std.debug.print("RuntimeError at line {}\n", .{@src().line});
                            return InterpretError.RuntimeError;
                        }
                    }
                },
                .jump => {
                    const offset = self.readShort();
                    self.ip += offset;
                },
                .jump_if_false => {
                    const offset = self.readShort();
                    const condition = try self.pop();
                    if (condition == .boolean) {
                        if (!condition.boolean) {
                            self.ip += offset;
                        }
                    } else if (condition == .integer) {
                        if (condition.integer == 0) {
                            self.ip += offset;
                        }
                    } else if (condition == .nil) {
                        self.ip += offset;
                    }
                },
                .loop => {
                    const offset = self.readShort();
                    self.ip -= offset;
                },
                .build_array => {
                    const count = self.readByte();
                    var list = std.ArrayList(Value).empty;
                    var i: usize = 0;
                    // Elements were pushed left-to-right, so they are in order on stack
                    while (i < count) : (i += 1) {
                        try list.append(self.allocator, self.stack[self.sp - count + i]);
                    }
                    self.sp -= count;
                    
                    const list_ptr = try self.allocator.create(std.ArrayList(Value));
                    list_ptr.* = list;
                    try self.push(Value{ .array = list_ptr });
                },
                .index_get => {
                    const index_val = try self.pop();
                    const target_val = try self.pop();
                    if (index_val != .integer) return InterpretError.RuntimeError;
                    const idx: usize = @intCast(index_val.integer);
                    if (target_val == .array) {
                        if (idx >= target_val.array.items.len) return InterpretError.RuntimeError;
                        try self.push(target_val.array.items[idx]);
                    } else if (target_val == .string) {
                        if (idx >= target_val.string.len) return InterpretError.RuntimeError;
                        try self.push(Value{ .integer = target_val.string[idx] });
                    } else {
                        return InterpretError.RuntimeError;
                    }
                },
                .index_set => {
                    const index_val = try self.pop();
                    const target_val = try self.pop();
                    const value = try self.pop();
                    if (index_val != .integer) return InterpretError.RuntimeError;
                    const idx: usize = @intCast(index_val.integer);
                    if (target_val != .array) return InterpretError.RuntimeError;
                    if (idx >= target_val.array.items.len) {
                        // For flexibility in lexer.mx, maybe allow growing or just error?
                        // lexer.mx uses `push()` so it doesn't assign out of bounds.
                        return InterpretError.RuntimeError;
                    }
                    target_val.array.items[idx] = value;
                    try self.push(value);
                },
                .set_local => {
                    const slot = self.readByte();
                    std.debug.print("SET_LOCAL slot={}, value={any}\n", .{slot, self.stack[self.sp - 1]});
                    const frame = self.frames[self.frame_count - 1];
                    self.stack[frame.slots_offset + slot] = self.stack[self.sp - 1]; // leave on stack
                },
                .pop => {
                    _ = try self.pop();
                },
                .call => {
                    const arg_count = self.readByte();
                    const callee = self.stack[self.sp - arg_count - 1];
                    if (callee == .function) {
                        if (callee.function.arity != arg_count) return InterpretError.RuntimeError;
                        try self.pushFrame(callee.function, arg_count + 1);
                    } else if (callee == .native) {
                        const args = self.stack[self.sp - arg_count .. self.sp];
                        const result = try callee.native(@ptrCast(self), args);
                        self.sp -= arg_count + 1; // pop args and callee
                        try self.push(result);
                    } else {
                        return InterpretError.RuntimeError;
                    }
                },
                .print => {
                    const a = try self.pop();
                    a.printToFd(1);
                },
                .get_global => {
                    const constant = self.readConstant();
                    if (constant != .string) {
                        std.debug.print("RuntimeError at line {}\n", .{@src().line});
                        return InterpretError.RuntimeError;
                    }
                    if (self.globals.get(constant.string)) |val| {
                        try self.push(val);
                    } else {
                        std.debug.print("Undefined global: {s}\n", .{constant.string});
                        return InterpretError.RuntimeError;
                    }
                },
                .set_global => {
                    const constant = self.readConstant();
                    if (constant != .string) {
                        std.debug.print("RuntimeError at line {}\n", .{@src().line});
                        return InterpretError.RuntimeError;
                    }
                    const val = try self.pop();
                    try self.globals.put(constant.string, val);
                },
                .return_op => {
                    if (self.frame_count > 0) {
                        const result = try self.pop();
                        self.popFrame();
                        try self.push(result);
                    } else {
                        return;
                    }
                },
            }
        }
    }
};

test "vm basic math" {
    var chunk = Chunk.init();
    defer chunk.deinit(std.testing.allocator);

    const idx1 = try chunk.addConstant(std.testing.allocator, Value{ .integer = 10 });
    const idx2 = try chunk.addConstant(std.testing.allocator, Value{ .integer = 20 });

    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.constant));
    try chunk.writeChunk(std.testing.allocator, @intCast((idx1 >> 8) & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intCast(idx1 & 0xFF));

    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.constant));
    try chunk.writeChunk(std.testing.allocator, @intCast((idx2 >> 8) & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intCast(idx2 & 0xFF));

    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.add));
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.return_op));

    var vm = try VM.init(std.testing.allocator, &chunk);
    defer vm.deinit();
    try vm.run();

    const result = try vm.pop();
    try std.testing.expectEqual(Value{ .integer = 30 }, result);
}
