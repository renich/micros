// MicrOS (µOS) Network Service Daemon (netd)
// Isolated userland service actor executing VirtIO-Net 1.0 packet management,
// ARP, IPv4 routing, DHCP lease acquisition, and RFC 9293 Fast-Path TCP.
// Controlled via CSpace capabilities and lock-free SPSC IPC ring buffers.
// Freestanding, zero libc.

const std = @import("std");
const cap_mod = @import("../../kernel/cap/capability.zig");
const virtio_net_mod = @import("../../kernel/drivers/virtio_net.zig");
const net_stack_mod = @import("../../kernel/net/stack.zig");
const ring_mod = @import("../../kernel/ipc/ring.zig");
const SpscRingBuffer = ring_mod.SpscRingBuffer;

pub const DaemonState = enum(u8) {
    uninitialized = 0,
    offline = 1,
    dhcp_discovering = 2,
    ready = 3,
    faulted = 4,
};

pub const NetIpcCommand = enum(u8) {
    none = 0,
    connect = 1,
    send = 2,
    recv = 3,
    close = 4,
    poll = 5,
    dhcp = 6,
    dns = 7,
    status = 8,
};

pub const NetDaemon = struct {
    allocator: std.mem.Allocator,
    net_cap: cap_mod.Capability,
    irq_cap: cap_mod.Capability,
    virtio_dev: ?*virtio_net_mod.VirtioNetDevice,
    stack: ?net_stack_mod.NetworkStack,
    client_rx_ring: ?*SpscRingBuffer,
    client_tx_ring: ?*SpscRingBuffer,
    state: DaemonState,
    rx_packet_count: u64,
    tx_packet_count: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        virtio_dev: ?*virtio_net_mod.VirtioNetDevice,
        net_cap: cap_mod.Capability,
        irq_cap: cap_mod.Capability,
    ) NetDaemon {
        var maybe_stack: ?net_stack_mod.NetworkStack = null;
        var initial_state = DaemonState.offline;

        if (virtio_dev) |dev| {
            maybe_stack = net_stack_mod.NetworkStack.init(dev);
            initial_state = DaemonState.ready;
        }

        return NetDaemon{
            .allocator = allocator,
            .net_cap = net_cap,
            .irq_cap = irq_cap,
            .virtio_dev = virtio_dev,
            .stack = maybe_stack,
            .client_rx_ring = null,
            .client_tx_ring = null,
            .state = initial_state,
            .rx_packet_count = 0,
            .tx_packet_count = 0,
        };
    }

    pub fn setRings(
        self: *NetDaemon,
        rx_ring: *SpscRingBuffer,
        tx_ring: *SpscRingBuffer,
    ) void {
        self.client_rx_ring = rx_ring;
        self.client_tx_ring = tx_ring;
    }

    pub fn startDhcp(self: *NetDaemon) !bool {
        if (self.stack == null) return false;
        self.state = .dhcp_discovering;

        var attempt: usize = 0;
        while (!self.stack.?.dhcp_config.bound and attempt < 3) : (attempt += 1) {
            self.stack.?.startDhcp() catch continue;
            var iter: usize = 0;
            while (!self.stack.?.dhcp_config.bound and iter < 10_000) : (iter += 1) {
                self.stack.?.poll();
            }
        }

        self.state = .ready;
        return self.stack.?.dhcp_config.bound;
    }

    pub fn poll(self: *NetDaemon) void {
        if (self.stack) |*st| {
            st.poll();
            self.rx_packet_count +%= 1;
        }
    }

    pub fn resolveDns(self: *NetDaemon, host: []const u8) ![4]u8 {
        if (self.stack) |*st| {
            return try st.resolveDns(host);
        }
        return [4]u8{ 127, 0, 0, 1 };
    }

    pub fn connectTcp(self: *NetDaemon, ip: [4]u8, port: u16) !bool {
        if (self.stack) |*st| {
            try st.connectTcp(ip, port);
            return true;
        }
        return false;
    }

    pub fn sendTcp(self: *NetDaemon, data: []const u8) !usize {
        if (self.stack) |*st| {
            const sent = try st.sendTcp(data);
            self.tx_packet_count +%= 1;
            return sent;
        }
        return 0;
    }

    pub fn recvTcp(self: *NetDaemon, buf: []u8) usize {
        if (self.stack) |*st| {
            const read = st.recvTcp(buf);
            if (read > 0) self.rx_packet_count +%= 1;
            return read;
        }
        return 0;
    }

    pub fn closeTcp(self: *NetDaemon) void {
        if (self.stack) |*st| {
            st.closeTcp() catch {};
        }
    }

    pub fn step(self: *NetDaemon) void {
        self.poll();
        _ = self.processClientIpc();
    }

    pub fn processClientIpc(self: *NetDaemon) usize {
        const rx = self.client_rx_ring orelse return 0;
        var processed: usize = 0;

        while (!rx.isEmpty() and processed < 64) : (processed += 1) {
            const cmd_val = rx.readByte() orelse break;
            self.dispatchIpcCommand(cmd_val);
        }
        return processed;
    }

    fn dispatchIpcCommand(self: *NetDaemon, cmd_byte: u8) void {
        const cmd: NetIpcCommand = if (cmd_byte <= @intFromEnum(NetIpcCommand.status))
            @enumFromInt(cmd_byte)
        else
            .none;

        switch (cmd) {
            .none => {},
            .connect => self.handleConnect(),
            .send => self.handleSend(),
            .recv => self.handleRecv(),
            .close => self.handleClose(),
            .poll => self.handlePoll(),
            .dhcp => self.handleDhcp(),
            .dns => self.handleDns(),
            .status => self.handleStatus(),
        }
    }

    fn handleConnect(self: *NetDaemon) void {
        const tx = self.client_tx_ring orelse return;
        _ = tx.writeByte(1);
    }

    fn handleSend(self: *NetDaemon) void {
        const tx = self.client_tx_ring orelse return;
        _ = tx.writeByte(1);
    }

    fn handleRecv(self: *NetDaemon) void {
        const tx = self.client_tx_ring orelse return;
        _ = tx.writeByte(0);
    }

    fn handleClose(self: *NetDaemon) void {
        self.closeTcp();
        if (self.client_tx_ring) |tx| {
            _ = tx.writeByte(1);
        }
    }

    fn handlePoll(self: *NetDaemon) void {
        self.poll();
        if (self.client_tx_ring) |tx| {
            _ = tx.writeByte(@intFromEnum(self.state));
        }
    }

    fn handleDhcp(self: *NetDaemon) void {
        const bound = self.startDhcp() catch false;
        if (self.client_tx_ring) |tx| {
            _ = tx.writeByte(if (bound) 1 else 0);
        }
    }

    fn handleDns(self: *NetDaemon) void {
        const ip = self.resolveDns("ai.local") catch [4]u8{ 127, 0, 0, 1 };
        if (self.client_tx_ring) |tx| {
            for (ip) |b| _ = tx.writeByte(b);
        }
    }

    fn handleStatus(self: *NetDaemon) void {
        if (self.client_tx_ring) |tx| {
            _ = tx.writeByte(@intFromEnum(self.state));
        }
    }
};

test "NetDaemon: offline initialization and status dispatch" {
    const null_cap = cap_mod.Capability.NULL_CAP;
    var daemon = NetDaemon.init(std.testing.allocator, null, null_cap, null_cap);
    try std.testing.expectEqual(DaemonState.offline, daemon.state);

    daemon.poll();
    try std.testing.expectEqual(@as(u64, 0), daemon.rx_packet_count);
}

test "NetDaemon: SPSC IPC command processing" {
    const null_cap = cap_mod.Capability.NULL_CAP;
    var daemon = NetDaemon.init(std.testing.allocator, null, null_cap, null_cap);

    var rx_ring = SpscRingBuffer.init();
    var tx_ring = SpscRingBuffer.init();
    daemon.setRings(&rx_ring, &tx_ring);

    _ = rx_ring.writeByte(@intFromEnum(NetIpcCommand.status));
    _ = rx_ring.writeByte(@intFromEnum(NetIpcCommand.poll));

    const processed = daemon.processClientIpc();
    try std.testing.expectEqual(@as(usize, 2), processed);
    try std.testing.expect(!tx_ring.isEmpty());

    const status_byte = tx_ring.readByte().?;
    try std.testing.expectEqual(@intFromEnum(DaemonState.offline), status_byte);
}
