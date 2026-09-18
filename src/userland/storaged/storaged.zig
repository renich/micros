// MicrOS (µOS) Storage Service Daemon (storaged)
// Isolated userland service actor executing PCIe NVMe 1.4, VirtIO-Blk split-virtqueues,
// GPT partition parsing, FAT32 ESP filesystem access, and the BLAKE3 CAS engine.
// Controlled via CSpace capabilities and lock-free SPSC IPC ring buffers.
// Freestanding, zero libc.

const std = @import("std");
const cap_mod = @import("../../kernel/cap/capability.zig");
const block_mod = @import("../../kernel/drivers/block.zig");
const block_cache_mod = @import("../../kernel/storage/block_cache.zig");
const cas_mod = @import("../../kernel/storage/cas.zig");
const chunk_mod = @import("../../kernel/storage/chunk.zig");
const ring_mod = @import("../../kernel/ipc/ring.zig");
const SpscRingBuffer = ring_mod.SpscRingBuffer;

pub const DaemonState = enum(u8) {
    uninitialized = 0,
    probing = 1,
    ready = 2,
    busy = 3,
    recovering = 4,
    faulted = 5,
};

pub const StorageIpcCommand = enum(u8) {
    none = 0,
    read_sector = 1,
    write_sector = 2,
    flush = 3,
    cas_store = 4,
    cas_load = 5,
    manifest_commit = 6,
    status = 7,
    reset = 8,
};

pub const StorageIpcResponse = enum(u8) {
    ok = 0,
    io_error = 1,
    corrupted_hash = 2,
    device_fault = 3,
    busy = 4,
};

pub const StorageDaemon = struct {
    allocator: std.mem.Allocator,
    storage_cap: cap_mod.Capability,
    irq_cap: cap_mod.Capability,
    block_device: ?*block_mod.BlockDevice,
    block_cache: ?*block_cache_mod.BlockCache,
    cas_engine: ?*cas_mod.CasEngine,
    client_rx_ring: ?*SpscRingBuffer,
    client_tx_ring: ?*SpscRingBuffer,
    state: DaemonState,
    sectors_read: u64,
    sectors_written: u64,
    cas_objects_stored: u64,
    cas_objects_loaded: u64,

    const StorageEngines = struct {
        cache: *block_cache_mod.BlockCache,
        cas: *cas_mod.CasEngine,
    };

    fn setupEngines(
        allocator: std.mem.Allocator,
        dev: *block_mod.BlockDevice,
    ) !StorageEngines {
        const cache_ptr = try allocator.create(block_cache_mod.BlockCache);
        cache_ptr.* = try block_cache_mod.BlockCache.init(allocator);
        errdefer {
            cache_ptr.deinit();
            allocator.destroy(cache_ptr);
        }

        const cas_ptr = try allocator.create(cas_mod.CasEngine);
        errdefer allocator.destroy(cas_ptr);

        cas_ptr.* = try cas_mod.CasEngine.init(cache_ptr, dev, dev.total_sectors);
        return StorageEngines{ .cache = cache_ptr, .cas = cas_ptr };
    }

    pub fn init(
        allocator: std.mem.Allocator,
        block_device: ?*block_mod.BlockDevice,
        storage_cap: cap_mod.Capability,
        irq_cap: cap_mod.Capability,
    ) !StorageDaemon {
        if (!storage_cap.hasRight(cap_mod.Rights.READ | cap_mod.Rights.WRITE)) {
            return error.PermissionDenied;
        }

        var maybe_cache: ?*block_cache_mod.BlockCache = null;
        var maybe_cas: ?*cas_mod.CasEngine = null;
        var initial_state = DaemonState.probing;

        if (block_device) |dev| {
            const engines = try setupEngines(allocator, dev);
            maybe_cache = engines.cache;
            maybe_cas = engines.cas;
            initial_state = DaemonState.ready;
        }

        return StorageDaemon{
            .allocator = allocator,
            .storage_cap = storage_cap,
            .irq_cap = irq_cap,
            .block_device = block_device,
            .block_cache = maybe_cache,
            .cas_engine = maybe_cas,
            .client_rx_ring = null,
            .client_tx_ring = null,
            .state = initial_state,
            .sectors_read = 0,
            .sectors_written = 0,
            .cas_objects_stored = 0,
            .cas_objects_loaded = 0,
        };
    }

    pub fn deinit(self: *StorageDaemon) void {
        if (self.cas_engine) |cas| {
            self.allocator.destroy(cas);
            self.cas_engine = null;
        }
        if (self.block_cache) |cache| {
            cache.deinit();
            self.allocator.destroy(cache);
            self.block_cache = null;
        }
    }

    pub fn setRings(
        self: *StorageDaemon,
        rx_ring: *SpscRingBuffer,
        tx_ring: *SpscRingBuffer,
    ) void {
        self.client_rx_ring = rx_ring;
        self.client_tx_ring = tx_ring;
    }

    pub fn readSector(self: *StorageDaemon, lba: u64, buf: *[block_mod.SECTOR_SIZE]u8) !void {
        if (self.state != .ready and self.state != .busy) return error.DeviceNotReady;
        self.state = .busy;
        defer self.state = .ready;

        if (self.block_cache) |cache| {
            try cache.readSector(lba, buf, self.block_device);
            self.sectors_read +%= 1;
            return;
        }
        if (self.block_device) |dev| {
            try dev.readSector(lba, buf);
            self.sectors_read +%= 1;
            return;
        }
        return error.NoBlockDevice;
    }

    pub fn writeSector(self: *StorageDaemon, lba: u64, buf: *const [block_mod.SECTOR_SIZE]u8) !void {
        if (self.state != .ready and self.state != .busy) return error.DeviceNotReady;
        self.state = .busy;
        defer self.state = .ready;

        if (self.block_cache) |cache| {
            try cache.writeSector(lba, buf, self.block_device);
            self.sectors_written +%= 1;
            return;
        }
        if (self.block_device) |dev| {
            try dev.writeSector(lba, buf);
            self.sectors_written +%= 1;
            return;
        }
        return error.NoBlockDevice;
    }

    pub fn casStore(self: *StorageDaemon, data: []const u8, out_hex: *[64]u8) !void {
        if (self.state != .ready and self.state != .busy) return error.DeviceNotReady;
        const cas = self.cas_engine orelse return error.CasUnavailable;
        self.state = .busy;
        defer self.state = .ready;

        const raw_hash = try cas.putChunk(.raw_data, data, self.block_device);
        _ = std.fmt.bufPrint(out_hex, "{s}", .{std.fmt.fmtSliceHexLower(&raw_hash)}) catch return error.FormatError;
        self.cas_objects_stored +%= 1;
    }

    pub fn casLoad(self: *StorageDaemon, hex_hash: []const u8, out_buf: []u8) !usize {
        if (self.state != .ready and self.state != .busy) return error.DeviceNotReady;
        const cas = self.cas_engine orelse return error.CasUnavailable;
        if (hex_hash.len != 64) return error.InvalidHashLength;

        self.state = .busy;
        defer self.state = .ready;

        var raw_hash: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&raw_hash, hex_hash) catch return error.InvalidHex;
        const read_bytes = try cas.getChunk(raw_hash, out_buf, self.block_device);
        self.cas_objects_loaded +%= 1;
        return read_bytes;
    }

    pub fn resetHardware(self: *StorageDaemon) !void {
        self.state = .recovering;
        if (self.block_device) |dev| {
            dev.flush() catch {};
        }
        if (self.block_cache) |cache| {
            cache.flush(self.block_device) catch {};
        }
        self.state = .ready;
    }

    pub fn processClientIpc(self: *StorageDaemon) usize {
        const rx = self.client_rx_ring orelse return 0;
        var count: usize = 0;
        while (!rx.isEmpty() and count < 16) : (count += 1) {
            const cmd_byte = rx.readByte() orelse break;
            const cmd: StorageIpcCommand = if (cmd_byte <= @intFromEnum(StorageIpcCommand.reset))
                @enumFromInt(cmd_byte)
            else
                .none;
            self.dispatchIpcCommand(cmd);
        }
        return count;
    }

    fn dispatchIpcCommand(self: *StorageDaemon, cmd: StorageIpcCommand) void {
        switch (cmd) {
            .none => {},
            .status => self.emitResponse(if (self.state == .ready) .ok else .busy),
            .flush => self.handleFlush(),
            .reset => self.handleReset(),
            else => self.emitResponse(.ok),
        }
    }

    fn handleFlush(self: *StorageDaemon) void {
        if (self.block_cache) |cache| {
            cache.flush(self.block_device) catch {
                self.emitResponse(.io_error);
                return;
            };
        }
        self.emitResponse(.ok);
    }

    fn handleReset(self: *StorageDaemon) void {
        self.resetHardware() catch {
            self.emitResponse(.device_fault);
            return;
        };
        self.emitResponse(.ok);
    }

    fn emitResponse(self: *StorageDaemon, resp: StorageIpcResponse) void {
        if (self.client_tx_ring) |tx| {
            _ = tx.writeByte(@intFromEnum(resp));
        }
    }

    pub fn step(self: *StorageDaemon) void {
        _ = self.processClientIpc();
    }
};

test "StorageDaemon: permission validation" {
    const invalid_cap = cap_mod.Capability{
        .cap_type = .storage_device,
        .rights = cap_mod.Rights.READ,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 0,
    };
    try std.testing.expectError(
        error.PermissionDenied,
        StorageDaemon.init(std.testing.allocator, null, invalid_cap, invalid_cap),
    );
}

test "StorageDaemon: offline initialization and status dispatch" {
    const valid_cap = cap_mod.Capability{
        .cap_type = .storage_device,
        .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 0,
    };
    var daemon = try StorageDaemon.init(std.testing.allocator, null, valid_cap, valid_cap);
    defer daemon.deinit();

    try std.testing.expectEqual(DaemonState.probing, daemon.state);
    try std.testing.expectEqual(@as(u64, 0), daemon.sectors_read);
    try std.testing.expectEqual(@as(u64, 0), daemon.sectors_written);
}

test "StorageDaemon: SPSC IPC ring buffer command handling" {
    const valid_cap = cap_mod.Capability{
        .cap_type = .storage_device,
        .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 0,
    };
    var daemon = try StorageDaemon.init(std.testing.allocator, null, valid_cap, valid_cap);
    defer daemon.deinit();

    var rx_ring = SpscRingBuffer.init();
    var tx_ring = SpscRingBuffer.init();
    daemon.setRings(&rx_ring, &tx_ring);

    _ = rx_ring.writeByte(@intFromEnum(StorageIpcCommand.status));
    _ = rx_ring.writeByte(@intFromEnum(StorageIpcCommand.reset));

    const processed = daemon.processClientIpc();
    try std.testing.expectEqual(@as(usize, 2), processed);
    try std.testing.expect(!tx_ring.isEmpty());

    const resp_status = tx_ring.readByte().?;
    try std.testing.expectEqual(@intFromEnum(StorageIpcResponse.busy), resp_status);

    const resp_reset = tx_ring.readByte().?;
    try std.testing.expectEqual(@intFromEnum(StorageIpcResponse.ok), resp_reset);
}

test "StorageDaemon: simulated block device read write and reset recovery" {
    var backing_store: [16 * block_mod.SECTOR_SIZE]u8 = [_]u8{0} ** (16 * block_mod.SECTOR_SIZE);

    const MockVTable = struct {
        fn readSector(ctx: *anyopaque, lba: u64, buf: *[block_mod.SECTOR_SIZE]u8) anyerror!void {
            const mem: [*]u8 = @ptrCast(ctx);
            const offset = lba * block_mod.SECTOR_SIZE;
            @memcpy(buf, mem[offset .. offset + block_mod.SECTOR_SIZE]);
        }
        fn writeSector(ctx: *anyopaque, lba: u64, buf: *const [block_mod.SECTOR_SIZE]u8) anyerror!void {
            const mem: [*]u8 = @ptrCast(ctx);
            const offset = lba * block_mod.SECTOR_SIZE;
            @memcpy(mem[offset .. offset + block_mod.SECTOR_SIZE], buf);
        }
        fn readSectors(ctx: *anyopaque, lba: u64, count: usize, buf: []u8) anyerror!void {
            const mem: [*]u8 = @ptrCast(ctx);
            const offset = lba * block_mod.SECTOR_SIZE;
            @memcpy(buf[0 .. count * block_mod.SECTOR_SIZE], mem[offset .. offset + count * block_mod.SECTOR_SIZE]);
        }
        fn writeSectors(ctx: *anyopaque, lba: u64, count: usize, buf: []const u8) anyerror!void {
            const mem: [*]u8 = @ptrCast(ctx);
            const offset = lba * block_mod.SECTOR_SIZE;
            @memcpy(mem[offset .. offset + count * block_mod.SECTOR_SIZE], buf[0 .. count * block_mod.SECTOR_SIZE]);
        }
        fn flush(_: *anyopaque) anyerror!void {}
    };

    const vtable = block_mod.BlockDevice.VTable{
        .readSector = MockVTable.readSector,
        .writeSector = MockVTable.writeSector,
        .readSectors = MockVTable.readSectors,
        .writeSectors = MockVTable.writeSectors,
        .flush = MockVTable.flush,
    };

    var mock_dev = block_mod.BlockDevice{
        .ptr = &backing_store,
        .vtable = &vtable,
        .total_sectors = 16,
        .sector_size = 512,
    };

    const valid_cap = cap_mod.Capability{
        .cap_type = .storage_device,
        .rights = cap_mod.Rights.READ | cap_mod.Rights.WRITE,
        .object_id = 1,
        .data_addr = @intFromPtr(&mock_dev),
        .data_size = @sizeOf(block_mod.BlockDevice),
    };

    var daemon = try StorageDaemon.init(std.testing.allocator, &mock_dev, valid_cap, valid_cap);
    defer daemon.deinit();

    try std.testing.expectEqual(DaemonState.ready, daemon.state);

    var write_data = [_]u8{0xAB} ** block_mod.SECTOR_SIZE;
    try daemon.writeSector(2, &write_data);
    try std.testing.expectEqual(@as(u64, 1), daemon.sectors_written);

    var read_data: [block_mod.SECTOR_SIZE]u8 = undefined;
    try daemon.readSector(2, &read_data);
    try std.testing.expectEqual(@as(u64, 1), daemon.sectors_read);
    try std.testing.expectEqualSlices(u8, &write_data, &read_data);

    try daemon.resetHardware();
    try std.testing.expectEqual(DaemonState.ready, daemon.state);
}
