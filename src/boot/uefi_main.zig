// MicrOS (µOS) Stage 1 UEFI Bootloader (boot.efi)
// Discovers GOP framebuffer, prepares BootInfo, and transitions to Microkernel.

const std = @import("std");
const uefi = std.os.uefi;
const boot_info_mod = @import("../kernel/boot_info.zig");
const BootInfo = boot_info_mod.BootInfo;
const FramebufferInfo = boot_info_mod.FramebufferInfo;
const MemoryDescriptor = boot_info_mod.MemoryDescriptor;

var global_boot_info: BootInfo = undefined;
var memory_descriptors_buf: [512]MemoryDescriptor = undefined;
var uefi_mmap_buffer: [65536]u8 align(@alignOf(uefi.tables.MemoryDescriptor)) = undefined;

const kernel_main = @import("../kernel/main.zig");

fn initFramebuffer(bs: *const uefi.tables.BootServices, info: *FramebufferInfo) void {
    const gop = bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch null orelse return;
    info.base_addr = gop.mode.frame_buffer_base;
    info.size_bytes = gop.mode.frame_buffer_size;
    info.width = gop.mode.info.horizontal_resolution;
    info.height = gop.mode.info.vertical_resolution;
    info.stride = gop.mode.info.pixels_per_scan_line;
    info.format = switch (gop.mode.info.pixel_format) {
        .red_green_blue_reserved_8_bit_per_color => .rgb_888,
        .blue_green_red_reserved_8_bit_per_color => .bgr_888,
        .bit_mask => .bitmask,
        .blt_only => .unknown,
    };
}

fn initMemoryMap(bs: *const uefi.tables.BootServices, info: *BootInfo) void {
    const mmap = bs.getMemoryMap(&uefi_mmap_buffer) catch return;
    var iter = mmap.iterator();
    var idx: usize = 0;
    while (iter.next()) |desc| {
        if (idx >= memory_descriptors_buf.len) break;
        memory_descriptors_buf[idx] = MemoryDescriptor{
            .physical_start = desc.physical_start,
            .virtual_start = desc.virtual_start,
            .number_of_pages = desc.number_of_pages,
            .type = if (desc.type == .conventional_memory)
                .usable
            else if (desc.type == .loader_code or desc.type == .loader_data)
                .bootloader_data
            else
                .reserved,
        };
        idx += 1;
    }
    info.memory_map_entries = idx;
}

pub fn main() uefi.Status {
    const con_out = uefi.system_table.con_out orelse return .device_error;
    _ = con_out.outputString(&[_:0]u16{ 'M', 'i', 'c', 'r', 'O', 'S', ' ', 'U', 'E', 'F', 'I', ' ', 'B', 'o', 'o', 't', 'l', 'o', 'a', 'd', 'e', 'r', '\r', '\n', 0 }) catch false;

    global_boot_info.magic = boot_info_mod.BOOT_INFO_MAGIC;
    global_boot_info.hhdm_offset = 0;
    global_boot_info.memory_map_entries = 0;
    global_boot_info.memory_map_ptr = &memory_descriptors_buf;
    global_boot_info.bundle_base = 0;
    global_boot_info.bundle_size = 0;

    global_boot_info.framebuffer = FramebufferInfo{
        .base_addr = 0,
        .size_bytes = 0,
        .width = 1024,
        .height = 768,
        .stride = 1024,
        .format = .bgr_888,
    };

    if (uefi.system_table.boot_services) |bs| {
        initFramebuffer(bs, &global_boot_info.framebuffer);
        initMemoryMap(bs, &global_boot_info);
    }

    _ = con_out.outputString(&[_:0]u16{ '[', 'b', 'o', 'o', 't', ']', ' ', 'B', 'o', 'o', 't', 'I', 'n', 'f', 'o', ' ', 'P', 'r', 'e', 'p', 'a', 'r', 'e', 'd', '\r', '\n', 0 }) catch false;
    _ = con_out.outputString(&[_:0]u16{ '[', 'b', 'o', 'o', 't', ']', ' ', 'J', 'u', 'm', 'p', 'i', 'n', 'g', ' ', 't', 'o', ' ', 'K', 'e', 'r', 'n', 'e', 'l', '.', '.', '.', '\r', '\n', 0 }) catch false;

    kernel_main.kmain(&global_boot_info);
}
