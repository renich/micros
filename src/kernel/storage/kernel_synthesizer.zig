// MicrOS (µOS) Freestanding Kernel Synthesizer & PE32+ Assembler
// Links relocatable substrate objects with the Genesis MCB bundle.
// Emits deterministic, bit-for-bit reproducible PE32+ BOOTX64.EFI images.
// Zero libc, freestanding, explicit allocator.

const std = @import("std");
const pe_emitter = @import("../../boot/pe_emitter.zig");
const bundle = @import("../bundle.zig");

pub const KERNEL_BANNER_STR: []const u8 = "MicrOS Silicon UEFI Kernel (Deterministic Rebuild)";
pub const DEFAULT_ENTRY_RVA: u32 = pe_emitter.SECTION_ALIGNMENT;

pub const DEFAULT_ENTRY_CODE = [_]u8{
    0x48, 0x31, 0xC0, 0xC3, // xor eax, eax; ret
};

pub const DEFAULT_DATA_PAYLOAD = [_]u8{
    0x01, 0x00, 0x00, 0x00, // Version flag
};

pub const DEFAULT_RELOCS = [_]u32{
    0x1002, 0x2000,
};

pub const SynthesizerError = error{
    InvalidBundleMagic,
    BundleEmpty,
    InvalidPeSignature,
    InvalidDosHeader,
    InvalidCoffHeader,
    InvalidOptionalHeader,
    SectionNotFound,
    AllocationFailed,
};

pub fn validateBundle(bundle_data: []const u8) SynthesizerError!void {
    if (bundle_data.len < @sizeOf(bundle.BundleHeader)) {
        return SynthesizerError.BundleEmpty;
    }
    var hdr_buf: [@sizeOf(bundle.BundleHeader)]u8 align(@alignOf(bundle.BundleHeader)) = undefined;
    @memcpy(&hdr_buf, bundle_data[0..@sizeOf(bundle.BundleHeader)]);
    const hdr: *const bundle.BundleHeader = @ptrCast(&hdr_buf);
    if (hdr.magic != bundle.MCB_MAGIC) {
        return SynthesizerError.InvalidBundleMagic;
    }
}

pub fn computeImageHash(pe_data: []const u8, out_hash: *[32]u8) void {
    std.crypto.hash.Blake3.hash(pe_data, out_hash, .{});
}

pub fn synthesizeCustomKernel(
    allocator: std.mem.Allocator,
    code: []const u8,
    rodata: []const u8,
    data: []const u8,
    bundle_data: []const u8,
    relocs: []const u32,
) ![]u8 {
    try validateBundle(bundle_data);

    const emitter = pe_emitter.PeEmitter.init(allocator, .{
        .entry_point_rva = DEFAULT_ENTRY_RVA,
    });

    const reloc_data = try pe_emitter.emitRelocationBlocks(allocator, relocs);
    defer allocator.free(reloc_data);

    const sections = [_]pe_emitter.SectionInput{
        .{ .name = ".text", .data = code, .characteristics = pe_emitter.CHAR_TEXT },
        .{ .name = ".rodata", .data = rodata, .characteristics = pe_emitter.CHAR_RODATA },
        .{ .name = ".data", .data = data, .characteristics = pe_emitter.CHAR_DATA },
        .{ .name = ".mcb", .data = bundle_data, .characteristics = pe_emitter.CHAR_RODATA },
    };

    return try emitter.synthesizeExecutable(&sections, reloc_data);
}

pub fn synthesizeKernel(allocator: std.mem.Allocator, bundle_data: []const u8) ![]u8 {
    return synthesizeCustomKernel(
        allocator,
        &DEFAULT_ENTRY_CODE,
        KERNEL_BANNER_STR,
        &DEFAULT_DATA_PAYLOAD,
        bundle_data,
        &DEFAULT_RELOCS,
    );
}

fn validateDosAndPeHeaders(pe_data: []const u8) SynthesizerError!u32 {
    if (pe_data.len < pe_emitter.DOS_LFANEW_OFFSET + 4) {
        return SynthesizerError.InvalidDosHeader;
    }
    var dos_buf: [@sizeOf(pe_emitter.DosHeader)]u8 align(@alignOf(pe_emitter.DosHeader)) = undefined;
    @memcpy(&dos_buf, pe_data[0..@sizeOf(pe_emitter.DosHeader)]);
    const dos: *const pe_emitter.DosHeader = @ptrCast(&dos_buf);
    if (dos.e_magic != pe_emitter.DOS_MAGIC) {
        return SynthesizerError.InvalidDosHeader;
    }
    const pe_sig = std.mem.readInt(u32, pe_data[pe_emitter.DOS_LFANEW_OFFSET .. pe_emitter.DOS_LFANEW_OFFSET + 4][0..4], .little);
    if (pe_sig != pe_emitter.PE_SIGNATURE) {
        return SynthesizerError.InvalidPeSignature;
    }
    return pe_emitter.DOS_LFANEW_OFFSET + 4;
}

pub fn validatePeImage(pe_data: []const u8) SynthesizerError!void {
    const coff_off = try validateDosAndPeHeaders(pe_data);
    const min_len = coff_off + @sizeOf(pe_emitter.CoffHeader) + @sizeOf(pe_emitter.OptionalHeader64);
    if (pe_data.len < min_len) {
        return SynthesizerError.InvalidCoffHeader;
    }

    var coff_buf: [@sizeOf(pe_emitter.CoffHeader)]u8 align(@alignOf(pe_emitter.CoffHeader)) = undefined;
    @memcpy(&coff_buf, pe_data[coff_off .. coff_off + @sizeOf(pe_emitter.CoffHeader)]);
    const coff: *const pe_emitter.CoffHeader = @ptrCast(&coff_buf);
    if (coff.machine != pe_emitter.MACHINE_AMD64 or coff.time_date_stamp != 0) {
        return SynthesizerError.InvalidCoffHeader;
    }

    const opt_off = coff_off + @sizeOf(pe_emitter.CoffHeader);
    var opt_buf: [@sizeOf(pe_emitter.OptionalHeader64)]u8 align(@alignOf(pe_emitter.OptionalHeader64)) = undefined;
    @memcpy(&opt_buf, pe_data[opt_off .. opt_off + @sizeOf(pe_emitter.OptionalHeader64)]);
    const opt: *const pe_emitter.OptionalHeader64 = @ptrCast(&opt_buf);
    if (opt.magic != pe_emitter.OPTIONAL_HEADER_MAGIC_PE32_PLUS or opt.subsystem != pe_emitter.SUBSYSTEM_EFI_APPLICATION) {
        return SynthesizerError.InvalidOptionalHeader;
    }
}

test "kernel synthesizer creates valid PE32+ image with embedded MCB" {
    const alloc = std.testing.allocator;
    const bundle_writer = @import("bundle_writer.zig");

    const entries = [_]bundle_writer.EntryInput{
        .{ .tag = "init.mx", .data = "print(1);" },
        .{ .tag = "msh.mx", .data = "print(2);" },
    };
    const test_bundle = try bundle_writer.packBundle(alloc, &entries);
    defer alloc.free(test_bundle);

    const pe_image = try synthesizeKernel(alloc, test_bundle);
    defer alloc.free(pe_image);

    // Validate headers and layout
    try validatePeImage(pe_image);

    // Verify 512-byte sector file alignment
    try std.testing.expectEqual(@as(usize, 0), pe_image.len % pe_emitter.FILE_ALIGNMENT);
}

test "kernel synthesizer guarantees bit-for-bit mathematical identity" {
    const alloc = std.testing.allocator;
    const bundle_writer = @import("bundle_writer.zig");

    const entries = [_]bundle_writer.EntryInput{
        .{ .tag = "init.mx", .data = "print(1);" },
        .{ .tag = "msh.mx", .data = "print(2);" },
    };
    const bundle_1 = try bundle_writer.packBundle(alloc, &entries);
    defer alloc.free(bundle_1);
    const bundle_2 = try bundle_writer.packBundle(alloc, &entries);
    defer alloc.free(bundle_2);

    const pe_1 = try synthesizeKernel(alloc, bundle_1);
    defer alloc.free(pe_1);
    const pe_2 = try synthesizeKernel(alloc, bundle_2);
    defer alloc.free(pe_2);

    var hash_1: [32]u8 = undefined;
    var hash_2: [32]u8 = undefined;
    computeImageHash(pe_1, &hash_1);
    computeImageHash(pe_2, &hash_2);

    // Bit-for-bit reproducibility assertion
    try std.testing.expectEqualSlices(u8, pe_1, pe_2);
    try std.testing.expectEqual(hash_1, hash_2);
}

test "kernel synthesizer rejects corrupted bundle" {
    const alloc = std.testing.allocator;
    const too_short = "SHORT";
    try std.testing.expectError(SynthesizerError.BundleEmpty, synthesizeKernel(alloc, too_short));

    const bad_magic = [_]u8{0xFF} ** 64;
    try std.testing.expectError(SynthesizerError.InvalidBundleMagic, synthesizeKernel(alloc, &bad_magic));
}
