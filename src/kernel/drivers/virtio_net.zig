// MicrOS (µOS) VirtIO Network Device Driver (virtio-net-pci)
// Implements VirtIO 1.0 split virtqueue packet transmission and reception.
// Zero libc, direct port I/O and page-aligned DMA ring buffers.

const std = @import("std");
const io = @import("../arch/x86_64/io.zig");
const pci = @import("pci.zig");
const pmm = @import("../mem/pmm.zig");

pub const QUEUE_SIZE: u16 = 256;
pub const RX_BUFFER_LEN: usize = 2048;
pub const NUM_RX_BUFFERS: u16 = 32;
pub const QUEUE_PAGES: usize = 3;
pub const MAX_PACKET_SIZE: usize = 1514;

pub const QUEUE_RX: u16 = 0;
pub const QUEUE_TX: u16 = 1;

pub const REG_DEVICE_FEATURES: u16 = 0x00;
pub const REG_GUEST_FEATURES: u16 = 0x04;
pub const REG_QUEUE_ADDRESS: u16 = 0x08;
pub const REG_QUEUE_SIZE: u16 = 0x0C;
pub const REG_QUEUE_SELECT: u16 = 0x0E;
pub const REG_QUEUE_NOTIFY: u16 = 0x10;
pub const REG_DEVICE_STATUS: u16 = 0x12;
pub const REG_ISR_STATUS: u16 = 0x13;
pub const REG_MAC_BASE: u16 = 0x14;

pub const STATUS_RESET: u8 = 0x00;
pub const STATUS_ACKNOWLEDGE: u8 = 0x01;
pub const STATUS_DRIVER: u8 = 0x02;
pub const STATUS_DRIVER_OK: u8 = 0x04;
pub const STATUS_FEATURES_OK: u8 = 0x08;
pub const STATUS_FAILED: u8 = 0x80;

pub const VRING_DESC_F_NEXT: u16 = 0x0001;
pub const VRING_DESC_F_WRITE: u16 = 0x0002;

pub const VirtioNetHeader = extern struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
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

pub const VirtioNetDevice = struct {
    io_base: u16,
    mac: [6]u8,
    rx_queue: VirtQueue,
    tx_queue: VirtQueue,
    rx_buffers_virt: [*]u8,
    rx_buffers_phys: u64,
    tx_buffer_virt: [*]u8,
    tx_buffer_phys: u64,
    initialized: bool,

    pub fn init(pci_dev: pci.PciDevice, rx_ring_page: u64, tx_ring_page: u64, buf_page_rx: u64, buf_page_tx: u64, hhdm_offset: u64) !VirtioNetDevice {
        const io_port = pci_dev.getIoPort(0) orelse return error.NoIoBar;
        pci_dev.enableBusMastering();

        io.outb(io_port + REG_DEVICE_STATUS, STATUS_RESET);
        io.outb(io_port + REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

        const mac = readMac(io_port);
        const queues = setupQueues(io_port, rx_ring_page, tx_ring_page, buf_page_rx, hhdm_offset);

        io.outb(io_port + REG_DEVICE_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_DRIVER_OK);
        io.outw(io_port + REG_QUEUE_NOTIFY, QUEUE_RX);

        return VirtioNetDevice{
            .io_base = io_port,
            .mac = mac,
            .rx_queue = queues.rx,
            .tx_queue = queues.tx,
            .rx_buffers_virt = @ptrFromInt(buf_page_rx + hhdm_offset),
            .rx_buffers_phys = buf_page_rx,
            .tx_buffer_virt = @ptrFromInt(buf_page_tx + hhdm_offset),
            .tx_buffer_phys = buf_page_tx,
            .initialized = true,
        };
    }

    pub fn sendPacket(self: *VirtioNetDevice, packet: []const u8) !void {
        if (packet.len > MAX_PACKET_SIZE) return error.PacketTooLarge;

        var wait_iter: usize = 0;
        while (self.tx_queue.avail.idx != self.tx_queue.used.idx and wait_iter < 100_000) : (wait_iter += 1) {
            io.ioWait();
        }

        const hdr_ptr: *VirtioNetHeader = @ptrCast(@alignCast(self.tx_buffer_virt));
        hdr_ptr.* = VirtioNetHeader{};
        @memcpy(self.tx_buffer_virt[@sizeOf(VirtioNetHeader) .. @sizeOf(VirtioNetHeader) + packet.len], packet);

        const total_len: u32 = @intCast(@sizeOf(VirtioNetHeader) + packet.len);
        self.tx_queue.descs[0] = VRingDesc{
            .addr = self.tx_buffer_phys,
            .len = total_len,
            .flags = 0,
            .next = 0,
        };

        const avail_idx = self.tx_queue.avail.idx;
        self.tx_queue.avail.ring[avail_idx % QUEUE_SIZE] = 0;
        asm volatile ("" ::: .{ .memory = true });
        self.tx_queue.avail.idx = avail_idx +% 1;

        io.outw(self.io_base + REG_QUEUE_NOTIFY, QUEUE_TX);

        wait_iter = 0;
        while (self.tx_queue.avail.idx != self.tx_queue.used.idx and wait_iter < 100_000) : (wait_iter += 1) {
            io.ioWait();
        }
    }


    pub fn pollReceive(self: *VirtioNetDevice, out_buffer: []u8) ?usize {
        if (self.rx_queue.last_used_idx == self.rx_queue.used.idx) return null;

        const used_idx = self.rx_queue.last_used_idx % QUEUE_SIZE;
        const elem = self.rx_queue.used.ring[used_idx];
        self.rx_queue.last_used_idx +%= 1;

        const desc_id = elem.id;
        const total_len = elem.len;
        const hdr_size = @sizeOf(VirtioNetHeader);

        if (total_len <= hdr_size) return 0;
        const payload_len = @min(total_len - hdr_size, out_buffer.len);

        const buf_offset = @as(usize, @intCast(desc_id)) * RX_BUFFER_LEN;
        const src = self.rx_buffers_virt[buf_offset + hdr_size .. buf_offset + hdr_size + payload_len];
        @memcpy(out_buffer[0..payload_len], src);

        // Recycle descriptor
        recycleRxDescriptor(&self.rx_queue, @intCast(desc_id));
        io.outw(self.io_base + REG_QUEUE_NOTIFY, QUEUE_RX);

        return payload_len;
    }
};

fn readMac(io_port: u16) [6]u8 {
    var mac: [6]u8 = undefined;
    for (0..6) |i| {
        mac[i] = io.inb(io_port + REG_MAC_BASE + @as(u16, @intCast(i)));
    }
    return mac;
}

const Queues = struct {
    rx: VirtQueue,
    tx: VirtQueue,
};

fn setupQueues(io_port: u16, rx_page: u64, tx_page: u64, buf_page_rx: u64, hhdm: u64) Queues {
    const rx_virt: [*]u8 = @ptrFromInt(rx_page + hhdm);
    const tx_virt: [*]u8 = @ptrFromInt(tx_page + hhdm);
    var rx_q = VirtQueue.init(QUEUE_RX, rx_page, rx_virt);
    const tx_q = VirtQueue.init(QUEUE_TX, tx_page, tx_virt);

    configureQueue(io_port, QUEUE_RX, rx_page);
    configureQueue(io_port, QUEUE_TX, tx_page);
    populateRxBuffers(&rx_q, buf_page_rx);

    return Queues{ .rx = rx_q, .tx = tx_q };
}

fn configureQueue(io_port: u16, queue_idx: u16, phys_addr: u64) void {
    io.outw(io_port + REG_QUEUE_SELECT, queue_idx);
    const pfn: u32 = @intCast(phys_addr / 4096);
    io.outl(io_port + REG_QUEUE_ADDRESS, pfn);
}

fn populateRxBuffers(rx_q: *VirtQueue, buf_phys: u64) void {
    var i: u16 = 0;
    while (i < NUM_RX_BUFFERS) : (i += 1) {
        rx_q.descs[i] = VRingDesc{
            .addr = buf_phys + (@as(u64, i) * RX_BUFFER_LEN),
            .len = @intCast(RX_BUFFER_LEN),
            .flags = VRING_DESC_F_WRITE,
            .next = 0,
        };
        rx_q.avail.ring[i] = i;
    }
    asm volatile ("" ::: .{ .memory = true });
    rx_q.avail.idx = NUM_RX_BUFFERS;
}

fn recycleRxDescriptor(rx_q: *VirtQueue, desc_id: u16) void {
    const avail_idx = rx_q.avail.idx;
    rx_q.avail.ring[avail_idx % QUEUE_SIZE] = desc_id;
    asm volatile ("" ::: .{ .memory = true });
    rx_q.avail.idx = avail_idx +% 1;
}

test "virtqueue layout and descriptor sizing" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(VRingDesc));
    try std.testing.expectEqual(@as(usize, 10), @sizeOf(VirtioNetHeader));
}

test "virtio net packet payload bounds" {
    var dev = VirtioNetDevice{
        .io_base = 0xC000,
        .mac = [_]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 },
        .rx_queue = undefined,
        .tx_queue = undefined,
        .rx_buffers_virt = undefined,
        .rx_buffers_phys = 0,
        .tx_buffer_virt = undefined,
        .tx_buffer_phys = 0,
        .initialized = false,
    };
    var oversized: [2000]u8 = undefined;
    const err = dev.sendPacket(&oversized);
    try std.testing.expectError(error.PacketTooLarge, err);
}
