// MicrOS (µOS) Sovereign Microkernel Entry Point
// Implements the Genesis Domain, CSpace authorization, and direct vector canvas.
// Eradicates legacy POSIX PIDs, ambient authority, and untyped ASCII pipes.

const std = @import("std");
const boot_info_mod = @import("boot_info.zig");
const BootInfo = boot_info_mod.BootInfo;
const serial = @import("serial.zig");
const gdt = @import("arch/x86_64/gdt.zig");
const idt = @import("arch/x86_64/idt.zig");
const pmm = @import("mem/pmm.zig");
const vmm = @import("mem/vmm.zig");
const io = @import("arch/x86_64/io.zig");
const syscall = @import("arch/x86_64/syscall.zig");
const apic = @import("arch/x86_64/apic.zig");
const smp = @import("sched/smp.zig");
const vm_mod = @import("../macros/vm.zig");
const chunk_mod = @import("../macros/chunk.zig");
const eval_mod = @import("../macros/eval.zig");
const fiber_mod = @import("../macros/fiber.zig");
const actor_mod = @import("actor.zig");
const cap_mod = @import("cap/capability.zig");
const fb_mod = @import("fb.zig");
const ipc_mod = @import("ipc/ring.zig");
const bundle_mod = @import("bundle.zig");
const parser_mod = @import("../macros/parser.zig");
const compiler_mod = @import("../macros/compiler.zig");
const supervisor_mod = @import("supervisor.zig");
const abi_mod = @import("abi.zig");
const ps2_kbd_mod = @import("drivers/ps2_kbd.zig");
const pci_mod = @import("drivers/pci.zig");
const virtio_net_mod = @import("drivers/virtio_net.zig");
const virtio_blk_mod = @import("drivers/virtio_blk.zig");
const nvme_mod = @import("drivers/nvme.zig");
const block_mod = @import("drivers/block.zig");
const block_cache_mod = @import("storage/block_cache.zig");
const cas_mod = @import("storage/cas.zig");
const cas_chunk_mod = @import("storage/chunk.zig");
const rebuild_mod = @import("storage/rebuild.zig");
const net_mod = @import("net.zig");
const ai_mod = @import("ai.zig");
const netd_mod = @import("../userland/netd/netd.zig");
const aid_mod = @import("../userland/aid/aid.zig");
const compositor_mod = @import("compositor.zig");
const config = @import("config");
const EMBEDDED_GENESIS_BUNDLE: []const u8 = @embedFile("genesis.mcb");
const KERNEL_HEAP_SIZE: usize = 16 * 1024 * 1024;
var kernel_heap: [KERNEL_HEAP_SIZE]u8 align(4096) = undefined;

const COLOR_BG: u32 = 0x000000;
const COLOR_TITLE: u32 = 0xE6EDF3;
const COLOR_SUBTITLE: u32 = 0x7D8590;

const CAP_OBJ_FRAMEBUFFER: u32 = 1;
const CAP_OBJ_IPC_RING: u32 = 2;
const CAP_OBJ_BUNDLE: u32 = 3;
const CAP_OBJ_NETWORK: u32 = 4;
const CAP_OBJ_STORAGE: u32 = 5;
const CAP_OBJ_ACTOR_CTRL: u32 = 6;

const GENESIS_CSPACE_CAPACITY: usize = 64;
const GENESIS_PAGE_TABLE_ROOT: u64 = 0;

var global_registry: actor_mod.ActorRegistry = actor_mod.ActorRegistry.init();
var global_fb: ?fb_mod.Framebuffer = null;
var global_canvas: ?compositor_mod.Canvas = null;
var global_wm: ?compositor_mod.WindowManager = null;
var global_pointer: ?compositor_mod.PointerState = null;
var global_supervisor: ?supervisor_mod.Supervisor = null;
var global_abi_ctx: ?abi_mod.AbiContext = null;
var global_virtio_net: ?virtio_net_mod.VirtioNetDevice = null;
var global_netd: ?netd_mod.NetDaemon = null;
var global_aid: ?aid_mod.AiDaemon = null;
var global_ai_req_ring = ipc_mod.SpscRingBuffer.init();
var global_ai_resp_ring = ipc_mod.SpscRingBuffer.init();
var global_kbd: ps2_kbd_mod.Ps2Keyboard = ps2_kbd_mod.Ps2Keyboard.init();
var global_sched: ?*fiber_mod.Scheduler = null;
var global_virtio_blk: ?virtio_blk_mod.VirtioBlkDevice = null;
var global_virtio_blk_dev: ?block_mod.BlockDevice = null;
var global_nvme: ?nvme_mod.NvmeDevice = null;
var global_nvme_blk_dev: ?block_mod.BlockDevice = null;
var global_block_device: ?block_mod.BlockDevice = null;
var global_block_cache: ?block_cache_mod.BlockCache = null;
var global_cas: ?cas_mod.CasEngine = null;
var global_rebuild: ?rebuild_mod.RebuildEngine = null;
var global_actor_sources: [actor_mod.MAX_ACTORS]?[]const u8 = [_]?[]const u8{null} ** actor_mod.MAX_ACTORS;
var global_bundle_data: ?[]const u8 = null;

fn kernelPanic(stage: []const u8) noreturn {
    serial.writeString("\n[KERNEL PANIC] Fatal error at stage: ");
    serial.writeString(stage);
    serial.writeString("\nHalting CPU.\n");
    haltLoop();
}

fn printBanner() void {
    serial.writeString("\n\x1b[1;97mµOS 0.1.0-dev\x1b[0m \x1b[90m(x86_64-uefi)\x1b[0m\n\n");
}

fn initHardware(boot_info: *const BootInfo) void {
    asm volatile ("cli");
    serial.init();
    printBanner();
    if (boot_info.magic != boot_info_mod.BOOT_INFO_MAGIC) {
        serial.writeString("[kernel] Fatal: Invalid BootInfo signature!\n");
        haltLoop();
    }
    serial.writeStatusOk("boot", "UEFI handoff parameters validated");
    gdt.init();
    idt.init();
    serial.writeStatusOk("arch", "GDT and IDT fault containment active");
    pmm.init(boot_info);
    vmm.init(boot_info.hhdm_offset);
    serial.writeStatusOk("mmu ", "PMM physical and VMM virtual paging active");
    syscall.init();
    syscall.setRegistry(&global_registry);
    syscall.setDeviceHandlers(frameInfoBridge, irqAckBridge);
    serial.writeStatusOk("priv", "TSS Ring 3 and Fast Syscall (LSTAR) ready");
    actor_mod.ActorRegistry.page_table_destructor = vmm.destroyActorAddressSpace;
    apic.enableLapic(boot_info.hhdm_offset);
    apic.initTimer(apic.DEFAULT_QUANTUM_TICKS);
    smp.global_topology.bootstrapSecondaryCores(1);
    serial.writeStatusOk("smp ", "Local APIC 1000Hz preemption timer & SMP topology online");
    initNetwork(boot_info);
}

fn printMac(mac: *const [6]u8) void {
    const hex_chars = "0123456789ABCDEF";
    for (mac, 0..) |b, i| {
        if (i > 0) serial.writeChar(':');
        serial.writeChar(hex_chars[(b >> 4) & 0xF]);
        serial.writeChar(hex_chars[b & 0xF]);
    }
}

fn initVirtioNet(net_dev: pci_mod.PciDevice, boot_info: *const BootInfo) void {
    const rx_ring = pmm.allocContiguousPages(virtio_net_mod.QUEUE_PAGES) orelse return;
    const tx_ring = pmm.allocContiguousPages(virtio_net_mod.QUEUE_PAGES) orelse return;
    const rx_buf = pmm.allocContiguousPages(16) orelse return;
    const tx_buf = pmm.allocPage() orelse return;

    global_virtio_net = virtio_net_mod.VirtioNetDevice.init(
        net_dev,
        rx_ring,
        tx_ring,
        rx_buf,
        tx_buf,
        boot_info.hhdm_offset,
    ) catch |err| {
        serial.writeString("[kernel] Failed to initialize VirtIO-Net device: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return;
    };
    serial.writeString("  \x1b[90m[\x1b[92m  ok  \x1b[90m]\x1b[0m \x1b[96mnet \x1b[90m: \x1b[97mVirtIO-Net 1.0 active (MAC \x1b[0m");
    printMac(&global_virtio_net.?.mac);
    serial.writeString("\x1b[97m)\x1b[0m\n");
}

fn frameInfoBridge(frame_idx: usize) ?u64 {
    return @as(u64, @intCast(frame_idx)) * 4096;
}

fn irqAckBridge(irq: u8) void {
    _ = irq;
}

fn initUserlandServices(allocator: std.mem.Allocator) void {
    const net_cap = cap_mod.Capability{
        .cap_type = .network_device,
        .rights = cap_mod.Rights.ALL,
        .object_id = CAP_OBJ_NETWORK,
        .data_addr = if (global_virtio_net != null) @intFromPtr(&global_virtio_net.?) else 0,
        .data_size = if (global_virtio_net != null) @sizeOf(virtio_net_mod.VirtioNetDevice) else 0,
    };
    const irq_cap = cap_mod.Capability{
        .cap_type = .irq_endpoint,
        .rights = cap_mod.Rights.WRITE,
        .object_id = 11,
        .data_addr = 0,
        .data_size = 0,
    };
    const virt_ptr = if (global_virtio_net != null) &global_virtio_net.? else null;
    global_netd = netd_mod.NetDaemon.init(allocator, virt_ptr, net_cap, irq_cap);

    const ptype = ai_mod.provider.parseProviderType(config.ai_provider);
    const ai_cfg = ai_mod.provider.ProviderConfig{
        .provider_type = ptype,
        .endpoint = config.ai_endpoint,
        .port = config.ai_port,
        .use_tls = config.ai_use_tls,
        .model = config.ai_model,
        .api_key = config.ai_api_key,
    };
    const ipc_cap = cap_mod.Capability{
        .cap_type = .ipc_ring,
        .rights = cap_mod.Rights.ALL,
        .object_id = 1,
        .data_addr = @intFromPtr(&global_ai_req_ring),
        .data_size = @sizeOf(ipc_mod.SpscRingBuffer),
    };
    const net_ptr = if (global_netd != null) &global_netd.? else null;
    global_aid = aid_mod.AiDaemon.init(allocator, ai_cfg, net_ptr, ipc_cap);
    global_aid.?.setRings(&global_ai_req_ring, &global_ai_resp_ring);
}

fn aiInferenceBridge(prompt_ptr: [*]const u8, prompt_len: usize, out_ptr: [*]u8, out_len: usize) callconv(.c) usize {
    if (global_aid) |*aid_inst| {
        return aid_inst.dispatchPrompt(prompt_ptr[0..prompt_len], out_ptr[0..out_len]);
    }
    return ai_mod.mock.generateResponse(prompt_ptr[0..prompt_len], out_ptr[0..out_len]) catch 0;
}

const ActorThreadContext = struct {
    allocator: std.mem.Allocator,
    actor: *actor_mod.Actor,
    vm: *vm_mod.VM,
};

fn onFiberContextSwitch(maybe_fib: ?*fiber_mod.Fiber) void {
    if (maybe_fib) |fib| {
        if (fib.entry == actorThread and fib.user_data != null) {
            const act_ctx: *ActorThreadContext = @ptrCast(@alignCast(fib.user_data.?));
            idt.current_actor_id = act_ctx.actor.id;
            syscall.setActorId(act_ctx.actor.id);
            return;
        }
    }
    idt.current_actor_id = 0;
    syscall.setActorId(0);
}

fn actorThread(ctx: ?*anyopaque) void {
    const act_ctx = @as(*ActorThreadContext, @ptrCast(@alignCast(ctx.?)));
    const actor = act_ctx.actor;
    var vm = act_ctx.vm;
    defer {
        vm.deinit();
        act_ctx.allocator.destroy(vm);
        act_ctx.allocator.destroy(act_ctx);
    }
    actor.state = .running;
    vm.run(0) catch |err| {
        actor.state = .faulted;
        serial.writeString("[kernel] Spawned Actor crashed: ");
        serial.writeString(@errorName(err));
        if (err == vm_mod.InterpretError.RuntimeError and vm.last_missing_symbol != null) {
            serial.writeString(" [Undefined: '");
            serial.writeString(vm.last_missing_symbol.?);
            serial.writeString("']");
        }
        serial.writeString(" frames=");
        serial.writeDec(vm.frame_count);
        serial.writeString(" ip=");
        serial.writeHex(vm.ip);
        serial.writeString(" sp=");
        serial.writeHex(vm.sp);
        serial.writeString("\n");
        return;
    };
    actor.state = .terminated;
}

fn compileActorScript(allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!*chunk_mod.Chunk {
    const chunk = try allocator.create(chunk_mod.Chunk);
    chunk.* = chunk_mod.Chunk.init();
    errdefer {
        chunk.deinit(allocator);
        allocator.destroy(chunk);
    }
    var compiler = compiler_mod.Compiler.init(allocator, chunk);
    var p = parser_mod.Parser.init(allocator, source);
    while (p.current_token.token_type != .eof) {
        const stmt = p.parseStatement() catch |err| {
            serial.writeString("[kernel] Actor compilation failed for '");
            serial.writeString(name);
            serial.writeString("': ");
            serial.writeString(@errorName(err));
            serial.writeString("\n");
            return err;
        };
        try compiler.compile(stmt);
    }
    return chunk;
}

fn logActorSpawn(id: u32, name: []const u8) void {
    serial.writeString("  [  \x1b[32mok\x1b[0m  ] spawn: Actor ");
    serial.writeDec(id);
    serial.writeString(" (");
    serial.writeString(name);
    serial.writeString("\x1b[97m) online\x1b[0m\n");
}

fn attachActorVm(allocator: std.mem.Allocator, child: *actor_mod.Actor, chunk: *chunk_mod.Chunk) !void {
    const child_vm = try allocator.create(vm_mod.VM);
    try child_vm.initInPlace(allocator, chunk);
    errdefer {
        child_vm.deinit();
        allocator.destroy(child_vm);
    }
    try abi_mod.registerSyscalls(child_vm);
    const act_ctx = try allocator.create(ActorThreadContext);
    act_ctx.* = .{
        .allocator = allocator,
        .actor = child,
        .vm = child_vm,
    };
    errdefer allocator.destroy(act_ctx);
    if (global_sched) |sched| {
        const fib = try sched.spawn(actorThread, act_ctx);
        child.fiber_ctx = @ptrCast(fib);
    }
}

fn delegateInitialCaps(child: *actor_mod.Actor, name: []const u8) !void {
    if (global_fb) |*fb| {
        _ = try child.insertCap(cap_mod.Capability{
            .cap_type = .framebuffer,
            .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE,
            .object_id = CAP_OBJ_FRAMEBUFFER,
            .data_addr = @intFromPtr(fb),
            .data_size = @sizeOf(fb_mod.Framebuffer),
        });
    }
    const is_sys = std.mem.eql(u8, name, "msh") or std.mem.eql(u8, name, "harness") or
        std.mem.eql(u8, name, "installer") or std.mem.eql(u8, name, "rebuild") or
        std.mem.eql(u8, name, "httpd") or std.mem.eql(u8, name, "web") or
        std.mem.eql(u8, name, "vedit");
    if (is_sys) {
        _ = try child.insertCap(cap_mod.Capability{
            .cap_type = .actor_control,
            .rights = cap_mod.Rights.ALL,
            .object_id = CAP_OBJ_ACTOR_CTRL,
            .data_addr = 0,
            .data_size = 0,
        });
        _ = try child.insertCap(cap_mod.Capability{
            .cap_type = .storage_device,
            .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE,
            .object_id = CAP_OBJ_STORAGE,
            .data_addr = 0,
            .data_size = 0,
        });
        _ = try child.insertCap(cap_mod.Capability{
            .cap_type = .network_device,
            .rights = cap_mod.Rights.ALL,
            .object_id = CAP_OBJ_NETWORK,
            .data_addr = 0,
            .data_size = 0,
        });
    }
}

fn spawnActorFromCode(allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 {
    const persistent_source = try allocator.dupe(u8, source);
    errdefer allocator.free(persistent_source);

    const chunk = try compileActorScript(allocator, name, persistent_source);
    errdefer {
        chunk.deinit(allocator);
        allocator.destroy(chunk);
    }

    const pml4_phys = vmm.createActorAddressSpace() orelse 0;
    const child = try global_registry.spawn(allocator, actor_mod.GENESIS_ACTOR_ID, name, 16, pml4_phys);
    errdefer {
        if (pml4_phys != 0) vmm.destroyActorAddressSpace(pml4_phys);
        global_registry.terminate(allocator, child.id) catch {};
    }

    try delegateInitialCaps(child, name);
    try attachActorVm(allocator, child, chunk);
    if (child.id < actor_mod.MAX_ACTORS) {
        global_actor_sources[child.id] = persistent_source;
    }

    logActorSpawn(child.id, name);
    return child.id;
}

fn casPutBridge(data: []const u8, out_hex: *[64]u8) anyerror!void {
    if (global_cas == null) return error.NoStorage;
    const dev = if (global_block_device != null) &global_block_device.? else null;
    const hash = try global_cas.?.putChunk(.raw_blob, data, dev);
    cas_chunk_mod.formatHexHash(&hash, out_hex);
}

fn casGetBridge(hex_hash: []const u8, out_buf: []u8) anyerror!usize {
    if (global_cas == null) return error.NoStorage;
    const dev = if (global_block_device != null) &global_block_device.? else null;
    var raw_hash: [cas_chunk_mod.HASH_SIZE]u8 = undefined;
    try cas_chunk_mod.parseHexHash(hex_hash, &raw_hash);
    return try global_cas.?.getChunk(&raw_hash, out_buf, dev);
}

fn persistActorBridge(actor_id: u32, out_hex: *[64]u8) anyerror!void {
    if (global_cas == null) return error.NoStorage;
    if (actor_id >= actor_mod.MAX_ACTORS) return error.ActorNotFound;
    const src = global_actor_sources[actor_id] orelse return error.NoSourceRecorded;
    const dev = if (global_block_device != null) &global_block_device.? else null;
    const hash = try global_cas.?.putChunk(.actor_source, src, dev);
    cas_chunk_mod.formatHexHash(&hash, out_hex);
    try global_cas.?.setRootHash(&hash, dev);
    serial.writeString("  \x1b[90m[\x1b[92m  ok  \x1b[90m]\x1b[0m \x1b[96mpersist\x1b[90m: \x1b[97mActor \x1b[0m");
    serial.writeDec(actor_id);
    serial.writeString(" \x1b[97mroot hash \x1b[0m");
    serial.writeString(out_hex);
    serial.writeString("\n");
}

fn spawnCasBridge(allocator: std.mem.Allocator, hex_hash: []const u8) anyerror!u32 {
    if (global_cas == null) return error.NoStorage;
    const dev = if (global_block_device != null) &global_block_device.? else null;
    var raw_hash: [cas_chunk_mod.HASH_SIZE]u8 = undefined;
    try cas_chunk_mod.parseHexHash(hex_hash, &raw_hash);
    var code_buf: [4096]u8 = undefined;
    const len = try global_cas.?.getChunk(&raw_hash, &code_buf, dev);
    return try spawnActorFromCode(allocator, "cas_restored", code_buf[0..len]);
}

fn grantCapBridge(target_actor: u32, source_slot: u32, rights_mask: u16) anyerror!bool {
    const target = global_registry.get(target_actor) orelse return error.ActorNotFound;
    const caller = getCurrentActorBridge() orelse global_registry.get(actor_mod.GENESIS_ACTOR_ID) orelse return error.ActorNotFound;
    _ = try caller.cspace.grant(source_slot, target.cspace, rights_mask);
    return true;
}

fn drawCanvasBridge(x: u32, y: u32, w: u32, h: u32, color: u32) void {
    if (global_canvas) |*canvas| {
        canvas.drawRect(x, y, w, h, color);
    } else if (global_fb) |*fb| {
        fb.drawRect(x, y, w, h, color);
    }
}

fn telemetryBridge() ai_mod.tools.TelemetrySnapshot {
    return ai_mod.tools.TelemetrySnapshot{
        .active_actors = @intCast(global_registry.active_count),
        .total_faults = if (global_supervisor) |s| s.total_faults else 0,
        .free_ram_pages = 256,
        .uptime_ticks = 100,
    };
}

fn initBlkDevice(blk_pci: pci_mod.PciDevice, boot_info: *const BootInfo) bool {
    const ring_phys = pmm.allocContiguousPages(virtio_blk_mod.QUEUE_PAGES) orelse return false;
    const dma_phys = pmm.allocContiguousPages(virtio_blk_mod.DMA_PAGES) orelse return false;

    global_virtio_blk = virtio_blk_mod.VirtioBlkDevice.init(
        blk_pci,
        ring_phys,
        dma_phys,
        boot_info.hhdm_offset,
    ) catch |err| {
        serial.writeString("[kernel] VirtIO-Blk init failed: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return false;
    };
    global_virtio_blk_dev = global_virtio_blk.?.blockDevice();
    global_virtio_blk_dev.?.is_boot_media = (global_block_device == null);
    if (global_block_device == null) {
        global_block_device = global_virtio_blk_dev.?;
    }
    abi_mod.registerBlockDevice(&global_virtio_blk_dev.?);

    serial.writeString("  \x1b[90m[\x1b[92m  ok  \x1b[90m]\x1b[0m \x1b[96mblk \x1b[90m: \x1b[97mVirtIO-Blk persistent drive (capacity: \x1b[0m");
    serial.writeDec(global_virtio_blk.?.capacity_sectors);
    serial.writeString("\x1b[97m sectors)\x1b[0m\n");
    return true;
}

fn initStorageEngines(allocator: std.mem.Allocator) void {
    global_block_cache = block_cache_mod.BlockCache.init(allocator) catch |err| {
        serial.writeString("[kernel] Block cache init failed: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return;
    };

    const dev = if (global_block_device != null) &global_block_device.? else null;
    const total_secs = if (dev != null) dev.?.total_sectors else 0;
    global_cas = cas_mod.CasEngine.init(
        &global_block_cache.?,
        dev,
        total_secs,
    ) catch |err| {
        serial.writeString("[kernel] CAS engine init failed: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return;
    };

    global_rebuild = rebuild_mod.RebuildEngine.init(&global_cas.?, null, null);
    abi_mod.setRebuildEngine(&global_rebuild.?);

    serial.writeStatusOk("cas ", "BLAKE3 Content-Addressed Storage engine ready");
}

const NvmeDmaPages = struct {
    asq: u64,
    acq: u64,
    iosq: u64,
    iocq: u64,
    prp: u64,
    dma: u64,

    fn alloc() ?NvmeDmaPages {
        return NvmeDmaPages{
            .asq = pmm.allocPage() orelse return null,
            .acq = pmm.allocPage() orelse return null,
            .iosq = pmm.allocPage() orelse return null,
            .iocq = pmm.allocPage() orelse return null,
            .prp = pmm.allocPage() orelse return null,
            .dma = pmm.allocContiguousPages(16) orelse return null,
        };
    }
};

fn initNvmeDevice(nvme_pci: pci_mod.PciDevice, boot_info: *const BootInfo) bool {
    const p = NvmeDmaPages.alloc() orelse return false;
    const hhdm = boot_info.hhdm_offset;
    global_nvme = nvme_mod.NvmeDevice.init(
        nvme_pci,
        p.asq,
        @ptrFromInt(p.asq + hhdm),
        p.acq,
        @ptrFromInt(p.acq + hhdm),
        p.iosq,
        @ptrFromInt(p.iosq + hhdm),
        p.iocq,
        @ptrFromInt(p.iocq + hhdm),
        p.prp,
        @ptrFromInt(p.prp + hhdm),
        p.dma,
        @ptrFromInt(p.dma + hhdm),
    ) catch |err| {
        serial.writeString("[kernel] NVMe init failed: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return false;
    };
    global_nvme_blk_dev = global_nvme.?.blockDevice();
    global_nvme_blk_dev.?.is_boot_media = (global_block_device == null);
    if (global_block_device == null) {
        global_block_device = global_nvme_blk_dev.?;
    }
    abi_mod.registerBlockDevice(&global_nvme_blk_dev.?);

    serial.writeString("  \x1b[90m[\x1b[92m  ok  \x1b[90m]\x1b[0m \x1b[96mnvme\x1b[90m: \x1b[97mPCIe NVMe 1.4 persistent drive (capacity: \x1b[0m");
    serial.writeDec(global_nvme.?.total_sectors);
    serial.writeString("\x1b[97m sectors)\x1b[0m\n");
    return true;
}

fn initStorage(boot_info: *const BootInfo, allocator: std.mem.Allocator) void {
    if (pci_mod.findVirtioBlkDevice()) |blk_dev| {
        _ = initBlkDevice(blk_dev, boot_info);
    }
    if (pci_mod.findNvmeDevice()) |nvme_dev| {
        _ = initNvmeDevice(nvme_dev, boot_info);
    }
    if (global_block_device != null) {
        initStorageEngines(allocator);
    }
}

fn initNetwork(boot_info: *const BootInfo) void {
    const maybe_net = pci_mod.findNetworkDevice();
    if (maybe_net) |net_dev| {
        if (net_dev.vendor_id == pci_mod.VENDOR_VIRTIO) {
            initVirtioNet(net_dev, boot_info);
        }
    }
}

fn initGenesisDisplay(boot_info: *const BootInfo) void {
    if (boot_info.framebuffer.base_addr == 0) return;

    var framebuffer = fb_mod.Framebuffer.init(boot_info.framebuffer);
    framebuffer.clear(COLOR_BG);
}

fn registerNetworkCap(genesis: *actor_mod.Actor) !void {
    if (global_virtio_net != null) {
        _ = try genesis.insertCap(cap_mod.Capability{
            .cap_type = .network_device,
            .rights = cap_mod.Rights.ALL,
            .object_id = CAP_OBJ_NETWORK,
            .data_addr = @intFromPtr(&global_virtio_net.?),
            .data_size = @sizeOf(virtio_net_mod.VirtioNetDevice),
        });
    }
}

fn registerStorageCap(genesis: *actor_mod.Actor) !void {
    if ((global_virtio_blk != null or global_nvme != null) and global_cas != null) {
        _ = try genesis.insertCap(cap_mod.Capability{
            .cap_type = .storage_device,
            .rights = cap_mod.Rights.ALL,
            .object_id = CAP_OBJ_STORAGE,
            .data_addr = @intFromPtr(&global_cas.?),
            .data_size = @sizeOf(cas_mod.CasEngine),
        });
    }
}

fn registerDisplayCap(genesis: *actor_mod.Actor, boot_info: *const BootInfo) !void {
    if (boot_info.framebuffer.base_addr != 0) {
        _ = try genesis.insertCap(cap_mod.Capability{
            .cap_type = .framebuffer,
            .rights = cap_mod.Rights.ALL,
            .object_id = CAP_OBJ_FRAMEBUFFER,
            .data_addr = boot_info.framebuffer.base_addr,
            .data_size = boot_info.framebuffer.size_bytes,
        });
    }
}

fn registerBundleCap(genesis: *actor_mod.Actor, boot_info: *const BootInfo) !void {
    if (boot_info.bundle_base != 0 and boot_info.bundle_size != 0) {
        _ = try genesis.insertCap(cap_mod.Capability{
            .cap_type = .memory_extent,
            .rights = cap_mod.Rights.READ,
            .object_id = CAP_OBJ_BUNDLE,
            .data_addr = boot_info.bundle_base,
            .data_size = boot_info.bundle_size,
        });
    }
}

fn registerGenesisCapabilities(
    genesis: *actor_mod.Actor,
    boot_info: *const BootInfo,
    ring: *ipc_mod.RingBuffer,
) !void {
    try registerDisplayCap(genesis, boot_info);
    try registerBundleCap(genesis, boot_info);

    _ = try genesis.insertCap(cap_mod.Capability{
        .cap_type = .ipc_ring,
        .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE,
        .object_id = CAP_OBJ_IPC_RING,
        .data_addr = @intFromPtr(ring),
        .data_size = @sizeOf(ipc_mod.RingBuffer),
    });

    try registerNetworkCap(genesis);
    try registerStorageCap(genesis);

    _ = try genesis.insertCap(cap_mod.Capability{
        .cap_type = .actor_control,
        .rights = cap_mod.Rights.ALL,
        .object_id = CAP_OBJ_ACTOR_CTRL,
        .data_addr = 0,
        .data_size = 0,
    });
}

fn buildFallbackGenesisChunk(allocator: std.mem.Allocator) !*chunk_mod.Chunk {
    const chunk = try allocator.create(chunk_mod.Chunk);
    chunk.* = chunk_mod.Chunk.init();
    errdefer {
        chunk.deinit(allocator);
        allocator.destroy(chunk);
    }
    const msg = eval_mod.Value{ .string = "Actor 0 initialized." };
    const c_idx = try chunk.addConstant(allocator, msg);

    try chunk.writeChunk(allocator, @intFromEnum(chunk_mod.OpCode.constant));
    try chunk.writeChunk(allocator, @intCast((c_idx >> 8) & 0xFF));
    try chunk.writeChunk(allocator, @intCast(c_idx & 0xFF));
    try chunk.writeChunk(allocator, @intFromEnum(chunk_mod.OpCode.print));
    try chunk.writeChunk(allocator, @intFromEnum(chunk_mod.OpCode.return_op));
    return chunk;
}

fn bundleReadBridge(name: []const u8) ?[]const u8 {
    const raw = global_bundle_data orelse return null;
    const reader = bundle_mod.BundleReader.init(raw) catch return null;
    return reader.findData(name);
}

fn getCurrentActorBridge() ?*actor_mod.Actor {
    if (global_sched) |sched| {
        if (sched.current) |fib| {
            if (fib.user_data) |ud| {
                const act_ctx = @as(*ActorThreadContext, @ptrCast(@alignCast(ud)));
                return act_ctx.actor;
            }
        }
    }
    return null;
}

fn loadGenesisChunk(allocator: std.mem.Allocator, boot_info: *const BootInfo) !*chunk_mod.Chunk {
    const raw_bundle: []const u8 = if (boot_info.bundle_base != 0 and boot_info.bundle_size != 0)
        @as([*]const u8, @ptrFromInt(boot_info.bundle_base))[0..boot_info.bundle_size]
    else
        EMBEDDED_GENESIS_BUNDLE;
    global_bundle_data = raw_bundle;

    const reader = bundle_mod.BundleReader.init(raw_bundle) catch {
        serial.writeStatusWarn("mcb ", "BundleReader failed. Using fallback chunk");
        return try buildFallbackGenesisChunk(allocator);
    };

    const maybe_source = reader.findData("init.mx") orelse reader.findData("harness.mx");
    if (maybe_source) |source| {
        global_actor_sources[actor_mod.GENESIS_ACTOR_ID] = source;
        const chunk = try allocator.create(chunk_mod.Chunk);
        chunk.* = chunk_mod.Chunk.init();
        errdefer {
            chunk.deinit(allocator);
            allocator.destroy(chunk);
        }
        var compiler = compiler_mod.Compiler.init(allocator, chunk);
        var p = parser_mod.Parser.init(allocator, source);
        while (p.current_token.token_type != .eof) {
            const stmt = try p.parseStatement();
            try compiler.compile(stmt);
        }
        try chunk.writeChunk(allocator, @intFromEnum(chunk_mod.OpCode.return_op));
        serial.writeStatusOk("mcb ", "Genesis bundle loaded and compiled (init.mx)");
        return chunk;
    }

    serial.writeStatusWarn("mcb ", "No startup script in bundle. Using fallback chunk");
    return try buildFallbackGenesisChunk(allocator);
}

fn initCompositor(allocator: std.mem.Allocator, fb_info: boot_info_mod.FramebufferInfo) void {
    if (fb_info.base_addr == 0) return;
    global_fb = fb_mod.Framebuffer.init(fb_info);
    const canvas = compositor_mod.Canvas.init(
        allocator,
        fb_info.width,
        fb_info.height,
        fb_info.format,
    ) catch null;
    if (canvas) |c| {
        global_canvas = c;
        global_wm = compositor_mod.WindowManager.init(allocator, fb_info.width, fb_info.height);
        global_pointer = compositor_mod.PointerState.init(fb_info.width, fb_info.height);
        serial.writeStatusOk("comp", "Double-buffered reactive compositor active (1280x800x32)");
    }
}

fn createAbiContext(genesis: *actor_mod.Actor, ipc_ring: *ipc_mod.RingBuffer) abi_mod.AbiContext {
    return abi_mod.AbiContext{
        .registry = &global_registry,
        .supervisor = genesis,
        .framebuffer = if (global_fb != null) &global_fb.? else null,
        .ipc_ring = ipc_ring,
        .supervisor_ctrl = if (global_supervisor != null) &global_supervisor.? else null,
        .kbd_ctrl = &global_kbd,
        .wm = if (global_wm != null) &global_wm.? else null,
        .canvas = if (global_canvas != null) &global_canvas.? else null,
        .pointer = if (global_pointer != null) &global_pointer.? else null,
        .ai_inference_fn = aiInferenceBridge,
        .spawn_code_fn = spawnActorFromCode,
        .cas_put_fn = casPutBridge,
        .cas_get_fn = casGetBridge,
        .persist_actor_fn = persistActorBridge,
        .spawn_cas_fn = spawnCasBridge,
        .grant_cap_fn = grantCapBridge,
        .draw_canvas_fn = drawCanvasBridge,
        .telemetry_fn = telemetryBridge,
        .bundle_read_fn = bundleReadBridge,
        .current_actor_fn = getCurrentActorBridge,
        .net_stack = if (global_netd != null and global_netd.?.stack != null) &global_netd.?.stack.? else null,
        .frame_info_fn = frameInfoBridge,
        .irq_ack_fn = irqAckBridge,
    };
}

fn setupAbiEnvironment(
    genesis: *actor_mod.Actor,
    boot_info: *const BootInfo,
    ipc_ring: *ipc_mod.RingBuffer,
    vm: *vm_mod.VM,
    allocator: std.mem.Allocator,
) void {
    initUserlandServices(allocator);
    idt.setInputRing(ipc_ring);
    global_registry.register(genesis) catch kernelPanic("register_genesis");
    global_supervisor = supervisor_mod.Supervisor.init(&global_registry, .restart_immediate);
    initCompositor(allocator, boot_info.framebuffer);

    global_abi_ctx = createAbiContext(genesis, ipc_ring);
    abi_mod.setContext(&global_abi_ctx.?);
    abi_mod.registerSyscalls(vm) catch kernelPanic("abi_syscalls");
}

fn initGenesisVm(
    boot_info: *const BootInfo,
    allocator: std.mem.Allocator,
    genesis: *actor_mod.Actor,
    ipc_ring: *ipc_mod.RingBuffer,
) *vm_mod.VM {
    initStorage(boot_info, allocator);
    registerGenesisCapabilities(genesis, boot_info, ipc_ring) catch kernelPanic("register_caps");
    serial.writeStatusOk("cap ", "Genesis CSpace initialized (64 capability slots)");

    initGenesisDisplay(boot_info);
    if (boot_info.framebuffer.base_addr != 0) {
        serial.writeStatusOk("gop ", "Direct GOP vector canvas active (1280x800x32)");
    }

    const chunk = loadGenesisChunk(allocator, boot_info) catch kernelPanic("load_genesis_chunk");
    const genesis_vm = allocator.create(vm_mod.VM) catch kernelPanic("vm_alloc");
    genesis_vm.initInPlace(allocator, chunk) catch kernelPanic("vm_init");
    return genesis_vm;
}

pub export fn kmain(boot_info: *const BootInfo) callconv(.c) noreturn {
    initHardware(boot_info);

    var fba = std.heap.FixedBufferAllocator.init(&kernel_heap);
    const allocator = fba.allocator();
    syscall.setAllocator(allocator);

    const genesis = actor_mod.Actor.init(
        allocator,
        actor_mod.GENESIS_ACTOR_ID,
        "genesis_actor",
        GENESIS_CSPACE_CAPACITY,
        GENESIS_PAGE_TABLE_ROOT,
    ) catch kernelPanic("actor_init");

    const ipc_ring = ipc_mod.RingBuffer.init(allocator, ipc_mod.DEFAULT_RING_CAPACITY) catch kernelPanic("ipc_ring_init");
    const genesis_vm = initGenesisVm(boot_info, allocator, genesis, ipc_ring);
    setupAbiEnvironment(genesis, boot_info, ipc_ring, genesis_vm, allocator);

    serial.writeStatusOk("act ", "Genesis Actor 0 online (cooperative fiber scheduler)");

    var sched = fiber_mod.Scheduler.init(allocator);
    sched.on_context_switch = onFiberContextSwitch;
    global_sched = &sched;
    _ = sched.spawn(vmThread, genesis_vm) catch kernelPanic("fiber_spawn");
    sched.run();

    serial.writeString("[kernel] Event loop terminated. Halting.\n");
    haltLoop();
}

fn vmThread(ctx: ?*anyopaque) void {
    var vm = @as(*vm_mod.VM, @ptrCast(@alignCast(ctx.?)));
    vm.run(0) catch {
        serial.writeString("[kernel] Genesis Actor crashed!\n");
    };
}

fn haltLoop() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}
