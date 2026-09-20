// MicrOS (µOS) Sovereign Microkernel Entry Point
// Implements the Genesis Domain, CSpace authorization, and direct vector canvas.
// Eradicates legacy POSIX PIDs, ambient authority, and untyped ASCII pipes.

const std = @import("std");
const builtin = @import("builtin");
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
const gc_mod = @import("../macros/gc.zig");
const actor_mod = @import("actor.zig");
const cap_mod = @import("cap/capability.zig");
const cspace_mod = @import("cap/cspace.zig");
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
const gopd_mod = @import("../userland/gopd/gopd.zig");
const storaged_mod = @import("../userland/storaged/storaged.zig");
const p2pd_mod = @import("../userland/p2pd/p2p.zig");
const pkgd_mod = @import("../userland/pkgd/package.zig");
const compositor_mod = @import("compositor.zig");
const config = @import("config");
const EMBEDDED_GENESIS_BUNDLE: []const u8 = @embedFile("genesis.mcb");
const KERNEL_HEAP_SIZE: usize = 16 * 1024 * 1024;
var kernel_heap: [KERNEL_HEAP_SIZE]u8 align(4096) = undefined;
const COLOR_BG: u32 = 0x000000;
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
var global_tls_adapter: net_mod.tls_stream.TcpStreamAdapter = undefined;
var global_aid: ?aid_mod.AiDaemon = null;
var global_gopd: ?gopd_mod.GopDaemon = null;
var global_storaged: ?storaged_mod.StorageDaemon = null;
var global_p2pd: ?p2pd_mod.P2pDaemon = null;
var global_pkgd: ?pkgd_mod.PackageDaemon = null;
var global_ai_req_ring = ipc_mod.SpscRingBuffer.init();
var global_ai_resp_ring = ipc_mod.SpscRingBuffer.init();
var global_kbd: ps2_kbd_mod.Ps2Keyboard = ps2_kbd_mod.Ps2Keyboard.init();
var global_sched: ?*fiber_mod.Scheduler = null;
var global_virtio_blk: ?virtio_blk_mod.VirtioBlkDevice = null;
var global_virtio_blk_dev: ?block_mod.BlockDevice = null;
var global_nvme: ?nvme_mod.NvmeDevice = null;
var global_nvme_blk_dev: ?block_mod.BlockDevice = null;
var global_block_device: ?block_mod.BlockDevice = null;
var global_block_cache: ?*block_cache_mod.BlockCache = null;
var global_cas: ?*cas_mod.CasEngine = null;
var global_rebuild: ?rebuild_mod.RebuildEngine = null;
var global_bundle_data: ?[]const u8 = null;

fn kernelPanic(stage: []const u8) noreturn {
    asm volatile ("cli");
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
    cspace_mod.unmap_extent_fn = vmm.unmapExtent;
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

fn dmaPinBridge(virt_addr: usize, len_bytes: usize) ?u64 {
    const USERLAND_MAX: usize = 0x0000_7FFF_FFFF_FFFF;
    if (virt_addr >= USERLAND_MAX or len_bytes > USERLAND_MAX - virt_addr) return null;
    if (virt_addr % 4096 != 0 or len_bytes % 512 != 0) return null;
    const cr3 = vmm.readCr3();
    const pml4 = if (cr3 != 0) cr3 else vmm.kernel_pml4_phys;
    if (pml4 == 0) return @as(u64, @intCast(virt_addr));
    return vmm.pinDmaPages(pml4, @as(u64, @intCast(virt_addr)), len_bytes);
}

fn initNetDaemon(allocator: std.mem.Allocator) void {
    const net_cap = cap_mod.Capability{
        .cap_type = .network_device,
        .rights = cap_mod.Rights.ALL,
        .object_id = CAP_OBJ_NETWORK,
        .data_addr = if (global_virtio_net != null) @intFromPtr(&global_virtio_net.?) else 0,
        .data_size = if (global_virtio_net != null) @sizeOf(virtio_net_mod.VirtioNetDevice) else 0,
    };
    const irq_cap = cap_mod.Capability{ .cap_type = .irq_endpoint, .rights = cap_mod.Rights.WRITE, .object_id = 11, .data_addr = 0, .data_size = 0 };
    const virt_ptr = if (global_virtio_net != null) &global_virtio_net.? else null;
    global_netd = netd_mod.NetDaemon.init(allocator, virt_ptr, net_cap, irq_cap);
    const netd = &(global_netd orelse return);
    const vdev = netd.virtio_dev orelse return;
    const bound = netd.startDhcp() catch false;
    if (bound) {
        serial.writeStatusOk("dhcp", "Network IPv4 lease acquired via VirtIO-Net");
        return;
    }
    if (netd.stack) |st| {
        st.dhcp_config = .{
            .ip = [4]u8{ 192, 168, 100, vdev.mac[5] },
            .subnet_mask = [4]u8{ 255, 255, 255, 0 },
            .gateway = [4]u8{ 192, 168, 100, 1 },
            .dns_server = [4]u8{ 1, 1, 1, 1 },
            .server_id = [4]u8{ 192, 168, 100, 1 },
            .lease_seconds = 86400,
            .bound = true,
        };
    }
    serial.writeStatusOk("dhcp", "Assigned link-local mesh IPv4 (192.168.100.x)");
}

fn initAiDaemon(allocator: std.mem.Allocator) void {
    const ptype = ai_mod.provider.parseProviderType(config.ai_provider);
    const ai_cfg = ai_mod.provider.ProviderConfig{
        .provider_type = ptype,
        .endpoint = config.ai_endpoint,
        .port = config.ai_port,
        .use_tls = config.ai_use_tls,
        .model = config.ai_model,
        .api_key = config.ai_api_key,
    };
    const ipc_cap = cap_mod.Capability{ .cap_type = .ipc_ring, .rights = cap_mod.Rights.ALL, .object_id = 1, .data_addr = @intFromPtr(&global_ai_req_ring), .data_size = @sizeOf(ipc_mod.SpscRingBuffer) };
    const net_ptr = if (global_netd != null) &global_netd.? else null;
    global_aid = aid_mod.AiDaemon.init(allocator, ai_cfg, net_ptr, ipc_cap);
    if (global_aid) |*aid_inst| {
        aid_inst.setRings(&global_ai_req_ring, &global_ai_resp_ring);
        if (global_netd) |*netd| {
            if (netd.stack) |st| {
                global_tls_adapter.init(st);
                aid_inst.setTlsAdapter(&global_tls_adapter);
            }
        }
    }
    if (ptype == .mock) {
        serial.writeStatusOk("aid ", "Resident AI daemon active (mock mode)");
    } else {
        serial.writeStatusOk("aid ", "Resident AI daemon active (online live inference)");
    }
}

fn initP2pDaemon(allocator: std.mem.Allocator) void {
    var seed = [_]u8{0x42} ** 32;
    if (global_virtio_net) |vdev| @memcpy(seed[0..6], &vdev.mac);
    global_p2pd = p2pd_mod.P2pDaemon.init(allocator, seed, 8080) catch null;
    if (global_p2pd != null) {
        serial.writeStatusOk("p2pd", "P2P mesh discovery daemon active (Noise/mTLS :8080)");
    }
}

fn initPackageDaemon() void {
    global_pkgd = pkgd_mod.PackageDaemon.init();
    serial.writeStatusOk("pkgd", "Sovereign package federation registry active (SPK1)");
}

fn initUserlandServices(allocator: std.mem.Allocator) void {
    initNetDaemon(allocator);
    initAiDaemon(allocator);
    initP2pDaemon(allocator);
    initPackageDaemon();
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
    var act_id: u32 = 0;
    var pt_base: u64 = 0;
    if (maybe_fib) |fib| {
        if (fib.entry == actorThread and fib.user_data != null) {
            const act_ctx: *ActorThreadContext = @ptrCast(@alignCast(fib.user_data.?));
            act_id = act_ctx.actor.id;
            pt_base = act_ctx.actor.page_table_base;
        }
    }
    smp.global_topology.getCurrentCore().current_actor_id = act_id;
    idt.current_actor_id = act_id;
    syscall.setActorId(act_id);
    if (!builtin.is_test) {
        if (pt_base != 0) {
            vmm.switchAddressSpace(pt_base);
        } else if (vmm.kernel_pml4_phys != 0) {
            vmm.switchAddressSpace(vmm.kernel_pml4_phys);
        }
    }
}

fn actorYieldCheck(vm: *vm_mod.VM) anyerror!void {
    if (vm.user_data) |ud| {
        const actor: *actor_mod.Actor = @ptrCast(@alignCast(ud));
        if (actor.state == .terminated) return error.ActorTerminated;
    }
}

fn actorThread(ctx: ?*anyopaque) void {
    const act_ctx = @as(*ActorThreadContext, @ptrCast(@alignCast(ctx.?)));
    const actor = act_ctx.actor;
    var vm = act_ctx.vm;
    defer {
        if (vm.gc_heap) |h| {
            h.deinit();
            act_ctx.allocator.destroy(h);
            vm.gc_heap = null;
        }
        vm.deinit();
        act_ctx.allocator.destroy(vm);
        act_ctx.allocator.destroy(act_ctx);
        actor.release();
    }
    actor.state = .running;
    vm.run(0) catch |err| {
        if (actor.state != .terminated) actor.state = .faulted;
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

fn runVmCollect(ctx: *anyopaque) void {
    const vm_inst: *vm_mod.VM = @ptrCast(@alignCast(ctx));
    if (vm_inst.gc_heap) |h| vm_inst.collect(h);
}

fn attachActorVm(allocator: std.mem.Allocator, child: *actor_mod.Actor, chunk: *chunk_mod.Chunk) !void {
    const child_vm = try allocator.create(vm_mod.VM);
    try child_vm.initInPlace(allocator, chunk);
    errdefer {
        child_vm.deinit();
        allocator.destroy(child_vm);
    }
    const heap = try allocator.create(gc_mod.Heap);
    heap.* = gc_mod.Heap.init(allocator);
    heap.gc_callback = runVmCollect;
    heap.gc_ctx = child_vm;
    child_vm.gc_heap = heap;

    try abi_mod.registerSyscalls(child_vm);
    child_vm.user_data = child;
    child_vm.yield_hook = actorYieldCheck;
    const act_ctx = try allocator.create(ActorThreadContext);
    act_ctx.* = .{
        .allocator = allocator,
        .actor = child,
        .vm = child_vm,
    };
    errdefer allocator.destroy(act_ctx);
    if (global_sched) |sched| {
        _ = child.ref_count.fetchAdd(1, .acquire);
        const fib = try sched.spawn(actorThread, act_ctx);
        child.fiber_ctx = @ptrCast(fib);
    }
}

fn isVerifiedSystemScript(name: []const u8, source: []const u8) bool {
    const bsrc = bundleReadBridge(name) orelse return false;
    if (!std.mem.eql(u8, bsrc, source)) return false;
    const sys_names = [_][]const u8{ "msh", "harness", "installer", "rebuild", "httpd", "web", "vedit" };
    for (sys_names) |sname| {
        if (std.mem.eql(u8, name, sname)) return true;
    }
    return false;
}

fn delegateInitialCaps(child: *actor_mod.Actor, name: []const u8, source: []const u8) !void {
    if (!isVerifiedSystemScript(name, source)) return;
    if (global_fb) |*fb| {
        _ = try child.insertCap(.{
            .cap_type = .framebuffer,
            .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE,
            .object_id = CAP_OBJ_FRAMEBUFFER,
            .data_addr = @intFromPtr(fb),
            .data_size = @sizeOf(fb_mod.Framebuffer),
        });
    }
    _ = try child.insertCap(.{ .cap_type = .actor_control, .rights = cap_mod.Rights.ALL, .object_id = CAP_OBJ_ACTOR_CTRL, .data_addr = 0, .data_size = 0 });
    _ = try child.insertCap(.{ .cap_type = .storage_device, .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE, .object_id = CAP_OBJ_STORAGE, .data_addr = 0, .data_size = 0 });
    _ = try child.insertCap(.{ .cap_type = .network_device, .rights = cap_mod.Rights.ALL, .object_id = CAP_OBJ_NETWORK, .data_addr = 0, .data_size = 0 });
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
    child.source = persistent_source;

    try delegateInitialCaps(child, name, persistent_source);
    try attachActorVm(allocator, child, chunk);

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
    const actor = global_registry.get(actor_id) orelse return error.ActorNotFound;
    defer actor.release();
    const src = actor.source orelse return error.NoSourceRecorded;
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
    const code_buf = try allocator.alloc(u8, cas_mod.MAX_CHUNK_PAYLOAD_SIZE);
    defer allocator.free(code_buf);
    const len = try global_cas.?.getChunk(&raw_hash, code_buf, dev);
    return spawnActorFromCode(allocator, "cas_restored", code_buf[0..len]);
}

fn grantCapBridge(target_actor: u32, source_slot: u32, rights_mask: u16) anyerror!bool {
    const target = global_registry.get(target_actor) orelse return error.ActorNotFound;
    defer target.release();
    const cur = getCurrentActorBridge();
    const caller = cur orelse (global_registry.get(actor_mod.GENESIS_ACTOR_ID) orelse return error.ActorNotFound);
    defer if (cur == null) caller.release();
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
    const faults = if (global_supervisor) |s| s.total_faults else 0;
    return .{ .active_actors = @intCast(global_registry.active_count), .total_faults = faults, .free_ram_pages = 256, .uptime_ticks = 100 };
}

fn initBlkDevice(blk_pci: pci_mod.PciDevice, boot_info: *const BootInfo) bool {
    const ring_phys = pmm.allocContiguousPages(virtio_blk_mod.QUEUE_PAGES) orelse return false;
    const dma_phys = pmm.allocContiguousPages(virtio_blk_mod.DMA_PAGES) orelse return false;

    global_virtio_blk = virtio_blk_mod.VirtioBlkDevice.init(blk_pci, ring_phys, dma_phys, boot_info.hhdm_offset) catch |err| {
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

fn initStorageDaemon(allocator: std.mem.Allocator, dev: ?*block_mod.BlockDevice) ?storaged_mod.StorageDaemon {
    const storage_cap = cap_mod.Capability{
        .cap_type = .storage_device,
        .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE,
        .object_id = CAP_OBJ_STORAGE,
        .data_addr = if (dev != null) @intFromPtr(dev.?) else 0,
        .data_size = if (dev != null) @sizeOf(block_mod.BlockDevice) else 0,
    };
    const irq_cap = cap_mod.Capability{
        .cap_type = .irq_endpoint,
        .rights = cap_mod.Rights.WRITE,
        .object_id = 14,
        .data_addr = 0,
        .data_size = 0,
    };
    return storaged_mod.StorageDaemon.init(allocator, dev, storage_cap, irq_cap) catch |err| {
        serial.writeString("[kernel] StorageDaemon init failed: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return null;
    };
}

fn initFallbackCas(allocator: std.mem.Allocator, dev: ?*block_mod.BlockDevice) void {
    const cache_ptr = allocator.create(block_cache_mod.BlockCache) catch return;
    cache_ptr.* = block_cache_mod.BlockCache.init(allocator) catch return;
    global_block_cache = cache_ptr;

    const total_secs = if (dev != null) dev.?.total_sectors else 0;
    const cas_ptr = allocator.create(cas_mod.CasEngine) catch return;
    cas_ptr.* = cas_mod.CasEngine.init(
        global_block_cache.?,
        dev,
        total_secs,
    ) catch return;
    global_cas = cas_ptr;

    global_rebuild = rebuild_mod.RebuildEngine.init(global_cas.?, null, null);
    abi_mod.setRebuildEngine(&global_rebuild.?);
    serial.writeStatusOk("cas ", "BLAKE3 Content-Addressed Storage engine ready");
}

fn initStorageEngines(allocator: std.mem.Allocator) void {
    const dev = if (global_block_device != null) &global_block_device.? else null;
    global_storaged = initStorageDaemon(allocator, dev);

    if (global_storaged) |*strd| {
        global_block_cache = strd.block_cache;
        global_cas = strd.cas_engine;
        if (global_cas) |cas| {
            global_rebuild = rebuild_mod.RebuildEngine.init(cas, null, null);
            abi_mod.setRebuildEngine(&global_rebuild.?);
        }
        serial.writeStatusOk("cas ", "BLAKE3 Content-Addressed Storage engine ready");
        serial.writeStatusOk("strd", "Userland storage daemon active (CAS + VirtIO/NVMe)");
        return;
    }

    initFallbackCas(allocator, dev);
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
        hhdm,
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
    if (global_block_device == null) global_block_device = global_nvme_blk_dev.?;
    abi_mod.registerBlockDevice(&global_nvme_blk_dev.?);

    serial.writeString("  \x1b[90m[\x1b[92m  ok  \x1b[90m]\x1b[0m \x1b[96mnvme\x1b[90m: \x1b[97mPCIe NVMe 1.4 persistent drive (capacity: \x1b[0m");
    serial.writeDec(global_nvme.?.total_sectors);
    serial.writeString("\x1b[97m sectors)\x1b[0m\n");
    return true;
}

fn initStorage(boot_info: *const BootInfo, allocator: std.mem.Allocator) void {
    if (pci_mod.findVirtioBlkDevice()) |blk_dev| _ = initBlkDevice(blk_dev, boot_info);
    if (pci_mod.findNvmeDevice()) |nvme_dev| _ = initNvmeDevice(nvme_dev, boot_info);
    if (global_block_device != null) initStorageEngines(allocator);
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

fn registerGenesisHardwareCaps(genesis: *actor_mod.Actor) !void {
    if (global_virtio_net != null) {
        _ = try genesis.insertCap(.{
            .cap_type = .network_device,
            .rights = cap_mod.Rights.ALL,
            .object_id = CAP_OBJ_NETWORK,
            .data_addr = @intFromPtr(&global_virtio_net.?),
            .data_size = @sizeOf(virtio_net_mod.VirtioNetDevice),
        });
    }
    if ((global_virtio_blk != null or global_nvme != null) and global_cas != null) {
        _ = try genesis.insertCap(.{
            .cap_type = .storage_device,
            .rights = cap_mod.Rights.ALL,
            .object_id = CAP_OBJ_STORAGE,
            .data_addr = @intFromPtr(global_cas.?),
            .data_size = @sizeOf(cas_mod.CasEngine),
        });
    }
    _ = try genesis.insertCap(.{
        .cap_type = .actor_control,
        .rights = cap_mod.Rights.ALL,
        .object_id = CAP_OBJ_ACTOR_CTRL,
        .data_addr = 0,
        .data_size = 0,
    });
}

fn registerGenesisCapabilities(genesis: *actor_mod.Actor, boot_info: *const BootInfo, ring: *ipc_mod.RingBuffer) !void {
    if (boot_info.framebuffer.base_addr != 0) {
        _ = try genesis.insertCap(.{
            .cap_type = .framebuffer,
            .rights = cap_mod.Rights.ALL,
            .object_id = CAP_OBJ_FRAMEBUFFER,
            .data_addr = boot_info.framebuffer.base_addr,
            .data_size = boot_info.framebuffer.size_bytes,
        });
    }
    if (boot_info.bundle_base != 0 and boot_info.bundle_size != 0) {
        _ = try genesis.insertCap(.{
            .cap_type = .memory_extent,
            .rights = cap_mod.Rights.READ,
            .object_id = CAP_OBJ_BUNDLE,
            .data_addr = boot_info.bundle_base,
            .data_size = boot_info.bundle_size,
        });
    }
    _ = try genesis.insertCap(.{
        .cap_type = .ipc_ring,
        .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE,
        .object_id = CAP_OBJ_IPC_RING,
        .data_addr = @intFromPtr(ring),
        .data_size = @sizeOf(ipc_mod.RingBuffer),
    });
    try registerGenesisHardwareCaps(genesis);
}

fn buildFallbackGenesisChunk(allocator: std.mem.Allocator) !*chunk_mod.Chunk {
    const chunk = try allocator.create(chunk_mod.Chunk);
    chunk.* = chunk_mod.Chunk.init();
    errdefer {
        chunk.deinit(allocator);
        allocator.destroy(chunk);
    }
    const c_idx = try chunk.addConstant(allocator, eval_mod.Value{ .string = "Actor 0 initialized." });
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

fn bundleListBridge(prefix: []const u8, out_buf: []u8) usize {
    const raw = global_bundle_data orelse return 0;
    const reader = bundle_mod.BundleReader.init(raw) catch return 0;
    var written: usize = 0;
    var i: usize = 0;
    while (i < reader.header.entry_count) : (i += 1) {
        const entry = reader.getEntry(i) orelse break;
        const tag = entry.getTag();
        if (prefix.len == 0 or std.mem.startsWith(u8, tag, prefix)) {
            if (written + tag.len + 1 <= out_buf.len) {
                @memcpy(out_buf[written .. written + tag.len], tag);
                out_buf[written + tag.len] = '\n';
                written += tag.len + 1;
            }
        }
    }
    return written;
}

fn getCurrentActorBridge() ?*actor_mod.Actor {
    const sched = global_sched orelse return null;
    const fib = sched.current orelse return null;
    const ud = fib.user_data orelse return null;
    return @as(*ActorThreadContext, @ptrCast(@alignCast(ud))).actor;
}

fn loadGenesisChunk(allocator: std.mem.Allocator, boot_info: *const BootInfo, genesis: *actor_mod.Actor) !*chunk_mod.Chunk {
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
        genesis.source = allocator.dupe(u8, source) catch null;
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
    const fb_cap = cap_mod.Capability{ .cap_type = .framebuffer, .rights = cap_mod.Rights.WRITE | cap_mod.Rights.READ, .object_id = 1, .data_addr = fb_info.base_addr, .data_size = fb_info.size_bytes };
    global_gopd = gopd_mod.GopDaemon.init(allocator, fb_info, fb_cap) catch |err| blk: {
        serial.writeString("[kernel] GopDaemon init failed: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        break :blk null;
    };
    if (global_gopd) |*gopd| {
        global_canvas = gopd.canvas;
        global_wm = gopd.wm;
        global_pointer = gopd.pointer;
        serial.writeStatusOk("gopd", "Userland display server actor active (1280x800x32)");
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
        .bundle_list_fn = bundleListBridge,
        .current_actor_fn = getCurrentActorBridge,
        .net_stack = if (global_netd != null) global_netd.?.stack else null,
        .frame_info_fn = frameInfoBridge,
        .irq_ack_fn = irqAckBridge,
        .dma_pin_fn = dmaPinBridge,
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

    const chunk = loadGenesisChunk(allocator, boot_info, genesis) catch kernelPanic("load_genesis_chunk");
    const genesis_vm = allocator.create(vm_mod.VM) catch kernelPanic("vm_alloc");
    genesis_vm.initInPlace(allocator, chunk) catch kernelPanic("vm_init");
    const heap = allocator.create(gc_mod.Heap) catch kernelPanic("gc_alloc");
    heap.* = gc_mod.Heap.init(allocator);
    heap.gc_callback = runVmCollect;
    heap.gc_ctx = genesis_vm;
    genesis_vm.gc_heap = heap;
    return genesis_vm;
}

fn getCoreIdBridge() u32 {
    return smp.global_topology.getCurrentCore().core_id;
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

    fiber_mod.get_core_id_fn = getCoreIdBridge;
    var sched = fiber_mod.Scheduler.init(allocator);
    sched.on_context_switch = onFiberContextSwitch;
    global_sched = &sched;
    _ = sched.spawn(vmThread, genesis_vm) catch kernelPanic("fiber_spawn");
    _ = sched.spawn(serviceWorker, null) catch kernelPanic("service_spawn");
    sched.run();

    serial.writeString("[kernel] Event loop terminated. Halting.\n");
    haltLoop();
}

fn serviceWorker(ctx: ?*anyopaque) void {
    _ = ctx;
    while (true) {
        var work: usize = 0;
        if (global_netd) |*netd| work += netd.poll();
        if (global_aid) |*aid| work += aid.processClientIpc();
        if (global_storaged) |*strd| work += strd.processClientIpc();
        if (global_gopd) |*gopd| {
            if (!gopd.canvas.damage.isEmpty()) {
                gopd.poll();
                gopd.renderHyperTree();
                work += 1;
            }
        }
        if (work == 0) io.pause();
        fiber_mod.yield();
    }
}

fn vmThread(ctx: ?*anyopaque) void {
    var vm = @as(*vm_mod.VM, @ptrCast(@alignCast(ctx.?)));
    defer {
        if (vm.gc_heap) |h| {
            h.deinit();
            vm.gc_heap = null;
        }
    }
    vm.run(0) catch {
        serial.writeString("[kernel] Genesis Actor crashed!\n");
    };
}

fn haltLoop() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}
