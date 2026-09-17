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
const harness_bindings_mod = @import("harness_bindings.zig");
const ps2_kbd_mod = @import("drivers/ps2_kbd.zig");
const pci_mod = @import("drivers/pci.zig");
const virtio_net_mod = @import("drivers/virtio_net.zig");
const net_mod = @import("net.zig");
const ai_mod = @import("ai.zig");
const config = @import("config");

const EMBEDDED_GENESIS_BUNDLE: []const u8 = @embedFile("genesis.mcb");

const KERNEL_HEAP_SIZE: usize = 4 * 1024 * 1024;
var kernel_heap: [KERNEL_HEAP_SIZE]u8 align(4096) = undefined;

const COLOR_BG: u32 = 0x000F1E;
const COLOR_TITLE: u32 = 0x00E0FF;
const COLOR_SUBTITLE: u32 = 0x50FA7B;

const CAP_OBJ_FRAMEBUFFER: u32 = 1;
const CAP_OBJ_IPC_RING: u32 = 2;
const CAP_OBJ_BUNDLE: u32 = 3;
const CAP_OBJ_NETWORK: u32 = 4;

const GENESIS_CSPACE_CAPACITY: usize = 64;
const GENESIS_PAGE_TABLE_ROOT: u64 = 0;

var global_registry: actor_mod.ActorRegistry = actor_mod.ActorRegistry.init();
var global_fb: ?fb_mod.Framebuffer = null;
var global_supervisor: ?supervisor_mod.Supervisor = null;
var global_harness_ctx: ?harness_bindings_mod.HarnessContext = null;
var global_virtio_net: ?virtio_net_mod.VirtioNetDevice = null;
var global_net_stack: ?net_mod.stack.NetworkStack = null;
var global_kbd: ps2_kbd_mod.Ps2Keyboard = ps2_kbd_mod.Ps2Keyboard.init();
var global_sched: ?*fiber_mod.Scheduler = null;

fn kernelPanic(stage: []const u8) noreturn {
    serial.writeString("\n[KERNEL PANIC] Fatal error at stage: ");
    serial.writeString(stage);
    serial.writeString("\nHalting CPU.\n");
    haltLoop();
}

fn initHardware(boot_info: *const BootInfo) void {
    asm volatile ("cli");
    serial.init();
    serial.writeString("\n=============================================\n");
    serial.writeString(" MicrOS (µOS) Sovereign Substrate (Milestone 11)\n");
    serial.writeString("=============================================\n");

    if (boot_info.magic != boot_info_mod.BOOT_INFO_MAGIC) {
        serial.writeString("[kernel] Fatal: Invalid BootInfo signature!\n");
        haltLoop();
    }
    serial.writeString("[kernel] BootInfo validated successfully.\n");

    gdt.init();
    idt.init();
    pmm.init(boot_info);
    vmm.init(boot_info.hhdm_offset);
    serial.writeString("[kernel] GDT, IDT, PMM, and VMM initialized.\n");
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
    serial.writeString("[kernel] Entering initVirtioNet...\n");
    const rx_ring = pmm.allocContiguousPages(virtio_net_mod.QUEUE_PAGES) orelse {
        serial.writeString("[kernel] PMM allocContiguousPages failed for rx_ring\n");
        return;
    };
    const tx_ring = pmm.allocContiguousPages(virtio_net_mod.QUEUE_PAGES) orelse {
        serial.writeString("[kernel] PMM allocContiguousPages failed for tx_ring\n");
        return;
    };
    const rx_buf = pmm.allocContiguousPages(16) orelse {
        serial.writeString("[kernel] PMM allocContiguousPages failed for rx_buf\n");
        return;
    };
    const tx_buf = pmm.allocPage() orelse {
        serial.writeString("[kernel] PMM allocPage failed for tx_buf\n");
        return;
    };

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
    serial.writeString("[kernel] VirtIO-Net active. MAC: ");
    printMac(&global_virtio_net.?.mac);
    serial.writeString("\n");
}

fn runDhcpHandshake() void {
    if (global_virtio_net == null) return;
    global_net_stack = net_mod.stack.NetworkStack.init(&global_virtio_net.?);
    serial.writeString("[kernel] Initiating DHCP auto-configuration...\n");

    var attempt: usize = 0;
    while (!global_net_stack.?.dhcp_config.bound and attempt < 5) : (attempt += 1) {
        global_net_stack.?.startDhcp() catch continue;
        var iter: usize = 0;
        while (!global_net_stack.?.dhcp_config.bound and iter < 100_000) : (iter += 1) {
            global_net_stack.?.poll();
        }
    }

    if (!global_net_stack.?.dhcp_config.bound) {
        serial.writeString("[kernel] Warning: DHCP timeout.\n");
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
    serial.writeString("[kernel] Connecting to Resident AI on port ");
    serial.writeHex(config.ai_port);
    serial.writeString("...\n");
    global_net_stack.?.connectTcp(ip, config.ai_port) catch |err| {
        serial.writeString("[kernel] TCP connection failed: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return false;
    };
    serial.writeString("[net] TCP 3-Way Handshake ESTABLISHED to Resident AI!\n");
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
    serial.writeString("[kernel] Initiating pure Zig TLS 1.3 handshake with ");
    serial.writeString(config.ai_endpoint);
    serial.writeString("...\n");
    global_tls_adapter.init(&global_net_stack.?);
    global_tls_adapter.handshake(config.ai_endpoint) catch |err| {
        serial.writeString("[kernel] TLS 1.3 handshake failed: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        global_tls_ready = false;
        return;
    };
    global_tls_ready = true;
    serial.writeString("[net] TLS 1.3 Handshake ESTABLISHED with Resident AI!\n");
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
}

fn readAiResponse(out_text: []u8) usize {
    const read_bytes = collectHttpStream(&ai_http_resp_buf);
    if (read_bytes == 0) return 0;
    serial.writeString("[ai] Response received (");
    serial.writeHex(@intCast(read_bytes));
    serial.writeString(" bytes)\n");

    const resp = net_mod.http.parseResponseHeaders(&ai_http_resp_buf, read_bytes) catch |err| {
        serial.writeString("[ai] HTTP parse error: ");
        serial.writeString(@errorName(err));
        serial.writeString("\n");
        return 0;
    };

    if (resp.status_code != net_mod.http.HTTP_OK) {
        serial.writeString("[ai] HTTP status: ");
        serial.writeHex(resp.status_code);
        serial.writeString("\n");
    }

    if (resp.body_offset < read_bytes) {
        if (global_ai_client.extractResponseText(ai_http_resp_buf[resp.body_offset..read_bytes], out_text)) |tlen| {
            serial.writeString("\n*** [RESIDENT AI SOVEREIGN INTELLIGENCE ONLINE] ***\n");
            serial.writeString(out_text[0..tlen]);
            serial.writeString("\n***************************************************\n\n");
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
        return global_ai_client.extractResponseText("", out_text) orelse 0;
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
    serial.writeString("[kernel] Re-establishing TLS connection for sovereign turn...\n");
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

fn actorThread(ctx: ?*anyopaque) void {
    var vm = @as(*vm_mod.VM, @ptrCast(@alignCast(ctx.?)));
    vm.run(0) catch |err| {
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
    };
}

fn spawnActorFromCode(allocator: std.mem.Allocator, name: []const u8, source: []const u8) anyerror!u32 {
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

    const child_vm = try allocator.create(vm_mod.VM);
    try child_vm.initInPlace(allocator, chunk);
    errdefer {
        child_vm.deinit();
        allocator.destroy(child_vm);
    }

    try harness_bindings_mod.registerBindings(child_vm);

    if (global_sched) |sched| {
        const fib = try sched.spawn(actorThread, child_vm);
        child.fiber_ctx = @ptrCast(fib);
    }

    serial.writeString("[kernel] Spawned dynamic Actor ");
    serial.writeHex(child.id);
    serial.writeString(" (");
    serial.writeString(name);
    serial.writeString(") successfully.\n");

    return child.id;
}

fn initNetwork(boot_info: *const BootInfo) void {
    serial.writeString("[kernel] Probing PCI bus for network devices...\n");
    const maybe_net = pci_mod.findNetworkDevice();
    if (maybe_net) |net_dev| {
        serial.writeString("[kernel] Found PCI net device. Vendor: 0x");
        serial.writeHex(net_dev.vendor_id);
        serial.writeString(" Device: 0x");
        serial.writeHex(net_dev.device_id);
        serial.writeString("\n");
        if (net_dev.vendor_id == pci_mod.VENDOR_VIRTIO) {
            serial.writeString("[kernel] Vendor matches VENDOR_VIRTIO. Calling initVirtioNet...\n");
            initVirtioNet(net_dev, boot_info);
            runDhcpHandshake();
        } else {
            serial.writeString("[kernel] Vendor did not match VIRTIO.\n");
        }
    } else {
        serial.writeString("[kernel] No PCI network device found.\n");
    }
}

fn initGenesisDisplay(boot_info: *const BootInfo) void {
    if (boot_info.framebuffer.base_addr == 0) return;

    var framebuffer = fb_mod.Framebuffer.init(boot_info.framebuffer);
    framebuffer.clear(COLOR_BG);
    framebuffer.drawString(20, 20, "MicrOS (uOS) Sovereign Substrate", COLOR_TITLE, COLOR_BG);
    framebuffer.drawString(20, 36, "Genesis Actor Active. Zero PIDs. Ambient Authority Eradicated.", COLOR_SUBTITLE, COLOR_BG);
    framebuffer.drawRect(20, 52, 600, 2, COLOR_TITLE);
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

fn registerGenesisCapabilities(
    genesis: *actor_mod.Actor,
    boot_info: *const BootInfo,
    ring: *ipc_mod.RingBuffer,
) !void {
    if (boot_info.framebuffer.base_addr != 0) {
        _ = try genesis.insertCap(cap_mod.Capability{
            .cap_type = .framebuffer,
            .rights = cap_mod.Rights.ALL,
            .object_id = CAP_OBJ_FRAMEBUFFER,
            .data_addr = boot_info.framebuffer.base_addr,
            .data_size = boot_info.framebuffer.size_bytes,
        });
    }

    _ = try genesis.insertCap(cap_mod.Capability{
        .cap_type = .ipc_ring,
        .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE,
        .object_id = CAP_OBJ_IPC_RING,
        .data_addr = @intFromPtr(ring),
        .data_size = @sizeOf(ipc_mod.RingBuffer),
    });

    if (boot_info.bundle_base != 0 and boot_info.bundle_size != 0) {
        _ = try genesis.insertCap(cap_mod.Capability{
            .cap_type = .memory_extent,
            .rights = cap_mod.Rights.READ,
            .object_id = CAP_OBJ_BUNDLE,
            .data_addr = boot_info.bundle_base,
            .data_size = boot_info.bundle_size,
        });
    }

    try registerNetworkCap(genesis);
}

fn buildFallbackGenesisChunk(allocator: std.mem.Allocator) !chunk_mod.Chunk {
    var chunk = chunk_mod.Chunk.init();
    const msg = eval_mod.Value{ .string = "Genesis Actor executing in Actor 0 under CSpace capability control." };
    const c_idx = try chunk.addConstant(allocator, msg);

    try chunk.writeChunk(allocator, @intFromEnum(chunk_mod.OpCode.constant));
    try chunk.writeChunk(allocator, @intCast((c_idx >> 8) & 0xFF));
    try chunk.writeChunk(allocator, @intCast(c_idx & 0xFF));
    try chunk.writeChunk(allocator, @intFromEnum(chunk_mod.OpCode.print));
    try chunk.writeChunk(allocator, @intFromEnum(chunk_mod.OpCode.return_op));
    return chunk;
}

fn loadGenesisChunk(allocator: std.mem.Allocator, boot_info: *const BootInfo) !chunk_mod.Chunk {
    const raw_bundle: []const u8 = if (boot_info.bundle_base != 0 and boot_info.bundle_size != 0)
        @as([*]const u8, @ptrFromInt(boot_info.bundle_base))[0..boot_info.bundle_size]
    else
        EMBEDDED_GENESIS_BUNDLE;

    const reader = bundle_mod.BundleReader.init(raw_bundle) catch {
        serial.writeString("[kernel] Warning: BundleReader failed. Using fallback chunk.\n");
        return buildFallbackGenesisChunk(allocator);
    };

    const maybe_source = reader.findData("harness.mx") orelse reader.findData("init.mx");
    if (maybe_source) |source| {
        serial.writeString("[kernel] Found startup script in Genesis MCB bundle. Compiling...\n");
        var chunk = chunk_mod.Chunk.init();
        var compiler = compiler_mod.Compiler.init(allocator, &chunk);
        var p = parser_mod.Parser.init(allocator, source);
        while (p.current_token.token_type != .eof) {
            const stmt = try p.parseStatement();
            try compiler.compile(stmt);
        }
        try chunk.writeChunk(allocator, @intFromEnum(chunk_mod.OpCode.return_op));
        serial.writeString("[kernel] Script compiled successfully.\n");
        return chunk;
    }

    serial.writeString("[kernel] No startup script found in bundle. Using fallback chunk.\n");
    return buildFallbackGenesisChunk(allocator);
}

fn setupHarnessEnvironment(
    genesis: *actor_mod.Actor,
    boot_info: *const BootInfo,
    ipc_ring: *ipc_mod.RingBuffer,
    vm: *vm_mod.VM,
) void {
    initAiClient();
    idt.setInputRing(ipc_ring);
    global_registry.register(genesis) catch kernelPanic("register_genesis");
    global_supervisor = supervisor_mod.Supervisor.init(&global_registry, .restart_immediate);

    if (boot_info.framebuffer.base_addr != 0) {
        global_fb = fb_mod.Framebuffer.init(boot_info.framebuffer);
    }

    global_harness_ctx = harness_bindings_mod.HarnessContext{
        .registry = &global_registry,
        .supervisor = genesis,
        .framebuffer = if (global_fb != null) &global_fb.? else null,
        .ipc_ring = ipc_ring,
        .supervisor_ctrl = if (global_supervisor != null) &global_supervisor.? else null,
        .kbd_ctrl = &global_kbd,
        .ai_inference_fn = aiInferenceBridge,
        .spawn_code_fn = spawnActorFromCode,
    };
    harness_bindings_mod.setContext(&global_harness_ctx.?);
    harness_bindings_mod.registerBindings(vm) catch kernelPanic("harness_bindings");
}

pub export fn kmain(boot_info: *const BootInfo) callconv(.c) noreturn {
    initHardware(boot_info);
    serial.writeString("[kernel] kmain at 0x");
    serial.writeHex(@intFromPtr(&kmain));
    serial.writeString("\n");

    var fba = std.heap.FixedBufferAllocator.init(&kernel_heap);
    const allocator = fba.allocator();

    serial.writeString("[kernel] Step 1: Initializing Genesis Actor...\n");
    const genesis = actor_mod.Actor.init(
        allocator,
        actor_mod.GENESIS_ACTOR_ID,
        "genesis_actor",
        GENESIS_CSPACE_CAPACITY,
        GENESIS_PAGE_TABLE_ROOT,
    ) catch kernelPanic("actor_init");

    serial.writeString("[kernel] Step 2: Initializing IPC ring...\n");
    const ipc_ring = ipc_mod.RingBuffer.init(allocator, ipc_mod.DEFAULT_RING_CAPACITY) catch kernelPanic("ipc_ring_init");

    serial.writeString("[kernel] Step 3: Registering capabilities...\n");
    registerGenesisCapabilities(genesis, boot_info, ipc_ring) catch kernelPanic("register_caps");

    serial.writeString("[kernel] Step 4: Initializing display...\n");
    initGenesisDisplay(boot_info);

    serial.writeString("[kernel] Step 5: Loading Genesis Chunk...\n");
    var chunk = loadGenesisChunk(allocator, boot_info) catch kernelPanic("load_genesis_chunk");

    serial.writeString("[kernel] Step 6: Initializing VM...\n");
    const genesis_vm = allocator.create(vm_mod.VM) catch kernelPanic("vm_alloc");
    genesis_vm.initInPlace(allocator, &chunk) catch kernelPanic("vm_init");

    serial.writeString("[kernel] Step 7: Configuring Sovereign Harness...\n");
    setupHarnessEnvironment(genesis, boot_info, ipc_ring, genesis_vm);

    serial.writeString("[kernel] Step 8: Starting cooperative event loop in Genesis Actor...\n");
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
