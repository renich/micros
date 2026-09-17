// MicrOS (µOS) Pure Freestanding PE/COFF 64-Bit EFI Synthesizer
// Generates valid PE32+ BOOTX64.EFI binaries without external linkers.
// Enforces W^X page protection and 4-byte aligned base relocations.
// Zero libc, freestanding, explicit allocator.

const std = @import("std");

pub const DOS_MAGIC: u16 = 0x5A4D; // "MZ"
pub const PE_SIGNATURE: u32 = 0x0000_4550; // "PE\0\0"
pub const MACHINE_AMD64: u16 = 0x8664;
pub const OPTIONAL_HEADER_MAGIC_PE32_PLUS: u16 = 0x020B;
pub const SUBSYSTEM_EFI_APPLICATION: u16 = 10;

pub const SECTION_ALIGNMENT: u32 = 4096; // 4 KiB
pub const FILE_ALIGNMENT: u32 = 512; // Sector size

pub const SCN_CNT_CODE: u32 = 0x0000_0020;
pub const SCN_CNT_INITIALIZED_DATA: u32 = 0x0000_0040;
pub const SCN_MEM_DISCARDABLE: u32 = 0x0200_0000;
pub const SCN_MEM_EXECUTE: u32 = 0x2000_0000;
pub const SCN_MEM_READ: u32 = 0x4000_0000;
pub const SCN_MEM_WRITE: u32 = 0x8000_0000;

pub const CHAR_TEXT: u32 = SCN_CNT_CODE | SCN_MEM_EXECUTE | SCN_MEM_READ; // 0x60000020 (RX)
pub const CHAR_RODATA: u32 = SCN_CNT_INITIALIZED_DATA | SCN_MEM_READ; // 0x40000040 (R)
pub const CHAR_DATA: u32 = SCN_CNT_INITIALIZED_DATA | SCN_MEM_READ | SCN_MEM_WRITE; // 0xC0000040 (RW)
pub const CHAR_RELOC: u32 = SCN_CNT_INITIALIZED_DATA | SCN_MEM_READ | SCN_MEM_DISCARDABLE; // 0x42000040 (R)

pub const IMAGE_REL_BASED_ABSOLUTE: u16 = 0;
pub const IMAGE_REL_BASED_DIR64: u16 = 10;
pub const DIRECTORY_ENTRY_BASERELOC: usize = 5;
pub const NUMBER_OF_DATA_DIRECTORIES: usize = 16;
pub const OPTIONAL_HEADER_SIZE: u16 = 240;
pub const DOS_LFANEW_OFFSET: u32 = 0x0080;
pub const DEFAULT_IMAGE_BASE: u64 = 0x0000_0001_4000_0000;

pub const DosHeader = extern struct {
    e_magic: u16 = DOS_MAGIC,
    e_cblp: u16 = 0x0090,
    e_cp: u16 = 0x0003,
    e_crlc: u16 = 0x0000,
    e_cparhdr: u16 = 0x0004,
    e_minalloc: u16 = 0x0000,
    e_maxalloc: u16 = 0xFFFF,
    e_ss: u16 = 0x0000,
    e_sp: u16 = 0x00B8,
    e_csum: u16 = 0x0000,
    e_ip: u16 = 0x0000,
    e_cs: u16 = 0x0000,
    e_lfarlc: u16 = 0x0040,
    e_ovno: u16 = 0x0000,
    e_res: [4]u16 = [_]u16{0} ** 4,
    e_oemid: u16 = 0x0000,
    e_oeminfo: u16 = 0x0000,
    e_res2: [10]u16 = [_]u16{0} ** 10,
    e_lfanew: u32 = DOS_LFANEW_OFFSET,
};

pub const CoffHeader = extern struct {
    machine: u16 = MACHINE_AMD64,
    number_of_sections: u16,
    time_date_stamp: u32 = 0,
    pointer_to_symbol_table: u32 = 0,
    number_of_symbols: u32 = 0,
    size_of_optional_header: u16 = OPTIONAL_HEADER_SIZE,
    characteristics: u16 = 0x0226, // EXECUTABLE_IMAGE | LARGE_ADDRESS_AWARE | LINE_NUMS_STRIPPED
};

pub const ImageDataDirectory = extern struct {
    virtual_address: u32 = 0,
    size: u32 = 0,
};

pub const OptionalHeader64 = extern struct {
    magic: u16 = OPTIONAL_HEADER_MAGIC_PE32_PLUS,
    major_linker_version: u8 = 1,
    minor_linker_version: u8 = 0,
    size_of_code: u32 = 0,
    size_of_initialized_data: u32 = 0,
    size_of_uninitialized_data: u32 = 0,
    address_of_entry_point: u32,
    base_of_code: u32 = SECTION_ALIGNMENT,
    image_base: u64 = DEFAULT_IMAGE_BASE,
    section_alignment: u32 = SECTION_ALIGNMENT,
    file_alignment: u32 = FILE_ALIGNMENT,
    major_os_version: u16 = 0,
    minor_os_version: u16 = 0,
    major_image_version: u16 = 1,
    minor_image_version: u16 = 0,
    major_subsystem_version: u16 = 0,
    minor_subsystem_version: u16 = 0,
    win32_version_value: u32 = 0,
    size_of_image: u32 = 0,
    size_of_headers: u32 = FILE_ALIGNMENT,
    check_sum: u32 = 0,
    subsystem: u16 = SUBSYSTEM_EFI_APPLICATION,
    dll_characteristics: u16 = 0x0140, // DYNAMIC_BASE | NX_COMPAT
    size_of_stack_reserve: u64 = 0x100000,
    size_of_stack_commit: u64 = 0x10000,
    size_of_heap_reserve: u64 = 0x100000,
    size_of_heap_commit: u64 = 0x10000,
    loader_flags: u32 = 0,
    number_of_rva_and_sizes: u32 = NUMBER_OF_DATA_DIRECTORIES,
    data_directories: [NUMBER_OF_DATA_DIRECTORIES]ImageDataDirectory = [_]ImageDataDirectory{.{}} ** NUMBER_OF_DATA_DIRECTORIES,
};

pub const SectionHeader = extern struct {
    name: [8]u8,
    virtual_size: u32,
    virtual_address: u32,
    size_of_raw_data: u32,
    pointer_to_raw_data: u32,
    pointer_to_relocations: u32 = 0,
    pointer_to_linenumbers: u32 = 0,
    number_of_relocations: u16 = 0,
    number_of_linenumbers: u16 = 0,
    characteristics: u32,
};

pub const BaseRelocBlockHeader = extern struct {
    page_rva: u32,
    block_size: u32,
};

pub const SectionInput = struct {
    name: []const u8,
    data: []const u8,
    characteristics: u32,
};

pub const PeEmitterConfig = struct {
    entry_point_rva: u32 = SECTION_ALIGNMENT,
    image_base: u64 = DEFAULT_IMAGE_BASE,
    subsystem: u16 = SUBSYSTEM_EFI_APPLICATION,
};

pub fn alignUp(val: u32, alignment: u32) u32 {
    return (val + (alignment - 1)) & ~(alignment - 1);
}

pub fn formatSectionName(name: []const u8) [8]u8 {
    var out = [_]u8{0} ** 8;
    const len = @min(name.len, 8);
    @memcpy(out[0..len], name[0..len]);
    return out;
}

pub fn calculateHeadersSize(section_count: usize) u32 {
    const raw_len = DOS_LFANEW_OFFSET + 4 + @sizeOf(CoffHeader) + @sizeOf(OptionalHeader64) + (section_count * @sizeOf(SectionHeader));
    return alignUp(@intCast(raw_len), FILE_ALIGNMENT);
}

fn writeRelocPageBlock(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),
    page_rva: u32,
    page_relocs: []const u32,
) !void {
    const odd = (page_relocs.len % 2) != 0;
    const total_entries = if (odd) page_relocs.len + 1 else page_relocs.len;
    const block_size: u32 = @intCast(@sizeOf(BaseRelocBlockHeader) + (total_entries * 2));

    const hdr = BaseRelocBlockHeader{ .page_rva = page_rva, .block_size = block_size };
    try list.appendSlice(allocator, std.mem.asBytes(&hdr));

    for (page_relocs) |r| {
        const offset = @as(u16, @truncate(r & 0x0FFF));
        const entry: u16 = (@as(u16, IMAGE_REL_BASED_DIR64) << 12) | offset;
        try list.appendSlice(allocator, std.mem.asBytes(&entry));
    }
    if (odd) {
        const pad: u16 = (@as(u16, IMAGE_REL_BASED_ABSOLUTE) << 12);
        try list.appendSlice(allocator, std.mem.asBytes(&pad));
    }
}

pub fn emitRelocationBlocks(
    allocator: std.mem.Allocator,
    relocs: []const u32,
) ![]u8 {
    if (relocs.len == 0) return try allocator.alloc(u8, 0);

    const sorted = try allocator.alloc(u32, relocs.len);
    defer allocator.free(sorted);
    @memcpy(sorted, relocs);
    std.mem.sort(u32, sorted, {}, std.sort.asc(u32));

    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    var i: usize = 0;
    while (i < sorted.len) {
        const page_rva = sorted[i] & ~@as(u32, 0x0FFF);
        var page_count: usize = 0;
        while (i + page_count < sorted.len) : (page_count += 1) {
            const next_page = sorted[i + page_count] & ~@as(u32, 0x0FFF);
            if (next_page != page_rva) break;
        }

        try writeRelocPageBlock(allocator, &list, page_rva, sorted[i .. i + page_count]);
        i += page_count;
    }

    return list.toOwnedSlice(allocator);
}

pub const PeEmitter = struct {
    allocator: std.mem.Allocator,
    config: PeEmitterConfig,

    pub fn init(allocator: std.mem.Allocator, config: PeEmitterConfig) PeEmitter {
        return .{ .allocator = allocator, .config = config };
    }

    const LayoutResult = struct {
        code_size: u32,
        init_data_size: u32,
        image_size: u32,
        total_file_size: u32,
        reloc_dir: ImageDataDirectory,
    };

    const LayoutState = struct {
        curr_rva: u32,
        curr_file_off: u32,
        code_size: u32 = 0,
        init_data_size: u32 = 0,
    };

    fn layoutStandardSections(
        sec_headers: []SectionHeader,
        sections: []const SectionInput,
        headers_size: u32,
    ) LayoutState {
        var state = LayoutState{ .curr_rva = SECTION_ALIGNMENT, .curr_file_off = headers_size };
        for (sections, 0..) |sec, i| {
            const raw_size = alignUp(@intCast(sec.data.len), FILE_ALIGNMENT);
            const virt_size: u32 = @intCast(sec.data.len);
            sec_headers[i] = SectionHeader{
                .name = formatSectionName(sec.name),
                .virtual_size = virt_size,
                .virtual_address = state.curr_rva,
                .size_of_raw_data = raw_size,
                .pointer_to_raw_data = state.curr_file_off,
                .characteristics = sec.characteristics,
            };
            if ((sec.characteristics & SCN_CNT_CODE) != 0) {
                state.code_size += raw_size;
            } else {
                state.init_data_size += raw_size;
            }
            state.curr_rva = alignUp(state.curr_rva + virt_size, SECTION_ALIGNMENT);
            state.curr_file_off += raw_size;
        }
        return state;
    }

    fn layoutRelocSection(
        sec_headers: []SectionHeader,
        sec_idx: usize,
        reloc_len: usize,
        state: *LayoutState,
    ) ImageDataDirectory {
        const r_raw = alignUp(@intCast(reloc_len), FILE_ALIGNMENT);
        const r_virt: u32 = @intCast(reloc_len);
        sec_headers[sec_idx] = SectionHeader{
            .name = formatSectionName(".reloc"),
            .virtual_size = r_virt,
            .virtual_address = state.curr_rva,
            .size_of_raw_data = r_raw,
            .pointer_to_raw_data = state.curr_file_off,
            .characteristics = CHAR_RELOC,
        };
        const reloc_dir = ImageDataDirectory{ .virtual_address = state.curr_rva, .size = r_virt };
        state.init_data_size += r_raw;
        state.curr_rva = alignUp(state.curr_rva + r_virt, SECTION_ALIGNMENT);
        state.curr_file_off += r_raw;
        return reloc_dir;
    }

    fn layoutSections(
        sec_headers: []SectionHeader,
        sections: []const SectionInput,
        reloc_data: []const u8,
        headers_size: u32,
    ) LayoutResult {
        var state = layoutStandardSections(sec_headers, sections, headers_size);
        var reloc_dir = ImageDataDirectory{ .virtual_address = 0, .size = 0 };
        if (reloc_data.len > 0) {
            reloc_dir = layoutRelocSection(sec_headers, sections.len, reloc_data.len, &state);
        }
        return .{
            .code_size = state.code_size,
            .init_data_size = state.init_data_size,
            .image_size = state.curr_rva,
            .total_file_size = state.curr_file_off,
            .reloc_dir = reloc_dir,
        };
    }

    fn writePayloads(
        out_buf: []u8,
        sec_headers: []const SectionHeader,
        sections: []const SectionInput,
        reloc_data: []const u8,
    ) void {
        for (sections, 0..) |sec, i| {
            const off = sec_headers[i].pointer_to_raw_data;
            @memcpy(out_buf[off .. off + sec.data.len], sec.data);
        }
        if (reloc_data.len > 0) {
            const r_off = sec_headers[sections.len].pointer_to_raw_data;
            @memcpy(out_buf[r_off .. r_off + reloc_data.len], reloc_data);
        }
    }

    pub fn synthesizeExecutable(
        self: *const PeEmitter,
        sections: []const SectionInput,
        reloc_data: []const u8,
    ) ![]u8 {
        const total_sec_count = if (reloc_data.len > 0) sections.len + 1 else sections.len;
        const headers_size = calculateHeadersSize(total_sec_count);

        const sec_headers = try self.allocator.alloc(SectionHeader, total_sec_count);
        defer self.allocator.free(sec_headers);

        const layout = layoutSections(sec_headers, sections, reloc_data, headers_size);
        const out_buf = try self.allocator.alloc(u8, layout.total_file_size);
        @memset(out_buf, 0);

        try self.writeHeaders(out_buf, sec_headers, layout, headers_size);
        writePayloads(out_buf, sec_headers, sections, reloc_data);

        return out_buf;
    }

    fn writeHeaders(
        self: *const PeEmitter,
        buf: []u8,
        sec_headers: []const SectionHeader,
        layout: LayoutResult,
        headers_size: u32,
    ) !void {
        const dos_hdr = DosHeader{};
        @memcpy(buf[0..@sizeOf(DosHeader)], std.mem.asBytes(&dos_hdr));

        const pe_sig: u32 = PE_SIGNATURE;
        @memcpy(buf[DOS_LFANEW_OFFSET .. DOS_LFANEW_OFFSET + 4], std.mem.asBytes(&pe_sig));

        const coff_off = DOS_LFANEW_OFFSET + 4;
        const coff_hdr = CoffHeader{
            .number_of_sections = @intCast(sec_headers.len),
        };
        @memcpy(buf[coff_off .. coff_off + @sizeOf(CoffHeader)], std.mem.asBytes(&coff_hdr));

        const opt_off = coff_off + @sizeOf(CoffHeader);
        var opt_hdr = OptionalHeader64{
            .size_of_code = layout.code_size,
            .size_of_initialized_data = layout.init_data_size,
            .address_of_entry_point = self.config.entry_point_rva,
            .image_base = self.config.image_base,
            .size_of_image = layout.image_size,
            .size_of_headers = headers_size,
            .subsystem = self.config.subsystem,
        };
        opt_hdr.data_directories[DIRECTORY_ENTRY_BASERELOC] = layout.reloc_dir;
        @memcpy(buf[opt_off .. opt_off + @sizeOf(OptionalHeader64)], std.mem.asBytes(&opt_hdr));

        const sec_tbl_off = opt_off + @sizeOf(OptionalHeader64);
        for (sec_headers, 0..) |sh, i| {
            const off = sec_tbl_off + (i * @sizeOf(SectionHeader));
            @memcpy(buf[off .. off + @sizeOf(SectionHeader)], std.mem.asBytes(&sh));
        }
    }

    pub fn synthesizeBootloader(
        self: *const PeEmitter,
        code: []const u8,
        rodata: []const u8,
        rwdata: []const u8,
        relocs: []const u32,
    ) ![]u8 {
        const reloc_data = try emitRelocationBlocks(self.allocator, relocs);
        defer self.allocator.free(reloc_data);

        const sections = [_]SectionInput{
            .{ .name = ".text", .data = code, .characteristics = CHAR_TEXT },
            .{ .name = ".rodata", .data = rodata, .characteristics = CHAR_RODATA },
            .{ .name = ".data", .data = rwdata, .characteristics = CHAR_DATA },
        };

        return try self.synthesizeExecutable(&sections, reloc_data);
    }
};

test "pe emitter dos and coff layout" {
    try std.testing.expectEqual(64, @sizeOf(DosHeader));
    try std.testing.expectEqual(20, @sizeOf(CoffHeader));
    try std.testing.expectEqual(240, @sizeOf(OptionalHeader64));
    try std.testing.expectEqual(40, @sizeOf(SectionHeader));
    try std.testing.expectEqual(8, @sizeOf(BaseRelocBlockHeader));
}

test "pe emitter relocation grouping and alignment" {
    const allocator = std.testing.allocator;
    const test_relocs = [_]u32{ 0x1008, 0x1010, 0x1024 }; // 3 relocations in page 0x1000 (odd count)
    const block_bytes = try emitRelocationBlocks(allocator, &test_relocs);
    defer allocator.free(block_bytes);

    // 8 bytes header + (4 entries * 2) = 16 bytes (padded to multiple of 4)
    try std.testing.expectEqual(@as(usize, 16), block_bytes.len);
    const hdr: *const BaseRelocBlockHeader = @ptrCast(@alignCast(block_bytes.ptr));
    try std.testing.expectEqual(@as(u32, 0x1000), hdr.page_rva);
    try std.testing.expectEqual(@as(u32, 16), hdr.block_size);
}

test "pe emitter unsorted relocation determinism" {
    const allocator = std.testing.allocator;
    const sorted_relocs = [_]u32{ 0x1008, 0x1010, 0x2004 };
    const unsorted_relocs = [_]u32{ 0x2004, 0x1010, 0x1008 };

    const b1 = try emitRelocationBlocks(allocator, &sorted_relocs);
    defer allocator.free(b1);
    const b2 = try emitRelocationBlocks(allocator, &unsorted_relocs);
    defer allocator.free(b2);

    try std.testing.expectEqualSlices(u8, b1, b2);
}

test "pe emitter synthetic bootloader validation" {
    const allocator = std.testing.allocator;
    const emitter = PeEmitter.init(allocator, .{
        .entry_point_rva = SECTION_ALIGNMENT,
    });

    const mock_code = [_]u8{ 0x48, 0x31, 0xC0, 0xC3 }; // xor rax, rax; ret
    const mock_rodata = "MicrOS Silicon UEFI Kernel";
    const mock_data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const mock_relocs = [_]u32{ 0x1002, 0x2000 };

    const pe_bin = try emitter.synthesizeBootloader(&mock_code, mock_rodata, &mock_data, &mock_relocs);
    defer allocator.free(pe_bin);

    // Verify DOS header
    const dos: *const DosHeader = @ptrCast(@alignCast(pe_bin.ptr));
    try std.testing.expectEqual(DOS_MAGIC, dos.e_magic);
    try std.testing.expectEqual(DOS_LFANEW_OFFSET, dos.e_lfanew);

    // Verify PE Signature
    const pe_sig: *const u32 = @ptrCast(@alignCast(pe_bin[DOS_LFANEW_OFFSET .. DOS_LFANEW_OFFSET + 4].ptr));
    try std.testing.expectEqual(PE_SIGNATURE, pe_sig.*);

    // Verify COFF Header
    const coff_off = DOS_LFANEW_OFFSET + 4;
    const coff: *const CoffHeader = @ptrCast(@alignCast(pe_bin[coff_off .. coff_off + @sizeOf(CoffHeader)].ptr));
    try std.testing.expectEqual(MACHINE_AMD64, coff.machine);
    try std.testing.expectEqual(@as(u16, 4), coff.number_of_sections); // .text, .rodata, .data, .reloc
    try std.testing.expectEqual(OPTIONAL_HEADER_SIZE, coff.size_of_optional_header);

    // Verify Optional Header
    const opt_off = coff_off + @sizeOf(CoffHeader);
    const opt: *const OptionalHeader64 = @ptrCast(@alignCast(pe_bin[opt_off .. opt_off + @sizeOf(OptionalHeader64)].ptr));
    try std.testing.expectEqual(OPTIONAL_HEADER_MAGIC_PE32_PLUS, opt.magic);
    try std.testing.expectEqual(SUBSYSTEM_EFI_APPLICATION, opt.subsystem);
    try std.testing.expect(opt.size_of_image >= SECTION_ALIGNMENT * 4);
    try std.testing.expect(opt.size_of_headers % FILE_ALIGNMENT == 0);

    // Verify Relocation Directory entry
    const reloc_dir = opt.data_directories[DIRECTORY_ENTRY_BASERELOC];
    try std.testing.expect(reloc_dir.virtual_address > 0);
    try std.testing.expect(reloc_dir.size > 0);
}
