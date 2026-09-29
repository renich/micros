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
    const auth = caller_auth_fn orelse return error.PermissionDenied;
    if (!auth(.storage_device, Rights.WRITE)) return error.PermissionDenied;
}

fn verifyRebuildAuthority(rights: u16) !void {
    const auth = caller_auth_fn orelse return error.PermissionDenied;
    if (!auth(.rebuild_control, rights)) return error.PermissionDenied;
}

fn verifyRebootAuthority() !void {
    const auth = caller_auth_fn orelse return error.PermissionDenied;
    if (!auth(.actor_control, Rights.EXECUTE)) return error.PermissionDenied;
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
    const duped = try vm.gcAllocator().dupe(u8, dev.name[0..len]);
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

fn writeEspBootloader(allocator: std.mem.Allocator, part: *block.PartitionBlockDevice) !void {
    const emitter = pe_emitter.PeEmitter.init(allocator, .{
        .entry_point_rva = pe_emitter.SECTION_ALIGNMENT,
    });
    const mock_code = [_]u8{ 0x48, 0x31, 0xC0, 0xC3 };
    const mock_rodata = "MicrOS Silicon UEFI Kernel";
    const mock_data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const mock_relocs = [_]u32{ 0x1002, 0x2000 };

    const pe_bin = try emitter.synthesizeBootloader(&mock_code, mock_rodata, &mock_data, &mock_relocs);
    defer allocator.free(pe_bin);

    try fat32.writeFile(part.blockDevice(), "/EFI/BOOT/BOOTX64.EFI", pe_bin);
}

fn nativeSysDiskProvision(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    try verifyStorageAuthority();
    if (args.len != 2 or args[0] != .integer or args[1] != .string) return error.InvalidArgs;
    if (!std.mem.eql(u8, args[1].string, "CONFIRM OVERWRITE")) return error.PermissionDenied;
    const idx = castToUsize(args[0].integer) orelse return error.InvalidArgs;
    const dev = getBlockDevice(idx) orelse return error.DeviceNotFound;
    if (dev.is_boot_media) return error.LiveBootMedia;

    const esp_sectors: u64 = 262144;
    try gpt.formatDisk(dev, esp_sectors);

    const tbl = try gpt.readGptTable(dev);
    const esp_idx = tbl.findByType(&gpt.ESP_GUID) orelse return error.PartitionNotFound;
    const esp_entry = tbl.entries[esp_idx];
    var esp_part = try block.PartitionBlockDevice.init(dev, esp_entry.starting_lba, esp_entry.sectorCount(), "esp");

    try fat32.formatEsp(esp_part.blockDevice());
    try writeEspBootloader(vm.allocator, &esp_part);

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
    try verifyRebuildAuthority(Rights.WRITE | Rights.EXECUTE);
    if (args.len != 1 or args[0] != .string) return error.InvalidArgs;
    const bundle_bytes = args[0].string;

    const kernel_bytes = try kernel_synthesizer.synthesizeKernel(vm.gcAllocator(), bundle_bytes);
    return Value{ .string = kernel_bytes };
}

fn nativeSysKernelStageUpdate(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    try verifyRebuildAuthority(Rights.WRITE);
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.InvalidArgs;
    const kernel_data = args[0].string;
    const bundle_data = args[1].string;

    const engine = active_rebuild_engine orelse return error.RebuildEngineNotInitialized;
    const manifest_hash = try engine.stageSystemUpdate(kernel_data, bundle_data, "", 0);

    const hex_slice = try vm.gcAllocator().alloc(u8, 64);
    @import("chunk.zig").formatHexHash(&manifest_hash, hex_slice[0..64]);
    return Value{ .string = hex_slice };
}

fn nativeSysRebuildStatus(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    _ = args;
    try verifyRebuildAuthority(Rights.READ);
    const engine = active_rebuild_engine orelse return error.RebuildEngineNotInitialized;
    const manifest = try engine.getActiveManifest();

    var fields = try vm.gcAllocator().alloc(Value, 4);
    fields[0] = Value{ .integer = @intCast(manifest.generation) };
    fields[1] = Value{ .boolean = manifest.isTrial() };
    fields[2] = Value{ .boolean = manifest.isStable() };

    const k_hash_hex = try vm.gcAllocator().alloc(u8, 64);
    @import("chunk.zig").formatHexHash(&manifest.kernel_hash, k_hash_hex[0..64]);
    fields[3] = Value{ .string = k_hash_hex };

    return Value{ .array = fields };
}

fn nativeSysReboot(vm_ptr: *anyopaque, args: []Value) anyerror!Value {
    _ = vm_ptr;
    _ = args;
    try verifyRebootAuthority();
    asm volatile ("cli");
    io.outb(0x64, 0xFE);
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn registerStorageSyscalls(vm: *VM) !void {
    try vm.globals.put("sys_block_dev_count", Value{ .native = nativeSysBlockDevCount });
    try vm.globals.put("sys_block_dev_name", Value{ .native = nativeSysBlockDevName });
    try vm.globals.put("sys_block_dev_sectors", Value{ .native = nativeSysBlockDevSectors });
    try vm.globals.put("sys_block_dev_is_boot", Value{ .native = nativeSysBlockDevIsBoot });
    try vm.globals.put("sys_disk_provision", Value{ .native = nativeSysDiskProvision });
    try vm.globals.put("sys_cas_confirm_boot", Value{ .native = nativeSysCasConfirmBoot });
    try vm.globals.put("sys_kernel_synthesize", Value{ .native = nativeSysKernelSynthesize });
    try vm.globals.put("sys_kernel_stage_update", Value{ .native = nativeSysKernelStageUpdate });
    try vm.globals.put("sys_rebuild_status", Value{ .native = nativeSysRebuildStatus });
    try vm.globals.put("sys_reboot", Value{ .native = nativeSysReboot });
}

test "storage abi registration and live boot media protection" {
    clearBlockDevices();
    caller_auth_fn = testAllowAuth;
    defer caller_auth_fn = null;

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
    var prov_args = [_]Value{ Value{ .integer = 0 }, Value{ .string = "CONFIRM OVERWRITE" } };
    try std.testing.expectError(error.LiveBootMedia, nativeSysDiskProvision(&dummy, &prov_args));
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

test "storage abi sys_kernel_synthesize generates valid PE image" {
    caller_auth_fn = testAllowAuth;
    defer caller_auth_fn = null;

    const allocator = std.testing.allocator;
    var chunk = @import("../../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);

    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    const bundle_bytes = try bundle_writer.packBundle(allocator, &[_]bundle_writer.EntryInput{
        .{ .tag = "init.mx", .data = "print(1);" },
    });
    defer allocator.free(bundle_bytes);

    var synth_args = [_]Value{Value{ .string = bundle_bytes }};
    const kernel_res = try nativeSysKernelSynthesize(&vm, &synth_args);
    defer allocator.free(kernel_res.string);

    try kernel_synthesizer.validatePeImage(kernel_res.string);
    try std.testing.expect(kernel_res.string.len >= 512);
    try std.testing.expectEqual(@as(usize, 0), kernel_res.string.len % pe_emitter.FILE_ALIGNMENT);
}

fn testAllowAuth(cap_type: CapType, rights: u16) bool {
    _ = cap_type;
    _ = rights;
    return true;
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
    var args = [_]Value{ Value{ .integer = 1 }, Value{ .string = "CONFIRM OVERWRITE" } };
    try std.testing.expectError(error.PermissionDenied, nativeSysDiskProvision(&dummy, &args));
    try std.testing.expectError(error.PermissionDenied, nativeSysReboot(&dummy, &args));

    // When auth callback is null, it must fail closed as well
    caller_auth_fn = null;
    try std.testing.expectError(error.PermissionDenied, nativeSysDiskProvision(&dummy, &args));
    try std.testing.expectError(error.PermissionDenied, nativeSysReboot(&dummy, &args));
}

test "storage abi sys_disk_provision denies invalid confirmation phrase" {
    caller_auth_fn = testAllowAuth;
    defer caller_auth_fn = null;
    var dummy: usize = 0;
    var bad_args = [_]Value{ Value{ .integer = 1 }, Value{ .string = "NO_CONFIRM" } };
    try std.testing.expectError(error.PermissionDenied, nativeSysDiskProvision(&dummy, &bad_args));
}

test "storage abi excised syscalls absent from vm globals" {
    const allocator = std.testing.allocator;
    var chunk = @import("../../macros/chunk.zig").Chunk.init();
    defer chunk.deinit(allocator);
    var vm = try VM.init(allocator, &chunk);
    defer vm.deinit();

    try registerStorageSyscalls(&vm);
    try std.testing.expect(!vm.globals.contains("sys_bundle_pack"));
    try std.testing.expect(!vm.globals.contains("sys_disk_gpt_format"));
    try std.testing.expect(!vm.globals.contains("sys_disk_esp_format"));
    try std.testing.expect(!vm.globals.contains("sys_disk_esp_write"));
    try std.testing.expect(!vm.globals.contains("sys_disk_esp_stage_bootloader"));
    try std.testing.expect(!vm.globals.contains("sys_disk_cas_format"));
    try std.testing.expect(vm.globals.contains("sys_disk_provision"));
}

fn testOnlyStorageAuth(cap_type: CapType, rights: u16) bool {
    _ = rights;
    return cap_type == .storage_device;
}

test "storage abi sys_kernel_synthesize denies callers without rebuild_control" {
    caller_auth_fn = testOnlyStorageAuth;
    defer caller_auth_fn = null;
    var dummy: usize = 0;
    var synth_args = [_]Value{Value{ .string = "test_bundle" }};
    // Caller holding only storage_device (0x0007) is denied because rebuild_control (0x000A) is strictly required (P4-C6)
    try std.testing.expectError(error.PermissionDenied, nativeSysKernelSynthesize(&dummy, &synth_args));
    var stage_args = [_]Value{ Value{ .string = "k" }, Value{ .string = "b" } };
    try std.testing.expectError(error.PermissionDenied, nativeSysKernelStageUpdate(&dummy, &stage_args));
}
