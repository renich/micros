// MicrOS (µOS) Minimal 8.3 FAT32 EFI System Partition (ESP) Driver
// Implements formatting, directory hierarchy, and file I/O for UEFI bootloader delivery.
// Zero libc, freestanding, 512-byte sector and 4096-byte cluster alignment.

const std = @import("std");
const block = @import("../drivers/block.zig");

pub const SECTOR_SIZE: usize = 512;
pub const SECTORS_PER_CLUSTER: u8 = 8; // 4 KiB cluster
pub const CLUSTER_SIZE: usize = @as(usize, SECTORS_PER_CLUSTER) * SECTOR_SIZE;
pub const RESERVED_SECTOR_COUNT: u16 = 32;
pub const NUM_FATS: u8 = 2;
pub const ROOT_DIR_CLUSTER: u32 = 2;
pub const FAT32_CLUSTER_THRESHOLD: u32 = 65525;

// FSInfo Signatures
pub const FSI_LEAD_SIG: u32 = 0x41615252; // "RRaA"
pub const FSI_STRUCT_SIG: u32 = 0x61417272; // "rrAa"
pub const FSI_TRAIL_SIG: u32 = 0xAA550000;
pub const BOOT_SECTOR_SIG: [2]u8 = [_]u8{ 0x55, 0xAA };

// FAT Cluster Markers
pub const FAT_ENTRY_MASK: u32 = 0x0FFF_FFFF;
pub const FAT_CLUSTER_FREE: u32 = 0x0000_0000;
pub const FAT_CLUSTER_RESERVED_0: u32 = 0x0FFF_FFF8; // Fixed disk media descriptor
pub const FAT_CLUSTER_RESERVED_1: u32 = 0x0FFF_FFFF; // Clean shutdown / dirty volume
pub const FAT_CLUSTER_EOF: u32 = 0x0FFF_FFFF;
pub const FAT_CLUSTER_BAD: u32 = 0x0FFF_FFF7;

// Directory Attributes
pub const ATTR_READ_ONLY: u8 = 0x01;
pub const ATTR_HIDDEN: u8 = 0x02;
pub const ATTR_SYSTEM: u8 = 0x04;
pub const ATTR_VOLUME_ID: u8 = 0x08;
pub const ATTR_DIRECTORY: u8 = 0x10;
pub const ATTR_ARCHIVE: u8 = 0x20;

pub const ENTRY_FREE: u8 = 0xE5;
pub const ENTRY_END: u8 = 0x00;

pub const ShortName = [11]u8;

pub const DirEntry = extern struct {
    name: [8]u8,
    ext: [3]u8,
    attr: u8,
    nt_res: u8 = 0,
    crt_time_tenth: u8 = 0,
    crt_time: u16 = 0,
    crt_date: u16 = 0x5421, // 2026 DOS epoch date
    lst_acc_date: u16 = 0,
    fst_clus_hi: u16,
    wrt_time: u16 = 0,
    wrt_date: u16 = 0x5421,
    fst_clus_lo: u16,
    file_size: u32,

    pub fn getCluster(self: *const DirEntry) u32 {
        const hi = @as(u32, self.fst_clus_hi);
        const lo = @as(u32, self.fst_clus_lo);
        return ((hi << 16) | lo) & FAT_ENTRY_MASK;
    }

    pub fn setCluster(self: *DirEntry, cluster: u32) void {
        self.fst_clus_hi = @truncate((cluster >> 16) & 0xFFFF);
        self.fst_clus_lo = @truncate(cluster & 0xFFFF);
    }
};

pub const Geometry = struct {
    total_sectors: u64,
    sectors_per_fat: u32,
    first_data_sector: u64,
    total_clusters: u32,
    fat1_lba: u64,
    fat2_lba: u64,

    pub fn clusterToLba(self: *const Geometry, cluster: u32) u64 {
        const offset = @as(u64, cluster - ROOT_DIR_CLUSTER) * SECTORS_PER_CLUSTER;
        return self.first_data_sector + offset;
    }
};

pub fn calculateGeometry(total_sectors: u64) !Geometry {
    if (total_sectors < 100_000) return error.PartitionTooSmall;

    const entries_per_sector: u64 = SECTOR_SIZE / 4;
    const reserved: u64 = RESERVED_SECTOR_COUNT;
    const numerator = total_sectors - reserved + 16;
    const denominator = entries_per_sector * SECTORS_PER_CLUSTER + NUM_FATS;
    const min_fat_sectors = (numerator + denominator - 1) / denominator;
    const sectors_per_fat: u32 = @intCast(std.mem.alignForward(u64, min_fat_sectors, 8));

    const first_data_sec = reserved + (@as(u64, NUM_FATS) * sectors_per_fat);
    if (total_sectors <= first_data_sec) return error.PartitionTooSmall;

    const data_sectors = total_sectors - first_data_sec;
    const total_clusters: u32 = @intCast(data_sectors / SECTORS_PER_CLUSTER);

    if (total_clusters < FAT32_CLUSTER_THRESHOLD) {
        return error.ClusterCountBelowFat32Threshold;
    }

    return Geometry{
        .total_sectors = total_sectors,
        .sectors_per_fat = sectors_per_fat,
        .first_data_sector = first_data_sec,
        .total_clusters = total_clusters,
        .fat1_lba = reserved,
        .fat2_lba = reserved + sectors_per_fat,
    };
}

pub const PathComponent = struct {
    short_name: ShortName,
    is_terminal: bool,
};

pub const PathIterator = struct {
    path: []const u8,
    index: usize = 0,

    pub fn init(path: []const u8) PathIterator {
        return .{ .path = path, .index = 0 };
    }

    pub fn next(self: *PathIterator) !?PathComponent {
        while (self.index < self.path.len and isSep(self.path[self.index])) {
            self.index += 1;
        }
        if (self.index >= self.path.len) return null;

        const start = self.index;
        while (self.index < self.path.len and !isSep(self.path[self.index])) {
            self.index += 1;
        }
        const segment = self.path[start..self.index];

        var peek = self.index;
        while (peek < self.path.len and isSep(self.path[peek])) {
            peek += 1;
        }
        const is_terminal = (peek >= self.path.len);
        const name83 = try parse8Dot3(segment);

        return PathComponent{
            .short_name = name83,
            .is_terminal = is_terminal,
        };
    }

    fn isSep(c: u8) bool {
        return c == '/' or c == '\\';
    }

    fn parse8Dot3(segment: []const u8) !ShortName {
        if (segment.len == 0) return error.EmptyPathComponent;
        var result: ShortName = [_]u8{' '} ** 11;
        var dot_idx: ?usize = null;

        for (segment, 0..) |c, i| {
            if (c == '.') {
                if (dot_idx != null) return error.MultipleDots;
                dot_idx = i;
            } else if (!isValidFatChar(c)) {
                return error.InvalidCharacter;
            }
        }
        if (dot_idx) |d| {
            if (d == 0 or d == segment.len - 1) return error.TrailingDot;
            const name_part = segment[0..d];
            const ext_part = segment[d + 1 ..];
            if (name_part.len > 8 or ext_part.len > 3) return error.NameTooLong;
            for (name_part, 0..) |c, i| result[i] = std.ascii.toUpper(c);
            for (ext_part, 0..) |c, i| result[8 + i] = std.ascii.toUpper(c);
        } else {
            if (segment.len > 8) return error.NameTooLong;
            for (segment, 0..) |c, i| result[i] = std.ascii.toUpper(c);
        }
        return result;
    }

    fn isValidFatChar(c: u8) bool {
        return switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9' => true,
            '$', '%', '\'', '-', '_', '@', '~', '`', '!', '(', ')', '#', '^', '&' => true,
            else => false,
        };
    }
};

fn writeBootSector(dev: *block.BlockDevice, geom: *const Geometry) !void {
    var sec = [_]u8{0} ** SECTOR_SIZE;
    sec[0] = 0xEB; // JMP short
    sec[1] = 0x58;
    sec[2] = 0x90; // NOP
    @memcpy(sec[3..11], "MSWIN4.1");
    std.mem.writeInt(u16, sec[11..13], @intCast(dev.sector_size), .little);
    sec[13] = SECTORS_PER_CLUSTER;
    std.mem.writeInt(u16, sec[14..16], RESERVED_SECTOR_COUNT, .little);
    sec[16] = NUM_FATS;
    sec[21] = 0xF8; // Fixed media
    std.mem.writeInt(u16, sec[24..26], 63, .little); // Sectors per track
    std.mem.writeInt(u16, sec[26..28], 255, .little); // Heads
    std.mem.writeInt(u32, sec[32..36], @intCast(geom.total_sectors), .little);
    std.mem.writeInt(u32, sec[36..40], geom.sectors_per_fat, .little);
    std.mem.writeInt(u32, sec[44..48], ROOT_DIR_CLUSTER, .little);
    std.mem.writeInt(u16, sec[48..50], 1, .little); // FSInfo sector
    std.mem.writeInt(u16, sec[50..52], 6, .little); // Backup VBR
    sec[64] = 0x80; // Drive number
    sec[66] = 0x29; // Boot signature
    std.mem.writeInt(u32, sec[67..71], 0x1234_5678, .little); // Volume ID
    @memcpy(sec[71..82], "MICROS ESP ");
    @memcpy(sec[82..90], "FAT32   ");
    sec[510] = BOOT_SECTOR_SIG[0];
    sec[511] = BOOT_SECTOR_SIG[1];

    try dev.writeSector(0, &sec);
    try dev.writeSector(6, &sec);
}

fn writeFsInfo(dev: *block.BlockDevice, free_count: u32, next_free: u32) !void {
    var sec = [_]u8{0} ** SECTOR_SIZE;
    std.mem.writeInt(u32, sec[0..4], FSI_LEAD_SIG, .little);
    std.mem.writeInt(u32, sec[484..488], FSI_STRUCT_SIG, .little);
    std.mem.writeInt(u32, sec[488..492], free_count, .little);
    std.mem.writeInt(u32, sec[492..496], next_free, .little);
    std.mem.writeInt(u32, sec[508..512], FSI_TRAIL_SIG, .little);

    try dev.writeSector(1, &sec);
    try dev.writeSector(7, &sec);
}

fn readFatEntry(dev: *block.BlockDevice, geom: *const Geometry, cluster: u32) !u32 {
    const sec_offset = cluster / 128;
    const ent_offset = (cluster % 128) * 4;
    var sec: [SECTOR_SIZE]u8 = undefined;
    try dev.readSector(geom.fat1_lba + sec_offset, &sec);
    const entry_slice = sec[ent_offset..][0..4];
    return std.mem.readInt(u32, entry_slice, .little) & FAT_ENTRY_MASK;
}

fn writeFatEntry(dev: *block.BlockDevice, geom: *const Geometry, cluster: u32, value: u32) !void {
    const sec_offset = cluster / 128;
    const ent_offset = (cluster % 128) * 4;
    var sec: [SECTOR_SIZE]u8 = undefined;

    try dev.readSector(geom.fat1_lba + sec_offset, &sec);
    const entry_slice = sec[ent_offset..][0..4];
    const existing = std.mem.readInt(u32, entry_slice, .little);
    const masked_val = (value & FAT_ENTRY_MASK) | (existing & ~FAT_ENTRY_MASK);
    std.mem.writeInt(u32, entry_slice, masked_val, .little);

    try dev.writeSector(geom.fat1_lba + sec_offset, &sec);
    try dev.writeSector(geom.fat2_lba + sec_offset, &sec);
}

fn zeroCluster(dev: *block.BlockDevice, geom: *const Geometry, cluster: u32) !void {
    const lba = geom.clusterToLba(cluster);
    const zero_buf = [_]u8{0} ** SECTOR_SIZE;
    var i: usize = 0;
    while (i < SECTORS_PER_CLUSTER) : (i += 1) {
        try dev.writeSector(lba + i, &zero_buf);
    }
}

fn allocateCluster(dev: *block.BlockDevice, geom: *const Geometry, prev_cluster: ?u32) !u32 {
    var c: u32 = if (prev_cluster) |p| p + 1 else ROOT_DIR_CLUSTER + 1;
    while (c < geom.total_clusters + ROOT_DIR_CLUSTER) : (c += 1) {
        const val = try readFatEntry(dev, geom, c);
        if (val == FAT_CLUSTER_FREE) {
            try writeFatEntry(dev, geom, c, FAT_CLUSTER_EOF);
            if (prev_cluster) |p| {
                try writeFatEntry(dev, geom, p, c);
            }
            try zeroCluster(dev, geom, c);
            return c;
        }
    }
    return error.DiskFull;
}

fn findEntryInSector(sec: *const [SECTOR_SIZE]u8, name83: ShortName) ?DirEntry {
    var offset: usize = 0;
    while (offset < SECTOR_SIZE) : (offset += @sizeOf(DirEntry)) {
        if (sec[offset] == ENTRY_END) return null;
        if (sec[offset] == ENTRY_FREE) continue;
        const entry: *const DirEntry = @ptrCast(@alignCast(&sec[offset]));
        var full_name: ShortName = undefined;
        @memcpy(full_name[0..8], &entry.name);
        @memcpy(full_name[8..11], &entry.ext);
        if (std.mem.eql(u8, &full_name, &name83)) {
            return entry.*;
        }
    }
    return null;
}

fn findDirEntry(dev: *block.BlockDevice, geom: *const Geometry, start_cluster: u32, name83: ShortName) !?DirEntry {
    var curr_cluster = start_cluster;
    while (curr_cluster < FAT_CLUSTER_BAD) {
        const base_lba = geom.clusterToLba(curr_cluster);
        var sec_idx: usize = 0;
        while (sec_idx < SECTORS_PER_CLUSTER) : (sec_idx += 1) {
            var sec: [SECTOR_SIZE]u8 align(@alignOf(DirEntry)) = undefined;
            try dev.readSector(base_lba + sec_idx, &sec);
            if (findEntryInSector(&sec, name83)) |entry| {
                return entry;
            }
        }
        curr_cluster = try readFatEntry(dev, geom, curr_cluster);
    }
    return null;
}

fn insertEntryInSector(sec: *[SECTOR_SIZE]u8, entry: DirEntry) bool {
    var offset: usize = 0;
    while (offset < SECTOR_SIZE) : (offset += @sizeOf(DirEntry)) {
        if (sec[offset] == ENTRY_END or sec[offset] == ENTRY_FREE) {
            const dst: *DirEntry = @ptrCast(@alignCast(&sec[offset]));
            dst.* = entry;
            return true;
        }
    }
    return false;
}

fn insertDirEntry(dev: *block.BlockDevice, geom: *const Geometry, dir_cluster: u32, entry: DirEntry) !void {
    var curr = dir_cluster;
    var last = dir_cluster;
    while (curr < FAT_CLUSTER_BAD) {
        last = curr;
        const base_lba = geom.clusterToLba(curr);
        var sec_idx: usize = 0;
        while (sec_idx < SECTORS_PER_CLUSTER) : (sec_idx += 1) {
            var sec: [SECTOR_SIZE]u8 align(@alignOf(DirEntry)) = undefined;
            try dev.readSector(base_lba + sec_idx, &sec);
            if (insertEntryInSector(&sec, entry)) {
                try dev.writeSector(base_lba + sec_idx, &sec);
                return;
            }
        }
        curr = try readFatEntry(dev, geom, curr);
    }
    const new_clus = try allocateCluster(dev, geom, last);
    const base_lba = geom.clusterToLba(new_clus);
    var sec: [SECTOR_SIZE]u8 align(@alignOf(DirEntry)) = [_]u8{0} ** SECTOR_SIZE;
    _ = insertEntryInSector(&sec, entry);
    try dev.writeSector(base_lba, &sec);
}

fn initSubdirectory(dev: *block.BlockDevice, geom: *const Geometry, new_clus: u32, parent_clus: u32) !void {
    var sec: [SECTOR_SIZE]u8 align(@alignOf(DirEntry)) = [_]u8{0} ** SECTOR_SIZE;
    var dot_entry = DirEntry{
        .name = [_]u8{ '.', ' ', ' ', ' ', ' ', ' ', ' ', ' ' },
        .ext = [_]u8{ ' ', ' ', ' ' },
        .attr = ATTR_DIRECTORY,
        .fst_clus_hi = 0,
        .fst_clus_lo = 0,
        .file_size = 0,
    };
    dot_entry.setCluster(new_clus);

    var dotdot_entry = DirEntry{
        .name = [_]u8{ '.', '.', ' ', ' ', ' ', ' ', ' ', ' ' },
        .ext = [_]u8{ ' ', ' ', ' ' },
        .attr = ATTR_DIRECTORY,
        .fst_clus_hi = 0,
        .fst_clus_lo = 0,
        .file_size = 0,
    };
    dotdot_entry.setCluster(if (parent_clus == ROOT_DIR_CLUSTER) 0 else parent_clus);

    _ = insertEntryInSector(&sec, dot_entry);
    _ = insertEntryInSector(&sec, dotdot_entry);

    const base_lba = geom.clusterToLba(new_clus);
    try dev.writeSector(base_lba, &sec);
}

pub fn formatEsp(dev: *block.BlockDevice) !void {
    const geom = try calculateGeometry(dev.total_sectors);
    try writeBootSector(dev, &geom);

    const zero_sec = [_]u8{0} ** SECTOR_SIZE;
    var sec_idx: u64 = 0;
    while (sec_idx < geom.sectors_per_fat) : (sec_idx += 1) {
        try dev.writeSector(geom.fat1_lba + sec_idx, &zero_sec);
        try dev.writeSector(geom.fat2_lba + sec_idx, &zero_sec);
    }

    try writeFatEntry(dev, &geom, 0, FAT_CLUSTER_RESERVED_0);
    try writeFatEntry(dev, &geom, 1, FAT_CLUSTER_RESERVED_1);
    try writeFatEntry(dev, &geom, ROOT_DIR_CLUSTER, FAT_CLUSTER_EOF);

    try zeroCluster(dev, &geom, ROOT_DIR_CLUSTER);
    try writeFsInfo(dev, geom.total_clusters - 1, ROOT_DIR_CLUSTER + 1);
    try dev.flush();
}

fn resolveOrCreatePath(
    dev: *block.BlockDevice,
    geom: *const Geometry,
    path: []const u8,
) !struct { parent_cluster: u32, target_name: ShortName } {
    var iter = PathIterator.init(path);
    var curr_cluster: u32 = ROOT_DIR_CLUSTER;

    while (try iter.next()) |comp| {
        if (comp.is_terminal) {
            return .{ .parent_cluster = curr_cluster, .target_name = comp.short_name };
        }
        if (try findDirEntry(dev, geom, curr_cluster, comp.short_name)) |existing| {
            if ((existing.attr & ATTR_DIRECTORY) == 0) return error.NotADirectory;
            curr_cluster = existing.getCluster();
        } else {
            const new_dir_clus = try allocateCluster(dev, geom, null);
            try initSubdirectory(dev, geom, new_dir_clus, curr_cluster);
            var entry = DirEntry{
                .name = comp.short_name[0..8].*,
                .ext = comp.short_name[8..11].*,
                .attr = ATTR_DIRECTORY,
                .fst_clus_hi = 0,
                .fst_clus_lo = 0,
                .file_size = 0,
            };
            entry.setCluster(new_dir_clus);
            try insertDirEntry(dev, geom, curr_cluster, entry);
            curr_cluster = new_dir_clus;
        }
    }
    return error.EmptyPath;
}

pub fn writeFile(dev: *block.BlockDevice, path: []const u8, data: []const u8) !void {
    const geom = try calculateGeometry(dev.total_sectors);
    const target = try resolveOrCreatePath(dev, &geom, path);

    const needed_clusters: usize = if (data.len == 0) 1 else (data.len + CLUSTER_SIZE - 1) / CLUSTER_SIZE;
    var first_clus: ?u32 = null;
    var prev_clus: ?u32 = null;

    var i: usize = 0;
    while (i < needed_clusters) : (i += 1) {
        const clus = try allocateCluster(dev, &geom, prev_clus);
        if (first_clus == null) first_clus = clus;
        prev_clus = clus;

        const slice_start = i * CLUSTER_SIZE;
        const slice_len = @min(data.len -| slice_start, CLUSTER_SIZE);
        if (slice_len > 0) {
            var clus_buf = [_]u8{0} ** CLUSTER_SIZE;
            @memcpy(clus_buf[0..slice_len], data[slice_start .. slice_start + slice_len]);
            const lba = geom.clusterToLba(clus);
            try dev.writeSectors(lba, SECTORS_PER_CLUSTER, &clus_buf);
        }
    }

    var file_entry = DirEntry{
        .name = target.target_name[0..8].*,
        .ext = target.target_name[8..11].*,
        .attr = ATTR_ARCHIVE,
        .fst_clus_hi = 0,
        .fst_clus_lo = 0,
        .file_size = @truncate(data.len),
    };
    file_entry.setCluster(first_clus orelse ROOT_DIR_CLUSTER);
    try insertDirEntry(dev, &geom, target.parent_cluster, file_entry);
    try dev.flush();
}

pub fn readFile(dev: *block.BlockDevice, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const geom = try calculateGeometry(dev.total_sectors);
    var iter = PathIterator.init(path);
    var curr_cluster: u32 = ROOT_DIR_CLUSTER;

    while (try iter.next()) |comp| {
        const maybe_entry = try findDirEntry(dev, &geom, curr_cluster, comp.short_name);
        const entry = maybe_entry orelse return error.FileNotFound;
        if (comp.is_terminal) {
            if ((entry.attr & ATTR_DIRECTORY) != 0) return error.IsADirectory;
            const buf = try allocator.alloc(u8, entry.file_size);
            errdefer allocator.free(buf);
            try copyFileClusters(dev, &geom, entry.getCluster(), buf);
            return buf;
        }
        curr_cluster = entry.getCluster();
    }
    return error.FileNotFound;
}

fn copyFileClusters(dev: *block.BlockDevice, geom: *const Geometry, start_cluster: u32, out_buf: []u8) !void {
    var curr = start_cluster;
    var offset: usize = 0;
    while (curr < FAT_CLUSTER_BAD and offset < out_buf.len) {
        var clus_buf: [CLUSTER_SIZE]u8 = undefined;
        const lba = geom.clusterToLba(curr);
        try dev.readSectors(lba, SECTORS_PER_CLUSTER, &clus_buf);
        const copy_len = @min(out_buf.len - offset, CLUSTER_SIZE);
        @memcpy(out_buf[offset .. offset + copy_len], clus_buf[0..copy_len]);
        offset += copy_len;
        curr = try readFatEntry(dev, geom, curr);
    }
}

test "fat32 geometry calculation" {
    // 300 MiB = 614,400 sectors
    const geom = try calculateGeometry(614400);
    try std.testing.expectEqual(@as(u64, 614400), geom.total_sectors);
    try std.testing.expectEqual(@as(u32, 600), geom.sectors_per_fat);
    try std.testing.expectEqual(@as(u64, 1232), geom.first_data_sector);
    try std.testing.expect(geom.total_clusters >= FAT32_CLUSTER_THRESHOLD);

    // Cluster to LBA
    try std.testing.expectEqual(@as(u64, 1232), geom.clusterToLba(2));
    try std.testing.expectEqual(@as(u64, 1240), geom.clusterToLba(3));
}

test "fat32 path iterator 8.3 parsing" {
    var iter = PathIterator.init("/EFI/BOOT/BOOTX64.EFI");
    const c1 = (try iter.next()).?;
    try std.testing.expectEqualStrings("EFI        ", &c1.short_name);
    try std.testing.expect(!c1.is_terminal);

    const c2 = (try iter.next()).?;
    try std.testing.expectEqualStrings("BOOT       ", &c2.short_name);
    try std.testing.expect(!c2.is_terminal);

    const c3 = (try iter.next()).?;
    try std.testing.expectEqualStrings("BOOTX64 EFI", &c3.short_name);
    try std.testing.expect(c3.is_terminal);

    try std.testing.expectEqual(@as(?PathComponent, null), try iter.next());
}

test "fat32 sparse block mock format and file roundtrip" {
    const SparseBlock = struct {
        sectors: std.AutoHashMap(u64, [SECTOR_SIZE]u8),
        device: block.BlockDevice = undefined,

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return .{
                .sectors = std.AutoHashMap(u64, [SECTOR_SIZE]u8).init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.sectors.deinit();
        }

        pub fn blockDevice(self: *@This()) *block.BlockDevice {
            self.device = block.BlockDevice{
                .ptr = @ptrCast(self),
                .vtable = &vtable,
                .total_sectors = 614400, // 300 MiB
            };
            return &self.device;
        }

        const vtable = block.BlockDevice.VTable{
            .readSector = mockReadSector,
            .writeSector = mockWriteSector,
            .readSectors = mockReadSectors,
            .writeSectors = mockWriteSectors,
            .flush = mockFlush,
        };

        fn mockReadSector(ctx: *anyopaque, lba: u64, buf: *[SECTOR_SIZE]u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.sectors.get(lba)) |sec| {
                @memcpy(buf, &sec);
            } else {
                @memset(buf, 0);
            }
        }

        fn mockWriteSector(ctx: *anyopaque, lba: u64, buf: *const [SECTOR_SIZE]u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.sectors.put(lba, buf.*);
        }

        fn readOneMockSector(self: *@This(), lba: u64, dst: []u8) void {
            if (self.sectors.get(lba)) |sec| {
                @memcpy(dst, &sec);
                return;
            }
            @memset(dst, 0);
        }

        fn mockReadSectors(ctx: *anyopaque, lba: u64, count: usize, buf: []u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (0..count) |i| {
                self.readOneMockSector(lba + i, buf[i * SECTOR_SIZE .. (i + 1) * SECTOR_SIZE]);
            }
        }

        fn writeOneMockSector(self: *@This(), lba: u64, src: []const u8) !void {
            var sec: [SECTOR_SIZE]u8 = undefined;
            @memcpy(&sec, src);
            try self.sectors.put(lba, sec);
        }

        fn mockWriteSectors(ctx: *anyopaque, lba: u64, count: usize, buf: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            for (0..count) |i| {
                try self.writeOneMockSector(lba + i, buf[i * SECTOR_SIZE .. (i + 1) * SECTOR_SIZE]);
            }
        }

        fn mockFlush(_: *anyopaque) anyerror!void {}
    };

    var sparse = try SparseBlock.init(std.testing.allocator);
    defer sparse.deinit();
    const dev = sparse.blockDevice();

    try formatEsp(dev);

    const test_payload = "MZP_MICROS_SOVEREIGN_UEFI_BOOTX64_BINARY_PAYLOAD_VALIDATED";
    try writeFile(dev, "/EFI/BOOT/BOOTX64.EFI", test_payload);

    const read_back = try readFile(dev, "/EFI/BOOT/BOOTX64.EFI", std.testing.allocator);
    defer std.testing.allocator.free(read_back);

    try std.testing.expectEqualStrings(test_payload, read_back);
}
