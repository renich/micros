const std = @import("std");

pub const Symbol = struct {
    name: []const u8,
    address: u64,
    size: u64,
};

pub const ElfSymbolTable = struct {
    symbols: std.ArrayList(Symbol),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ElfSymbolTable {
        return ElfSymbolTable{
            .symbols = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ElfSymbolTable) void {
        self.symbols.deinit(self.allocator);
    }

    pub fn addSymbol(self: *ElfSymbolTable, name: []const u8, addr: u64, size: u64) !void {
        try self.symbols.append(self.allocator, .{
            .name = name,
            .address = addr,
            .size = size,
        });
    }

    fn checkSymbolMatch(sym: Symbol, addr: u64, best: *?SymbolMatch) ?SymbolMatch {
        if (addr < sym.address) return null;
        const offset = addr - sym.address;
        if (sym.size > 0 and offset < sym.size) {
            return SymbolMatch{ .name = sym.name, .offset = offset };
        }
        if (best.* == null or offset < best.*.?.offset) {
            best.* = SymbolMatch{ .name = sym.name, .offset = offset };
        }
        return null;
    }

    pub fn resolve(self: *const ElfSymbolTable, addr: u64) ?SymbolMatch {
        var best_match: ?SymbolMatch = null;
        for (self.symbols.items) |sym| {
            if (checkSymbolMatch(sym, addr, &best_match)) |exact| return exact;
        }
        return best_match;
    }
};

pub const SymbolMatch = struct {
    name: []const u8,
    offset: u64,

    pub fn format(
        self: SymbolMatch,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        if (self.offset == 0) {
            try writer.print("{s}", .{self.name});
        } else {
            try writer.print("{s}+0x{x}", .{ self.name, self.offset });
        }
    }
};

const SectionHeaders = struct {
    symtab: []const u8,
    strtab: []const u8,
};

fn findSymtabHeaders(elf_bytes: []const u8) ?SectionHeaders {
    const e_shoff = std.mem.readInt(u64, elf_bytes[40..48], .little);
    const e_shentsize = std.mem.readInt(u16, elf_bytes[58..60], .little);
    const e_shnum = std.mem.readInt(u16, elf_bytes[60..62], .little);

    var symtab_shdr: ?[]const u8 = null;
    var strtab_shdr: ?[]const u8 = null;

    var i: usize = 0;
    while (i < e_shnum) : (i += 1) {
        const offset = e_shoff + i * e_shentsize;
        if (offset + 64 > elf_bytes.len) break;
        const shdr = elf_bytes[offset .. offset + 64];
        const sh_type = std.mem.readInt(u32, shdr[4..8], .little);

        if (sh_type == 2) { // SHT_SYMTAB
            symtab_shdr = shdr;
            const sh_link = std.mem.readInt(u32, shdr[40..44], .little);
            const str_offset = e_shoff + @as(usize, sh_link) * e_shentsize;
            if (str_offset + 64 <= elf_bytes.len) {
                strtab_shdr = elf_bytes[str_offset .. str_offset + 64];
            }
        }
    }

    if (symtab_shdr == null or strtab_shdr == null) return null;
    return SectionHeaders{ .symtab = symtab_shdr.?, .strtab = strtab_shdr.? };
}

fn parseSymbolEntries(table: *ElfSymbolTable, elf_bytes: []const u8, hdrs: SectionHeaders) !void {
    const sym_offset = std.mem.readInt(u64, hdrs.symtab[24..32], .little);
    const sym_size = std.mem.readInt(u64, hdrs.symtab[32..40], .little);
    const sym_entsize = std.mem.readInt(u64, hdrs.symtab[56..64], .little);

    const str_offset = std.mem.readInt(u64, hdrs.strtab[24..32], .little);
    const str_size = std.mem.readInt(u64, hdrs.strtab[32..40], .little);

    if (str_offset + str_size > elf_bytes.len) return;
    const strtab = elf_bytes[str_offset .. str_offset + str_size];

    var cur: usize = 0;
    const step = if (sym_entsize > 0) sym_entsize else 24;
    while (cur + 24 <= sym_size and sym_offset + cur + 24 <= elf_bytes.len) : (cur += step) {
        const entry = elf_bytes[sym_offset + cur .. sym_offset + cur + 24];
        const st_name = std.mem.readInt(u32, entry[0..4], .little);
        const st_value = std.mem.readInt(u64, entry[8..16], .little);
        const st_size = std.mem.readInt(u64, entry[16..24], .little);

        if (st_name < strtab.len and st_value > 0) {
            const sym_name = std.mem.sliceTo(strtab[st_name..], 0);
            if (sym_name.len > 0) {
                try table.addSymbol(sym_name, st_value, st_size);
            }
        }
    }
}

pub fn parseElfSymbols(allocator: std.mem.Allocator, elf_bytes: []const u8) !ElfSymbolTable {
    var table = ElfSymbolTable.init(allocator);
    if (elf_bytes.len < 64) return error.InvalidElfHeader;
    if (!std.mem.eql(u8, elf_bytes[0..4], "\x7fELF")) return error.InvalidMagic;

    const hdrs = findSymtabHeaders(elf_bytes) orelse return table;
    try parseSymbolEntries(&table, elf_bytes, hdrs);
    return table;
}

fn resolveAndPrintSymbols(table: *const ElfSymbolTable, addresses: []const u64, elf_path: []const u8) void {
    for (addresses) |addr| {
        if (table.resolve(addr)) |match| {
            std.debug.print("0x{x} -> {}\n", .{ addr, match });
        } else {
            std.debug.print("0x{x} -> ??\n", .{addr});
        }
    }

    if (addresses.len == 0) {
        std.debug.print("Loaded {} symbols from {s}\n", .{ table.symbols.items.len, elf_path });
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = init.minimal.args.iterate();
    _ = args.skip(); // skip exe

    var elf_path: []const u8 = "zig-out/bin/micros-init";
    var addresses: std.ArrayList(u64) = .empty;
    defer addresses.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--elf")) {
            if (args.next()) |p| elf_path = p;
        } else if (std.fmt.parseInt(u64, arg, 0)) |val| {
            try addresses.append(allocator, val);
        } else |_| {}
    }

    const file = std.Io.Dir.openFile(std.Io.Dir.cwd(), init.io, elf_path, .{}) catch {
        std.debug.print("micros-sym: could not open ELF '{s}'\n", .{elf_path});
        std.process.exit(1);
    };
    defer file.close(init.io);

    const len = try file.length(init.io);
    const buf = try allocator.alloc(u8, len);
    defer allocator.free(buf);
    _ = try file.readPositionalAll(init.io, buf, 0);

    var table = try parseElfSymbols(allocator, buf);
    defer table.deinit();

    resolveAndPrintSymbols(&table, addresses.items, elf_path);
}

const testing = std.testing;

test "ElfSymbolTable resolution" {
    var table = ElfSymbolTable.init(testing.allocator);
    defer table.deinit();

    try table.addSymbol("kernel_init", 0x1000, 0x50);
    try table.addSymbol("page_fault_handler", 0x2000, 0x100);

    const m1 = table.resolve(0x1010);
    try testing.expect(m1 != null);
    try testing.expectEqualStrings("kernel_init", m1.?.name);
    try testing.expectEqual(@as(u64, 0x10), m1.?.offset);

    const m2 = table.resolve(0x2000);
    try testing.expect(m2 != null);
    try testing.expectEqualStrings("page_fault_handler", m2.?.name);
    try testing.expectEqual(@as(u64, 0), m2.?.offset);
}
