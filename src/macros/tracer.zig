const std = @import("std");
const eval = @import("eval.zig");
const Value = eval.Value;
const gc = @import("gc.zig");
const Heap = gc.Heap;

pub fn traceValue(heap: *Heap, value: Value) void {
    switch (value) {
        .string => |s| {
            heap.markSlice(s.ptr, s.len);
        },
        .array => |arr| {
            heap.markSlice(@ptrCast(arr), @sizeOf(std.ArrayList(Value)));
            heap.markSlice(@ptrCast(arr.items.ptr), arr.capacity * @sizeOf(Value));
            for (arr.items) |val| {
                traceValue(heap, val);
            }
        },
        .function => |func| {
            _ = func; // VM execution contexts for functions don't heap allocate ast.Nodes directly inside eval.Function, but if they had captures we'd mark them.
        },
        else => {},
    }
}
