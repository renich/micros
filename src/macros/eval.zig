const std = @import("std");
const ast = @import("ast.zig");
const sys = @import("../sys.zig");

pub const EvalError = error{
    UndefinedVariable,
    UndefinedFunction,
    TypeMismatch,
    DivisionByZero,
    InvalidLiteral,
    OutOfMemory,
};

pub const Function = struct {
    name: []const u8,
    arity: usize,
    local_count: usize,
    ip_start: usize,
};

pub const NativeFn = *const fn (vm: *anyopaque, args: []Value) anyerror!Value;

pub const Value = union(enum) {
    integer: i64,
    boolean: bool,
    string: []const u8,
    function: Function,
    native: NativeFn,
    array: []Value,
    nil: void,

    fn writeFd(fd: i32, bytes: []const u8) void {
        _ = sys.io.write(fd, bytes) catch {};
    }

    fn printInt(fd: i32, v: i64) void {
        var buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{}", .{v})) |m| writeFd(fd, m) else |_| {}
    }

    fn printBool(fd: i32, v: bool) void {
        var buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{}", .{v})) |m| writeFd(fd, m) else |_| {}
    }

    fn printFunc(fd: i32, name: []const u8) void {
        var buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "<fn {s}>", .{name})) |m| writeFd(fd, m) else |_| {}
    }

    fn printStr(fd: i32, v: []const u8) void {
        writeFd(fd, "\"");
        writeFd(fd, v);
        writeFd(fd, "\"");
    }

    fn printArr(fd: i32, arr: []Value) void {
        writeFd(fd, "[");
        for (arr, 0..) |item, i| {
            if (i > 0) writeFd(fd, ", ");
            item.printToFd(fd);
        }
        writeFd(fd, "]");
    }

    pub fn printToFd(self: Value, fd: i32) void {
        switch (self) {
            .integer => |v| printInt(fd, v),
            .boolean => |v| printBool(fd, v),
            .string => |v| printStr(fd, v),
            .function => |f| printFunc(fd, f.name),
            .native => writeFd(fd, "<native fn>"),
            .array => |arr| printArr(fd, arr),
            .nil => writeFd(fd, "nil"),
        }
    }
};

