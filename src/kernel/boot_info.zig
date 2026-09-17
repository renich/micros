// MicrOS Boot Information Structure
// ABI contract between UEFI Bootloader (boot.efi) and Microkernel (kernel.elf)

pub const BOOT_INFO_MAGIC: u64 = 0x4D494352_4F534B45; // "MICROSKE"

pub const PixelFormat = enum(u32) {
    rgb_888 = 1,
    bgr_888 = 2,
    bitmask = 3,
    unknown = 4,
};

pub const FramebufferInfo = extern struct {
    base_addr: u64,
    size_bytes: usize,
    width: u32,
    height: u32,
    stride: u32,
    format: PixelFormat,
};

pub const MemoryDescriptorType = enum(u32) {
    reserved = 0,
    usable = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_code = 5,
    bootloader_data = 6,
    kernel_code = 7,
    kernel_data = 8,
    framebuffer = 9,
};

pub const MemoryDescriptor = extern struct {
    physical_start: u64,
    virtual_start: u64,
    number_of_pages: u64,
    type: MemoryDescriptorType,
};

pub const BootInfo = extern struct {
    magic: u64,
    hhdm_offset: u64,
    framebuffer: FramebufferInfo,
    bundle_base: u64,
    bundle_size: usize,
    memory_map_entries: usize,
    memory_map_ptr: [*]const MemoryDescriptor,
    kernel_physical_base: u64,
    kernel_virtual_base: u64,
    kernel_size_bytes: usize,
};
