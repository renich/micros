// MicrOS (µOS) VirtIO Block Device Driver (virtio-blk-pci)
// Implements VirtIO 1.0 split virtqueue sector read and write transactions.
// Zero libc, direct port I/O and page-aligned DMA ring buffers.

const std = @import("std");
const block = @import("block.zig");
const io = @import("../arch/x86_64/io.zig");
const pci = @import("pci.zig");
const serial = @import("../serial.zig");
const virtio = @import("virtio.zig");

pub const QUEUE_SIZE: u16 = 256;
pub const QUEUE_PAGES: usize = 3;
pub const DMA_PAGES: usize = 2;
pub const MAX_BATCH_SECTORS: usize = 8;
pub const SECTOR_SIZE: usize = 512;
pub const STATUS_DMA_OFFSET: usize = 16;
pub const DATA_DMA_OFFSET: usize = 512;
pub const PAUSE_SPIN_LIMIT: usize = virtio.PAUSE_SPIN_LIMIT;
pub const QUEUE_INDEX: u16 = 0;

pub const REG_DEVICE_FEATURES: u16 = virtio.REG_DEVICE_FEATURES;
pub const REG_GUEST_FEATURES: u16 = virtio.REG_GUEST_FEATURES;
pub const REG_QUEUE_ADDRESS: u16 = virtio.REG_QUEUE_ADDRESS;
pub const REG_QUEUE_SIZE: u16 = virtio.REG_QUEUE_SIZE;
pub const REG_QUEUE_SELECT: u16 = virtio.REG_QUEUE_SELECT;
pub const REG_QUEUE_NOTIFY: u16 = virtio.REG_QUEUE_NOTIFY;
pub const REG_DEVICE_STATUS: u16 = virtio.REG_DEVICE_STATUS;
pub const REG_ISR_STATUS: u16 = virtio.REG_ISR_STATUS;
pub const REG_CAPACITY_LOW: u16 = 0x14;
pub const REG_CAPACITY_HIGH: u16 = 0x18;

pub const STATUS_RESET: u8 = virtio.STATUS_RESET;
pub const STATUS_ACKNOWLEDGE: u8 = virtio.STATUS_ACKNOWLEDGE;
pub const STATUS_DRIVER: u8 = virtio.STATUS_DRIVER;
pub const STATUS_DRIVER_OK: u8 = virtio.STATUS_DRIVER_OK;
pub const STATUS_FEATURES_OK: u8 = virtio.STATUS_FEATURES_OK;
pub const STATUS_FAILED: u8 = virtio.STATUS_FAILED;

pub const VRING_DESC_F_NEXT: u16 = virtio.VRING_DESC_F_NEXT;
pub const VRING_DESC_F_WRITE: u16 = virtio.VRING_DESC_F_WRITE;
pub const VRING_AVAIL_F_NO_INTERRUPT: u16 = virtio.VRING_AVAIL_F_NO_INTERRUPT;

pub const VIRTIO_BLK_T_IN: u32 = 0;
pub const VIRTIO_BLK_T_OUT: u32 = 1;
pub const VIRTIO_BLK_T_FLUSH: u32 = 4;

pub const VirtioBlkOutHdr = extern struct {
    type: u32,
    ioprio: u32 = 0,
    sector: u64,
};

pub const VirtioBlkStatus = enum(u8) {
    ok = 0,
    io_err = 1,
    unsupp = 2,
    pending = 0xFF,
};

pub const VRingDesc = virtio.VRingDesc;
pub const VRingAvail = virtio.VRingAvail(QUEUE_SIZE);
pub const VRingUsedElem = virtio.VRingUsedElem;
pub const VRingUsed = virtio.VRingUsed(QUEUE_SIZE);

pub const VirtQueue = struct {
    queue_index: u16,
    num_descs: u16,
    descs: [*]VRingDesc,
    avail: *volatile VRingAvail,
    used: *volatile VRingUsed,
    last_used_idx: u16,
    ring_phys: u64,

    pub fn init(queue_index: u16, mem_phys: u64, mem_virt: [*]u8) VirtQueue {
        @memset(mem_virt[0 .. QUEUE_PAGES * 4096], 0);

        const desc_size = @as(usize, QUEUE_SIZE) * @sizeOf(VRingDesc);
        const avail_size = @sizeOf(VRingAvail);
        const avail_offset = desc_size;
        const used_offset = std.mem.alignForward(usize, desc_size + avail_size, 4096);

        const descs: [*]VRingDesc = @ptrCast(@alignCast(mem_virt));
        const avail: *volatile VRingAvail = @ptrCast(@alignCast(mem_virt + avail_offset));
        const used: *volatile VRingUsed = @ptrCast(@alignCast(mem_virt + used_offset));

        avail.flags = VRING_AVAIL_F_NO_INTERRUPT;
        avail.idx = 0;
        used.flags = 0;
        used.idx = 0;

        return VirtQueue{
            .queue_index = queue_index,
            .num_descs = QUEUE_SIZE,
            .descs = descs,
            .avail = avail,
            .used = used,
            .last_used_idx = 0,
            .ring_phys = mem_phys,
        };
    }
};

pub const VirtioBlkDevice = struct {
    io_base: u16,
    capacity_sectors: u64,
    queue: VirtQueue,
    dma_buffer_virt: [*]u8,
    dma_buffer_phys: u64,
    initialized: bool,

    pub fn init(pci_dev: pci.PciDevice, ring_page_phys: u64, dma_page_phys: u64, hhdm_offset: u64) !VirtioBlkDevice {
        const io_port = pci_dev.getIoPort(0) orelse return error.NoIoBar;
        pci_dev.enableBusMastering();

        io.outb(io_port + REG_DEVICE_STATUS, STATUS_RESET);
        io.outb(io_port + REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

        const cap = readCapacity(io_port);
        const ring_virt: [*]u8 = @ptrFromInt(ring_page_phys + hhdm_offset);
        const q = VirtQueue.init(QUEUE_INDEX, ring_page_phys, ring_virt);

        io.outw(io_port + REG_QUEUE_SELECT, QUEUE_INDEX);
        _ = io.inw(io_port + REG_QUEUE_SIZE);

        const pfn: u32 = @intCast(ring_page_phys / 4096);
        io.outl(io_port + REG_QUEUE_ADDRESS, pfn);

        io.outb(io_port + REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_DRIVER_OK);

        const dma_virt: [*]u8 = @ptrFromInt(dma_page_phys + hhdm_offset);
        @memset(dma_virt[0 .. DMA_PAGES * 4096], 0);

        return VirtioBlkDevice{
            .io_base = io_port,
            .capacity_sectors = cap,
            .queue = q,
            .dma_buffer_virt = dma_virt,
            .dma_buffer_phys = dma_page_phys,
            .initialized = true,
        };
    }

    pub fn readSector(self: *VirtioBlkDevice, sector: u64, out_buf: *[SECTOR_SIZE]u8) !void {
        return self.readSectors(sector, 1, out_buf);
    }

    pub fn readSectors(self: *VirtioBlkDevice, sector: u64, count: usize, out_buf: []u8) !void {
        try self.validateTransfer(sector, count, out_buf.len);

        const hdr_ptr: *VirtioBlkOutHdr = @ptrCast(@alignCast(self.dma_buffer_virt));
        hdr_ptr.* = VirtioBlkOutHdr{
            .type = VIRTIO_BLK_T_IN,
            .ioprio = 0,
            .sector = sector,
        };

        self.dma_buffer_virt[STATUS_DMA_OFFSET] = @intFromEnum(VirtioBlkStatus.pending);
        const data_phys = self.dma_buffer_phys + DATA_DMA_OFFSET;
        const status_phys = self.dma_buffer_phys + STATUS_DMA_OFFSET;

        const data_len: u32 = @intCast(count * SECTOR_SIZE);
        self.setupDescChain(self.dma_buffer_phys, data_phys, data_len, status_phys, VRING_DESC_F_WRITE);
        try self.submitAndWait();

        if (self.dma_buffer_virt[STATUS_DMA_OFFSET] != @intFromEnum(VirtioBlkStatus.ok)) {
            return error.IoError;
        }

        const data_slice = self.dma_buffer_virt[DATA_DMA_OFFSET .. DATA_DMA_OFFSET + data_len];
        @memcpy(out_buf[0..data_len], data_slice);
    }

    pub fn writeSector(self: *VirtioBlkDevice, sector: u64, in_buf: *const [SECTOR_SIZE]u8) !void {
        return self.writeSectors(sector, 1, in_buf);
    }

    pub fn writeSectors(self: *VirtioBlkDevice, sector: u64, count: usize, in_buf: []const u8) !void {
        try self.validateTransfer(sector, count, in_buf.len);

        const hdr_ptr: *VirtioBlkOutHdr = @ptrCast(@alignCast(self.dma_buffer_virt));
        hdr_ptr.* = VirtioBlkOutHdr{
            .type = VIRTIO_BLK_T_OUT,
            .ioprio = 0,
            .sector = sector,
        };

        const data_len: u32 = @intCast(count * SECTOR_SIZE);
        const data_slice = self.dma_buffer_virt[DATA_DMA_OFFSET .. DATA_DMA_OFFSET + data_len];
        @memcpy(data_slice, in_buf[0..data_len]);

        self.dma_buffer_virt[STATUS_DMA_OFFSET] = @intFromEnum(VirtioBlkStatus.pending);
        const data_phys = self.dma_buffer_phys + DATA_DMA_OFFSET;
        const status_phys = self.dma_buffer_phys + STATUS_DMA_OFFSET;

        self.setupDescChain(self.dma_buffer_phys, data_phys, data_len, status_phys, 0);
        try self.submitAndWait();

        if (self.dma_buffer_virt[STATUS_DMA_OFFSET] != @intFromEnum(VirtioBlkStatus.ok)) {
            return error.IoError;
        }
    }

    fn validateTransfer(self: *const VirtioBlkDevice, sector: u64, count: usize, buf_len: usize) !void {
        if (!self.initialized) return error.DeviceNotInitialized;
        if (count == 0 or count > MAX_BATCH_SECTORS) return error.InvalidSectorCount;
        if (buf_len < count * SECTOR_SIZE) return error.BufferTooSmall;
        if (sector + @as(u64, @intCast(count)) > self.capacity_sectors) return error.SectorOutOfBounds;
    }

    fn setupDescChain(self: *VirtioBlkDevice, hdr_phys: u64, data_phys: u64, data_len: u32, status_phys: u64, data_extra_flag: u16) void {
        self.queue.descs[0] = VRingDesc{
            .addr = hdr_phys,
            .len = @sizeOf(VirtioBlkOutHdr),
            .flags = VRING_DESC_F_NEXT,
            .next = 1,
        };
        self.queue.descs[1] = VRingDesc{
            .addr = data_phys,
            .len = data_len,
            .flags = VRING_DESC_F_NEXT | data_extra_flag,
            .next = 2,
        };
        self.queue.descs[2] = VRingDesc{
            .addr = status_phys,
            .len = 1,
            .flags = VRING_DESC_F_WRITE,
            .next = 0,
        };
    }

    fn submitAndWait(self: *VirtioBlkDevice) !void {
        const avail_ptr = self.queue.avail;
        const avail_idx = avail_ptr.idx;
        avail_ptr.ring[avail_idx % QUEUE_SIZE] = 0;
        asm volatile ("" ::: .{ .memory = true });
        avail_ptr.idx = avail_idx +% 1;
        asm volatile ("" ::: .{ .memory = true });

        io.outw(self.io_base + REG_QUEUE_NOTIFY, QUEUE_INDEX);

        const used_ptr = self.queue.used;
        var wait_iter: usize = 0;
        while (used_ptr.idx == self.queue.last_used_idx and wait_iter < PAUSE_SPIN_LIMIT) : (wait_iter += 1) {
            io.pause();
        }

        if (used_ptr.idx == self.queue.last_used_idx) {
            serial.writeString("[virtio-blk] Timeout! used.idx: 0x");
            serial.writeHex(used_ptr.idx);
            serial.writeString(" last_used: 0x");
            serial.writeHex(self.queue.last_used_idx);
            serial.writeString(" isr: 0x");
            serial.writeHex(io.inb(self.io_base + REG_ISR_STATUS));
            serial.writeString("\n");
            return error.DeviceTimeout;
        }
        self.queue.last_used_idx = used_ptr.idx;
    }

    pub fn blockDevice(self: *VirtioBlkDevice) block.BlockDevice {
        var dev = block.BlockDevice{
            .ptr = @ptrCast(self),
            .vtable = &virtio_blk_vtable,
            .total_sectors = self.capacity_sectors,
            .sector_size = SECTOR_SIZE,
        };
        const dev_name = "virtio-blk";
        @memcpy(dev.name[0..dev_name.len], dev_name);
        return dev;
    }

    const virtio_blk_vtable = block.BlockDevice.VTable{
        .readSector = vtableReadSector,
        .writeSector = vtableWriteSector,
        .readSectors = vtableReadSectors,
        .writeSectors = vtableWriteSectors,
        .flush = vtableFlush,
    };

    fn vtableReadSector(ctx: *anyopaque, lba: u64, buf: *[SECTOR_SIZE]u8) anyerror!void {
        const self: *VirtioBlkDevice = @ptrCast(@alignCast(ctx));
        return self.readSector(lba, buf);
    }

    fn vtableWriteSector(ctx: *anyopaque, lba: u64, buf: *const [SECTOR_SIZE]u8) anyerror!void {
        const self: *VirtioBlkDevice = @ptrCast(@alignCast(ctx));
        return self.writeSector(lba, buf);
    }

    fn vtableReadSectors(ctx: *anyopaque, lba: u64, count: usize, buf: []u8) anyerror!void {
        const self: *VirtioBlkDevice = @ptrCast(@alignCast(ctx));
        return self.readSectors(lba, count, buf);
    }

    fn vtableWriteSectors(ctx: *anyopaque, lba: u64, count: usize, buf: []const u8) anyerror!void {
        const self: *VirtioBlkDevice = @ptrCast(@alignCast(ctx));
        return self.writeSectors(lba, count, buf);
    }

    fn vtableFlush(_: *anyopaque) anyerror!void {}
};

fn readCapacity(io_port: u16) u64 {
    const low = io.inl(io_port + REG_CAPACITY_LOW);
    const high = io.inl(io_port + REG_CAPACITY_HIGH);
    return @as(u64, low) | (@as(u64, high) << 32);
}

test "virtio blk header and descriptor size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(VirtioBlkOutHdr));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(VRingDesc));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(VRingUsedElem));
}

test "virtio blk sector bounds check" {
    var dev = VirtioBlkDevice{
        .io_base = 0xC100,
        .capacity_sectors = 100,
        .queue = undefined,
        .dma_buffer_virt = undefined,
        .dma_buffer_phys = 0,
        .initialized = true,
    };
    var buf: [512]u8 = undefined;
    const err = dev.readSector(100, &buf);
    try std.testing.expectError(error.SectorOutOfBounds, err);
}

test "virtio blk batch sector validation" {
    var dev = VirtioBlkDevice{
        .io_base = 0xC100,
        .capacity_sectors = 100,
        .queue = undefined,
        .dma_buffer_virt = undefined,
        .dma_buffer_phys = 0,
        .initialized = true,
    };
    var buf: [4096]u8 = undefined;
    try std.testing.expectError(error.InvalidSectorCount, dev.readSectors(0, 0, &buf));
    try std.testing.expectError(error.InvalidSectorCount, dev.readSectors(0, 9, &buf));
    var small_buf: [511]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, dev.readSectors(0, 1, &small_buf));
    try std.testing.expectError(error.SectorOutOfBounds, dev.readSectors(98, 4, &buf));
}

test "virtio blk polymorphic block device interface" {
    var dev = VirtioBlkDevice{
        .io_base = 0xC100,
        .capacity_sectors = 500,
        .queue = undefined,
        .dma_buffer_virt = undefined,
        .dma_buffer_phys = 0,
        .initialized = true,
    };
    var bdev = dev.blockDevice();
    try std.testing.expectEqual(@as(u64, 500), bdev.total_sectors);
    try std.testing.expectEqual(@as(u32, 512), bdev.sector_size);
    try std.testing.expect(std.mem.startsWith(u8, &bdev.name, "virtio-blk"));

    var buf: [512]u8 = undefined;
    try std.testing.expectError(error.SectorOutOfBounds, bdev.readSector(500, &buf));
}
