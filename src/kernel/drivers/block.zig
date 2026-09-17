// MicrOS (µOS) Polymorphic Block Device Substrate
// Defines universal BlockDevice abstraction and PartitionBlockDevice slicing.
// Zero libc, explicit allocators, 512-byte sector and 4096-byte page alignment.

const std = @import("std");

pub const SECTOR_SIZE: usize = 512;
pub const PAGE_SIZE: usize = 4096;

pub const BlockDevice = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    total_sectors: u64,
    sector_size: u32 = SECTOR_SIZE,
    name: [32]u8 = [_]u8{0} ** 32,

    pub const VTable = struct {
        readSector: *const fn (ctx: *anyopaque, lba: u64, buf: *[SECTOR_SIZE]u8) anyerror!void,
        writeSector: *const fn (ctx: *anyopaque, lba: u64, buf: *const [SECTOR_SIZE]u8) anyerror!void,
        readSectors: *const fn (ctx: *anyopaque, lba: u64, count: usize, buf: []u8) anyerror!void,
        writeSectors: *const fn (ctx: *anyopaque, lba: u64, count: usize, buf: []const u8) anyerror!void,
        flush: *const fn (ctx: *anyopaque) anyerror!void,
    };

    pub inline fn readSector(self: *BlockDevice, lba: u64, buf: *[SECTOR_SIZE]u8) !void {
        if (lba >= self.total_sectors) return error.SectorOutOfBounds;
        return self.vtable.readSector(self.ptr, lba, buf);
    }

    pub inline fn writeSector(self: *BlockDevice, lba: u64, buf: *const [SECTOR_SIZE]u8) !void {
        if (lba >= self.total_sectors) return error.SectorOutOfBounds;
        return self.vtable.writeSector(self.ptr, lba, buf);
    }

    pub inline fn readSectors(self: *BlockDevice, lba: u64, count: usize, buf: []u8) !void {
        if (count == 0) return error.InvalidSectorCount;
        if (lba + count > self.total_sectors) return error.SectorOutOfBounds;
        if (buf.len < count * self.sector_size) return error.BufferTooSmall;
        return self.vtable.readSectors(self.ptr, lba, count, buf);
    }

    pub inline fn writeSectors(self: *BlockDevice, lba: u64, count: usize, buf: []const u8) !void {
        if (count == 0) return error.InvalidSectorCount;
        if (lba + count > self.total_sectors) return error.SectorOutOfBounds;
        if (buf.len < count * self.sector_size) return error.BufferTooSmall;
        return self.vtable.writeSectors(self.ptr, lba, count, buf);
    }

    pub inline fn flush(self: *BlockDevice) !void {
        return self.vtable.flush(self.ptr);
    }
};

pub const PartitionBlockDevice = struct {
    parent: *BlockDevice,
    start_lba: u64,
    sector_count: u64,
    device: BlockDevice,

    pub fn init(parent: *BlockDevice, start_lba: u64, sector_count: u64, name: []const u8) !PartitionBlockDevice {
        if (start_lba + sector_count > parent.total_sectors) return error.PartitionOutOfBounds;
        var part = PartitionBlockDevice{
            .parent = parent,
            .start_lba = start_lba,
            .sector_count = sector_count,
            .device = BlockDevice{
                .ptr = undefined,
                .vtable = &partition_vtable,
                .total_sectors = sector_count,
                .sector_size = parent.sector_size,
            },
        };
        const copy_len = @min(name.len, part.device.name.len);
        @memcpy(part.device.name[0..copy_len], name[0..copy_len]);
        part.device.ptr = @ptrCast(&part);
        return part;
    }

    pub fn blockDevice(self: *PartitionBlockDevice) *BlockDevice {
        self.device.ptr = @ptrCast(self);
        return &self.device;
    }

    const partition_vtable = BlockDevice.VTable{
        .readSector = partitionReadSector,
        .writeSector = partitionWriteSector,
        .readSectors = partitionReadSectors,
        .writeSectors = partitionWriteSectors,
        .flush = partitionFlush,
    };

    fn partitionReadSector(ctx: *anyopaque, lba: u64, buf: *[SECTOR_SIZE]u8) anyerror!void {
        const self: *PartitionBlockDevice = @ptrCast(@alignCast(ctx));
        if (lba >= self.sector_count) return error.SectorOutOfBounds;
        return self.parent.readSector(self.start_lba + lba, buf);
    }

    fn partitionWriteSector(ctx: *anyopaque, lba: u64, buf: *const [SECTOR_SIZE]u8) anyerror!void {
        const self: *PartitionBlockDevice = @ptrCast(@alignCast(ctx));
        if (lba >= self.sector_count) return error.SectorOutOfBounds;
        return self.parent.writeSector(self.start_lba + lba, buf);
    }

    fn partitionReadSectors(ctx: *anyopaque, lba: u64, count: usize, buf: []u8) anyerror!void {
        const self: *PartitionBlockDevice = @ptrCast(@alignCast(ctx));
        if (lba + count > self.sector_count) return error.SectorOutOfBounds;
        return self.parent.readSectors(self.start_lba + lba, count, buf);
    }

    fn partitionWriteSectors(ctx: *anyopaque, lba: u64, count: usize, buf: []const u8) anyerror!void {
        const self: *PartitionBlockDevice = @ptrCast(@alignCast(ctx));
        if (lba + count > self.sector_count) return error.SectorOutOfBounds;
        return self.parent.writeSectors(self.start_lba + lba, count, buf);
    }

    fn partitionFlush(ctx: *anyopaque) anyerror!void {
        const self: *PartitionBlockDevice = @ptrCast(@alignCast(ctx));
        return self.parent.flush();
    }
};

test "block device partition slice abstraction" {
    const MockMemoryBlock = struct {
        sectors: [100][SECTOR_SIZE]u8 = [_][SECTOR_SIZE]u8{[_]u8{0} ** SECTOR_SIZE} ** 100,
        device: BlockDevice = undefined,

        pub fn init(self: *@This()) *BlockDevice {
            self.device = BlockDevice{
                .ptr = @ptrCast(self),
                .vtable = &vtable,
                .total_sectors = 100,
            };
            return &self.device;
        }

        const vtable = BlockDevice.VTable{
            .readSector = mockReadSector,
            .writeSector = mockWriteSector,
            .readSectors = mockReadSectors,
            .writeSectors = mockWriteSectors,
            .flush = mockFlush,
        };

        fn mockReadSector(ctx: *anyopaque, lba: u64, buf: *[SECTOR_SIZE]u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(buf, &self.sectors[lba]);
        }

        fn mockWriteSector(ctx: *anyopaque, lba: u64, buf: *const [SECTOR_SIZE]u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(&self.sectors[lba], buf);
        }

        fn mockReadSectors(ctx: *anyopaque, lba: u64, count: usize, buf: []u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (0..count) |i| {
                const src = &self.sectors[lba + i];
                @memcpy(buf[i * SECTOR_SIZE .. (i + 1) * SECTOR_SIZE], src);
            }
        }

        fn mockWriteSectors(ctx: *anyopaque, lba: u64, count: usize, buf: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (0..count) |i| {
                const dst = &self.sectors[lba + i];
                @memcpy(dst, buf[i * SECTOR_SIZE .. (i + 1) * SECTOR_SIZE]);
            }
        }

        fn mockFlush(_: *anyopaque) anyerror!void {}
    };

    var raw_disk = MockMemoryBlock{};
    const parent_dev = raw_disk.init();

    // Create partition slice from LBA 20 to 60 (40 sectors)
    var part = try PartitionBlockDevice.init(parent_dev, 20, 40, "test_part");
    const part_dev = part.blockDevice();

    try std.testing.expectEqual(@as(u64, 40), part_dev.total_sectors);

    var sample_sector: [SECTOR_SIZE]u8 = [_]u8{0xAB} ** SECTOR_SIZE;
    try part_dev.writeSector(5, &sample_sector);

    // Verify parent has it at LBA 25 (20 + 5)
    var read_buf: [SECTOR_SIZE]u8 = undefined;
    try parent_dev.readSector(25, &read_buf);
    try std.testing.expectEqual(sample_sector, read_buf);

    // Verify out-of-bounds error on slice
    try std.testing.expectError(error.SectorOutOfBounds, part_dev.readSector(40, &read_buf));
}
