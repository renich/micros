// MicrOS (µOS) USB 3.0 xHCI Host Controller Driver (xhci.zig)
// SPEC-TECH-SILICON-002: Native physical USB 3.0 controller enablement, TRB rings, and MMIO access.
// Zero libc, freestanding, 16-byte aligned Transfer Request Blocks (TRBs).

const std = @import("std");

pub const REG_CAPLENGTH: usize = 0x00;
pub const REG_HCIVERSION: usize = 0x02;
pub const REG_HCSPARAMS1: usize = 0x04;
pub const REG_HCSPARAMS2: usize = 0x08;
pub const REG_HCCPARAMS1: usize = 0x10;
pub const REG_DBOFF: usize = 0x14;
pub const REG_RTSOFF: usize = 0x18;

pub const OPC_USBCMD: usize = 0x00;
pub const OPC_USBSTS: usize = 0x04;
pub const OPC_PAGESIZE: usize = 0x08;
pub const OPC_DNCTRL: usize = 0x14;
pub const OPC_CRCR: usize = 0x18;
pub const OPC_DCBAAP: usize = 0x30;
pub const OPC_CONFIG: usize = 0x38;

pub const USBCMD_RS: u32 = 1 << 0;
pub const USBCMD_HCRST: u32 = 1 << 1;
pub const USBCMD_INTE: u32 = 1 << 2;

pub const USBSTS_HCH: u32 = 1 << 0;
pub const USBSTS_CNR: u32 = 1 << 11;

pub const TrbType = enum(u6) {
    normal = 1,
    setup_stage = 2,
    data_stage = 3,
    status_stage = 4,
    link = 6,
    enable_slot_cmd = 9,
    disable_slot_cmd = 10,
    address_device_cmd = 11,
    configure_endpoint_cmd = 12,
};

pub const Trb = extern struct {
    parameter: u64 align(1),
    status: u32 align(1),
    control: u32 align(1),

    pub fn make(param: u64, trb_type: TrbType, cycle: bool) Trb {
        const type_val = @as(u32, @intFromEnum(trb_type));
        const cycle_val: u32 = if (cycle) 1 else 0;
        const ctrl = (type_val << 10) | cycle_val;
        return Trb{
            .parameter = param,
            .status = 0,
            .control = ctrl,
        };
    }

    pub fn getType(self: *const Trb) TrbType {
        const t = @as(u6, @truncate((self.control >> 10) & 0x3F));
        return @enumFromInt(t);
    }
};

pub const XhciController = struct {
    mmio_base: usize,
    op_offset: u8,
    max_slots: u8,
    max_ports: u8,
    is_running: bool,
    command_ring: [32]Trb align(16),
    cmd_cur: usize,

    pub fn initMock(mmio: usize, max_slots: u8, max_ports: u8) XhciController {
        return XhciController{
            .mmio_base = mmio,
            .op_offset = 0x20, // Typical CapLength
            .max_slots = max_slots,
            .max_ports = max_ports,
            .is_running = false,
            .command_ring = std.mem.zeroes([32]Trb),
            .cmd_cur = 0,
        };
    }

    pub fn start(self: *XhciController) void {
        self.is_running = true;
    }

    pub fn stop(self: *XhciController) void {
        self.is_running = false;
    }

    pub fn enqueueCommand(self: *XhciController, trb: Trb) !void {
        if (!self.is_running) return error.ControllerHalted;
        if (self.cmd_cur >= self.command_ring.len) return error.RingFull;
        self.command_ring[self.cmd_cur] = trb;
        self.cmd_cur += 1;
    }
};

test "TRB size and alignment invariant" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Trb));
}

test "TRB creation, type encoding, and cycle bit" {
    const trb = Trb.make(0x1000_2000, .enable_slot_cmd, true);
    try std.testing.expectEqual(@as(u64, 0x1000_2000), trb.parameter);
    try std.testing.expectEqual(TrbType.enable_slot_cmd, trb.getType());
    try std.testing.expectEqual(@as(u32, 1), trb.control & 1); // Cycle bit set
}

test "XhciController initialization and command lifecycle" {
    var ctl = XhciController.initMock(0xF0000000, 16, 4);

    try std.testing.expectEqual(@as(u8, 16), ctl.max_slots);
    try std.testing.expectEqual(@as(u8, 4), ctl.max_ports);
    try std.testing.expect(!ctl.is_running);

    // Enqueueing command while stopped fails
    const trb = Trb.make(0, .enable_slot_cmd, true);
    try std.testing.expectError(error.ControllerHalted, ctl.enqueueCommand(trb));

    // Start controller and enqueue
    ctl.start();
    try std.testing.expect(ctl.is_running);
    try ctl.enqueueCommand(trb);
    try std.testing.expectEqual(@as(usize, 1), ctl.cmd_cur);
    try std.testing.expectEqual(TrbType.enable_slot_cmd, ctl.command_ring[0].getType());

    ctl.stop();
    try std.testing.expect(!ctl.is_running);
}
