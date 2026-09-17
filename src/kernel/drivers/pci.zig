// MicrOS (µOS) PCI Bus Enumerator & Configuration Access
// Discovers PCI devices, reads Base Address Registers (BARs), and configures bus mastering.
// Independent of libc and host kernel services.

const std = @import("std");
const io = @import("../arch/x86_64/io.zig");

pub const PCI_CONFIG_ADDRESS: u16 = 0xCF8;
pub const PCI_CONFIG_DATA: u16 = 0xCFC;
pub const PCI_ENABLE_BIT: u32 = 0x8000_0000;
pub const PCI_VENDOR_INVALID: u16 = 0xFFFF;

pub const REG_VENDOR_ID: u8 = 0x00;
pub const REG_DEVICE_ID: u8 = 0x02;
pub const REG_COMMAND: u8 = 0x04;
pub const REG_STATUS: u8 = 0x06;
pub const REG_PROG_IF: u8 = 0x09;
pub const REG_SUBCLASS: u8 = 0x0A;
pub const REG_CLASS_CODE: u8 = 0x0B;
pub const REG_HEADER_TYPE: u8 = 0x0E;
pub const REG_BAR0: u8 = 0x10;
pub const REG_INTERRUPT_LINE: u8 = 0x3C;

pub const CMD_IO_SPACE: u16 = 0x0001;
pub const CMD_MEMORY_SPACE: u16 = 0x0002;
pub const CMD_BUS_MASTER: u16 = 0x0004;

pub const CLASS_STORAGE: u8 = 0x01;
pub const CLASS_NETWORK: u8 = 0x02;
pub const CLASS_DISPLAY: u8 = 0x03;
pub const SUBCLASS_ETHERNET: u8 = 0x00;

pub const VENDOR_VIRTIO: u16 = 0x1AF4;
pub const VENDOR_INTEL: u16 = 0x8086;
pub const DEVICE_VIRTIO_NET_LEGACY: u16 = 0x1000;
pub const DEVICE_VIRTIO_NET_MODERN: u16 = 0x1041;

pub const PciDevice = struct {
    bus: u8,
    device: u8,
    function: u8,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    header_type: u8,
    irq_line: u8,
    bar0: u32,
    bar1: u32,
    bar2: u32,
    bar3: u32,
    bar4: u32,
    bar5: u32,

    pub fn isIoBar(self: PciDevice, bar_index: usize) bool {
        const val = self.getBar(bar_index);
        return (val & 0x01) == 0x01;
    }

    pub fn getIoPort(self: PciDevice, bar_index: usize) ?u16 {
        const val = self.getBar(bar_index);
        if ((val & 0x01) != 0x01) return null;
        return @intCast(val & 0xFFFC);
    }

    pub fn getMmioAddr(self: PciDevice, bar_index: usize) ?u64 {
        const val = self.getBar(bar_index);
        if ((val & 0x01) != 0) return null;
        return @as(u64, val & 0xFFFF_FFF0);
    }

    pub fn getBar(self: PciDevice, index: usize) u32 {
        return switch (index) {
            0 => self.bar0,
            1 => self.bar1,
            2 => self.bar2,
            3 => self.bar3,
            4 => self.bar4,
            5 => self.bar5,
            else => 0,
        };
    }

    pub fn enableBusMastering(self: PciDevice) void {
        const cmd = read16(self.bus, self.device, self.function, REG_COMMAND);
        write16(self.bus, self.device, self.function, REG_COMMAND, cmd | CMD_BUS_MASTER | CMD_IO_SPACE | CMD_MEMORY_SPACE);
    }
};

fn makeConfigAddress(bus: u8, device: u8, function: u8, offset: u8) u32 {
    return PCI_ENABLE_BIT |
        (@as(u32, bus) << 16) |
        (@as(u32, device & 0x1F) << 11) |
        (@as(u32, function & 0x07) << 8) |
        (@as(u32, offset) & 0xFC);
}

pub fn read32(bus: u8, device: u8, function: u8, offset: u8) u32 {
    const address = makeConfigAddress(bus, device, function, offset);
    io.outl(PCI_CONFIG_ADDRESS, address);
    return io.inl(PCI_CONFIG_DATA);
}

pub fn read16(bus: u8, device: u8, function: u8, offset: u8) u16 {
    const val32 = read32(bus, device, function, offset);
    const shift: u5 = @intCast((offset & 2) * 8);
    return @intCast((val32 >> shift) & 0xFFFF);
}

pub fn read8(bus: u8, device: u8, function: u8, offset: u8) u8 {
    const val32 = read32(bus, device, function, offset);
    const shift: u5 = @intCast((offset & 3) * 8);
    return @intCast((val32 >> shift) & 0xFF);
}

pub fn write32(bus: u8, device: u8, function: u8, offset: u8, val: u32) void {
    const address = makeConfigAddress(bus, device, function, offset);
    io.outl(PCI_CONFIG_ADDRESS, address);
    io.outl(PCI_CONFIG_DATA, val);
}

pub fn write16(bus: u8, device: u8, function: u8, offset: u8, val: u16) void {
    const aligned_offset = offset & 0xFC;
    var val32 = read32(bus, device, function, aligned_offset);
    const shift: u5 = @intCast((offset & 2) * 8);
    val32 &= ~(@as(u32, 0xFFFF) << shift);
    val32 |= (@as(u32, val) << shift);
    write32(bus, device, function, aligned_offset, val32);
}

fn inspectDevice(bus: u8, device: u8, function: u8) ?PciDevice {
    const vendor_id = read16(bus, device, function, REG_VENDOR_ID);
    if (vendor_id == PCI_VENDOR_INVALID or vendor_id == 0) return null;

    return PciDevice{
        .bus = bus,
        .device = device,
        .function = function,
        .vendor_id = vendor_id,
        .device_id = read16(bus, device, function, REG_DEVICE_ID),
        .class_code = read8(bus, device, function, REG_CLASS_CODE),
        .subclass = read8(bus, device, function, REG_SUBCLASS),
        .prog_if = read8(bus, device, function, REG_PROG_IF),
        .header_type = read8(bus, device, function, REG_HEADER_TYPE),
        .irq_line = read8(bus, device, function, REG_INTERRUPT_LINE),
        .bar0 = read32(bus, device, function, REG_BAR0 + 0x00),
        .bar1 = read32(bus, device, function, REG_BAR0 + 0x04),
        .bar2 = read32(bus, device, function, REG_BAR0 + 0x08),
        .bar3 = read32(bus, device, function, REG_BAR0 + 0x0C),
        .bar4 = read32(bus, device, function, REG_BAR0 + 0x10),
        .bar5 = read32(bus, device, function, REG_BAR0 + 0x14),
    };
}

pub fn scanAll(out_devices: []PciDevice) usize {
    var count: usize = 0;
    var bus: u16 = 0;
    while (bus < 256 and count < out_devices.len) : (bus += 1) {
        var dev: u8 = 0;
        while (dev < 32 and count < out_devices.len) : (dev += 1) {
            const maybe_base = inspectDevice(@intCast(bus), dev, 0);
            if (maybe_base) |base_dev| {
                out_devices[count] = base_dev;
                count += 1;
                count = scanFunctions(@intCast(bus), dev, base_dev.header_type, out_devices, count);
            }
        }
    }
    return count;
}

fn scanFunctions(bus: u8, dev: u8, header_type: u8, out_devices: []PciDevice, initial_count: usize) usize {
    if ((header_type & 0x80) == 0) return initial_count;
    var count = initial_count;
    var func: u8 = 1;
    while (func < 8 and count < out_devices.len) : (func += 1) {
        if (inspectDevice(bus, dev, func)) |f_dev| {
            out_devices[count] = f_dev;
            count += 1;
        }
    }
    return count;
}

pub fn findNetworkDevice() ?PciDevice {
    var devices: [32]PciDevice = undefined;
    const count = scanAll(&devices);
    for (devices[0..count]) |dev| {
        if (dev.class_code == CLASS_NETWORK and dev.subclass == SUBCLASS_ETHERNET) {
            return dev;
        }
        if (dev.vendor_id == VENDOR_VIRTIO and (dev.device_id == DEVICE_VIRTIO_NET_LEGACY or dev.device_id == DEVICE_VIRTIO_NET_MODERN)) {
            return dev;
        }
    }
    return null;
}

test "pci config address generation" {
    const addr = makeConfigAddress(0, 3, 0, 0x10);
    try std.testing.expect((addr & PCI_ENABLE_BIT) != 0);
    try std.testing.expect(((addr >> 11) & 0x1F) == 3);
    try std.testing.expect((addr & 0xFC) == 0x10);
}

test "pci device bar interpretation" {
    const dev = PciDevice{
        .bus = 0,
        .device = 3,
        .function = 0,
        .vendor_id = VENDOR_VIRTIO,
        .device_id = DEVICE_VIRTIO_NET_LEGACY,
        .class_code = CLASS_NETWORK,
        .subclass = SUBCLASS_ETHERNET,
        .prog_if = 0,
        .header_type = 0,
        .irq_line = 11,
        .bar0 = 0xC001, // I/O Port 0xC000
        .bar1 = 0xFEBD_0000, // MMIO
        .bar2 = 0,
        .bar3 = 0,
        .bar4 = 0,
        .bar5 = 0,
    };
    try std.testing.expect(dev.isIoBar(0));
    try std.testing.expectEqual(@as(?u16, 0xC000), dev.getIoPort(0));
    try std.testing.expect(!dev.isIoBar(1));
    try std.testing.expectEqual(@as(?u64, 0xFEBD_0000), dev.getMmioAddr(1));
}
