const std = @import("std");
const eval = @import("eval.zig");
const Value = eval.Value;
const chunk_mod = @import("chunk.zig");
const sys = @import("../sys.zig");

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

fn nativeStrToInt(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1) return InterpretError.RuntimeError;
    if (args[0] != .string) return InterpretError.RuntimeError;
    const val = std.fmt.parseInt(i64, args[0].string, 10) catch return InterpretError.RuntimeError;
    return eval.Value{ .integer = val };
}

fn nativeBitShr(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 2) return InterpretError.RuntimeError;
    if (args[0] != .integer or args[1] != .integer) return InterpretError.RuntimeError;
    // zig requires shift amounts to be unsigned and bounded
    const amount: u6 = @intCast(args[1].integer & 63);
    const result = args[0].integer >> amount;
    return eval.Value{ .integer = result };
}

fn nativeBitAnd(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 2) return InterpretError.RuntimeError;
    if (args[0] != .integer or args[1] != .integer) return InterpretError.RuntimeError;
    const result = args[0].integer & args[1].integer;
    return eval.Value{ .integer = result };
}

fn nativeBuildFunction(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 5) return InterpretError.RuntimeError;
    if (args[0] != .string) return InterpretError.RuntimeError;
    if (args[1] != .integer) return InterpretError.RuntimeError;
    if (args[2] != .integer) return InterpretError.RuntimeError;
    if (args[3] != .integer) return InterpretError.RuntimeError;
    if (args[4] != .integer) return InterpretError.RuntimeError;

    const vm_func = eval.Function{
        .name = args[0].string,
        .arity = @intCast(args[1].integer),
        .local_count = @intCast(args[2].integer),
        .upvalue_count = @intCast(args[3].integer),
        .ip_start = @intCast(args[4].integer),
    };
    return eval.Value{ .function = vm_func };
}

fn nativeMakeNil(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return eval.Value{ .nil = {} };
}

fn nativeMakeBool(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1) return InterpretError.RuntimeError;
    if (args[0] != .integer) return InterpretError.RuntimeError;
    return eval.Value{ .boolean = args[0].integer != 0 };
}

fn nativeExecChunk(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2) return InterpretError.RuntimeError;
    if (args[0] != .array or args[1] != .array) return InterpretError.RuntimeError;

    var new_chunk = chunk_mod.Chunk.init();
    // We should not defer deinit here because constants might be referenced.
    // In a real GC language, this chunk should be GC allocated.
    // For now we just leak the ArrayLists of the chunk since we don't have tracing GC yet.

    for (args[0].array) |val| {
        if (val != .integer) return InterpretError.RuntimeError;
        try new_chunk.writeChunk(vm.allocator, @intCast(val.integer));
    }
    for (args[1].array) |val| {
        _ = try new_chunk.addConstant(vm.allocator, val);
    }

    const old_chunk = vm.chunk;
    const old_ip = vm.ip;
    const old_sp = vm.sp;

    vm.chunk = &new_chunk;
    vm.ip = 0;

    vm.run(vm.frame_count) catch {
        vm.chunk = old_chunk;
        vm.ip = old_ip;
        vm.sp = old_sp;
        return InterpretError.RuntimeError;
    };

    vm.chunk = old_chunk;
    vm.ip = old_ip;
    vm.sp = old_sp;

    return eval.Value{ .nil = {} };
}

fn nativePush(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2) return InterpretError.RuntimeError;
    if (args[0] != .array) return InterpretError.RuntimeError;
    const old_slice = args[0].array;
    const new_slice = try vm.allocator.alloc(eval.Value, old_slice.len + 1);
    @memcpy(new_slice[0..old_slice.len], old_slice);
    new_slice[old_slice.len] = args[1];
    return eval.Value{ .array = new_slice };
}

fn nativeLen(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1) return InterpretError.RuntimeError;
    if (args[0] == .array) {
        return eval.Value{ .integer = @intCast(args[0].array.len) };
    } else if (args[0] == .string) {
        return eval.Value{ .integer = @intCast(args[0].string.len) };
    }
    return InterpretError.RuntimeError;
}

fn nativeSubstr(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 3) return InterpretError.RuntimeError;
    if (args[0] != .string or args[1] != .integer or args[2] != .integer) return InterpretError.RuntimeError;
    if (args[1].integer < 0 or args[2].integer < 0) return InterpretError.RuntimeError;
    const start: usize = @intCast(args[1].integer);
    const end: usize = @intCast(args[2].integer);
    if (start > end or end > args[0].string.len) return InterpretError.RuntimeError;
    return Value{ .string = args[0].string[start..end] };
}

pub const CallFrame = struct {
    closure: ?*eval.Closure,
    function: eval.Function,
    ip: usize,
    slots_offset: usize,
};

pub const VM = struct {
    pub const STACK_CAPACITY: usize = 256;
    pub const FRAMES_CAPACITY: usize = 64;

    allocator: std.mem.Allocator,
    chunk: *chunk_mod.Chunk,
    ip: usize,
    stack: [STACK_CAPACITY]Value,
    sp: usize,
    frames: [FRAMES_CAPACITY]CallFrame,
    frame_count: usize,
    globals: std.StringHashMap(Value),
    open_upvalues: ?*eval.Upvalue = null,

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
        try vm.globals.put("str_to_int", Value{ .native = nativeStrToInt });
        try vm.globals.put("bit_shr", Value{ .native = nativeBitShr });
        try vm.globals.put("bit_and", Value{ .native = nativeBitAnd });
        try vm.globals.put("build_function", Value{ .native = nativeBuildFunction });
        try vm.globals.put("make_nil", Value{ .native = nativeMakeNil });
        try vm.globals.put("make_bool", Value{ .native = nativeMakeBool });
        try vm.globals.put("exec_chunk", Value{ .native = nativeExecChunk });
        try vm.globals.put("bundle_get", Value{ .native = nativeBundleGet });
        try vm.globals.put("sys_open", Value{ .native = nativeSysOpen });
        try vm.globals.put("sys_read", Value{ .native = nativeSysRead });
        try vm.globals.put("sys_write", Value{ .native = nativeSysWrite });
        try vm.globals.put("sys_close", Value{ .native = nativeSysClose });
        return vm;
    }

    pub fn deinit(self: *VM) void {
        self.globals.deinit();
    }

    pub fn executeChunk(self: *VM, new_chunk: *chunk_mod.Chunk) !void {
        const old_chunk = self.chunk;
        const old_ip = self.ip;
        const old_sp = self.sp;

        self.chunk = new_chunk;
        self.ip = 0;

        const res = self.run(self.frame_count);

        self.chunk = old_chunk;
        self.ip = old_ip;
        self.sp = old_sp;

        try res;
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
        if (self.sp >= VM.STACK_CAPACITY) return InterpretError.StackOverflow;
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

    pub fn captureUpvalue(self: *VM, local: *Value) !*eval.Upvalue {
        var prev_upvalue: ?*eval.Upvalue = null;
        var upvalue: ?*eval.Upvalue = self.open_upvalues;
        while (upvalue != null and @intFromPtr(upvalue.?.location) > @intFromPtr(local)) {
            prev_upvalue = upvalue;
            upvalue = upvalue.?.next;
        }

        if (upvalue != null and upvalue.?.location == local) {
            return upvalue.?;
        }

        var created_upvalue = try self.allocator.create(eval.Upvalue);
        created_upvalue.location = local;
        created_upvalue.closed = .{ .nil = {} };
        created_upvalue.next = upvalue;

        if (prev_upvalue == null) {
            self.open_upvalues = created_upvalue;
        } else {
            prev_upvalue.?.next = created_upvalue;
        }

        return created_upvalue;
    }

    fn closeUpvalues(self: *VM, last: *Value) void {
        while (self.open_upvalues != null and @intFromPtr(self.open_upvalues.?.location) >= @intFromPtr(last)) {
            var upvalue = self.open_upvalues.?;
            upvalue.closed = upvalue.location.*;
            upvalue.location = &upvalue.closed;
            self.open_upvalues = upvalue.next;
        }
    }

    pub fn pushFrame(self: *VM, callee: eval.Value, arg_count: usize) !void {
        if (self.frame_count >= VM.FRAMES_CAPACITY) return InterpretError.StackOverflow;
        if (callee == .function) {
            self.frames[self.frame_count] = CallFrame{
                .closure = null,
                .function = callee.function,
                .ip = self.ip,
                .slots_offset = self.sp - arg_count,
            };
        } else {
            self.frames[self.frame_count] = CallFrame{
                .closure = callee.closure,
                .function = callee.closure.function.*,
                .ip = self.ip,
                .slots_offset = self.sp - arg_count,
            };
        }
        self.frame_count += 1;
    }

    pub fn popFrame(self: *VM) void {
        self.frame_count -= 1;
        const frame = self.frames[self.frame_count];
        self.closeUpvalues(&self.stack[frame.slots_offset]);
        self.ip = frame.ip;
        self.sp = frame.slots_offset;
    }

    fn traceRuntimeError(self: *VM) InterpretError {
        _ = self;
        return InterpretError.RuntimeError;
    }

    fn dispatchInstruction(self: *VM, instruction: OpCode, base_frame_count: usize) !bool {
        switch (instruction) {
            .get_local => try self.execGetLocal(),
            .constant => try self.execConstant(),
            .add => try self.execBinaryAdd(),
            .sub => try self.execBinarySub(),
            .equal => try self.execBinaryEqual(),
            .not_equal => try self.execBinaryNotEqual(),
            .less => try self.execBinaryCompare(OpCode.less),
            .greater => try self.execBinaryCompare(OpCode.greater),
            .less_equal => try self.execBinaryCompare(OpCode.less_equal),
            .greater_equal => try self.execBinaryCompare(OpCode.greater_equal),
            .print => try self.execPrint(),
            .return_op => if (try self.execReturn(base_frame_count)) return true,
            .get_global => try self.execGetGlobal(),
            .set_global => try self.execSetGlobal(),
            .jump => self.execJump(),
            .jump_if_false => try self.execJumpIfFalse(),
            .loop => self.execLoop(),
            .build_array => try self.execBuildArray(),
            .index_get => try self.execIndexGet(),
            .index_set => try self.execIndexSet(),
            .build_dict => try self.execBuildDict(),
            .get_property => try self.execGetProperty(),
            .set_property => try self.execSetProperty(),
            .set_local => try self.execSetLocal(),
            .pop => _ = try self.pop(),
            .call => try self.execCall(),
            .closure => try self.execClosure(),
            .get_upvalue => try self.execGetUpvalue(),
            .set_upvalue => try self.execSetUpvalue(),
            .close_upvalue => try self.execCloseUpvalue(),
        }
        return false;
    }

    pub fn run(self: *VM, base_frame_count: usize) !void {
        while (true) {
            if (self.ip >= self.chunk.code.items.len) break;
            const byte = self.readByte();
            const instruction: OpCode = @enumFromInt(byte);
            if (try self.dispatchInstruction(instruction, base_frame_count)) return;
        }
    }

    fn execClosure(self: *VM) !void {
        const constant = try self.pop();
        if (constant != .function) return InterpretError.RuntimeError;

        var closure = try self.allocator.create(eval.Closure);
        closure.function = try self.allocator.create(eval.Function);
        closure.function.* = constant.function;
        closure.upvalues = try self.allocator.alloc(*eval.Upvalue, constant.function.upvalue_count);

        var i: usize = 0;
        while (i < closure.function.upvalue_count) : (i += 1) {
            const is_local = self.readByte();
            const index = self.readByte();
            if (self.frame_count == 0) return InterpretError.RuntimeError;
            const frame = self.frames[self.frame_count - 1];
            if (is_local == 1) {
                if (frame.slots_offset + index >= VM.STACK_CAPACITY) return InterpretError.RuntimeError;
                closure.upvalues[i] = try self.captureUpvalue(&self.stack[frame.slots_offset + index]);
            } else {
                if (frame.closure == null or index >= frame.closure.?.upvalues.len) return InterpretError.RuntimeError;
                closure.upvalues[i] = frame.closure.?.upvalues[index];
            }
        }

        try self.push(.{ .closure = closure });
    }

    fn execGetUpvalue(self: *VM) !void {
        const slot = self.readByte();
        if (self.frame_count == 0) return InterpretError.RuntimeError;
        const frame = self.frames[self.frame_count - 1];
        if (frame.closure == null or slot >= frame.closure.?.upvalues.len) return InterpretError.RuntimeError;
        try self.push(frame.closure.?.upvalues[slot].location.*);
    }

    fn execSetUpvalue(self: *VM) !void {
        const slot = self.readByte();
        if (self.frame_count == 0) return InterpretError.RuntimeError;
        const frame = self.frames[self.frame_count - 1];
        if (frame.closure == null or slot >= frame.closure.?.upvalues.len) return InterpretError.RuntimeError;
        if (self.sp == 0) return InterpretError.StackUnderflow;
        const val = self.stack[self.sp - 1];
        frame.closure.?.upvalues[slot].location.* = val;
    }

    fn execCloseUpvalue(self: *VM) !void {
        if (self.sp == 0) return InterpretError.StackUnderflow;
        self.closeUpvalues(&self.stack[self.sp - 1]);
        _ = try self.pop();
    }

    fn execGetLocal(self: *VM) !void {
        const slot = self.readByte();
        if (self.frame_count == 0) return InterpretError.RuntimeError;
        const frame = self.frames[self.frame_count - 1];
        if (frame.slots_offset + slot >= VM.STACK_CAPACITY) return InterpretError.RuntimeError;
        const val = self.stack[frame.slots_offset + slot];
        try self.push(val);
    }

    fn execSetLocal(self: *VM) !void {
        const slot = self.readByte();
        if (self.frame_count == 0) return InterpretError.RuntimeError;
        const frame = self.frames[self.frame_count - 1];
        if (frame.slots_offset + slot >= VM.STACK_CAPACITY) return InterpretError.RuntimeError;
        if (self.sp == 0) return InterpretError.StackUnderflow;
        self.stack[frame.slots_offset + slot] = self.stack[self.sp - 1];
    }

    fn execConstant(self: *VM) !void {
        const constant = self.readConstant();
        try self.push(constant);
    }

    fn execBinaryAdd(self: *VM) !void {
        const b = try self.pop();
        const a = try self.pop();
        if (a == .integer and b == .integer) {
            try self.push(.{ .integer = a.integer + b.integer });
        } else if (a == .string and b == .string) {
            const new_len = a.string.len + b.string.len;
            const new_str = try self.allocator.alloc(u8, new_len);
            @memcpy(new_str[0..a.string.len], a.string);
            @memcpy(new_str[a.string.len..], b.string);
            try self.push(.{ .string = new_str });
        } else if (a == .array and b == .array) {
            const new_len = a.array.len + b.array.len;
            const new_arr = try self.allocator.alloc(eval.Value, new_len);
            @memcpy(new_arr[0..a.array.len], a.array);
            @memcpy(new_arr[a.array.len..], b.array);
            try self.push(.{ .array = new_arr });
        } else {
            return InterpretError.RuntimeError;
        }
    }

    fn execBinarySub(self: *VM) !void {
        const b = try self.pop();
        const a = try self.pop();
        if (a == .integer and b == .integer) {
            try self.push(.{ .integer = a.integer - b.integer });
        } else {
            return InterpretError.RuntimeError;
        }
    }

    fn execBinaryCompare(self: *VM, op: OpCode) !void {
        const b = try self.pop();
        const a = try self.pop();
        if (a == .integer and b == .integer) {
            switch (op) {
                .less => try self.push(.{ .boolean = a.integer < b.integer }),
                .greater => try self.push(.{ .boolean = a.integer > b.integer }),
                .less_equal => try self.push(.{ .boolean = a.integer <= b.integer }),
                .greater_equal => try self.push(.{ .boolean = a.integer >= b.integer }),
                else => return InterpretError.RuntimeError,
            }
        } else {
            return InterpretError.RuntimeError;
        }
    }

    fn execBinaryEqual(self: *VM) !void {
        const b = try self.pop();
        const a = try self.pop();
        if (a == .integer and b == .integer) {
            try self.push(.{ .boolean = a.integer == b.integer });
        } else if (a == .string and b == .string) {
            try self.push(.{ .boolean = std.mem.eql(u8, a.string, b.string) });
        } else {
            try self.push(.{ .boolean = false });
        }
    }

    fn execBinaryNotEqual(self: *VM) !void {
        const b = try self.pop();
        const a = try self.pop();
        if (a == .integer and b == .integer) {
            try self.push(.{ .boolean = a.integer != b.integer });
        } else if (a == .string and b == .string) {
            try self.push(.{ .boolean = !std.mem.eql(u8, a.string, b.string) });
        } else {
            try self.push(.{ .boolean = true });
        }
    }

    fn execPrint(self: *VM) !void {
        const val = try self.pop();
        val.printToFd(1);
        _ = sys.io.write(1, "\n") catch 0;
    }

    fn execReturn(self: *VM, base_frame_count: usize) !bool {
        if (self.frame_count == base_frame_count) {
            return true;
        }
        const result = try self.pop();
        self.popFrame();
        try self.push(result);
        return false;
    }

    fn execGetGlobal(self: *VM) !void {
        const name_val = self.readConstant();
        if (self.globals.get(name_val.string)) |v| {
            try self.push(v);
        } else {
            return InterpretError.RuntimeError;
        }
    }

    fn execSetGlobal(self: *VM) !void {
        const name_val = self.readConstant();
        if (self.sp == 0) return InterpretError.StackUnderflow;
        const value = self.stack[self.sp - 1];
        const gop = try self.globals.getOrPut(name_val.string);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, name_val.string);
        }
        gop.value_ptr.* = value;
    }

    fn execJump(self: *VM) void {
        const offset = self.readShort();
        self.ip += offset;
    }

    fn execJumpIfFalse(self: *VM) !void {
        const offset = self.readShort();
        const condition = try self.pop();
        if (condition == .boolean and !condition.boolean) {
            self.ip += offset;
        } else if (condition == .integer and condition.integer == 0) {
            self.ip += offset;
        } else if (condition == .nil) {
            self.ip += offset;
        }
    }

    fn execLoop(self: *VM) void {
        const offset = self.readShort();
        self.ip -= offset;
    }

    fn execBuildArray(self: *VM) !void {
        const count = self.readByte();
        if (self.sp < count) return InterpretError.StackUnderflow;
        const new_arr = try self.allocator.alloc(eval.Value, count);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            new_arr[i] = self.stack[self.sp - count + i];
        }
        self.sp -= count;
        try self.push(.{ .array = new_arr });
    }

    fn execIndexGet(self: *VM) !void {
        const index_val = try self.pop();
        const target_val = try self.pop();
        if (index_val != .integer) return InterpretError.RuntimeError;
        const idx: usize = @intCast(index_val.integer);
        if (target_val == .array) {
            if (idx >= target_val.array.len) return InterpretError.RuntimeError;
            try self.push(target_val.array[idx]);
        } else if (target_val == .string) {
            if (idx >= target_val.string.len) return InterpretError.RuntimeError;
            try self.push(.{ .integer = target_val.string[idx] });
        } else {
            return InterpretError.RuntimeError;
        }
    }

    fn execBuildDict(self: *VM) !void {
        const arg_count = self.readByte();
        const dict = try self.allocator.create(eval.Dict);
        const entries = try self.allocator.alloc(eval.Dict.Entry, arg_count);

        var i: usize = 0;
        while (i < arg_count) : (i += 1) {
            const val = try self.pop();
            const key = try self.pop();
            if (key != .string) return InterpretError.RuntimeError;
            entries[i] = .{ .key = key.string, .value = val };
        }
        dict.* = eval.Dict{ .entries = entries };
        try self.push(eval.Value{ .dict = dict });
    }

    fn execGetProperty(self: *VM) !void {
        const name_val = self.readConstant();
        const obj = try self.pop();
        if (obj != .dict) return InterpretError.RuntimeError;

        var found = false;
        for (obj.dict.entries) |entry| {
            if (std.mem.eql(u8, entry.key, name_val.string)) {
                try self.push(entry.value);
                found = true;
                break;
            }
        }
        if (!found) return InterpretError.RuntimeError;
    }

    fn execSetProperty(self: *VM) !void {
        const val = try self.pop();
        const name_val = self.readConstant();
        const obj = try self.pop();
        if (obj != .dict) return InterpretError.RuntimeError;

        var found = false;
        for (obj.dict.entries) |*entry| {
            if (std.mem.eql(u8, entry.key, name_val.string)) {
                entry.value = val;
                found = true;
                break;
            }
        }
        if (!found) {
            // Allocate a larger array
            const new_entries = try self.allocator.alloc(eval.Dict.Entry, obj.dict.entries.len + 1);
            @memcpy(new_entries[0..obj.dict.entries.len], obj.dict.entries);
            new_entries[obj.dict.entries.len] = .{ .key = name_val.string, .value = val };
            obj.dict.entries = new_entries;
        }
        try self.push(val);
    }

    fn execIndexSet(self: *VM) !void {
        const index_val = try self.pop();
        const target_val = try self.pop();
        const value = try self.pop();
        if (index_val != .integer) return InterpretError.RuntimeError;
        const idx: usize = @intCast(index_val.integer);
        if (target_val != .array) return InterpretError.RuntimeError;
        if (idx >= target_val.array.len) return InterpretError.RuntimeError;
        target_val.array[idx] = value;
        try self.push(value);
    }

    fn execCall(self: *VM) !void {
        const arg_count = self.readByte();
        if (self.sp < arg_count + 1) return InterpretError.StackUnderflow;
        const callee = self.stack[self.sp - arg_count - 1];
        if (callee == .function) {
            if (callee.function.arity != arg_count) return InterpretError.RuntimeError;
            try self.pushFrame(callee, arg_count + 1);
            self.ip = if (callee == .function) callee.function.ip_start else callee.closure.function.ip_start;
        } else if (callee == .closure) {
            if (callee.closure.function.arity != arg_count) return InterpretError.RuntimeError;
            try self.pushFrame(callee, arg_count + 1);
            self.ip = if (callee == .function) callee.function.ip_start else callee.closure.function.ip_start;
        } else if (callee == .native) {
            const args = self.stack[self.sp - arg_count .. self.sp];
            const result = try callee.native(@ptrCast(self), args);
            self.sp -= arg_count + 1;
            try self.push(result);
        } else {
            return InterpretError.RuntimeError;
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
    try vm.run(0);

    const result = try vm.pop();
    try std.testing.expectEqual(Value{ .integer = 30 }, result);
}

fn nativeSysOpen(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .string) return InterpretError.RuntimeError;
    const path = args[0].string;

    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return InterpretError.RuntimeError;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    const fd = sys.io.open(@ptrCast(buf[0 .. path.len + 1].ptr), 0, 0) catch -1;
    return eval.Value{ .integer = fd };
}

fn nativeSysRead(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .integer or args[1] != .integer) return InterpretError.RuntimeError;
    if (args[0].integer < 0 or args[1].integer < 0) return InterpretError.RuntimeError;
    const fd = @as(i32, @intCast(args[0].integer));
    const size = @as(usize, @intCast(args[1].integer));

    const buf = try vm.allocator.alloc(u8, size);
    const bytes_read = sys.io.read(fd, buf) catch 0;
    if (bytes_read == 0) {
        vm.allocator.free(buf);
        return eval.Value{ .string = "" };
    }
    const final_buf = try vm.allocator.alloc(u8, bytes_read);
    @memcpy(final_buf, buf[0..bytes_read]);
    vm.allocator.free(buf);
    return eval.Value{ .string = final_buf };
}

fn nativeSysWrite(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 2 or args[0] != .integer or args[1] != .string) return InterpretError.RuntimeError;
    if (args[0].integer < 0) return InterpretError.RuntimeError;
    const fd = @as(i32, @intCast(args[0].integer));
    const str = args[1].string;

    const written = sys.io.write(fd, str) catch 0;
    return eval.Value{ .integer = @as(i64, @intCast(written)) };
}

fn nativeSysClose(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return InterpretError.RuntimeError;
    if (args[0].integer < 0) return InterpretError.RuntimeError;
    const fd = @as(i32, @intCast(args[0].integer));
    sys.io.close(fd) catch {};
    return eval.Value{ .nil = {} };
}

var active_bundle_data: ?[]const u8 = null;

pub fn setActiveBundle(bundle_bytes: ?[]const u8) void {
    active_bundle_data = bundle_bytes;
}

fn nativeBundleGet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .string) return InterpretError.RuntimeError;
    const bundle_bytes = active_bundle_data orelse return eval.Value{ .string = "" };

    const bundle_mod = @import("../kernel/bundle.zig");
    const reader = bundle_mod.BundleReader.init(bundle_bytes) catch return eval.Value{ .string = "" };
    const content = reader.findData(args[0].string) orelse return eval.Value{ .string = "" };
    return eval.Value{ .string = content };
}
