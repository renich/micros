const std = @import("std");
const eval = @import("eval.zig");
const Value = eval.Value;
const chunk_mod = @import("chunk.zig");
const serializer = @import("serializer.zig");
const vm_mod = @import("vm.zig");
const VM = vm_mod.VM;
const InterpretError = vm_mod.InterpretError;

pub fn nativeStrToInt(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1) return InterpretError.RuntimeError;
    if (args[0] != .string) return InterpretError.RuntimeError;
    const val = std.fmt.parseInt(i64, args[0].string, 10) catch return InterpretError.RuntimeError;
    return eval.Value{ .integer = val };
}

pub fn nativeCharToStr(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .integer) return InterpretError.RuntimeError;
    const c: u8 = @intCast(args[0].integer & 0xFF);
    const str = try vm.gcAllocator().alloc(u8, 1);
    str[0] = c;
    return eval.Value{ .string = str };
}

pub fn nativeIntToStr(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .integer) return InterpretError.RuntimeError;
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{args[0].integer}) catch return InterpretError.RuntimeError;
    const str = try vm.gcAllocator().alloc(u8, s.len);
    @memcpy(str, s);
    return eval.Value{ .string = str };
}

pub fn nativeBitShr(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 2) return InterpretError.RuntimeError;
    if (args[0] != .integer or args[1] != .integer) return InterpretError.RuntimeError;
    const amount: u6 = @intCast(args[1].integer & 63);
    const result = args[0].integer >> amount;
    return eval.Value{ .integer = result };
}

pub fn nativeBitAnd(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 2) return InterpretError.RuntimeError;
    if (args[0] != .integer or args[1] != .integer) return InterpretError.RuntimeError;
    const result = args[0].integer & args[1].integer;
    return eval.Value{ .integer = result };
}

pub fn nativeBuildFunction(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 5 or args[0] != .string) return InterpretError.RuntimeError;
    if (args[1] != .integer or args[2] != .integer or args[3] != .integer or args[4] != .integer) {
        return InterpretError.RuntimeError;
    }

    const vm_func = eval.Function{
        .name = args[0].string,
        .arity = @intCast(args[1].integer),
        .local_count = @intCast(args[2].integer),
        .upvalue_count = @intCast(args[3].integer),
        .ip_start = @intCast(args[4].integer),
        .chunk = @ptrCast(vm.chunk),
    };
    return eval.Value{ .function = vm_func };
}

pub fn nativeMakeNil(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return eval.Value{ .nil = {} };
}

pub fn nativeMakeBool(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return InterpretError.RuntimeError;
    return eval.Value{ .boolean = args[0].integer != 0 };
}

pub fn nativeExecChunk(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .array or args[1] != .array) return InterpretError.RuntimeError;

    const new_chunk = try vm.allocator.create(chunk_mod.Chunk);
    new_chunk.* = chunk_mod.Chunk.init();
    errdefer {
        new_chunk.deinit(vm.allocator);
        vm.allocator.destroy(new_chunk);
    }
    try vm.dynamic_chunks.append(vm.allocator, new_chunk);
    var prepared = false;
    errdefer {
        if (!prepared) {
            _ = vm.dynamic_chunks.pop();
        }
    }

    for (args[0].array) |val| {
        if (val != .integer) return InterpretError.RuntimeError;
        if (val.integer < 0 or val.integer > 255) return InterpretError.RuntimeError;
        try new_chunk.writeChunk(vm.allocator, @intCast(val.integer));
    }
    for (args[1].array) |val| {
        _ = try new_chunk.addConstant(vm.allocator, val);
    }
    prepared = true;

    try vm.executeChunk(new_chunk);
    return eval.Value{ .nil = {} };
}

pub fn nativeChunkSerialize(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .array or args[1] != .array) return InterpretError.RuntimeError;

    var ch = chunk_mod.Chunk.init();
    defer ch.deinit(vm.allocator);

    for (args[0].array) |val| {
        if (val != .integer) return InterpretError.RuntimeError;
        try ch.writeChunk(vm.allocator, @intCast(val.integer & 0xFF));
    }
    for (args[1].array) |val| {
        _ = try ch.addConstant(vm.allocator, val);
    }

    const bytes = try serializer.serializeChunk(vm.allocator, &ch);
    return eval.Value{ .string = bytes };
}

pub fn nativeChunkHash(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .array or args[1] != .array) return InterpretError.RuntimeError;

    var ch = chunk_mod.Chunk.init();
    defer ch.deinit(vm.allocator);

    for (args[0].array) |val| {
        if (val != .integer) return InterpretError.RuntimeError;
        try ch.writeChunk(vm.allocator, @intCast(val.integer & 0xFF));
    }
    for (args[1].array) |val| {
        _ = try ch.addConstant(vm.allocator, val);
    }

    const hash = try serializer.computeChunkHash(vm.allocator, &ch);
    const hex_chars = "0123456789abcdef";
    var hex_buf: [64]u8 = undefined;
    for (hash, 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[(b >> 4) & 0x0F];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0F];
    }
    const out_str = try vm.allocator.dupe(u8, &hex_buf);
    return eval.Value{ .string = out_str };
}

pub fn nativePush(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .array) return InterpretError.RuntimeError;
    const old_slice = args[0].array;
    const new_slice = try vm.gcAllocator().alloc(eval.Value, old_slice.len + 1);
    @memcpy(new_slice[0..old_slice.len], old_slice);
    new_slice[old_slice.len] = args[1];
    return eval.Value{ .array = new_slice };
}

pub fn nativeLen(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1) return InterpretError.RuntimeError;
    if (args[0] == .array) {
        return eval.Value{ .integer = @intCast(args[0].array.len) };
    } else if (args[0] == .string) {
        return eval.Value{ .integer = @intCast(args[0].string.len) };
    }
    return InterpretError.RuntimeError;
}

pub fn nativeSubstr(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 3 or args[0] != .string or args[1] != .integer or args[2] != .integer) {
        return InterpretError.RuntimeError;
    }
    if (args[1].integer < 0 or args[2].integer < 0) return InterpretError.RuntimeError;
    const start: usize = @intCast(args[1].integer);
    const end: usize = @intCast(args[2].integer);
    if (start > end or end > args[0].string.len) return InterpretError.RuntimeError;
    return Value{ .string = args[0].string[start..end] };
}

pub var active_bundle_data: ?[]const u8 = null;

pub fn setActiveBundle(bundle_bytes: ?[]const u8) void {
    active_bundle_data = bundle_bytes;
}

pub fn nativeBundleGet(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .string) return InterpretError.RuntimeError;
    const bundle_bytes = active_bundle_data orelse return eval.Value{ .string = "" };

    const bundle_mod = @import("../kernel/bundle.zig");
    const reader = bundle_mod.BundleReader.init(bundle_bytes) catch return eval.Value{ .string = "" };
    const content = reader.findData(args[0].string) orelse return eval.Value{ .string = "" };
    return eval.Value{ .string = content };
}

pub fn registerBuiltins(vm: *VM) !void {
    try vm.globals.put("push", Value{ .native = nativePush });
    try vm.globals.put("len", Value{ .native = nativeLen });
    try vm.globals.put("substr", Value{ .native = nativeSubstr });
    try vm.globals.put("str_to_int", Value{ .native = nativeStrToInt });
    try vm.globals.put("char_to_str", Value{ .native = nativeCharToStr });
    try vm.globals.put("int_to_str", Value{ .native = nativeIntToStr });
    try vm.globals.put("bit_shr", Value{ .native = nativeBitShr });
    try vm.globals.put("bit_and", Value{ .native = nativeBitAnd });
    try vm.globals.put("build_function", Value{ .native = nativeBuildFunction });
    try vm.globals.put("make_nil", Value{ .native = nativeMakeNil });
    try vm.globals.put("make_bool", Value{ .native = nativeMakeBool });
    try vm.globals.put("exec_chunk", Value{ .native = nativeExecChunk });
    try vm.globals.put("bundle_get", Value{ .native = nativeBundleGet });
    try vm.globals.put("chunk_serialize", Value{ .native = nativeChunkSerialize });
    try vm.globals.put("chunk_hash", Value{ .native = nativeChunkHash });
}
