// MicrOS (µOS) Storage & Rebuild System ABI Bindings
// Exposes hardware block enumeration, GPT partitioning, FAT32 ESP delivery, and CAS rebuild to Macros.
// Enforces live boot media protection and capability safety.
// Zero libc, freestanding.

const std = @import("std");
const eval = @import("../../macros/eval.zig");
const Value = eval.Value;
const vm_mod = @import("../../macros/vm.zig");
const VM = vm_mod.VM;
const block = @import("../drivers/block.zig");
const gpt = @import("../drivers/gpt.zig");
const fat32 = @import("fat32.zig");
const cas_mod = @import("cas.zig");
const rebuild = @import("rebuild.zig");
const pe_emitter = @import("../../boot/pe_emitter.zig");
const bundle_writer = @import("bundle_writer.zig");
const kernel_synthesizer = @import("kernel_synthesizer.zig");
const io = @import("../arch/x86_64/io.zig");
const cap_mod = @import("../cap/capability.zig");
const CapType = cap_mod.CapType;
const Rights = cap_mod.Rights;

pub const MAX_BLOCK_DEVICES: usize = 8;
var registered_devices: [MAX_BLOCK_DEVICES]?*block.BlockDevice = [_]?*block.BlockDevice{null} ** MAX_BLOCK_DEVICES;
var registered_count: usize = 0;
var active_rebuild_engine: ?*rebuild.RebuildEngine = null;
pub var caller_auth_fn: ?*const fn (cap_type: CapType, rights: u16) bool = null;

fn verifyStorageAuthority() !void {
    if (caller_auth_fn) |auth| {
        if (!auth(.storage_device, Rights.WRITE)) return error.PermissionDenied;
    }
}

fn verifyRebootAuthority() !void {
    if (caller_auth_fn) |auth| {
        if (!auth(.actor_control, Rights.EXECUTE)) return error.PermissionDenied;
    }
}

pub fn registerBlockDevice(dev: *block.BlockDevice) void {
    if (registered_count < MAX_BLOCK_DEVICES) {
        registered_devices[registered_count] = dev;
        registered_count += 1;
    }
}

pub fn clearBlockDevices() void {
    registered_devices = [_]?*block.BlockDevice{null} ** MAX_BLOCK_DEVICES;
    registered_count = 0;
}

pub fn getBlockDevice(idx: usize) ?*block.BlockDevice {
    if (idx >= registered_count) return null;
    return registered_devices[idx];
}

pub fn getDeviceCount() usize {
    return registered_count;
}

pub fn setRebuildEngine(engine: *rebuild.RebuildEngine) void {
    active_rebuild_engine = engine;
}

fn castToUsize(val: i64) ?usize {
    if (val < 0 or val > std.math.maxInt(usize)) return null;
    return @intCast(val);
}

fn castToU64(val: i64) ?u64 {
    if (val < 0 or val > std.math.maxInt(u64)) return null;
    return @intCast(val);
}

fn nativeSysBlockDevCount(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    return Value{ .integer = @intCast(registered_count) };
}

fn nativeSysBlockDevName(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const idx = castToUsize(args[0].integer) orelse return error.InvalidArgs;
    const dev = getBlockDevice(idx) orelse return error.DeviceNotFound;
    const len = std.mem.indexOfScalar(u8, &dev.name, 0) orelse dev.name.len;
    const duped = try vm.allocator.dupe(u8, dev.name[0..len]);
    return Value{ .string = duped };
}

fn nativeSysBlockDevSectors(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const idx = castToUsize(args[0].integer) orelse return error.InvalidArgs;
    const dev = getBlockDevice(idx) orelse return error.DeviceNotFound;
    return Value{ .integer = @intCast(dev.total_sectors) };
}

fn nativeSysBlockDevIsBoot(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const idx = castToUsize(args[0].integer) orelse return error.InvalidArgs;
    const dev = getBlockDevice(idx) orelse return error.DeviceNotFound;
    return Value{ .boolean = dev.is_boot_media };
}

fn nativeSysDiskGptFormat(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    try verifyStorageAuthority();
    if (args.len != 2 or args[0] != .integer or args[1] != .integer) return error.InvalidArgs;
    const idx = castToUsize(args[0].integer) orelse return error.InvalidArgs;
    const esp_sectors = castToU64(args[1].integer) orelse return error.InvalidArgs;
    const dev = getBlockDevice(idx) orelse return error.DeviceNotFound;
    if (dev.is_boot_media) return error.LiveBootMedia;

    try gpt.formatDisk(dev, esp_sectors);
    return Value{ .boolean = true };
}

fn nativeSysDiskEspFormat(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    try verifyStorageAuthority();
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const idx = castToUsize(args[0].integer) orelse return error.InvalidArgs;
    const dev = getBlockDevice(idx) orelse return error.DeviceNotFound;
    if (dev.is_boot_media) return error.LiveBootMedia;

    const tbl = try gpt.readGptTable(dev);
    const esp_idx = tbl.findByType(&gpt.ESP_GUID) orelse return error.PartitionNotFound;
    const esp_entry = tbl.entries[esp_idx];
    const sector_count = esp_entry.sectorCount();
    var esp_part = try block.PartitionBlockDevice.init(dev, esp_entry.starting_lba, sector_count, "esp");

    try fat32.formatEsp(esp_part.blockDevice());
    return Value{ .boolean = true };
}

fn nativeSysDiskEspWrite(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    if (args.len != 3 or args[0] != .integer or args[1] != .string or args[2] != .string) return error.InvalidArgs;
    const idx = castToUsize(args[0].integer) orelse return error.InvalidArgs;
    const dev = getBlockDevice(idx) orelse return error.DeviceNotFound;
    if (dev.is_boot_media) return error.LiveBootMedia;

    const tbl = try gpt.readGptTable(dev);
    const esp_idx = tbl.findByType(&gpt.ESP_GUID) orelse return error.PartitionNotFound;
    const esp_entry = tbl.entries[esp_idx];
    const sector_count = esp_entry.sectorCount();
    var esp_part = try block.PartitionBlockDevice.init(dev, esp_entry.starting_lba, sector_count, "esp");

    try fat32.writeFile(esp_part.blockDevice(), args[1].string, args[2].string);
    return Value{ .boolean = true };
}

fn nativeSysDiskEspStageBootloader(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const idx = castToUsize(args[0].integer) orelse return error.InvalidArgs;
    const dev = getBlockDevice(idx) orelse return error.DeviceNotFound;
    if (dev.is_boot_media) return error.LiveBootMedia;

    const tbl = try gpt.readGptTable(dev);
    const esp_idx = tbl.findByType(&gpt.ESP_GUID) orelse return error.PartitionNotFound;
    const esp_entry = tbl.entries[esp_idx];
    var esp_part = try block.PartitionBlockDevice.init(dev, esp_entry.starting_lba, esp_entry.sectorCount(), "esp");

    const emitter = pe_emitter.PeEmitter.init(vm.allocator, .{
        .entry_point_rva = pe_emitter.SECTION_ALIGNMENT,
    });
    const mock_code = [_]u8{ 0x48, 0x31, 0xC0, 0xC3 };
    const mock_rodata = "MicrOS Silicon UEFI Kernel";
    const mock_data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const mock_relocs = [_]u32{ 0x1002, 0x2000 };

    const pe_bin = try emitter.synthesizeBootloader(&mock_code, mock_rodata, &mock_data, &mock_relocs);
    defer vm.allocator.free(pe_bin);

    try fat32.writeFile(esp_part.blockDevice(), "/EFI/BOOT/BOOTX64.EFI", pe_bin);
    return Value{ .boolean = true };
}

fn nativeSysDiskCasFormat(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    try verifyStorageAuthority();
    if (args.len != 1 or args[0] != .integer) return error.InvalidArgs;
    const idx = castToUsize(args[0].integer) orelse return error.InvalidArgs;
    const dev = getBlockDevice(idx) orelse return error.DeviceNotFound;
    if (dev.is_boot_media) return error.LiveBootMedia;

    const tbl = try gpt.readGptTable(dev);
    const cas_idx = tbl.findByType(&gpt.CAS_GUID) orelse return error.PartitionNotFound;
    const cas_entry = tbl.entries[cas_idx];
    const sector_count = cas_entry.sectorCount();
    var cas_part = try block.PartitionBlockDevice.init(dev, cas_entry.starting_lba, sector_count, "cas");

    var cache = try @import("block_cache.zig").BlockCache.init(vm.allocator);
    defer cache.deinit();

    _ = try cas_mod.CasEngine.init(&cache, cas_part.blockDevice(), sector_count);
    return Value{ .boolean = true };
}

fn nativeSysCasConfirmBoot(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    if (active_rebuild_engine) |engine| {
        const promoted = engine.confirmBoot() catch return Value{ .boolean = false };
        return Value{ .boolean = promoted };
    }
    return Value{ .boolean = false };
}

fn nativeSysKernelSynthesize(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const bundle_bytes = args[0].string;

    const kernel_bytes = try kernel_synthesizer.synthesizeKernel(vm.allocator, bundle_bytes);
    return Value{ .string = kernel_bytes };
}

fn nativeSysKernelStageUpdate(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.InvalidArgs;
    const kernel_data = args[0].string;
    const bundle_data = args[1].string;

    const engine = active_rebuild_engine orelse return error.RebuildEngineNotInitialized;
    const manifest_hash = try engine.stageSystemUpdate(kernel_data, bundle_data, "", 0);

    const hex_slice = try vm.allocator.alloc(u8, 64);
    @import("chunk.zig").formatHexHash(&manifest_hash, hex_slice[0..64]);
    return Value{ .string = hex_slice };
}

fn nativeSysRebuildStatus(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    const engine = active_rebuild_engine orelse return error.RebuildEngineNotInitialized;
    const manifest = try engine.getActiveManifest();

    var fields = try vm.allocator.alloc(Value, 4);
    fields[0] = Value{ .integer = @intCast(manifest.generation) };
    fields[1] = Value{ .boolean = manifest.isTrial() };
    fields[2] = Value{ .boolean = manifest.isStable() };

    const k_hash_hex = try vm.allocator.alloc(u8, 64);
    @import("chunk.zig").formatHexHash(&manifest.kernel_hash, k_hash_hex[0..64]);
    fields[3] = Value{ .string = k_hash_hex };

    return Value{ .array = fields };
}

fn nativeSysReboot(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    try verifyRebootAuthority();
    io.outb(0x64, 0xFE);
    while (true) {
        asm volatile ("hlt");
    }
}

fn nativeSysBundlePack(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    if (args.len != 1 or args[0] != .array) return error.InvalidArgs;
    const raw_arr = args[0].array;

    var entries = try vm.allocator.alloc(bundle_writer.EntryInput, raw_arr.len);
    defer vm.allocator.free(entries);

    for (raw_arr, 0..) |item, i| {
        if (item != .array or item.array.len != 2) return error.InvalidEntryFormat;
        if (item.array[0] != .string or item.array[1] != .string) return error.InvalidEntryType;
        entries[i] = .{
            .tag = item.array[0].string,
            .data = item.array[1].string,
        };
    }

    const bundle_bytes = try bundle_writer.packBundle(vm.allocator, entries);
    return Value{ .string = bundle_bytes };
}

pub fn registerStorageSyscalls(vm: *VM) !void {
    try vm.globals.put("sys_block_dev_count", Value{ .native = nativeSysBlockDevCount });
    try vm.globals.put("sys_block_dev_name", Value{ .native = nativeSysBlockDevName });
    try vm.globals.put("sys_block_dev_sectors", Value{ .native = nativeSysBlockDevSectors });
    try vm.globals.put("sys_block_dev_is_boot", Value{ .native = nativeSysBlockDevIsBoot });
    try vm.globals.put("sys_disk_gpt_format", Value{ .native = nativeSysDiskGptFormat });
    try vm.globals.put("sys_disk_esp_format", Value{ .native = nativeSysDiskEspFormat });
    try vm.globals.put("sys_disk_esp_write", Value{ .native = nativeSysDiskEspWrite });
    try vm.globals.put("sys_disk_esp_stage_bootloader", Value{ .native = nativeSysDiskEspStageBootloader });
    try vm.globals.put("sys_disk_cas_format", Value{ .native = nativeSysDiskCasFormat });
    try vm.globals.put("sys_cas_confirm_boot", Value{ .native = nativeSysCasConfirmBoot });
    try vm.globals.put("sys_kernel_synthesize", Value{ .native = nativeSysKernelSynthesize });
    try vm.globals.put("sys_kernel_stage_update", Value{ .native = nativeSysKernelStageUpdate });
    try vm.globals.put("sys_rebuild_status", Value{ .native = nativeSysRebuildStatus });
    try vm.globals.put("sys_bundle_pack", Value{ .native = nativeSysBundlePack });
    try vm.globals.put("sys_reboot", Value{ .native = nativeSysReboot });
}

test "storage abi registration and live boot media protection" {
    clearBlockDevices();

    const mock_vtable = block.BlockDevice.VTable{
        .readSector = testMockRead,
        .writeSector = testMockWrite,
        .readSectors = testMockReads,
        .writeSectors = testMockWrites,
        .flush = testMockFlush,
    };

    var boot_dev = block.BlockDevice{
        .ptr = undefined,
        .vtable = &mock_vtable,
        .total_sectors = 100000,
        .is_boot_media = true,
    };
    @memcpy(boot_dev.name[0..4], "usb0");

    var target_dev = block.BlockDevice{
        .ptr = undefined,
        .vtable = &mock_vtable,
        .total_sectors = 2000000,
        .is_boot_media = false,
    };
    @memcpy(target_dev.name[0..5], "nvme0");

    registerBlockDevice(&boot_dev);
    registerBlockDevice(&target_dev);

    try std.testing.expectEqual(@as(usize, 2), getDeviceCount());
    try std.testing.expect(getBlockDevice(0).?.is_boot_media);
    try std.testing.expect(!getBlockDevice(1).?.is_boot_media);

    var dummy: usize = 0;
    var args = [_]Value{ Value{ .integer = 0 }, Value{ .integer = 614400 } };
    try std.testing.expectError(error.LiveBootMedia, nativeSysDiskGptFormat(&dummy, &args));

    var stage_args = [_]Value{Value{ .integer = 0 }};
    try std.testing.expectError(error.LiveBootMedia, nativeSysDiskEspStageBootloader(&dummy, &stage_args));
}

fn testMockRead(ctx: *anyopaque, lba: u64, buf: *[block.SECTOR_SIZE]u8) anyerror!void {
    _ = ctx;
    _ = lba;
    @memset(buf, 0);
}

fn testMockWrite(ctx: *anyopaque, lba: u64, buf: *const [block.SECTOR_SIZE]u8) anyerror!void {
    _ = ctx;
    _ = lba;
    _ = buf;
}

fn testMockReads(ctx: *anyopaque, lba: u64, count: usize, buf: []u8) anyerror!void {
    _ = ctx;
    _ = lba;
    _ = count;
    @memset(buf, 0);
}

fn testMockWrites(ctx: *anyopaque, lba: u64, count: usize, buf: []const u8) anyerror!void {
    _ = ctx;
    _ = lba;
    _ = count;
    _ = buf;
}

fn testMockFlush(ctx: *anyopaque) anyerror!void {
    _ = ctx;
}

test "storage abi sys_bundle_pack packs and roundtrips entries" {
    const allocator = std.testing.allocator;
    var chunk = @import("../../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    var item0 = [_]Value{ Value{ .string = "alpha.mx" }, Value{ .string = "content 1" } };
    var item1 = [_]Value{ Value{ .string = "beta.mx" }, Value{ .string = "content 2" } };
    var items = [_]Value{ Value{ .array = &item0 }, Value{ .array = &item1 } };
    var args = [_]Value{Value{ .array = &items }};

    const res = try nativeSysBundlePack(&vm, &args);
    defer allocator.free(res.string);

    const bundle_mod = @import("../bundle.zig");
    const reader = try bundle_mod.BundleReader.init(res.string);
    try std.testing.expectEqual(@as(u32, 2), reader.header.entry_count);
    try std.testing.expectEqualStrings("content 1", reader.findData("alpha.mx").?);
    try std.testing.expectEqualStrings("content 2", reader.findData("beta.mx").?);
}

test "storage abi sys_kernel_synthesize generates valid PE image" {
    const allocator = std.testing.allocator;
    var chunk = @import("../../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    var item0 = [_]Value{ Value{ .string = "init.mx" }, Value{ .string = "print(1);" } };
    var items = [_]Value{Value{ .array = &item0 }};
    var pack_args = [_]Value{Value{ .array = &items }};

    const bundle_res = try nativeSysBundlePack(&vm, &pack_args);
    defer allocator.free(bundle_res.string);

    var synth_args = [_]Value{bundle_res};
    const kernel_res = try nativeSysKernelSynthesize(&vm, &synth_args);
    defer allocator.free(kernel_res.string);

    try kernel_synthesizer.validatePeImage(kernel_res.string);
    try std.testing.expect(kernel_res.string.len >= 512);
    try std.testing.expectEqual(@as(usize, 0), kernel_res.string.len % pe_emitter.FILE_ALIGNMENT);
}

fn testRejectAuth(cap_type: CapType, rights: u16) bool {
    _ = cap_type;
    _ = rights;
    return false;
}

test "storage abi rejects unprivileged callers" {
    caller_auth_fn = testRejectAuth;
    defer {
        caller_auth_fn = null;
    }

    var dummy: usize = 0;
    var args = [_]Value{ Value{ .integer = 1 }, Value{ .integer = 614400 } };
    try std.testing.expectError(error.PermissionDenied, nativeSysDiskGptFormat(&dummy, &args));
    try std.testing.expectError(error.PermissionDenied, nativeSysReboot(&dummy, &args));
}
