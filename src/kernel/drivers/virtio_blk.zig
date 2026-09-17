// MicrOS (µOS) VirtIO Block Device Driver (virtio-blk-pci)
// Implements VirtIO 1.0 split virtqueue sector read and write transactions.
// Zero libc, direct port I/O and page-aligned DMA ring buffers.

const std = @import("std");
const io = @import("../arch/x86_64/io.zig");
const pci = @import("pci.zig");
const serial = @import("../serial.zig");

pub const QUEUE_SIZE: u16 = 256;
pub const QUEUE_PAGES: usize = 3;
pub const SECTOR_SIZE: usize = 512;
pub const QUEUE_INDEX: u16 = 0;

pub const REG_DEVICE_FEATURES: u16 = 0x00;
pub const REG_GUEST_FEATURES: u16 = 0x04;
pub const REG_QUEUE_ADDRESS: u16 = 0x08;
pub const REG_QUEUE_SIZE: u16 = 0x0C;
pub const REG_QUEUE_SELECT: u16 = 0x0E;
pub const REG_QUEUE_NOTIFY: u16 = 0x10;
pub const REG_DEVICE_STATUS: u16 = 0x12;
pub const REG_ISR_STATUS: u16 = 0x13;
pub const REG_CAPACITY_LOW: u16 = 0x14;
pub const REG_CAPACITY_HIGH: u16 = 0x18;

pub const STATUS_RESET: u8 = 0x00;
pub const STATUS_ACKNOWLEDGE: u8 = 0x01;
pub const STATUS_DRIVER: u8 = 0x02;
pub const STATUS_DRIVER_OK: u8 = 0x04;
pub const STATUS_FEATURES_OK: u8 = 0x08;
pub const STATUS_FAILED: u8 = 0x80;

pub const VRING_DESC_F_NEXT: u16 = 0x0001;
pub const VRING_DESC_F_WRITE: u16 = 0x0002;

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

pub const VRingDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

pub const VRingAvail = extern struct {
    flags: u16,
    idx: u16,
    ring: [QUEUE_SIZE]u16,
    used_event: u16,
};

pub const VRingUsedElem = extern struct {
    id: u32,
    len: u32,
};

pub const VRingUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [QUEUE_SIZE]VRingUsedElem,
    avail_event: u16,
};

pub const VirtQueue = struct {
    queue_index: u16,
    num_descs: u16,
    descs: [*]VRingDesc,
    avail: *VRingAvail,
    used: *VRingUsed,
    last_used_idx: u16,
    ring_phys: u64,

    pub fn init(queue_index: u16, mem_phys: u64, mem_virt: [*]u8) VirtQueue {
        @memset(mem_virt[0 .. QUEUE_PAGES * 4096], 0);

        const desc_size = @as(usize, QUEUE_SIZE) * @sizeOf(VRingDesc);
        const avail_size = @sizeOf(VRingAvail);
        const avail_offset = desc_size;
        const used_offset = std.mem.alignForward(usize, desc_size + avail_size, 4096);

        const descs: [*]VRingDesc = @ptrCast(@alignCast(mem_virt));
        const avail: *VRingAvail = @ptrCast(@alignCast(mem_virt + avail_offset));
        const used: *VRingUsed = @ptrCast(@alignCast(mem_virt + used_offset));

        avail.flags = 0;
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
        const dev_q_size = io.inw(io_port + REG_QUEUE_SIZE);
        serial.writeString("[virtio-blk] Device reported queue size: 0x");
        serial.writeHex(dev_q_size);
        serial.writeString("\n");

        const pfn: u32 = @intCast(ring_page_phys / 4096);
        io.outl(io_port + REG_QUEUE_ADDRESS, pfn);

        io.outb(io_port + REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_DRIVER_OK);

        const dma_virt: [*]u8 = @ptrFromInt(dma_page_phys + hhdm_offset);
        @memset(dma_virt[0..4096], 0);

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
        if (!self.initialized) return error.DeviceNotInitialized;
        if (sector >= self.capacity_sectors) return error.SectorOutOfBounds;

        const hdr_ptr: *VirtioBlkOutHdr = @ptrCast(@alignCast(self.dma_buffer_virt));
        hdr_ptr.* = VirtioBlkOutHdr{
            .type = VIRTIO_BLK_T_IN,
            .ioprio = 0,
            .sector = sector,
        };

        const status_offset: usize = @sizeOf(VirtioBlkOutHdr) + SECTOR_SIZE;
        self.dma_buffer_virt[status_offset] = @intFromEnum(VirtioBlkStatus.pending);

        const data_phys = self.dma_buffer_phys + @sizeOf(VirtioBlkOutHdr);
        const status_phys = self.dma_buffer_phys + status_offset;

        self.setupDescChain(self.dma_buffer_phys, data_phys, status_phys, VRING_DESC_F_WRITE);
        try self.submitAndWait();

        const status_val = self.dma_buffer_virt[status_offset];
        if (status_val != @intFromEnum(VirtioBlkStatus.ok)) return error.IoError;

        const data_slice = self.dma_buffer_virt[@sizeOf(VirtioBlkOutHdr) .. @sizeOf(VirtioBlkOutHdr) + SECTOR_SIZE];
        @memcpy(out_buf, data_slice);
    }

    pub fn writeSector(self: *VirtioBlkDevice, sector: u64, in_buf: *const [SECTOR_SIZE]u8) !void {
        if (!self.initialized) return error.DeviceNotInitialized;
        if (sector >= self.capacity_sectors) return error.SectorOutOfBounds;

        const hdr_ptr: *VirtioBlkOutHdr = @ptrCast(@alignCast(self.dma_buffer_virt));
        hdr_ptr.* = VirtioBlkOutHdr{
            .type = VIRTIO_BLK_T_OUT,
            .ioprio = 0,
            .sector = sector,
        };

        const data_slice = self.dma_buffer_virt[@sizeOf(VirtioBlkOutHdr) .. @sizeOf(VirtioBlkOutHdr) + SECTOR_SIZE];
        @memcpy(data_slice, in_buf);

        const status_offset: usize = @sizeOf(VirtioBlkOutHdr) + SECTOR_SIZE;
        self.dma_buffer_virt[status_offset] = @intFromEnum(VirtioBlkStatus.pending);

        const data_phys = self.dma_buffer_phys + @sizeOf(VirtioBlkOutHdr);
        const status_phys = self.dma_buffer_phys + status_offset;

        self.setupDescChain(self.dma_buffer_phys, data_phys, status_phys, 0);
        try self.submitAndWait();

        const status_val = self.dma_buffer_virt[status_offset];
        if (status_val != @intFromEnum(VirtioBlkStatus.ok)) return error.IoError;
    }

    fn setupDescChain(self: *VirtioBlkDevice, hdr_phys: u64, data_phys: u64, status_phys: u64, data_extra_flag: u16) void {
        self.queue.descs[0] = VRingDesc{
            .addr = hdr_phys,
            .len = @sizeOf(VirtioBlkOutHdr),
            .flags = VRING_DESC_F_NEXT,
            .next = 1,
        };
        self.queue.descs[1] = VRingDesc{
            .addr = data_phys,
            .len = SECTOR_SIZE,
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
        const avail_ptr: *volatile VRingAvail = @ptrCast(self.queue.avail);
        const avail_idx = avail_ptr.idx;
        avail_ptr.ring[avail_idx % QUEUE_SIZE] = 0;
        asm volatile ("" ::: .{ .memory = true });
        avail_ptr.idx = avail_idx +% 1;
        asm volatile ("" ::: .{ .memory = true });

        io.outw(self.io_base + REG_QUEUE_NOTIFY, QUEUE_INDEX);

        const used_ptr: *volatile VRingUsed = @ptrCast(self.queue.used);
        var wait_iter: usize = 0;
        while (used_ptr.idx == self.queue.last_used_idx and wait_iter < 1_000_000) : (wait_iter += 1) {
            io.ioWait();
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
