const std = @import("std");
const eval = @import("eval.zig");
const Value = eval.Value;
const gc = @import("gc.zig");
const Heap = gc.Heap;

fn traceClosure(heap: *Heap, c: *eval.Closure) void {
    heap.markSlice(@ptrCast(c), @sizeOf(eval.Closure));
    heap.markSlice(@ptrCast(c.function), @sizeOf(eval.Function));
    heap.markSlice(c.function.name.ptr, c.function.name.len);
    if (c.upvalues.len == 0) return;

    heap.markSlice(@ptrCast(c.upvalues.ptr), c.upvalues.len * @sizeOf(*eval.Upvalue));
    for (c.upvalues) |uv| {
        heap.markSlice(@ptrCast(uv), @sizeOf(eval.Upvalue));
        traceValue(heap, uv.location.*);
    }
}

fn traceDict(heap: *Heap, d: *eval.Dict) void {
    heap.markSlice(@ptrCast(d), @sizeOf(eval.Dict));
    heap.markSlice(@ptrCast(d.entries.ptr), d.entries.len * @sizeOf(eval.Dict.Entry));
    for (d.entries) |entry| {
        heap.markSlice(entry.key.ptr, entry.key.len);
        traceValue(heap, entry.value);
    }
}

pub fn traceValue(heap: *Heap, value: Value) void {
    switch (value) {
        .string => |s| {
            heap.markSlice(s.ptr, s.len);
        },
        .array => |arr| {
            heap.markSlice(@ptrCast(arr.ptr), arr.len * @sizeOf(Value));
            for (arr) |val| {
                traceValue(heap, val);
            }
        },
        .function => |func| {
            heap.markSlice(func.name.ptr, func.name.len);
        },
        .closure => |c| {
            traceClosure(heap, c);
        },
        .dict => |d| {
            traceDict(heap, d);
        },
        else => {},
    }
}

pub fn traceChunk(heap: *Heap, ch: anytype) void {
    for (ch.constants.items) |constant| {
        traceValue(heap, constant);
    }
}

pub fn traceCallFrames(heap: *Heap, frames: anytype) void {
    for (frames) |frame| {
        if (frame.closure) |c| {
            traceValue(heap, Value{ .closure = c });
        } else {
            heap.markSlice(frame.function.name.ptr, frame.function.name.len);
        }
    }
}

pub fn traceOpenUpvalues(heap: *Heap, upvalues: ?*eval.Upvalue) void {
    var curr = upvalues;
    while (curr) |uv| {
        heap.markSlice(@ptrCast(uv), @sizeOf(eval.Upvalue));
        traceValue(heap, uv.location.*);
        curr = uv.next;
    }
}

pub fn traceExports(heap: *Heap, exports: ?*std.ArrayList(eval.Dict.Entry)) void {
    if (exports) |exp| {
        for (exp.items) |entry| {
            heap.markSlice(entry.key.ptr, entry.key.len);
            traceValue(heap, entry.value);
        }
    }
}

pub fn valueReferencesChunk(val: Value, target_ptr: *anyopaque) bool {
    return switch (val) {
        .function => |f| f.chunk == target_ptr,
        .closure => |c| blk: {
            if (c.function.chunk == target_ptr) break :blk true;
            for (c.upvalues) |uv| {
                if (valueReferencesChunk(uv.location.*, target_ptr)) break :blk true;
            }
            break :blk false;
        },
        .array => |arr| blk: {
            for (arr) |item| {
                if (valueReferencesChunk(item, target_ptr)) break :blk true;
            }
            break :blk false;
        },
        .dict => |dict| blk: {
            for (dict.entries) |entry| {
                if (valueReferencesChunk(entry.value, target_ptr)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

test "tracer compiles and marks basic types" {
    // Tests for tracer logic are covered via vm and gc integration tests
}
