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
const block_cache_mod = @import("storage/block_cache.zig");
const cas_mod = @import("storage/cas.zig");
const cas_chunk_mod = @import("storage/chunk.zig");
const net_mod = @import("net.zig");
const ai_mod = @import("ai.zig");
const compositor_mod = @import("compositor.zig");
const config = @import("config");

const EMBEDDED_GENESIS_BUNDLE: []const u8 = @embedFile("genesis.mcb");

const KERNEL_HEAP_SIZE: usize = 8 * 1024 * 1024;
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
var global_net_stack: ?net_mod.stack.NetworkStack = null;
var global_kbd: ps2_kbd_mod.Ps2Keyboard = ps2_kbd_mod.Ps2Keyboard.init();
var global_sched: ?*fiber_mod.Scheduler = null;
var global_virtio_blk: ?virtio_blk_mod.VirtioBlkDevice = null;
var global_block_cache: ?block_cache_mod.BlockCache = null;
var global_cas: ?cas_mod.CasEngine = null;
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

fn runDhcpHandshake() void {
    if (global_virtio_net == null) return;
    global_net_stack = net_mod.stack.NetworkStack.init(&global_virtio_net.?);

    var attempt: usize = 0;
    while (!global_net_stack.?.dhcp_config.bound and attempt < 5) : (attempt += 1) {
        global_net_stack.?.startDhcp() catch continue;
        var iter: usize = 0;
        while (!global_net_stack.?.dhcp_config.bound and iter < 100_000) : (iter += 1) {
            global_net_stack.?.poll();
        }
    }

    if (!global_net_stack.?.dhcp_config.bound) {
        serial.writeStatusWarn("dhcp", "Network auto-configuration timed out");
    }
}

var global_ai_ip: ?[4]u8 = null;

fn runDnsResolution() ?[4]u8 {
    if (global_ai_ip) |ip| return ip;
    if (global_net_stack == null or !global_net_stack.?.dhcp_config.bound) return null;
    serial.writeString("[kernel] Resolving DNS for Resident AI endpoint (");
    serial.writeString(config.ai_endpoint);
    serial.writeString(")...\n");
    const ip = global_net_stack.?.resolveDns(config.ai_endpoint) catch |err| {
        serial.writeString("[kernel] DNS resolution failed: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return null;
    };
    global_ai_ip = ip;
    serial.writeString("[net] DNS Resolved! ");
    serial.writeString(config.ai_endpoint);
    serial.writeString(" -> ");
    global_net_stack.?.printIp(ip);
    serial.writeString("\n");
    return ip;
}

fn runTcpConnection(ip: [4]u8) bool {
    if (global_net_stack == null) return false;
    global_net_stack.?.connectTcp(ip, config.ai_port) catch |err| {
        serial.writeString("[kernel] TCP connection failed: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return false;
    };
    return true;
}

var global_tls_adapter: net_mod.tls_stream.TcpStreamAdapter = undefined;
var global_tls_ready: bool = false;

fn runTlsHandshake() void {
    if (global_net_stack == null) return;
    if (!config.ai_use_tls) {
        global_tls_ready = true;
        return;
    }
    global_tls_adapter.init(&global_net_stack.?);
    global_tls_adapter.handshake(config.ai_endpoint) catch |err| {
        serial.writeString("[kernel] TLS 1.3 handshake failed: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        global_tls_ready = false;
        return;
    };
    global_tls_ready = true;
}

var global_ai_client: ai_mod.client.AiClient = undefined;
var ai_http_req_buf: [8192]u8 = undefined;
var ai_http_body_buf: [8192]u8 = undefined;
var ai_http_resp_buf: [65536]u8 = undefined;
var ai_text_buf: [32768]u8 = undefined;
var ai_code_buf: [8192]u8 = undefined;

fn initAiClient() void {
    const ptype = ai_mod.provider.parseProviderType(config.ai_provider);
    const cfg = ai_mod.provider.ProviderConfig{
        .provider_type = ptype,
        .endpoint = config.ai_endpoint,
        .port = config.ai_port,
        .use_tls = config.ai_use_tls,
        .model = config.ai_model,
        .api_key = config.ai_api_key,
    };
    global_ai_client = ai_mod.client.AiClient.init(cfg);
    if (ptype != .mock and ptype != .local_http and config.ai_api_key.len == 0) {
        serial.writeStatusWarn("ai  ", "No API key configured for resident AI");
    }
}

fn readAiResponse(out_text: []u8) usize {
    const read_bytes = collectHttpStream(&ai_http_resp_buf);
    if (read_bytes == 0) return 0;
    serial.writeString("[ai] Response received (");
    serial.writeDec(read_bytes);
    serial.writeString(" bytes)\n");

    const resp = net_mod.http.parseResponseHeaders(&ai_http_resp_buf, read_bytes) catch |err| {
        serial.writeString("[ai] HTTP parse error: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return 0;
    };

    if (resp.status_code != net_mod.http.HTTP_OK) {
        serial.writeString("[ai] HTTP status: ");
        serial.writeDec(resp.status_code);
        serial.writeString("\n");
    }

    if (resp.body_offset < read_bytes) {
        if (global_ai_client.extractResponseText(ai_http_resp_buf[resp.body_offset..read_bytes], out_text)) |tlen| {
            return tlen;
        }
        logRawBody(read_bytes, resp.body_offset);
    }
    return 0;
}

fn collectHttpStream(dest: []u8) usize {
    var total_read: usize = 0;
    while (total_read < dest.len) {
        const n = global_tls_adapter.readSlice(dest[total_read..]) catch |err| {
            if (total_read > 0) break;
            serial.writeString("[ai] Read failed: ");
            serial.writeString(@errorName(err));
            serial.writeString("\n");
            return 0;
        };
        if (n == 0) break;
        total_read += n;
        if (checkHttpDone(dest[0..total_read])) break;
    }
    return total_read;
}

fn checkHttpDone(data: []const u8) bool {
    const resp = net_mod.http.parseResponseHeaders(data, data.len) catch return false;
    const clen = resp.content_length orelse return false;
    return data.len >= resp.body_offset + clen;
}

fn logRawBody(read_bytes: usize, body_offset: usize) void {
    serial.writeString("[ai] Raw body preview:\n");
    const print_len = @min(read_bytes - body_offset, 512);
    serial.writeString(ai_http_resp_buf[body_offset .. body_offset + print_len]);
    serial.writeString("\n");
}

fn executeAiInference(prompt: []const u8, out_text: []u8) usize {
    if (global_ai_client.config.provider_type == .mock) {
        return ai_mod.mock.generateResponse(prompt, out_text) catch 0;
    }
    if (!global_tls_ready) return 0;
    serial.writeString("[ai] Dispatching prompt to Resident AI (");
    serial.writeString(global_ai_client.config.model);
    serial.writeString(")...\n");

    const req_len = global_ai_client.formatPromptRequest(
        &ai_http_req_buf,
        &ai_http_body_buf,
        prompt,
    ) catch |err| {
        serial.writeString("[ai] Request format error: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return 0;
    };

    global_tls_adapter.writeAll(ai_http_req_buf[0..req_len]) catch |err| {
        serial.writeString("[ai] Send error: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return 0;
    };

    serial.writeString("[ai] Prompt sent! Awaiting cognitive response...\n");
    return readAiResponse(out_text);
}

fn ensureTlsConnection() bool {
    if (global_tls_ready and global_tls_adapter.connected) {
        if (global_net_stack) |*stack| {
            if (stack.tcp_client) |*client| {
                if (client.state == .established) return true;
            }
        }
    }
    serial.writeString("[kernel] Re-establishing TLS connection...\n");
    global_tls_ready = false;
    global_tls_adapter.close();
    return attemptEstablishSession();
}

fn attemptEstablishSession() bool {
    const ip = runDnsResolution() orelse return false;
    if (!runTcpConnection(ip)) return false;
    runTlsHandshake();
    return global_tls_ready;
}

fn aiInferenceBridge(prompt: []const u8, out_text: []u8) usize {
    if (global_ai_client.config.provider_type != .mock) {
        if (!ensureTlsConnection()) return 0;
    }
    return executeAiInference(prompt, out_text);
}

const ActorThreadContext = struct {
    actor: *actor_mod.Actor,
    vm: *vm_mod.VM,
};

fn actorThread(ctx: ?*anyopaque) void {
    const act_ctx = @as(*ActorThreadContext, @ptrCast(@alignCast(ctx.?)));
    const actor = act_ctx.actor;
    var vm = act_ctx.vm;
    actor.state = .running;
    vm.run(0) catch |err| {
        actor.state = .faulted;
        serial.writeString("[kernel] Spawned Actor crashed: ");
        serial.writeString(@errorName(err));
        if (vm.last_missing_symbol) |sym| {
            serial.writeString(" [Undefined symbol: '");
            serial.writeString(sym);
            serial.writeString("']");
        }
        serial.writeString(" ip=");
        serial.writeHex(vm.ip);
        serial.writeString(" sp=");
        serial.writeHex(vm.sp);
        serial.writeString("\n");
        return;
    };
    actor.state = .terminated;
}

fn compileActorScript(allocator: std.mem.Allocator, source: []const u8) !*chunk_mod.Chunk {
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
    return chunk;
}

fn logActorSpawn(id: u32, name: []const u8) void {
    serial.writeString("  [  \x1b[32mok\x1b[0m  ] spawn: Actor ");
    serial.writeDec(id);
    serial.writeString(" (");
    serial.writeString(name);
    serial.writeString("\x1b[97m) online\x1b[0m\n");
}

fn compileActorSource(allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!*chunk_mod.Chunk {
    return compileActorScript(allocator, source) catch |err| {
        serial.writeString("[kernel] Actor compilation failed for '");
        serial.writeString(name);
        serial.writeString("': ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return err;
    };
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
        .actor = child,
        .vm = child_vm,
    };
    errdefer allocator.destroy(act_ctx);
    if (global_sched) |sched| {
        const fib = try sched.spawn(actorThread, act_ctx);
        child.fiber_ctx = @ptrCast(fib);
    }
}

fn spawnActorFromCode(allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 {
    const persistent_source = try allocator.dupe(u8, source);
    errdefer allocator.free(persistent_source);

    const chunk = try compileActorSource(allocator, name, persistent_source);
    errdefer {
        chunk.deinit(allocator);
        allocator.destroy(chunk);
    }

    const child = try global_registry.spawn(allocator, actor_mod.GENESIS_ACTOR_ID, name, 16, 0);
    errdefer global_registry.terminate(allocator, child.id) catch {};

    if (global_fb) |*fb| {
        _ = try child.insertCap(cap_mod.Capability{
            .cap_type = .framebuffer,
            .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE,
            .object_id = CAP_OBJ_FRAMEBUFFER,
            .data_addr = @intFromPtr(fb),
            .data_size = @sizeOf(fb_mod.Framebuffer),
        });
    }

    try attachActorVm(allocator, child, chunk);
    if (child.id < actor_mod.MAX_ACTORS) {
        global_actor_sources[child.id] = persistent_source;
    }

    logActorSpawn(child.id, name);
    return child.id;
}

fn casPutBridge(data: []const u8, out_hex: *[64]u8) anyerror!void {
    if (global_cas == null) return error.NoStorage;
    const dev = if (global_virtio_blk != null) &global_virtio_blk.? else null;
    const hash = try global_cas.?.putChunk(.raw_blob, data, dev);
    cas_chunk_mod.formatHexHash(&hash, out_hex);
}

fn casGetBridge(hex_hash: []const u8, out_buf: []u8) anyerror!usize {
    if (global_cas == null) return error.NoStorage;
    const dev = if (global_virtio_blk != null) &global_virtio_blk.? else null;
    var raw_hash: [cas_chunk_mod.HASH_SIZE]u8 = undefined;
    try cas_chunk_mod.parseHexHash(hex_hash, &raw_hash);
    return try global_cas.?.getChunk(&raw_hash, out_buf, dev);
}

fn persistActorBridge(actor_id: u32, out_hex: *[64]u8) anyerror!void {
    if (global_cas == null) return error.NoStorage;
    if (actor_id >= actor_mod.MAX_ACTORS) return error.ActorNotFound;
    const src = global_actor_sources[actor_id] orelse return error.NoSourceRecorded;
    const dev = if (global_virtio_blk != null) &global_virtio_blk.? else null;
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
    const dev = if (global_virtio_blk != null) &global_virtio_blk.? else null;
    var raw_hash: [cas_chunk_mod.HASH_SIZE]u8 = undefined;
    try cas_chunk_mod.parseHexHash(hex_hash, &raw_hash);
    var code_buf: [4096]u8 = undefined;
    const len = try global_cas.?.getChunk(&raw_hash, &code_buf, dev);
    return try spawnActorFromCode(allocator, "cas_restored", code_buf[0..len]);
}

fn grantCapBridge(target_actor: u32, source_slot: u32, rights_mask: u16) anyerror!bool {
    const target = global_registry.get(target_actor) orelse return error.ActorNotFound;
    const genesis = global_registry.get(actor_mod.GENESIS_ACTOR_ID) orelse return error.ActorNotFound;
    _ = try genesis.cspace.grant(source_slot, target.cspace, rights_mask);
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

    global_cas = cas_mod.CasEngine.init(
        &global_block_cache.?,
        &global_virtio_blk.?,
        global_virtio_blk.?.capacity_sectors,
    ) catch |err| {
        serial.writeString("[kernel] CAS engine init failed: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return;
    };

    serial.writeStatusOk("cas ", "BLAKE3 Content-Addressed Storage engine ready");
}

fn initVirtioBlk(blk_pci: pci_mod.PciDevice, boot_info: *const BootInfo, allocator: std.mem.Allocator) void {
    if (!initBlkDevice(blk_pci, boot_info)) return;
    initStorageEngines(allocator);
}

fn initStorage(boot_info: *const BootInfo, allocator: std.mem.Allocator) void {
    const maybe_blk = pci_mod.findBlockDevice();
    if (maybe_blk) |blk_dev| {
        if (blk_dev.vendor_id == pci_mod.VENDOR_VIRTIO) {
            initVirtioBlk(blk_dev, boot_info, allocator);
        }
    }
}

fn initNetwork(boot_info: *const BootInfo) void {
    const maybe_net = pci_mod.findNetworkDevice();
    if (maybe_net) |net_dev| {
        if (net_dev.vendor_id == pci_mod.VENDOR_VIRTIO) {
            initVirtioNet(net_dev, boot_info);
            runDhcpHandshake();
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
    if (global_virtio_blk != null and global_cas != null) {
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

fn setupAbiEnvironment(
    genesis: *actor_mod.Actor,
    boot_info: *const BootInfo,
    ipc_ring: *ipc_mod.RingBuffer,
    vm: *vm_mod.VM,
    allocator: std.mem.Allocator,
) void {
    initAiClient();
    idt.setInputRing(ipc_ring);
    global_registry.register(genesis) catch kernelPanic("register_genesis");
    global_supervisor = supervisor_mod.Supervisor.init(&global_registry, .restart_immediate);

    initCompositor(allocator, boot_info.framebuffer);

    global_abi_ctx = abi_mod.AbiContext{
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
    };
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
