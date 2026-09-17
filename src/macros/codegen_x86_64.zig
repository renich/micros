// Macros Freestanding Direct x86_64 Machine Code Emitter (codegen_x86_64.zig)
// Compiles bytecode directly to native x86_64 machine code with W^X page protection.
// Implements SPEC-TECH-LANG-002 Section 5.

const std = @import("std");
const sys = @import("../sys.zig");
const chunk_mod = @import("chunk.zig");
const eval = @import("eval.zig");

const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Allocator = std.mem.Allocator;

pub const PAGE_SIZE: usize = 4096;
pub const NativeFn = *const fn () callconv(.c) i64;

pub const CodegenError = error{
    BufferTooSmall,
    UnsupportedOpcode,
    InvalidJumpOffset,
    ProtectionFailed,
    OutOfMemory,
};

pub const ExecutableBuffer = struct {
    memory: []align(4096) u8,
    cursor: usize,
    capacity: usize,
    is_executable: bool,

    pub fn init(size: usize) !ExecutableBuffer {
        const aligned_len = std.mem.alignForward(usize, size, PAGE_SIZE);
        const ptr = try sys.mem.map(
            null,
            aligned_len,
            sys.mem.Prot.read | sys.mem.Prot.write,
            sys.mem.Flags.private | sys.mem.Flags.anonymous,
            -1,
            0,
        );
        const slice: []align(4096) u8 = @alignCast(@as([*]u8, @ptrCast(ptr))[0..aligned_len]);
        @memset(slice, 0xCC); // Fill with INT3 breakpoint instructions for security
        return ExecutableBuffer{
            .memory = slice,
            .cursor = 0,
            .capacity = aligned_len,
            .is_executable = false,
        };
    }

    pub fn deinit(self: *ExecutableBuffer) void {
        sys.mem.unmap(self.memory.ptr, self.capacity) catch {};
    }

    pub fn emitByte(self: *ExecutableBuffer, b: u8) !void {
        if (self.cursor >= self.capacity) return CodegenError.BufferTooSmall;
        self.memory[self.cursor] = b;
        self.cursor += 1;
    }

    pub fn emitBytes(self: *ExecutableBuffer, bytes: []const u8) !void {
        if (self.cursor + bytes.len > self.capacity) return CodegenError.BufferTooSmall;
        @memcpy(self.memory[self.cursor .. self.cursor + bytes.len], bytes);
        self.cursor += bytes.len;
    }

    pub fn emitU32(self: *ExecutableBuffer, val: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, val, .little);
        try self.emitBytes(&b);
    }

    pub fn emitU64(self: *ExecutableBuffer, val: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, val, .little);
        try self.emitBytes(&b);
    }

    pub fn makeExecutable(self: *ExecutableBuffer) !NativeFn {
        // Enforce W^X: Transition from Read|Write to Read|Execute
        try sys.mem.protect(self.memory.ptr, self.capacity, sys.mem.Prot.read | sys.mem.Prot.exec);
        self.is_executable = true;
        return @ptrCast(@alignCast(self.memory.ptr));
    }
};

const JumpFixup = struct {
    patch_offset: usize,
    target_bytecode_ip: usize,
};

pub const X86Codegen = struct {
    buffer: ExecutableBuffer,
    fixups: std.ArrayList(JumpFixup),
    ip_map: std.ArrayList(usize),
    allocator: Allocator,

    pub fn init(allocator: Allocator, buffer_size: usize) !X86Codegen {
        return X86Codegen{
            .buffer = try ExecutableBuffer.init(buffer_size),
            .fixups = .empty,
            .ip_map = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *X86Codegen) void {
        self.buffer.deinit();
        self.fixups.deinit(self.allocator);
        self.ip_map.deinit(self.allocator);
    }

    fn emitPrologue(self: *X86Codegen, locals_bytes: u32) !void {
        // push rbp (0x55)
        // mov rbp, rsp (0x48, 0x89, 0xE5)
        // sub rsp, imm32 (0x48, 0x81, 0xEC, <imm32>)
        try self.buffer.emitBytes(&[_]u8{ 0x55, 0x48, 0x89, 0xE5 });
        if (locals_bytes > 0) {
            try self.buffer.emitBytes(&[_]u8{ 0x48, 0x81, 0xEC });
            try self.buffer.emitU32(locals_bytes);
        }
    }

    fn emitEpilogue(self: *X86Codegen) !void {
        // pop rax (0x58) -> return value from operand stack
        // mov rsp, rbp (0x48, 0x89, 0xEC)
        // pop rbp (0x5D)
        // ret (0xC3)
        try self.buffer.emitBytes(&[_]u8{ 0x58, 0x48, 0x89, 0xEC, 0x5D, 0xC3 });
    }

    fn emitConstant(self: *X86Codegen, chunk: *const Chunk, idx: u16) !void {
        if (idx >= chunk.constants.items.len) return CodegenError.UnsupportedOpcode;
        const val = chunk.constants.items[idx];
        const int_val: u64 = switch (val) {
            .integer => |i| @bitCast(i),
            .boolean => |b| if (b) 1 else 0,
            else => 0,
        };
        // mov rax, imm64 (0x48, 0xB8, <8 bytes>)
        // push rax (0x50)
        try self.buffer.emitBytes(&[_]u8{ 0x48, 0xB8 });
        try self.buffer.emitU64(int_val);
        try self.buffer.emitByte(0x50);
    }

    fn emitAdd(self: *X86Codegen) !void {
        // pop rcx (0x59)
        // add [rsp], rcx (0x48, 0x01, 0x0C, 0x24)
        try self.buffer.emitBytes(&[_]u8{ 0x59, 0x48, 0x01, 0x0C, 0x24 });
    }

    fn emitSub(self: *X86Codegen) !void {
        // pop rcx (0x59)
        // sub [rsp], rcx (0x48, 0x29, 0x0C, 0x24)
        try self.buffer.emitBytes(&[_]u8{ 0x59, 0x48, 0x29, 0x0C, 0x24 });
    }

    fn emitMultiply(self: *X86Codegen) !void {
        // pop rcx (0x59), pop rax (0x58), imul rax, rcx (0x48, 0x0F, 0xAF, 0xC1), push rax (0x50)
        try self.buffer.emitBytes(&[_]u8{ 0x59, 0x58, 0x48, 0x0F, 0xAF, 0xC1, 0x50 });
    }

    fn emitDivide(self: *X86Codegen) !void {
        // pop rcx (0x59), pop rax (0x58), cqo (0x48, 0x99), idiv rcx (0x48, 0xF7, 0xF9), push rax (0x50)
        try self.buffer.emitBytes(&[_]u8{ 0x59, 0x58, 0x48, 0x99, 0x48, 0xF7, 0xF9, 0x50 });
    }

    fn emitModulo(self: *X86Codegen) !void {
        // pop rcx (0x59), pop rax (0x58), cqo (0x48, 0x99), idiv rcx (0x48, 0xF7, 0xF9), push rdx (0x52)
        try self.buffer.emitBytes(&[_]u8{ 0x59, 0x58, 0x48, 0x99, 0x48, 0xF7, 0xF9, 0x52 });
    }

    fn emitBitwiseAnd(self: *X86Codegen) !void {
        // pop rcx (0x59), and [rsp], rcx (0x48, 0x21, 0x0C, 0x24)
        try self.buffer.emitBytes(&[_]u8{ 0x59, 0x48, 0x21, 0x0C, 0x24 });
    }

    fn emitBitwiseOr(self: *X86Codegen) !void {
        // pop rcx (0x59), or [rsp], rcx (0x48, 0x09, 0x0C, 0x24)
        try self.buffer.emitBytes(&[_]u8{ 0x59, 0x48, 0x09, 0x0C, 0x24 });
    }

    fn emitBitwiseXor(self: *X86Codegen) !void {
        // pop rcx (0x59), xor [rsp], rcx (0x48, 0x31, 0x0C, 0x24)
        try self.buffer.emitBytes(&[_]u8{ 0x59, 0x48, 0x31, 0x0C, 0x24 });
    }

    fn emitShiftLeft(self: *X86Codegen) !void {
        // pop rcx (0x59), shl qword [rsp], cl (0x48, 0xD3, 0x24, 0x24)
        try self.buffer.emitBytes(&[_]u8{ 0x59, 0x48, 0xD3, 0x24, 0x24 });
    }

    fn emitShiftRight(self: *X86Codegen) !void {
        // pop rcx (0x59), sar qword [rsp], cl (0x48, 0xD3, 0x3C, 0x24)
        try self.buffer.emitBytes(&[_]u8{ 0x59, 0x48, 0xD3, 0x3C, 0x24 });
    }

    fn emitNegate(self: *X86Codegen) !void {
        // neg qword [rsp] (0x48, 0xF7, 0x1C, 0x24)
        try self.buffer.emitBytes(&[_]u8{ 0x48, 0xF7, 0x1C, 0x24 });
    }

    fn emitNot(self: *X86Codegen) !void {
        // pop rax (0x58), test rax, rax (0x48, 0x85, 0xC0), setz al (0x0F, 0x94, 0xC0), movzx rax, al (0x48, 0x0F, 0xB6, 0xC0), push rax (0x50)
        try self.buffer.emitBytes(&[_]u8{ 0x58, 0x48, 0x85, 0xC0, 0x0F, 0x94, 0xC0, 0x48, 0x0F, 0xB6, 0xC0, 0x50 });
    }

    fn emitGetLocal(self: *X86Codegen, slot: u8) !void {
        const offset: i8 = -@as(i8, @intCast((@as(usize, slot) + 1) * 8));
        // mov rax, [rbp + disp8] (0x48, 0x8B, 0x45, <disp8>)
        // push rax (0x50)
        try self.buffer.emitBytes(&[_]u8{ 0x48, 0x8B, 0x45, @bitCast(offset), 0x50 });
    }

    fn emitSetLocal(self: *X86Codegen, slot: u8) !void {
        const offset: i8 = -@as(i8, @intCast((@as(usize, slot) + 1) * 8));
        // mov rax, [rsp] (0x48, 0x8B, 0x04, 0x24)
        // mov [rbp + disp8], rax (0x48, 0x89, 0x45, <disp8>)
        try self.buffer.emitBytes(&[_]u8{ 0x48, 0x8B, 0x04, 0x24, 0x48, 0x89, 0x45, @bitCast(offset) });
    }

    fn emitPop(self: *X86Codegen) !void {
        // pop rax (0x58)
        try self.buffer.emitByte(0x58);
    }

    fn emitJump(self: *X86Codegen, target_ip: usize) !void {
        // jmp rel32 (0xE9, <rel32>)
        try self.buffer.emitByte(0xE9);
        const patch_pos = self.buffer.cursor;
        try self.buffer.emitU32(0);
        try self.fixups.append(self.allocator, .{ .patch_offset = patch_pos, .target_bytecode_ip = target_ip });
    }

    fn emitJumpIfFalse(self: *X86Codegen, target_ip: usize) !void {
        // pop rax (0x58)
        // test rax, rax (0x48, 0x85, 0xC0)
        // jz rel32 (0x0F, 0x84, <rel32>)
        try self.buffer.emitBytes(&[_]u8{ 0x58, 0x48, 0x85, 0xC0, 0x0F, 0x84 });
        const patch_pos = self.buffer.cursor;
        try self.buffer.emitU32(0);
        try self.fixups.append(self.allocator, .{ .patch_offset = patch_pos, .target_bytecode_ip = target_ip });
    }

    fn patchFixups(self: *X86Codegen) !void {
        for (self.fixups.items) |fixup| {
            if (fixup.target_bytecode_ip >= self.ip_map.items.len) {
                return CodegenError.InvalidJumpOffset;
            }
            const target_native = self.ip_map.items[fixup.target_bytecode_ip];
            const jump_end = fixup.patch_offset + 4;
            const diff: i32 = @intCast(@as(isize, @bitCast(target_native)) - @as(isize, @bitCast(jump_end)));
            var b: [4]u8 = undefined;
            std.mem.writeInt(i32, &b, diff, .little);
            @memcpy(self.buffer.memory[fixup.patch_offset .. fixup.patch_offset + 4], &b);
        }
    }

    fn compileConstant(self: *X86Codegen, chunk: *const Chunk, ip: *usize) !void {
        const high = chunk.code.items[ip.*];
        const low = chunk.code.items[ip.* + 1];
        ip.* += 2;
        const idx = (@as(u16, high) << 8) | low;
        try self.emitConstant(chunk, idx);
    }

    fn compileJumpOp(self: *X86Codegen, chunk: *const Chunk, ip: *usize, is_cond: bool) !void {
        const high = chunk.code.items[ip.*];
        const low = chunk.code.items[ip.* + 1];
        ip.* += 2;
        const offset = (@as(usize, high) << 8) | low;
        if (is_cond) {
            try self.emitJumpIfFalse(ip.* + offset);
        } else {
            try self.emitJump(ip.* + offset);
        }
    }

    fn compileLocalOp(self: *X86Codegen, chunk: *const Chunk, ip: *usize, is_set: bool) !void {
        const slot = chunk.code.items[ip.*];
        ip.* += 1;
        if (is_set) try self.emitSetLocal(slot) else try self.emitGetLocal(slot);
    }

    fn compileInstruction(self: *X86Codegen, chunk: *const Chunk, ip: *usize) !bool {
        const op_byte = chunk.code.items[ip.*];
        ip.* += 1;
        const op: OpCode = @enumFromInt(op_byte);
        switch (op) {
            .constant => try self.compileConstant(chunk, ip),
            .add => try self.emitAdd(),
            .sub => try self.emitSub(),
            .multiply => try self.emitMultiply(),
            .divide => try self.emitDivide(),
            .modulo => try self.emitModulo(),
            .bitwise_and => try self.emitBitwiseAnd(),
            .bitwise_or => try self.emitBitwiseOr(),
            .bitwise_xor => try self.emitBitwiseXor(),
            .shift_left => try self.emitShiftLeft(),
            .shift_right => try self.emitShiftRight(),
            .negate => try self.emitNegate(),
            .not => try self.emitNot(),
            .get_local => try self.compileLocalOp(chunk, ip, false),
            .set_local => try self.compileLocalOp(chunk, ip, true),
            .pop => try self.emitPop(),
            .jump => try self.compileJumpOp(chunk, ip, false),
            .jump_if_false => try self.compileJumpOp(chunk, ip, true),
            .return_op => {
                try self.emitEpilogue();
                return true;
            },
            else => return CodegenError.UnsupportedOpcode,
        }
        return false;
    }

    pub fn compile(self: *X86Codegen, chunk: *const Chunk, local_count: usize) !NativeFn {
        const locals_bytes: u32 = @intCast(std.mem.alignForward(usize, local_count * 8, 16));
        try self.emitPrologue(locals_bytes);

        try self.ip_map.resize(self.allocator, chunk.code.items.len);
        var ip: usize = 0;
        while (ip < chunk.code.items.len) {
            self.ip_map.items[ip] = self.buffer.cursor;
            const is_ret = try self.compileInstruction(chunk, &ip);
            if (is_ret) break;
        }

        try self.patchFixups();
        return self.buffer.makeExecutable();
    }
};

test "x86_64 JIT basic arithmetic execution with W^X" {
    const testing = std.testing;
    var ch = Chunk.init();
    defer ch.deinit(testing.allocator);

    // 15 + 27 = 42
    const c1 = try ch.addConstant(testing.allocator, eval.Value{ .integer = 15 });
    const c2 = try ch.addConstant(testing.allocator, eval.Value{ .integer = 27 });

    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.constant));
    try ch.writeChunk(testing.allocator, @intCast((c1 >> 8) & 0xFF));
    try ch.writeChunk(testing.allocator, @intCast(c1 & 0xFF));

    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.constant));
    try ch.writeChunk(testing.allocator, @intCast((c2 >> 8) & 0xFF));
    try ch.writeChunk(testing.allocator, @intCast(c2 & 0xFF));

    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.add));
    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.return_op));

    var codegen = try X86Codegen.init(testing.allocator, 4096);
    defer codegen.deinit();

    const native_fn = try codegen.compile(&ch, 0);
    const result = native_fn();
    try testing.expectEqual(@as(i64, 42), result);
}

test "x86_64 JIT local variables and subtraction" {
    const testing = std.testing;
    var ch = Chunk.init();
    defer ch.deinit(testing.allocator);

    // local 0 = 100
    // local 0 - 42 = 58
    const c1 = try ch.addConstant(testing.allocator, eval.Value{ .integer = 100 });
    const c2 = try ch.addConstant(testing.allocator, eval.Value{ .integer = 42 });

    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.constant));
    try ch.writeChunk(testing.allocator, @intCast((c1 >> 8) & 0xFF));
    try ch.writeChunk(testing.allocator, @intCast(c1 & 0xFF));
    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.set_local));
    try ch.writeChunk(testing.allocator, 0);
    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.pop));

    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.get_local));
    try ch.writeChunk(testing.allocator, 0);
    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.constant));
    try ch.writeChunk(testing.allocator, @intCast((c2 >> 8) & 0xFF));
    try ch.writeChunk(testing.allocator, @intCast(c2 & 0xFF));
    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.sub));
    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.return_op));

    var codegen = try X86Codegen.init(testing.allocator, 4096);
    defer codegen.deinit();

    const native_fn = try codegen.compile(&ch, 1);
    const result = native_fn();
    try testing.expectEqual(@as(i64, 58), result);
}

test "x86_64 JIT math, bitwise, and unary completeness" {
    const testing = std.testing;
    var ch = Chunk.init();
    defer ch.deinit(testing.allocator);

    // Compute: (((6 * 7) / 2) % 10) ^ 3
    // 6 * 7 = 42
    // 42 / 2 = 21
    // 21 % 10 = 1
    // 1 ^ 3 = 2
    const c6 = try ch.addConstant(testing.allocator, eval.Value{ .integer = 6 });
    const c7 = try ch.addConstant(testing.allocator, eval.Value{ .integer = 7 });
    const c2 = try ch.addConstant(testing.allocator, eval.Value{ .integer = 2 });
    const c10 = try ch.addConstant(testing.allocator, eval.Value{ .integer = 10 });
    const c3 = try ch.addConstant(testing.allocator, eval.Value{ .integer = 3 });

    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.constant));
    try ch.writeChunk(testing.allocator, @intCast((c6 >> 8) & 0xFF));
    try ch.writeChunk(testing.allocator, @intCast(c6 & 0xFF));
    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.constant));
    try ch.writeChunk(testing.allocator, @intCast((c7 >> 8) & 0xFF));
    try ch.writeChunk(testing.allocator, @intCast(c7 & 0xFF));
    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.multiply));

    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.constant));
    try ch.writeChunk(testing.allocator, @intCast((c2 >> 8) & 0xFF));
    try ch.writeChunk(testing.allocator, @intCast(c2 & 0xFF));
    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.divide));

    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.constant));
    try ch.writeChunk(testing.allocator, @intCast((c10 >> 8) & 0xFF));
    try ch.writeChunk(testing.allocator, @intCast(c10 & 0xFF));
    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.modulo));

    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.constant));
    try ch.writeChunk(testing.allocator, @intCast((c3 >> 8) & 0xFF));
    try ch.writeChunk(testing.allocator, @intCast(c3 & 0xFF));
    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.bitwise_xor));

    // Negate: -(2) = -2
    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.negate));
    try ch.writeChunk(testing.allocator, @intFromEnum(OpCode.return_op));

    var codegen = try X86Codegen.init(testing.allocator, 4096);
    defer codegen.deinit();

    const native_fn = try codegen.compile(&ch, 0);
    const result = native_fn();
    try testing.expectEqual(@as(i64, -2), result);
}
