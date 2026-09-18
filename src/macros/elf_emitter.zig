// MicrOS (µOS) Pure Freestanding 64-Bit ELF Object Synthesizer (elf_emitter.zig)
// Emits deterministic, relocatable ELF64 (.o) objects and symbol tables directly on silicon.
// SPEC-TECH-LANG-004: Pure in-system native compiler backend and W^X enforcement.
// Zero libc, freestanding, explicit allocator.

const std = @import("std");

pub const EI_MAG0: usize = 0;
pub const EI_MAG1: usize = 1;
pub const EI_MAG2: usize = 2;
pub const EI_MAG3: usize = 3;
pub const EI_CLASS: usize = 4;
pub const EI_DATA: usize = 5;
pub const EI_VERSION: usize = 6;
pub const EI_OSABI: usize = 7;
pub const EI_NIDENT: usize = 16;

pub const ELFCLASS64: u8 = 2;
pub const ELFDATA2LSB: u8 = 1;
pub const EV_CURRENT: u8 = 1;
pub const ELFOSABI_NONE: u8 = 0;

pub const ET_REL: u16 = 1;
pub const EM_X86_64: u16 = 62;

pub const SHT_NULL: u32 = 0;
pub const SHT_PROGBITS: u32 = 1;
pub const SHT_SYMTAB: u32 = 2;
pub const SHT_STRTAB: u32 = 3;

pub const SHF_WRITE: u64 = 0x1;
pub const SHF_ALLOC: u64 = 0x2;
pub const SHF_EXECINSTR: u64 = 0x4;

pub const STB_LOCAL: u8 = 0;
pub const STB_GLOBAL: u8 = 1;
pub const STT_NOTYPE: u8 = 0;
pub const STT_OBJECT: u8 = 1;
pub const STT_FUNC: u8 = 2;

pub const Elf64_Ehdr = extern struct {
    e_ident: [EI_NIDENT]u8 align(1),
    e_type: u16 align(1),
    e_machine: u16 align(1),
    e_version: u32 align(1),
    e_entry: u64 align(1),
    e_phoff: u64 align(1),
    e_shoff: u64 align(1),
    e_flags: u32 align(1),
    e_ehsize: u16 align(1),
    e_phentsize: u16 align(1),
    e_phnum: u16 align(1),
    e_shentsize: u16 align(1),
    e_shnum: u16 align(1),
    e_shstrndx: u16 align(1),

    pub fn initDefault() Elf64_Ehdr {
        var hdr = std.mem.zeroes(Elf64_Ehdr);
        hdr.e_ident[EI_MAG0] = 0x7F;
        hdr.e_ident[EI_MAG1] = 'E';
        hdr.e_ident[EI_MAG2] = 'L';
        hdr.e_ident[EI_MAG3] = 'F';
        hdr.e_ident[EI_CLASS] = ELFCLASS64;
        hdr.e_ident[EI_DATA] = ELFDATA2LSB;
        hdr.e_ident[EI_VERSION] = EV_CURRENT;
        hdr.e_ident[EI_OSABI] = ELFOSABI_NONE;

        hdr.e_type = ET_REL;
        hdr.e_machine = EM_X86_64;
        hdr.e_version = EV_CURRENT;
        hdr.e_ehsize = @sizeOf(Elf64_Ehdr);
        hdr.e_shentsize = @sizeOf(Elf64_Shdr);
        return hdr;
    }
};

pub const Elf64_Shdr = extern struct {
    sh_name: u32 align(1),
    sh_type: u32 align(1),
    sh_flags: u64 align(1),
    sh_addr: u64 align(1),
    sh_offset: u64 align(1),
    sh_size: u64 align(1),
    sh_link: u32 align(1),
    sh_info: u32 align(1),
    sh_addralign: u64 align(1),
    sh_entsize: u64 align(1),
};

pub const Elf64_Sym = extern struct {
    st_name: u32 align(1),
    st_info: u8 align(1),
    st_other: u8 align(1),
    st_shndx: u16 align(1),
    st_value: u64 align(1),
    st_size: u64 align(1),

    pub fn make(name_off: u32, info: u8, shndx: u16, val: u64, sz: u64) Elf64_Sym {
        return Elf64_Sym{
            .st_name = name_off,
            .st_info = info,
            .st_other = 0,
            .st_shndx = shndx,
            .st_value = val,
            .st_size = sz,
        };
    }
};

pub const EmitterSymbol = struct {
    name: []const u8,
    section_idx: u16,
    value: u64,
    size: u64,
    is_func: bool,
};

pub const ElfEmitter = struct {
    allocator: std.mem.Allocator,
    symbols: std.ArrayList(EmitterSymbol),

    pub fn init(allocator: std.mem.Allocator) ElfEmitter {
        return ElfEmitter{
            .allocator = allocator,
            .symbols = .empty,
        };
    }

    pub fn deinit(self: *ElfEmitter) void {
        self.symbols.deinit(self.allocator);
    }

    pub fn addSymbol(self: *ElfEmitter, name: []const u8, sec_idx: u16, val: u64, sz: u64, is_func: bool) !void {
        try self.symbols.append(self.allocator, .{
            .name = name,
            .section_idx = sec_idx,
            .value = val,
            .size = sz,
            .is_func = is_func,
        });
    }

    pub fn emitRelocatable(self: *const ElfEmitter, text: []const u8, rodata: []const u8, data: []const u8) ![]u8 {
        var strtab = std.ArrayList(u8).empty;
        defer strtab.deinit(self.allocator);
        try strtab.append(self.allocator, 0); // null entry

        var syms = std.ArrayList(Elf64_Sym).empty;
        defer syms.deinit(self.allocator);
        try syms.append(self.allocator, std.mem.zeroes(Elf64_Sym)); // STN_UNDEF

        for (self.symbols.items) |sym| {
            const name_off = @as(u32, @intCast(strtab.items.len));
            try strtab.appendSlice(self.allocator, sym.name);
            try strtab.append(self.allocator, 0);

            const sym_type = if (sym.is_func) STT_FUNC else STT_OBJECT;
            const info = (STB_GLOBAL << 4) | (sym_type & 0xF);
            try syms.append(self.allocator, Elf64_Sym.make(name_off, info, sym.section_idx, sym.value, sym.size));
        }

        const shstrtab = "\x00.text\x00.rodata\x00.data\x00.symtab\x00.strtab\x00.shstrtab\x00";
        return try assembleElfObject(self.allocator, text, rodata, data, syms.items, strtab.items, shstrtab);
    }
};

const SectionOffsets = struct {
    off_text: usize,
    off_rodata: usize,
    off_data: usize,
    off_symtab: usize,
    off_strtab: usize,
    off_shstrtab: usize,
};

fn appendSectionPayloads(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    text: []const u8,
    rodata: []const u8,
    data: []const u8,
    syms: []const Elf64_Sym,
    strtab: []const u8,
    shstrtab: []const u8,
) !SectionOffsets {
    const off_text = out.items.len;
    try out.appendSlice(allocator, text);
    const off_rodata = out.items.len;
    try out.appendSlice(allocator, rodata);
    const off_data = out.items.len;
    try out.appendSlice(allocator, data);
    const off_symtab = out.items.len;
    const sym_bytes: [*]const u8 = @ptrCast(syms.ptr);
    try out.appendSlice(allocator, sym_bytes[0 .. syms.len * @sizeOf(Elf64_Sym)]);
    const off_strtab = out.items.len;
    try out.appendSlice(allocator, strtab);
    const off_shstrtab = out.items.len;
    try out.appendSlice(allocator, shstrtab);

    return SectionOffsets{
        .off_text = off_text,
        .off_rodata = off_rodata,
        .off_data = off_data,
        .off_symtab = off_symtab,
        .off_strtab = off_strtab,
        .off_shstrtab = off_shstrtab,
    };
}

fn assembleElfObject(
    allocator: std.mem.Allocator,
    text: []const u8,
    rodata: []const u8,
    data: []const u8,
    syms: []const Elf64_Sym,
    strtab: []const u8,
    shstrtab: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var ehdr = Elf64_Ehdr.initDefault();
    const ehdr_size = @sizeOf(Elf64_Ehdr);
    try out.appendNTimes(allocator, 0, ehdr_size);

    const offs = try appendSectionPayloads(&out, allocator, text, rodata, data, syms, strtab, shstrtab);
    const off_shdrs = out.items.len;
    const shdrs = createSectionHeaders(
        text.len, offs.off_text,
        rodata.len, offs.off_rodata,
        data.len, offs.off_data,
        syms.len, offs.off_symtab,
        strtab.len, offs.off_strtab,
        shstrtab.len, offs.off_shstrtab,
    );

    const shdr_bytes: [*]const u8 = @ptrCast(&shdrs);
    try out.appendSlice(allocator, shdr_bytes[0..@sizeOf(@TypeOf(shdrs))]);

    ehdr.e_shoff = off_shdrs;
    ehdr.e_shnum = 7;
    ehdr.e_shstrndx = 6;
    const ehdr_bytes: [*]const u8 = @ptrCast(&ehdr);
    @memcpy(out.items[0..ehdr_size], ehdr_bytes[0..ehdr_size]);

    return out.toOwnedSlice(allocator);
}

fn createSectionHeaders(
    text_len: usize, off_text: usize,
    rodata_len: usize, off_rodata: usize,
    data_len: usize, off_data: usize,
    sym_count: usize, off_symtab: usize,
    strtab_len: usize, off_strtab: usize,
    shstrtab_len: usize, off_shstrtab: usize,
) [7]Elf64_Shdr {
    var shdrs = std.mem.zeroes([7]Elf64_Shdr);
    // 1: .text (shstrtab off 1)
    shdrs[1] = .{ .sh_name = 1, .sh_type = SHT_PROGBITS, .sh_flags = SHF_ALLOC | SHF_EXECINSTR, .sh_addr = 0, .sh_offset = off_text, .sh_size = text_len, .sh_link = 0, .sh_info = 0, .sh_addralign = 16, .sh_entsize = 0 };
    // 2: .rodata (shstrtab off 7)
    shdrs[2] = .{ .sh_name = 7, .sh_type = SHT_PROGBITS, .sh_flags = SHF_ALLOC, .sh_addr = 0, .sh_offset = off_rodata, .sh_size = rodata_len, .sh_link = 0, .sh_info = 0, .sh_addralign = 8, .sh_entsize = 0 };
    // 3: .data (shstrtab off 15)
    shdrs[3] = .{ .sh_name = 15, .sh_type = SHT_PROGBITS, .sh_flags = SHF_ALLOC | SHF_WRITE, .sh_addr = 0, .sh_offset = off_data, .sh_size = data_len, .sh_link = 0, .sh_info = 0, .sh_addralign = 8, .sh_entsize = 0 };
    // 4: .symtab (shstrtab off 21)
    shdrs[4] = .{ .sh_name = 21, .sh_type = SHT_SYMTAB, .sh_flags = 0, .sh_addr = 0, .sh_offset = off_symtab, .sh_size = sym_count * @sizeOf(Elf64_Sym), .sh_link = 5, .sh_info = 1, .sh_addralign = 8, .sh_entsize = @sizeOf(Elf64_Sym) };
    // 5: .strtab (shstrtab off 29)
    shdrs[5] = .{ .sh_name = 29, .sh_type = SHT_STRTAB, .sh_flags = 0, .sh_addr = 0, .sh_offset = off_strtab, .sh_size = strtab_len, .sh_link = 0, .sh_info = 0, .sh_addralign = 1, .sh_entsize = 0 };
    // 6: .shstrtab (shstrtab off 37)
    shdrs[6] = .{ .sh_name = 37, .sh_type = SHT_STRTAB, .sh_flags = 0, .sh_addr = 0, .sh_offset = off_shstrtab, .sh_size = shstrtab_len, .sh_link = 0, .sh_info = 0, .sh_addralign = 1, .sh_entsize = 0 };
    return shdrs;
}

pub fn computeImageHash(elf_bytes: []const u8, out_hash: *[32]u8) void {
    std.crypto.hash.Blake3.hash(elf_bytes, out_hash, .{});
}

test "ElfEmitter header validation and section integrity" {
    var emitter = ElfEmitter.init(std.testing.allocator);
    defer emitter.deinit();

    const code = [_]u8{ 0x48, 0x31, 0xC0, 0xC3 }; // xor rax, rax; ret
    const rodata = "Hello MicrOS Silicon";
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };

    try emitter.addSymbol("_start", 1, 0, code.len, true);
    try emitter.addSymbol("banner", 2, 0, rodata.len, false);

    const elf_obj = try emitter.emitRelocatable(&code, rodata, &data);
    defer std.testing.allocator.free(elf_obj);

    try std.testing.expect(elf_obj.len > @sizeOf(Elf64_Ehdr));
    const ehdr: *const Elf64_Ehdr = @ptrCast(elf_obj.ptr);
    try std.testing.expectEqual(@as(u8, 0x7F), ehdr.e_ident[EI_MAG0]);
    try std.testing.expectEqual(@as(u8, 'E'), ehdr.e_ident[EI_MAG1]);
    try std.testing.expectEqual(@as(u8, 'L'), ehdr.e_ident[EI_MAG2]);
    try std.testing.expectEqual(@as(u8, 'F'), ehdr.e_ident[EI_MAG3]);
    try std.testing.expectEqual(ELFCLASS64, ehdr.e_ident[EI_CLASS]);
    try std.testing.expectEqual(ET_REL, ehdr.e_type);
    try std.testing.expectEqual(EM_X86_64, ehdr.e_machine);
    try std.testing.expectEqual(@as(u16, 7), ehdr.e_shnum);
    try std.testing.expectEqual(@as(u16, 6), ehdr.e_shstrndx);
}

test "ElfEmitter bit-for-bit deterministic reproducibility" {
    var emitter1 = ElfEmitter.init(std.testing.allocator);
    defer emitter1.deinit();
    try emitter1.addSymbol("fn_a", 1, 0, 16, true);
    try emitter1.addSymbol("var_b", 3, 0, 8, false);

    const obj1 = try emitter1.emitRelocatable("code1", "rodata1", "data1");
    defer std.testing.allocator.free(obj1);

    var emitter2 = ElfEmitter.init(std.testing.allocator);
    defer emitter2.deinit();
    try emitter2.addSymbol("fn_a", 1, 0, 16, true);
    try emitter2.addSymbol("var_b", 3, 0, 8, false);

    const obj2 = try emitter2.emitRelocatable("code1", "rodata1", "data1");
    defer std.testing.allocator.free(obj2);

    var hash1: [32]u8 = undefined;
    var hash2: [32]u8 = undefined;
    computeImageHash(obj1, &hash1);
    computeImageHash(obj2, &hash2);

    try std.testing.expectEqualStrings(&hash1, &hash2);
}
