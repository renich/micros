// MicrOS (µOS) PCIe NVMe 1.4 Solid-State Storage Controller Driver
// Implements polled NVMe 1.4 Admin/IO queue pairs, PRP chaining, and BlockDevice interface.
// Zero libc, freestanding, 4096-byte DMA alignment, 512-byte sector transfers.

const std = @import("std");
const block = @import("block.zig");
const pci = @import("pci.zig");
const io = @import("../arch/x86_64/io.zig");
const serial = @import("../serial.zig");

pub const SECTOR_SIZE: usize = 512;
pub const PAGE_SIZE: usize = 4096;
pub const ADMIN_QUEUE_SIZE: u16 = 64;
pub const IO_QUEUE_SIZE: u16 = 64;
pub const MAX_BATCH_SECTORS: usize = 128; // Up to 64 KiB (16 pages)
pub const DEFAULT_TIMEOUT_CYCLES: usize = 10_000_000;

// MMIO Register Offsets
pub const REG_CAP: usize = 0x0000;
pub const REG_VS: usize = 0x0008;
pub const REG_INTMS: usize = 0x000C;
pub const REG_INTMC: usize = 0x0010;
pub const REG_CC: usize = 0x0014;
pub const REG_CSTS: usize = 0x001C;
pub const REG_NSSR: usize = 0x0020;
pub const REG_AQA: usize = 0x0024;
pub const REG_ASQ: usize = 0x0028;
pub const REG_ACQ: usize = 0x0030;
pub const DOORBELL_BASE: usize = 0x1000;

// Register Bitmasks
pub const CC_EN: u32 = 1 << 0;
pub const CC_CSS_NVM: u32 = 0 << 4;
pub const CC_MPS_4K: u32 = 0 << 7;
pub const CC_IOSQES_64B: u32 = 6 << 16;
pub const CC_IOCQES_16B: u32 = 4 << 20;

pub const CSTS_RDY: u32 = 1 << 0;
pub const CSTS_CFS: u32 = 1 << 1;

// Admin Opcodes
pub const NVME_ADMIN_DELETE_IO_SQ: u8 = 0x00;
pub const NVME_ADMIN_CREATE_IO_SQ: u8 = 0x01;
pub const NVME_ADMIN_DELETE_IO_CQ: u8 = 0x04;
pub const NVME_ADMIN_CREATE_IO_CQ: u8 = 0x05;
pub const NVME_ADMIN_IDENTIFY: u8 = 0x06;

// NVM I/O Opcodes
pub const NVME_NVM_FLUSH: u8 = 0x00;
pub const NVME_NVM_WRITE: u8 = 0x01;
pub const NVME_NVM_READ: u8 = 0x02;

// Identify CNS Codes
pub const NVME_CNS_IDENTIFY_NAMESPACE: u8 = 0x00;
pub const NVME_CNS_IDENTIFY_CONTROLLER: u8 = 0x01;

// 64-byte Submission Queue Entry (SQE)
pub const NvmeSqe = extern struct {
    cdw0: u32,
    nsid: u32,
    cdw2: u32 = 0,
    cdw3: u32 = 0,
    mptr: u64 = 0,
    prp1: u64 = 0,
    prp2: u64 = 0,
    cdw10: u32 = 0,
    cdw11: u32 = 0,
    cdw12: u32 = 0,
    cdw13: u32 = 0,
    cdw14: u32 = 0,
    cdw15: u32 = 0,

    pub fn make(opcode: u8, flags: u8, cid: u16, nsid: u32) NvmeSqe {
        const cdw0 = @as(u32, opcode) | (@as(u32, flags) << 8) | (@as(u32, cid) << 16);
        return NvmeSqe{
            .cdw0 = cdw0,
            .nsid = nsid,
        };
    }
};

// 16-byte Completion Queue Entry (CQE)
pub const NvmeCqe = extern struct {
    result: u32,
    reserved: u32,
    sq_head: u16,
    sq_id: u16,
    cid: u16,
    status: u16,

    pub inline fn phase(self: NvmeCqe) u1 {
        return @truncate(self.status & 1);
    }

    pub inline fn statusCode(self: NvmeCqe) u8 {
        return @truncate((self.status >> 1) & 0xFF);
    }

    pub inline fn statusCodeType(self: NvmeCqe) u3 {
        return @truncate((self.status >> 9) & 0x07);
    }

    pub inline fn isSuccess(self: NvmeCqe) bool {
        return ((self.status >> 1) & 0x7FF) == 0;
    }
};

pub inline fn readMmio32(addr: u64) u32 {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    return ptr.*;
}

pub inline fn writeMmio32(addr: u64, val: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(addr);
    ptr.* = val;
}

pub inline fn readMmio64(addr: u64) u64 {
    const low = @as(u64, readMmio32(addr));
    const high = @as(u64, readMmio32(addr + 4));
    return (high << 32) | low;
}

pub inline fn writeMmio64(addr: u64, val: u64) void {
    writeMmio32(addr, @truncate(val));
    writeMmio32(addr + 4, @truncate(val >> 32));
}

pub fn calcDoorbellOffset(qid: u16, is_cq: bool, dstrd: u4) usize {
    const stride = @as(usize, 4) << dstrd;
    const index = (2 * @as(usize, qid)) + (if (is_cq) @as(usize, 1) else 0);
    return DOORBELL_BASE + (index * stride);
}

pub fn calcPrpChaining(
    dma_phys: u64,
    total_bytes: usize,
    prp_list_phys: u64,
    prp_list: [*]u64,
) struct { prp1: u64, prp2: u64 } {
    const prp1 = dma_phys;
    if (total_bytes <= PAGE_SIZE) {
        return .{ .prp1 = prp1, .prp2 = 0 };
    }
    if (total_bytes <= 2 * PAGE_SIZE) {
        return .{ .prp1 = prp1, .prp2 = dma_phys + PAGE_SIZE };
    }
    const pages = (total_bytes + PAGE_SIZE - 1) / PAGE_SIZE;
    var i: usize = 0;
    while (i < pages - 1) : (i += 1) {
        prp_list[i] = dma_phys + (i + 1) * PAGE_SIZE;
    }
    return .{ .prp1 = prp1, .prp2 = prp_list_phys };
}

pub const NvmeQueue = struct {
    qid: u16,
    size: u16,
    sq_cmds: [*]NvmeSqe,
    cq_entries: [*]volatile NvmeCqe,
    sq_tail: u16,
    cq_head: u16,
    cq_phase: u1,
    sq_doorbell: usize,
    cq_doorbell: usize,
    sq_phys: u64,
    cq_phys: u64,

    pub fn init(qid: u16, size: u16, sq_phys: u64, sq_virt: [*]u8, cq_phys: u64, cq_virt: [*]u8, dstrd: u4) NvmeQueue {
        @memset(sq_virt[0 .. @as(usize, size) * @sizeOf(NvmeSqe)], 0);
        @memset(cq_virt[0 .. @as(usize, size) * @sizeOf(NvmeCqe)], 0);
        return NvmeQueue{
            .qid = qid,
            .size = size,
            .sq_cmds = @ptrCast(@alignCast(sq_virt)),
            .cq_entries = @ptrCast(@alignCast(cq_virt)),
            .sq_tail = 0,
            .cq_head = 0,
            .cq_phase = 1,
            .sq_doorbell = calcDoorbellOffset(qid, false, dstrd),
            .cq_doorbell = calcDoorbellOffset(qid, true, dstrd),
            .sq_phys = sq_phys,
            .cq_phys = cq_phys,
        };
    }

    pub fn submit(self: *NvmeQueue, cmd: NvmeSqe, mmio_base: u64) void {
        const slot = self.sq_tail;
        self.sq_cmds[slot] = cmd;
        self.sq_tail = (self.sq_tail + 1) % self.size;
        asm volatile ("" ::: .{ .memory = true });
        writeMmio32(mmio_base + self.sq_doorbell, self.sq_tail);
    }

    pub fn pollCompletion(self: *NvmeQueue, cid: u16, mmio_base: u64) !NvmeCqe {
        var iter: usize = 0;
        while (self.cq_entries[self.cq_head].phase() != self.cq_phase) : (iter += 1) {
            if (iter >= DEFAULT_TIMEOUT_CYCLES) return error.DeviceTimeout;
            io.pause();
        }
        asm volatile ("lfence" ::: .{ .memory = true });
        const cqe = self.cq_entries[self.cq_head];
        if (cqe.cid != cid) return error.CommandIdMismatch;
        if (!cqe.isSuccess()) return error.NvmeCommandFailed;

        self.cq_head = (self.cq_head + 1) % self.size;
        if (self.cq_head == 0) self.cq_phase ^= 1;
        writeMmio32(mmio_base + self.cq_doorbell, self.cq_head);
        return cqe;
    }
};

pub const NvmeDevice = struct {
    mmio_base: u64,
    dstrd: u4,
    admin_q: NvmeQueue,
    io_q: NvmeQueue,
    nsid: u32,
    total_sectors: u64,
    sector_size: u32,
    sector_shift: u5,
    dma_buf_phys: u64,
    dma_buf_virt: [*]u8,
    prp_list_phys: u64,
    prp_list_virt: [*]u64,
    next_cid: u16,
    initialized: bool,

    pub fn init(
        pci_dev: pci.PciDevice,
        asq_phys: u64,
        asq_virt: [*]u8,
        acq_phys: u64,
        acq_virt: [*]u8,
        iosq_phys: u64,
        iosq_virt: [*]u8,
        iocq_phys: u64,
        iocq_virt: [*]u8,
        prp_list_phys: u64,
        prp_list_virt: [*]u8,
        dma_phys: u64,
        dma_virt: [*]u8,
    ) !NvmeDevice {
        const mmio = pci_dev.getMmioAddr(0) orelse return error.NoMmioBar;
        pci_dev.enableBusMastering();

        const cap = readMmio64(mmio + REG_CAP);
        const dstrd: u4 = @truncate((cap >> 32) & 0x0F);
        const timeout_val: u8 = @truncate((cap >> 24) & 0xFF);

        try resetController(mmio, timeout_val);
        const admin_q = setupAdminQueues(mmio, asq_phys, asq_virt, acq_phys, acq_virt, dstrd);
        try enableController(mmio, timeout_val);

        var dev = createDeviceInstance(mmio, dstrd, admin_q, dma_phys, dma_virt, prp_list_phys, prp_list_virt);
        try dev.identifyNamespace();
        dev.io_q = NvmeQueue.init(1, IO_QUEUE_SIZE, iosq_phys, iosq_virt, iocq_phys, iocq_virt, dstrd);
        try dev.createIoQueues();
        dev.initialized = true;
        return dev;
    }

    fn setupAdminQueues(mmio: u64, asq_phys: u64, asq_virt: [*]u8, acq_phys: u64, acq_virt: [*]u8, dstrd: u4) NvmeQueue {
        const admin_q = NvmeQueue.init(0, ADMIN_QUEUE_SIZE, asq_phys, asq_virt, acq_phys, acq_virt, dstrd);
        writeMmio32(mmio + REG_AQA, (@as(u32, ADMIN_QUEUE_SIZE - 1) << 16) | (ADMIN_QUEUE_SIZE - 1));
        writeMmio64(mmio + REG_ASQ, asq_phys);
        writeMmio64(mmio + REG_ACQ, acq_phys);
        return admin_q;
    }

    fn createDeviceInstance(
        mmio: u64,
        dstrd: u4,
        admin_q: NvmeQueue,
        dma_phys: u64,
        dma_virt: [*]u8,
        prp_list_phys: u64,
        prp_list_virt: [*]u8,
    ) NvmeDevice {
        return NvmeDevice{
            .mmio_base = mmio,
            .dstrd = dstrd,
            .admin_q = admin_q,
            .io_q = undefined,
            .nsid = 1,
            .total_sectors = 0,
            .sector_size = SECTOR_SIZE,
            .sector_shift = 9,
            .dma_buf_phys = dma_phys,
            .dma_buf_virt = dma_virt,
            .prp_list_phys = prp_list_phys,
            .prp_list_virt = @ptrCast(@alignCast(prp_list_virt)),
            .next_cid = 1,
            .initialized = false,
        };
    }

    fn resetController(mmio: u64, to_val: u8) !void {
        const cc = readMmio32(mmio + REG_CC);
        if ((cc & CC_EN) != 0) {
            writeMmio32(mmio + REG_CC, cc & ~CC_EN);
        }
        const max_iter = @max(@as(usize, to_val) * 100_000, 1_000_000);
        var iter: usize = 0;
        while ((readMmio32(mmio + REG_CSTS) & CSTS_RDY) != 0) : (iter += 1) {
            if (iter >= max_iter) return error.DeviceTimeout;
            if ((readMmio32(mmio + REG_CSTS) & CSTS_CFS) != 0) return error.ControllerFatalError;
            io.pause();
        }
    }

    fn enableController(mmio: u64, to_val: u8) !void {
        const cc_cfg = CC_EN | CC_CSS_NVM | CC_MPS_4K | CC_IOSQES_64B | CC_IOCQES_16B;
        writeMmio32(mmio + REG_CC, cc_cfg);

        const max_iter = @max(@as(usize, to_val) * 100_000, 1_000_000);
        var iter: usize = 0;
        while ((readMmio32(mmio + REG_CSTS) & CSTS_RDY) == 0) : (iter += 1) {
            if (iter >= max_iter) return error.DeviceTimeout;
            if ((readMmio32(mmio + REG_CSTS) & CSTS_CFS) != 0) return error.ControllerFatalError;
            io.pause();
        }
    }

    fn identifyNamespace(self: *NvmeDevice) !void {
        const cid = self.allocCid();
        var cmd = NvmeSqe.make(NVME_ADMIN_IDENTIFY, 0, cid, self.nsid);
        cmd.prp1 = self.dma_buf_phys;
        cmd.cdw10 = NVME_CNS_IDENTIFY_NAMESPACE;

        self.admin_q.submit(cmd, self.mmio_base);
        _ = try self.admin_q.pollCompletion(cid, self.mmio_base);

        const nsze = std.mem.readInt(u64, self.dma_buf_virt[0..8], .little);
        const flbas = self.dma_buf_virt[26];
        const lbaf_idx = flbas & 0x0F;
        const lbaf_offset = 128 + @as(usize, lbaf_idx) * 4;
        const lbads = self.dma_buf_virt[lbaf_offset + 2];

        self.total_sectors = nsze;
        self.sector_shift = if (lbads >= 9 and lbads <= 14) @truncate(lbads) else 9;
        self.sector_size = @as(u32, 1) << self.sector_shift;
    }

    fn createIoQueues(self: *NvmeDevice) !void {
        const cq_cid = self.allocCid();
        var cq_cmd = NvmeSqe.make(NVME_ADMIN_CREATE_IO_CQ, 0, cq_cid, 0);
        cq_cmd.prp1 = self.io_q.cq_phys;
        cq_cmd.cdw10 = (@as(u32, IO_QUEUE_SIZE - 1) << 16) | 1;
        cq_cmd.cdw11 = 0x0001; // Physically contiguous
        self.admin_q.submit(cq_cmd, self.mmio_base);
        _ = try self.admin_q.pollCompletion(cq_cid, self.mmio_base);

        const sq_cid = self.allocCid();
        var sq_cmd = NvmeSqe.make(NVME_ADMIN_CREATE_IO_SQ, 0, sq_cid, 0);
        sq_cmd.prp1 = self.io_q.sq_phys;
        sq_cmd.cdw10 = (@as(u32, IO_QUEUE_SIZE - 1) << 16) | 1;
        sq_cmd.cdw11 = (1 << 16) | 0x0001; // CQID = 1, Physically contiguous
        self.admin_q.submit(sq_cmd, self.mmio_base);
        _ = try self.admin_q.pollCompletion(sq_cid, self.mmio_base);
    }

    pub fn allocCid(self: *NvmeDevice) u16 {
        const cid = self.next_cid;
        self.next_cid +%= 1;
        if (self.next_cid == 0) self.next_cid = 1;
        return cid;
    }

    pub fn readSectors(self: *NvmeDevice, lba: u64, count: usize, buf: []u8) !void {
        if (count == 0 or count > MAX_BATCH_SECTORS) return error.InvalidSectorCount;
        if (buf.len < count * self.sector_size) return error.BufferTooSmall;
        if (lba + count > self.total_sectors) return error.SectorOutOfBounds;

        const total_bytes = count * self.sector_size;
        const prps = calcPrpChaining(self.dma_buf_phys, total_bytes, self.prp_list_phys, self.prp_list_virt);

        const cid = self.allocCid();
        var cmd = NvmeSqe.make(NVME_NVM_READ, 0, cid, self.nsid);
        cmd.prp1 = prps.prp1;
        cmd.prp2 = prps.prp2;
        cmd.cdw10 = @truncate(lba);
        cmd.cdw11 = @truncate(lba >> 32);
        cmd.cdw12 = @intCast(count - 1);

        self.io_q.submit(cmd, self.mmio_base);
        _ = try self.io_q.pollCompletion(cid, self.mmio_base);
        @memcpy(buf[0..total_bytes], self.dma_buf_virt[0..total_bytes]);
    }

    pub fn writeSectors(self: *NvmeDevice, lba: u64, count: usize, buf: []const u8) !void {
        if (count == 0 or count > MAX_BATCH_SECTORS) return error.InvalidSectorCount;
        if (buf.len < count * self.sector_size) return error.BufferTooSmall;
        if (lba + count > self.total_sectors) return error.SectorOutOfBounds;

        const total_bytes = count * self.sector_size;
        @memcpy(self.dma_buf_virt[0..total_bytes], buf[0..total_bytes]);
        const prps = calcPrpChaining(self.dma_buf_phys, total_bytes, self.prp_list_phys, self.prp_list_virt);

        const cid = self.allocCid();
        var cmd = NvmeSqe.make(NVME_NVM_WRITE, 0, cid, self.nsid);
        cmd.prp1 = prps.prp1;
        cmd.prp2 = prps.prp2;
        cmd.cdw10 = @truncate(lba);
        cmd.cdw11 = @truncate(lba >> 32);
        cmd.cdw12 = @intCast(count - 1);

        self.io_q.submit(cmd, self.mmio_base);
        _ = try self.io_q.pollCompletion(cid, self.mmio_base);
    }

    pub fn flush(self: *NvmeDevice) !void {
        const cid = self.allocCid();
        const cmd = NvmeSqe.make(NVME_NVM_FLUSH, 0, cid, self.nsid);
        self.io_q.submit(cmd, self.mmio_base);
        _ = try self.io_q.pollCompletion(cid, self.mmio_base);
    }

    pub fn blockDevice(self: *NvmeDevice) block.BlockDevice {
        var dev = block.BlockDevice{
            .ptr = @ptrCast(self),
            .vtable = &nvme_vtable,
            .total_sectors = self.total_sectors,
            .sector_size = self.sector_size,
        };
        const dev_name = "nvme0n1";
        @memcpy(dev.name[0..dev_name.len], dev_name);
        return dev;
    }

    const nvme_vtable = block.BlockDevice.VTable{
        .readSector = vtableReadSector,
        .writeSector = vtableWriteSector,
        .readSectors = vtableReadSectors,
        .writeSectors = vtableWriteSectors,
        .flush = vtableFlush,
    };

    fn vtableReadSector(ctx: *anyopaque, lba: u64, buf: *[SECTOR_SIZE]u8) anyerror!void {
        const self: *NvmeDevice = @ptrCast(@alignCast(ctx));
        return self.readSectors(lba, 1, buf);
    }

    fn vtableWriteSector(ctx: *anyopaque, lba: u64, buf: *const [SECTOR_SIZE]u8) anyerror!void {
        const self: *NvmeDevice = @ptrCast(@alignCast(ctx));
        return self.writeSectors(lba, 1, buf);
    }

    fn vtableReadSectors(ctx: *anyopaque, lba: u64, count: usize, buf: []u8) anyerror!void {
        const self: *NvmeDevice = @ptrCast(@alignCast(ctx));
        return self.readSectors(lba, count, buf);
    }

    fn vtableWriteSectors(ctx: *anyopaque, lba: u64, count: usize, buf: []const u8) anyerror!void {
        const self: *NvmeDevice = @ptrCast(@alignCast(ctx));
        return self.writeSectors(lba, count, buf);
    }

    fn vtableFlush(ctx: *anyopaque) anyerror!void {
        const self: *NvmeDevice = @ptrCast(@alignCast(ctx));
        return self.flush();
    }
};

test "nvme structure sizes" {
    try std.testing.expectEqual(64, @sizeOf(NvmeSqe));
    try std.testing.expectEqual(16, @sizeOf(NvmeCqe));
}

test "nvme cqe status and phase parsing" {
    const success_cqe = NvmeCqe{
        .result = 0,
        .reserved = 0,
        .sq_head = 5,
        .sq_id = 1,
        .cid = 42,
        .status = 0x0001, // Phase = 1, Status = 0 (Success)
    };
    try std.testing.expectEqual(@as(u1, 1), success_cqe.phase());
    try std.testing.expect(success_cqe.isSuccess());
    try std.testing.expectEqual(@as(u8, 0), success_cqe.statusCode());

    const error_cqe = NvmeCqe{
        .result = 0,
        .reserved = 0,
        .sq_head = 5,
        .sq_id = 1,
        .cid = 42,
        .status = 0x0002, // Phase = 0, Status = 1 (LBA Out of Range)
    };
    try std.testing.expectEqual(@as(u1, 0), error_cqe.phase());
    try std.testing.expect(!error_cqe.isSuccess());
    try std.testing.expectEqual(@as(u8, 1), error_cqe.statusCode());
}

test "nvme doorbell offset calculation" {
    // DSTRD = 0 (4 bytes stride)
    try std.testing.expectEqual(@as(usize, 0x1000), calcDoorbellOffset(0, false, 0)); // SQ0
    try std.testing.expectEqual(@as(usize, 0x1004), calcDoorbellOffset(0, true, 0)); // CQ0
    try std.testing.expectEqual(@as(usize, 0x1008), calcDoorbellOffset(1, false, 0)); // SQ1
    try std.testing.expectEqual(@as(usize, 0x100C), calcDoorbellOffset(1, true, 0)); // CQ1

    // DSTRD = 1 (8 bytes stride)
    try std.testing.expectEqual(@as(usize, 0x1000), calcDoorbellOffset(0, false, 1));
    try std.testing.expectEqual(@as(usize, 0x1008), calcDoorbellOffset(0, true, 1));
    try std.testing.expectEqual(@as(usize, 0x1010), calcDoorbellOffset(1, false, 1));
    try std.testing.expectEqual(@as(usize, 0x1018), calcDoorbellOffset(1, true, 1));
}

test "nvme prp chaining calculation" {
    var prp_list: [512]u64 = [_]u64{0} ** 512;

    // Single page (4 KiB)
    const prp_1p = calcPrpChaining(0x10000, 4096, 0x20000, &prp_list);
    try std.testing.expectEqual(@as(u64, 0x10000), prp_1p.prp1);
    try std.testing.expectEqual(@as(u64, 0), prp_1p.prp2);

    // Two pages (8 KiB)
    const prp_2p = calcPrpChaining(0x10000, 8192, 0x20000, &prp_list);
    try std.testing.expectEqual(@as(u64, 0x10000), prp_2p.prp1);
    try std.testing.expectEqual(@as(u64, 0x11000), prp_2p.prp2);

    // Three pages (12 KiB) -> PRP list used
    const prp_3p = calcPrpChaining(0x10000, 12288, 0x20000, &prp_list);
    try std.testing.expectEqual(@as(u64, 0x10000), prp_3p.prp1);
    try std.testing.expectEqual(@as(u64, 0x20000), prp_3p.prp2);
    try std.testing.expectEqual(@as(u64, 0x11000), prp_list[0]);
    try std.testing.expectEqual(@as(u64, 0x12000), prp_list[1]);
}

test "nvme block device interface mock" {
    var dev = NvmeDevice{
        .mmio_base = 0,
        .dstrd = 0,
        .admin_q = undefined,
        .io_q = undefined,
        .nsid = 1,
        .total_sectors = 1000,
        .sector_size = 512,
        .sector_shift = 9,
        .dma_buf_phys = 0,
        .dma_buf_virt = undefined,
        .prp_list_phys = 0,
        .prp_list_virt = undefined,
        .next_cid = 1,
        .initialized = true,
    };
    var bdev = dev.blockDevice();
    try std.testing.expectEqual(@as(u64, 1000), bdev.total_sectors);
    try std.testing.expectEqual(@as(u32, 512), bdev.sector_size);
    try std.testing.expect(std.mem.startsWith(u8, &bdev.name, "nvme0n1"));
}
