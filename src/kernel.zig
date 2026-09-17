// MicrOS Freestanding Microkernel Root (kernel.elf)
pub const kmain = @import("kernel/main.zig").kmain;
pub const cap = @import("kernel/cap/capability.zig");
pub const cspace = @import("kernel/cap/cspace.zig");
pub const actor = @import("kernel/actor.zig");
pub const ipc = @import("kernel/ipc/ring.zig");
pub const bundle = @import("kernel/bundle.zig");
pub const events = @import("kernel/ipc/events.zig");
pub const ps2_kbd = @import("kernel/drivers/ps2_kbd.zig");
pub const supervisor = @import("kernel/supervisor.zig");
pub const harness_bindings = @import("kernel/harness_bindings.zig");
pub const io = @import("kernel/arch/x86_64/io.zig");
pub const pci = @import("kernel/drivers/pci.zig");
pub const virtio_net = @import("kernel/drivers/virtio_net.zig");
pub const net = @import("kernel/net.zig");
pub const ai = @import("kernel/ai.zig");

test "kernel module tests" {
    _ = @import("kernel/cap/capability.zig");
    _ = @import("kernel/cap/cspace.zig");
    _ = @import("kernel/actor.zig");
    _ = @import("kernel/ipc/ring.zig");
    _ = @import("kernel/ipc/events.zig");
    _ = @import("kernel/drivers/ps2_kbd.zig");
    _ = @import("kernel/bundle.zig");
    _ = @import("kernel/fb.zig");
    _ = @import("kernel/supervisor.zig");
    _ = @import("kernel/harness_bindings.zig");
    _ = @import("kernel/arch/x86_64/io.zig");
    _ = @import("kernel/drivers/pci.zig");
    _ = @import("kernel/drivers/virtio_net.zig");
    _ = @import("kernel/net.zig");
    _ = @import("kernel/ai.zig");
}
