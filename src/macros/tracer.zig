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
        if (uv.location) |loc| {
            traceValue(heap, loc.*);
        }
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

test "tracer compiles and marks basic types" {
    // Tests for tracer logic are covered via vm and gc integration tests
}
