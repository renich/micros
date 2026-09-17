// MicrOS (µOS) GUID Partition Table (GPT) Substrate
// Implements Protective MBR, Primary/Backup GPT Headers, and Partition Entry Array.
// Zero libc, freestanding, 512-byte sector and 4096-byte page alignment.

const std = @import("std");
const block = @import("block.zig");

pub const GPT_HEADER_SIGNATURE: u64 = 0x5452415020494645; // "EFI PART"
pub const GPT_HEADER_REVISION: u32 = 0x00010000; // 1.0
pub const GPT_HEADER_SIZE: u32 = 92;
pub const GPT_NUM_PARTITIONS: u32 = 128;
pub const GPT_ENTRY_SIZE: u32 = 128;
pub const GPT_ARRAY_SECTORS: u64 = (GPT_NUM_PARTITIONS * GPT_ENTRY_SIZE) / block.SECTOR_SIZE; // 32 sectors
pub const DEFAULT_ALIGNMENT_SECTORS: u64 = 2048; // 1 MiB alignment (2048 sectors)

// Standard EFI System Partition GUID: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
pub const ESP_GUID: [16]u8 = [_]u8{
    0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11,
    0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b,
};

// MicrOS Content-Addressed Storage GUID: 4D494352-4F53-4341-5300-000000000001
pub const CAS_GUID: [16]u8 = [_]u8{
    0x52, 0x49, 0x43, 0x4d, 0x53, 0x4f, 0x41, 0x43,
    0x53, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
};

pub const MbrPartitionEntry = extern struct {
    boot_indicator: u8 = 0,
    starting_chs: [3]u8 = [_]u8{ 0x00, 0x02, 0x00 },
    os_type: u8 = 0xEE,
    ending_chs: [3]u8 = [_]u8{ 0xFF, 0xFF, 0xFF },
    starting_lba: [4]u8 = [_]u8{ 0x01, 0x00, 0x00, 0x00 },
    size_in_lba: [4]u8 = [_]u8{0} ** 4,

    pub fn setStartingLba(self: *MbrPartitionEntry, lba: u32) void {
        std.mem.writeInt(u32, &self.starting_lba, lba, .little);
    }

    pub fn setSizeInLba(self: *MbrPartitionEntry, size: u32) void {
        std.mem.writeInt(u32, &self.size_in_lba, size, .little);
    }

    pub fn getStartingLba(self: *const MbrPartitionEntry) u32 {
        return std.mem.readInt(u32, &self.starting_lba, .little);
    }

    pub fn getSizeInLba(self: *const MbrPartitionEntry) u32 {
        return std.mem.readInt(u32, &self.size_in_lba, .little);
    }
};

pub const ProtectiveMbr = extern struct {
    boot_code: [446]u8 = [_]u8{0} ** 446,
    partition_records: [4]MbrPartitionEntry = [_]MbrPartitionEntry{
        MbrPartitionEntry{},
        MbrPartitionEntry{ .boot_indicator = 0, .starting_chs = [_]u8{0} ** 3, .os_type = 0, .ending_chs = [_]u8{0} ** 3, .starting_lba = [_]u8{0} ** 4, .size_in_lba = [_]u8{0} ** 4 },
        MbrPartitionEntry{ .boot_indicator = 0, .starting_chs = [_]u8{0} ** 3, .os_type = 0, .ending_chs = [_]u8{0} ** 3, .starting_lba = [_]u8{0} ** 4, .size_in_lba = [_]u8{0} ** 4 },
        MbrPartitionEntry{ .boot_indicator = 0, .starting_chs = [_]u8{0} ** 3, .os_type = 0, .ending_chs = [_]u8{0} ** 3, .starting_lba = [_]u8{0} ** 4, .size_in_lba = [_]u8{0} ** 4 },
    },
    boot_signature: [2]u8 = [_]u8{ 0x55, 0xAA },
};

pub const GptHeader = extern struct {
    signature: u64,
    revision: u32,
    header_size: u32,
    header_crc32: u32,
    reserved: u32 = 0,
    my_lba: u64,
    alternate_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    disk_guid: [16]u8,
    partition_entry_lba: u64,
    num_partition_entries: u32,
    size_of_partition_entry: u32,
    partition_entry_array_crc32: u32,
    reserved_padding: [420]u8 = [_]u8{0} ** 420,
};

pub const GptPartitionEntry = extern struct {
    type_guid: [16]u8,
    unique_partition_guid: [16]u8,
    starting_lba: u64,
    ending_lba: u64,
    attributes: u64 = 0,
    name: [72]u8 = [_]u8{0} ** 72,

    pub fn isUsed(self: *const GptPartitionEntry) bool {
        const zero_guid = [_]u8{0} ** 16;
        return !std.mem.eql(u8, &self.type_guid, &zero_guid);
    }

    pub fn sectorCount(self: *const GptPartitionEntry) u64 {
        if (self.ending_lba < self.starting_lba) return 0;
        return self.ending_lba - self.starting_lba + 1;
    }
};

pub const GptTable = struct {
    header: GptHeader,
    entries: [GPT_NUM_PARTITIONS]GptPartitionEntry,

    pub fn findByType(self: *const GptTable, target_guid: *const [16]u8) ?usize {
        for (0..GPT_NUM_PARTITIONS) |i| {
            if (self.entries[i].isUsed() and std.mem.eql(u8, &self.entries[i].type_guid, target_guid)) {
                return i;
            }
        }
        return null;
    }
};

pub fn computeCrc32(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

pub fn computeHeaderCrc32(hdr: *const GptHeader) u32 {
    var copy = hdr.*;
    copy.header_crc32 = 0;
    const raw: [*]const u8 = @ptrCast(&copy);
    return computeCrc32(raw[0..GPT_HEADER_SIZE]);
}

pub fn computeArrayCrc32(entries: *const [GPT_NUM_PARTITIONS]GptPartitionEntry) u32 {
    const raw: [*]const u8 = @ptrCast(entries);
    return computeCrc32(raw[0 .. GPT_NUM_PARTITIONS * GPT_ENTRY_SIZE]);
}

pub fn readGptTable(dev: *block.BlockDevice) !GptTable {
    if (dev.total_sectors < 68) return error.DiskTooSmall;

    var sec_buf: [block.SECTOR_SIZE]u8 align(@alignOf(GptHeader)) = undefined;
    try dev.readSector(1, &sec_buf);

    const hdr_ptr: *const GptHeader = @ptrCast(@alignCast(&sec_buf));
    if (hdr_ptr.signature != GPT_HEADER_SIGNATURE) return error.InvalidGptSignature;
    if (hdr_ptr.header_size < GPT_HEADER_SIZE) return error.InvalidHeaderSize;

    const expected_crc = computeHeaderCrc32(hdr_ptr);
    if (hdr_ptr.header_crc32 != expected_crc) return error.CorruptedGptHeader;

    var table = GptTable{
        .header = hdr_ptr.*,
        .entries = undefined,
    };

    const array_bytes: [*]u8 = @ptrCast(&table.entries);
    try dev.readSectors(hdr_ptr.partition_entry_lba, GPT_ARRAY_SECTORS, array_bytes[0 .. GPT_NUM_PARTITIONS * GPT_ENTRY_SIZE]);

    const expected_array_crc = computeArrayCrc32(&table.entries);
    if (table.header.partition_entry_array_crc32 != expected_array_crc) {
        return error.CorruptedPartitionArray;
    }

    return table;
}

fn writeProtectiveMbr(dev: *block.BlockDevice) !void {
    var mbr = ProtectiveMbr{};
    mbr.partition_records[0].setSizeInLba(@intCast(@min(dev.total_sectors - 1, std.math.maxInt(u32))));
    const mbr_bytes: *const [block.SECTOR_SIZE]u8 = @ptrCast(@alignCast(&mbr));
    try dev.writeSector(0, mbr_bytes);
}

fn initPartitionEntries(dev: *block.BlockDevice, esp_sectors: u64, entries: *[GPT_NUM_PARTITIONS]GptPartitionEntry) void {
    @memset(entries, std.mem.zeroes(GptPartitionEntry));
    const esp_start = DEFAULT_ALIGNMENT_SECTORS;
    const esp_end = esp_start + esp_sectors - 1;
    entries[0] = GptPartitionEntry{
        .type_guid = ESP_GUID,
        .unique_partition_guid = generateGuid(1),
        .starting_lba = esp_start,
        .ending_lba = esp_end,
    };
    encodeUtf16Name("EFI System Partition", &entries[0].name);

    entries[1] = GptPartitionEntry{
        .type_guid = CAS_GUID,
        .unique_partition_guid = generateGuid(2),
        .starting_lba = esp_end + 1,
        .ending_lba = dev.total_sectors - 34,
    };
    encodeUtf16Name("MicrOS CAS", &entries[1].name);
}

fn writeGptHeaders(dev: *block.BlockDevice, array_crc: u32, backup_lba: u64) !void {
    var primary_hdr = GptHeader{
        .signature = GPT_HEADER_SIGNATURE,
        .revision = GPT_HEADER_REVISION,
        .header_size = GPT_HEADER_SIZE,
        .header_crc32 = 0,
        .my_lba = 1,
        .alternate_lba = dev.total_sectors - 1,
        .first_usable_lba = 34,
        .last_usable_lba = dev.total_sectors - 34,
        .disk_guid = generateGuid(0xAA),
        .partition_entry_lba = 2,
        .num_partition_entries = GPT_NUM_PARTITIONS,
        .size_of_partition_entry = GPT_ENTRY_SIZE,
        .partition_entry_array_crc32 = array_crc,
    };
    primary_hdr.header_crc32 = computeHeaderCrc32(&primary_hdr);
    const primary_bytes: *const [block.SECTOR_SIZE]u8 = @ptrCast(@alignCast(&primary_hdr));
    try dev.writeSector(1, primary_bytes);

    var backup_hdr = primary_hdr;
    backup_hdr.my_lba = dev.total_sectors - 1;
    backup_hdr.alternate_lba = 1;
    backup_hdr.partition_entry_lba = backup_lba;
    backup_hdr.header_crc32 = computeHeaderCrc32(&backup_hdr);
    const backup_bytes: *const [block.SECTOR_SIZE]u8 = @ptrCast(@alignCast(&backup_hdr));
    try dev.writeSector(dev.total_sectors - 1, backup_bytes);
}

pub fn formatDisk(dev: *block.BlockDevice, esp_sectors: u64) !void {
    if (dev.total_sectors < DEFAULT_ALIGNMENT_SECTORS + esp_sectors + 68) {
        return error.DiskTooSmall;
    }

    try writeProtectiveMbr(dev);

    var entries: [GPT_NUM_PARTITIONS]GptPartitionEntry = undefined;
    initPartitionEntries(dev, esp_sectors, &entries);

    const array_crc = computeArrayCrc32(&entries);
    const array_bytes: [*]const u8 = @ptrCast(&entries);

    try dev.writeSectors(2, GPT_ARRAY_SECTORS, array_bytes[0 .. GPT_NUM_PARTITIONS * GPT_ENTRY_SIZE]);
    const backup_array_lba = dev.total_sectors - 33;
    try dev.writeSectors(backup_array_lba, GPT_ARRAY_SECTORS, array_bytes[0 .. GPT_NUM_PARTITIONS * GPT_ENTRY_SIZE]);

    try writeGptHeaders(dev, array_crc, backup_array_lba);
    try dev.flush();
}

fn generateGuid(seed: u8) [16]u8 {
    var guid: [16]u8 = [_]u8{seed} ** 16;
    guid[6] = (guid[6] & 0x0F) | 0x40; // Version 4
    guid[8] = (guid[8] & 0x3F) | 0x80; // Variant 1
    return guid;
}

fn encodeUtf16Name(ascii_str: []const u8, out_name: *[72]u8) void {
    @memset(out_name, 0);
    const max_chars = @min(ascii_str.len, 36);
    for (0..max_chars) |i| {
        out_name[i * 2] = ascii_str[i];
        out_name[i * 2 + 1] = 0;
    }
}

test "gpt structure sizes and alignments" {
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(ProtectiveMbr));
    try std.testing.expectEqual(@as(usize, 512), @sizeOf(GptHeader));
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(GptPartitionEntry));
}

test "gpt formatting and parsing roundtrip" {
    const MockDisk = struct {
        sectors: [10000][block.SECTOR_SIZE]u8 = [_][block.SECTOR_SIZE]u8{[_]u8{0} ** block.SECTOR_SIZE} ** 10000,
        device: block.BlockDevice = undefined,

        pub fn init(self: *@This()) *block.BlockDevice {
            self.device = block.BlockDevice{
                .ptr = @ptrCast(self),
                .vtable = &vtable,
                .total_sectors = 10000,
            };
            return &self.device;
        }

        const vtable = block.BlockDevice.VTable{
            .readSector = mockRead,
            .writeSector = mockWrite,
            .readSectors = mockReads,
            .writeSectors = mockWrites,
            .flush = mockFlush,
        };

        fn mockRead(ctx: *anyopaque, lba: u64, buf: *[block.SECTOR_SIZE]u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(buf, &self.sectors[lba]);
        }

        fn mockWrite(ctx: *anyopaque, lba: u64, buf: *const [block.SECTOR_SIZE]u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(&self.sectors[lba], buf);
        }

        fn mockReads(ctx: *anyopaque, lba: u64, count: usize, buf: []u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (0..count) |i| {
                @memcpy(buf[i * block.SECTOR_SIZE .. (i + 1) * block.SECTOR_SIZE], &self.sectors[lba + i]);
            }
        }

        fn mockWrites(ctx: *anyopaque, lba: u64, count: usize, buf: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (0..count) |i| {
                @memcpy(&self.sectors[lba + i], buf[i * block.SECTOR_SIZE .. (i + 1) * block.SECTOR_SIZE]);
            }
        }

        fn mockFlush(_: *anyopaque) anyerror!void {}
    };

    var raw_disk = MockDisk{};
    const disk_dev = raw_disk.init();

    // Format with 1000 sectors for ESP
    try formatDisk(disk_dev, 1000);

    // Verify Protective MBR at LBA 0
    const mbr_ptr: *const ProtectiveMbr = @ptrCast(@alignCast(&raw_disk.sectors[0]));
    try std.testing.expectEqual(@as(u8, 0xEE), mbr_ptr.partition_records[0].os_type);
    try std.testing.expectEqual(@as(u16, 0xAA55), std.mem.readInt(u16, &mbr_ptr.boot_signature, .little));

    // Read and verify GPT Table
    const table = try readGptTable(disk_dev);
    try std.testing.expectEqual(GPT_HEADER_SIGNATURE, table.header.signature);
    try std.testing.expectEqual(@as(u64, 1), table.header.my_lba);
    try std.testing.expectEqual(@as(u64, 9999), table.header.alternate_lba);

    // Verify Partitions
    const esp_idx = table.findByType(&ESP_GUID);
    try std.testing.expect(esp_idx != null);
    try std.testing.expectEqual(@as(u64, 2048), table.entries[esp_idx.?].starting_lba);
    try std.testing.expectEqual(@as(u64, 3047), table.entries[esp_idx.?].ending_lba);
    try std.testing.expectEqual(@as(u64, 1000), table.entries[esp_idx.?].sectorCount());

    const cas_idx = table.findByType(&CAS_GUID);
    try std.testing.expect(cas_idx != null);
    try std.testing.expectEqual(@as(u64, 3048), table.entries[cas_idx.?].starting_lba);
    try std.testing.expectEqual(@as(u64, 9966), table.entries[cas_idx.?].ending_lba);
}
