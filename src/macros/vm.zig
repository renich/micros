const std = @import("std");
const eval = @import("eval.zig");
const Value = eval.Value;
const chunk_mod = @import("chunk.zig");
const sys = @import("../sys.zig");

const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const gc = @import("gc.zig");
const tracer = @import("tracer.zig");
const fiber = @import("fiber.zig");
const module_mod = @import("module.zig");

pub const PREEMPTION_QUANTUM: usize = 1024;

pub const InterpretError = error{
    CompileError,
    RuntimeError,
    StackOverflow,
    StackUnderflow,
    CircularDependency,
    ModuleNotFound,
    InvalidHexHash,
};

pub const builtins = @import("builtins.zig");
pub const setActiveBundle = builtins.setActiveBundle;
pub const nativeCharToStr = builtins.nativeCharToStr;
pub const nativeIntToStr = builtins.nativeIntToStr;
pub const nativeExecChunk = builtins.nativeExecChunk;

pub const CallFrame = struct {
    closure: ?*eval.Closure,
    function: eval.Function,
    ip: usize,
    slots_offset: usize,
    chunk: *chunk_mod.Chunk,
};

pub const VM = struct {
    pub const STACK_CAPACITY: usize = 1024;
    pub const FRAMES_CAPACITY: usize = 64;

    allocator: std.mem.Allocator,
    chunk: *chunk_mod.Chunk,
    dynamic_chunks: std.ArrayList(*chunk_mod.Chunk),
    ip: usize,
    stack: [STACK_CAPACITY]Value,
    sp: usize,
    frames: [FRAMES_CAPACITY]CallFrame,
    frame_count: usize,
    globals: std.StringHashMap(Value),
    allocated_keys: std.ArrayList([]const u8),
    open_upvalues: ?*eval.Upvalue = null,
    last_missing_symbol: ?[]const u8 = null,
    instruction_count: usize = 0,
    yield_hook: ?*const fn (vm: *VM) anyerror!void = null,
    module_resolver: ?*module_mod.ModuleResolver = null,
    current_exports: ?*std.ArrayList(eval.Dict.Entry) = null,

    pub fn initInPlace(self: *VM, allocator: std.mem.Allocator, ch: *chunk_mod.Chunk) !void {
        self.allocator = allocator;
        self.chunk = ch;
        self.dynamic_chunks = .empty;
        self.ip = 0;
        self.sp = 0;
        self.frame_count = 0;
        self.open_upvalues = null;
        self.last_missing_symbol = null;
        self.instruction_count = 0;
        self.yield_hook = null;
        self.module_resolver = null;
        self.current_exports = null;
        self.globals = std.StringHashMap(Value).init(allocator);
        self.allocated_keys = .empty;
        try builtins.registerBuiltins(self);
    }

    pub fn setModuleResolver(self: *VM, resolver: *module_mod.ModuleResolver) void {
        self.module_resolver = resolver;
    }

    pub fn init(allocator: std.mem.Allocator, ch: *chunk_mod.Chunk) !VM {
        var vm: VM = undefined;
        try vm.initInPlace(allocator, ch);
        return vm;
    }

    pub fn deinit(self: *VM) void {
        for (self.dynamic_chunks.items) |ch| {
            ch.deinit(self.allocator);
            self.allocator.destroy(ch);
        }
        self.dynamic_chunks.deinit(self.allocator);
        for (self.allocated_keys.items) |k| {
            self.allocator.free(k);
        }
        self.allocated_keys.deinit(self.allocator);
        self.globals.deinit();
    }

    pub fn executeChunk(self: *VM, new_chunk: *chunk_mod.Chunk) anyerror!void {
        const old_frame_count = self.frame_count;
        const old_chunk = self.chunk;
        const old_ip = self.ip;
        const old_sp = self.sp;

        self.chunk = new_chunk;
        self.ip = 0;

        const res = self.run(self.frame_count);

        self.chunk = old_chunk;
        self.ip = old_ip;
        self.sp = old_sp;
        while (self.frame_count > old_frame_count) self.popFrame();

        try res;
    }

    pub fn collect(self: *VM, heap: *gc.Heap) void {
        heap.clearMarks();

        // Trace constants
        for (self.chunk.constants.items) |constant| {
            tracer.traceValue(heap, constant);
        }
        for (self.dynamic_chunks.items) |ch| {
            if (ch == self.chunk) continue;
            for (ch.constants.items) |constant| {
                tracer.traceValue(heap, constant);
            }
        }
        if (self.module_resolver) |resolver| {
            for (resolver.dynamic_chunks.items) |ch| {
                for (ch.constants.items) |constant| {
                    tracer.traceValue(heap, constant);
                }
            }
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
        const func = if (callee == .function) callee.function else callee.closure.function.*;
        const closure_ptr = if (callee == .function) null else callee.closure;
        self.frames[self.frame_count] = CallFrame{
            .closure = closure_ptr,
            .function = func,
            .ip = self.ip,
            .slots_offset = self.sp - arg_count,
            .chunk = self.chunk,
        };
        if (func.chunk) |c| {
            self.chunk = @ptrCast(@alignCast(c));
        }
        self.frame_count += 1;
    }

    pub fn popFrame(self: *VM) void {
        self.frame_count -= 1;
        const frame = self.frames[self.frame_count];
        self.closeUpvalues(&self.stack[frame.slots_offset]);
        self.ip = frame.ip;
        self.sp = frame.slots_offset;
        self.chunk = frame.chunk;
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
            .multiply, .divide, .modulo, .bitwise_and, .bitwise_or, .bitwise_xor, .shift_left, .shift_right => |op| try self.execBinaryIntOp(op),
            .negate, .not => |op| try self.execUnaryOp(op),
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
            .import_op => try self.execImport(),
            .export_op => try self.execExport(),
        }
        return false;
    }

    fn checkPreemption(self: *VM) !void {
        self.instruction_count +%= 1;
        if (self.instruction_count < PREEMPTION_QUANTUM) return;
        self.instruction_count = 0;
        fiber.yield();
        if (self.yield_hook) |hook| try hook(self);
    }

    pub fn run(self: *VM, base_frame_count: usize) !void {
        while (true) {
            try self.checkPreemption();
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

    fn execExport(self: *VM) !void {
        const name_val = self.readConstant();
        if (name_val != .string) return InterpretError.RuntimeError;
        if (self.sp == 0) return InterpretError.StackUnderflow;
        const val = self.stack[self.sp - 1];
        const exports_list = self.current_exports orelse return;
        for (exports_list.items) |*entry| {
            if (std.mem.eql(u8, entry.key, name_val.string)) {
                entry.value = val;
                return;
            }
        }
        try exports_list.append(self.allocator, .{
            .key = name_val.string,
            .value = val,
        });
    }

    fn execImport(self: *VM) !void {
        const path_val = self.readConstant();
        if (path_val != .string) return InterpretError.RuntimeError;
        const resolver = self.module_resolver orelse return InterpretError.RuntimeError;
        const dict_val = resolver.importModule(self, path_val.string) catch |err| switch (err) {
            error.CircularDependency => return InterpretError.CircularDependency,
            error.ModuleNotFound => return InterpretError.ModuleNotFound,
            error.InvalidHexHash => return InterpretError.InvalidHexHash,
            else => return InterpretError.RuntimeError,
        };
        try self.push(dict_val);
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
            try self.push(.{ .integer = a.integer -% b.integer });
        } else {
            return InterpretError.RuntimeError;
        }
    }

    fn execBinaryIntOp(self: *VM, op: OpCode) !void {
        const b = try self.pop();
        const a = try self.pop();
        if (a != .integer or b != .integer) return InterpretError.RuntimeError;
        const res: i64 = switch (op) {
            .multiply => a.integer *% b.integer,
            .divide => if (b.integer == 0) return InterpretError.RuntimeError else if (a.integer == std.math.minInt(i64) and b.integer == -1) return InterpretError.RuntimeError else @divTrunc(a.integer, b.integer),
            .modulo => if (b.integer == 0) return InterpretError.RuntimeError else if (a.integer == std.math.minInt(i64) and b.integer == -1) 0 else @rem(a.integer, b.integer),
            .bitwise_and => a.integer & b.integer,
            .bitwise_or => a.integer | b.integer,
            .bitwise_xor => a.integer ^ b.integer,
            .shift_left => a.integer << @as(u6, @intCast(@as(u64, @bitCast(b.integer)) & 63)),
            .shift_right => a.integer >> @as(u6, @intCast(@as(u64, @bitCast(b.integer)) & 63)),
            else => return InterpretError.RuntimeError,
        };
        try self.push(.{ .integer = res });
    }

    fn execUnaryOp(self: *VM, op: OpCode) !void {
        const a = try self.pop();
        switch (op) {
            .negate => {
                if (a != .integer) return InterpretError.RuntimeError;
                try self.push(.{ .integer = -%a.integer });
            },
            .not => {
                const is_falsy = (a == .boolean and !a.boolean) or (a == .integer and a.integer == 0) or (a == .nil);
                try self.push(.{ .boolean = is_falsy });
            },
            else => return InterpretError.RuntimeError,
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
        if (name_val != .string) return InterpretError.RuntimeError;
        if (self.globals.get(name_val.string)) |v| {
            try self.push(v);
        } else {
            self.last_missing_symbol = name_val.string;
            return InterpretError.RuntimeError;
        }
    }

    fn execSetGlobal(self: *VM) !void {
        const name_val = self.readConstant();
        if (name_val != .string) return InterpretError.RuntimeError;
        if (self.sp == 0) return InterpretError.StackUnderflow;
        const value = self.stack[self.sp - 1];
        const gop = try self.globals.getOrPut(name_val.string);
        if (!gop.found_existing) {
            const k = try self.allocator.dupe(u8, name_val.string);
            try self.allocated_keys.append(self.allocator, k);
            gop.key_ptr.* = k;
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

test "vm char_to_str and int_to_str builtins" {
    var chunk = Chunk.init();
    defer chunk.deinit(std.testing.allocator);
    var vm = try VM.init(std.testing.allocator, &chunk);
    defer vm.deinit();

    var args1 = [_]Value{Value{ .integer = 65 }};
    const res1 = try nativeCharToStr(&vm, &args1);
    try std.testing.expectEqualStrings("A", res1.string);
    std.testing.allocator.free(res1.string);

    var args2 = [_]Value{Value{ .integer = 42 }};
    const res2 = try nativeIntToStr(&vm, &args2);
    try std.testing.expectEqualStrings("42", res2.string);
    std.testing.allocator.free(res2.string);
}

var test_yield_counter: usize = 0;
fn testYieldHook(vm: *VM) anyerror!void {
    test_yield_counter += 1;
    if (test_yield_counter >= 3) {
        vm.ip = vm.chunk.code.items.len;
    }
}

test "vm instruction preemption quantum and yield hook" {
    var chunk = Chunk.init();
    defer chunk.deinit(std.testing.allocator);

    // Infinite loop: loop 3 bytes back
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.loop));
    try chunk.writeChunk(std.testing.allocator, 0);
    try chunk.writeChunk(std.testing.allocator, 3);

    var vm = try VM.init(std.testing.allocator, &chunk);
    defer vm.deinit();

    test_yield_counter = 0;
    vm.yield_hook = testYieldHook;
    try vm.run(0);

    try std.testing.expectEqual(@as(usize, 3), test_yield_counter);
}

test "vm dynamic chunk lifecycle and cross-chunk execution" {
    var main_chunk = Chunk.init();
    defer main_chunk.deinit(std.testing.allocator);
    try main_chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.return_op));

    var vm = try VM.init(std.testing.allocator, &main_chunk);
    defer vm.deinit();

    var code_vals = [_]Value{
        .{ .integer = @intFromEnum(OpCode.constant) },
        .{ .integer = 0 },
        .{ .integer = 0 },
        .{ .integer = @intFromEnum(OpCode.return_op) },
    };
    var const_vals = [_]Value{.{ .integer = 99 }};
    var args = [_]Value{
        .{ .array = &code_vals },
        .{ .array = &const_vals },
    };
    _ = try nativeExecChunk(&vm, &args);

    try std.testing.expectEqual(@as(usize, 1), vm.dynamic_chunks.items.len);
}

test "vm arithmetic completeness: mul, div, mod, div-by-zero" {
    var chunk = Chunk.init();
    defer chunk.deinit(std.testing.allocator);

    // 10 * 4 = 40
    const c10 = try chunk.addConstant(std.testing.allocator, Value{ .integer = 10 });
    const c4 = try chunk.addConstant(std.testing.allocator, Value{ .integer = 4 });
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.constant));
    try chunk.writeChunk(std.testing.allocator, @intCast((c10 >> 8) & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intCast(c10 & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.constant));
    try chunk.writeChunk(std.testing.allocator, @intCast((c4 >> 8) & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intCast(c4 & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.multiply));

    // 40 / 3 = 13
    const c3 = try chunk.addConstant(std.testing.allocator, Value{ .integer = 3 });
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.constant));
    try chunk.writeChunk(std.testing.allocator, @intCast((c3 >> 8) & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intCast(c3 & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.divide));

    // 13 % 5 = 3
    const c5 = try chunk.addConstant(std.testing.allocator, Value{ .integer = 5 });
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.constant));
    try chunk.writeChunk(std.testing.allocator, @intCast((c5 >> 8) & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intCast(c5 & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.modulo));
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.return_op));

    var vm = try VM.init(std.testing.allocator, &chunk);
    defer vm.deinit();
    try vm.run(0);

    const result = try vm.pop();
    try std.testing.expectEqual(Value{ .integer = 3 }, result);
}

test "vm division by zero error handling" {
    var chunk = Chunk.init();
    defer chunk.deinit(std.testing.allocator);

    const c10 = try chunk.addConstant(std.testing.allocator, Value{ .integer = 10 });
    const c0 = try chunk.addConstant(std.testing.allocator, Value{ .integer = 0 });
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.constant));
    try chunk.writeChunk(std.testing.allocator, @intCast((c10 >> 8) & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intCast(c10 & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.constant));
    try chunk.writeChunk(std.testing.allocator, @intCast((c0 >> 8) & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intCast(c0 & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.divide));

    var vm = try VM.init(std.testing.allocator, &chunk);
    defer vm.deinit();
    try std.testing.expectError(InterpretError.RuntimeError, vm.run(0));
}

test "vm bitwise and unary operators: and, or, xor, shl, shr, neg, not" {
    var chunk = Chunk.init();
    defer chunk.deinit(std.testing.allocator);

    // 1 << 4 = 16
    const c1 = try chunk.addConstant(std.testing.allocator, Value{ .integer = 1 });
    const c4 = try chunk.addConstant(std.testing.allocator, Value{ .integer = 4 });
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.constant));
    try chunk.writeChunk(std.testing.allocator, @intCast((c1 >> 8) & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intCast(c1 & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.constant));
    try chunk.writeChunk(std.testing.allocator, @intCast((c4 >> 8) & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intCast(c4 & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.shift_left));

    // 16 | 7 = 23
    const c7 = try chunk.addConstant(std.testing.allocator, Value{ .integer = 7 });
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.constant));
    try chunk.writeChunk(std.testing.allocator, @intCast((c7 >> 8) & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intCast(c7 & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.bitwise_or));

    // 23 & 15 = 7
    const c15 = try chunk.addConstant(std.testing.allocator, Value{ .integer = 15 });
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.constant));
    try chunk.writeChunk(std.testing.allocator, @intCast((c15 >> 8) & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intCast(c15 & 0xFF));
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.bitwise_and));

    // negate: -7
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.negate));
    try chunk.writeChunk(std.testing.allocator, @intFromEnum(OpCode.return_op));

    var vm = try VM.init(std.testing.allocator, &chunk);
    defer vm.deinit();
    try vm.run(0);

    const result = try vm.pop();
    try std.testing.expectEqual(Value{ .integer = -7 }, result);
}
