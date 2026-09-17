// MicrOS (µOS) Sovereign Network Stack Orchestrator
// Coordinates VirtIO-Net, Ethernet, ARP, IPv4, ICMP, and DHCP.
// Zero libc, freestanding, capability-compatible.

const std = @import("std");
const frame_mod = @import("frame.zig");
const arp_mod = @import("arp.zig");
const ipv4_mod = @import("ipv4.zig");
const icmp_mod = @import("icmp.zig");
const udp_mod = @import("udp.zig");
const dhcp_mod = @import("dhcp.zig");
const dns_mod = @import("dns.zig");
const tcp_mod = @import("tcp.zig");
const virtio_net_mod = @import("../drivers/virtio_net.zig");
const serial = @import("../serial.zig");
const io = @import("../arch/x86_64/io.zig");

pub const IP_BROADCAST: [4]u8 = [_]u8{ 255, 255, 255, 255 };
pub const IP_ZERO: [4]u8 = [_]u8{ 0, 0, 0, 0 };
pub const DNS_FALLBACK_GOOGLE: [4]u8 = [_]u8{ 8, 8, 8, 8 };
pub const DNS_FALLBACK_CLOUDFLARE: [4]u8 = [_]u8{ 1, 1, 1, 1 };
pub const MAX_SYN_RETRIES: usize = 5;
pub const MAX_CHUNK_RETRIES: usize = 5;
pub const MAX_DNS_RETRIES: usize = 3;
pub const BASE_SYN_ITERS: usize = 100_000;
pub const BASE_CHUNK_ITERS: usize = 100_000;

pub const NetworkStack = struct {
    device: *virtio_net_mod.VirtioNetDevice,
    arp_table: arp_mod.ArpTable = arp_mod.ArpTable{},
    dhcp_config: dhcp_mod.DhcpConfig = dhcp_mod.DhcpConfig{},
    dhcp_xid: u32 = 0x4D494352, // "MICR"
    dns_xid: u16 = 0x5353,
    dns_result: ?[4]u8 = null,
    tcp_client: ?tcp_mod.TcpClient = null,
    tcp_rx_buf: [65536]u8 = undefined,
    tcp_rx_len: usize = 0,
    packet_id: u16 = 1,
    next_local_port: u16 = 50000,

    pub fn init(device: *virtio_net_mod.VirtioNetDevice) NetworkStack {
        return NetworkStack{ .device = device };
    }

    pub fn handleIncoming(self: *NetworkStack, raw_frame: []const u8) void {
        const eth_hdr = frame_mod.parseHeader(raw_frame) orelse return;
        const payload = frame_mod.getPayload(raw_frame);

        switch (eth_hdr.ethertype) {
            frame_mod.ETHERTYPE_ARP => self.processArp(payload),
            frame_mod.ETHERTYPE_IPV4 => self.processIpv4(eth_hdr.src_mac, payload),
            else => {},
        }
    }

    fn processArp(self: *NetworkStack, data: []const u8) void {
        const arp = arp_mod.parseArp(data) orelse return;
        self.arp_table.insert(arp.sender_ip, arp.sender_mac);

        if (arp.opcode == arp_mod.OP_REQUEST and self.dhcp_config.bound) {
            if (std.mem.eql(u8, &arp.target_ip, &self.dhcp_config.ip)) {
                self.sendArpReply(arp.sender_mac, arp.sender_ip);
            }
        }
    }

    fn processIpv4(self: *NetworkStack, src_mac: [6]u8, data: []const u8) void {
        const ip_hdr = ipv4_mod.parseHeader(data) orelse return;
        self.arp_table.insert(ip_hdr.src_ip, src_mac);
        if (!self.isTargetIp(ip_hdr.dst_ip)) return;

        const ip_header_len = @as(usize, ip_hdr.ihl) * 4;
        if (data.len < ip_header_len) return;
        const payload = data[ip_header_len..@min(data.len, ip_hdr.total_len)];

        switch (ip_hdr.protocol) {
            ipv4_mod.PROTO_ICMP => self.processIcmp(ip_hdr.src_ip, payload),
            ipv4_mod.PROTO_UDP => self.processUdp(payload),
            ipv4_mod.PROTO_TCP => self.processTcp(ip_hdr.src_ip, payload),
            else => {},
        }
    }

    fn processTcp(self: *NetworkStack, src_ip: [4]u8, payload: []const u8) void {
        const client = &(self.tcp_client orelse return);
        if (!std.mem.eql(u8, &src_ip, &client.remote_ip)) return;

        const tcp_hdr = tcp_mod.parseHeader(payload) orelse return;
        if (tcp_hdr.src_port != client.remote_port) return;

        const hdr_len = @as(usize, tcp_hdr.data_offset) * 4;
        const data = if (payload.len > hdr_len) payload[hdr_len..] else &[_]u8{};
        const was_syn_sent = (client.state == .syn_sent);

        if (!client.processSegment(tcp_hdr, data)) return;

        if (data.len > 0) {
            self.storeTcpData(data);
        }

        if (was_syn_sent and client.state == .established) {
            self.sendTcpAck(src_ip, client);
        } else if (data.len > 0 or (tcp_hdr.flags & tcp_mod.FLAG_FIN) != 0) {
            self.sendTcpAck(src_ip, client);
        }
    }

    fn sendTcpAck(self: *NetworkStack, dst_ip: [4]u8, client: *tcp_mod.TcpClient) void {
        var ack_buf: [64]u8 = undefined;
        const ack_len = client.buildAck(&ack_buf) catch return;
        self.sendIpv4(dst_ip, ipv4_mod.PROTO_TCP, ack_buf[0..ack_len]) catch {};
    }

    fn storeTcpData(self: *NetworkStack, data: []const u8) void {
        const copy_len = @min(data.len, self.tcp_rx_buf.len - self.tcp_rx_len);
        @memcpy(self.tcp_rx_buf[self.tcp_rx_len .. self.tcp_rx_len + copy_len], data[0..copy_len]);
        self.tcp_rx_len += copy_len;
    }

    fn isTargetIp(self: *const NetworkStack, dst_ip: [4]u8) bool {
        if (std.mem.eql(u8, &dst_ip, &IP_BROADCAST)) return true;
        if (self.dhcp_config.bound and std.mem.eql(u8, &dst_ip, &self.dhcp_config.ip)) return true;
        if (!self.dhcp_config.bound) return true;
        return false;
    }

    fn processIcmp(self: *NetworkStack, src_ip: [4]u8, payload: []const u8) void {
        const echo = icmp_mod.parseEcho(payload) orelse return;
        if (echo.icmp_type == icmp_mod.ICMP_TYPE_ECHO_REQUEST) {
            var reply_buf: [1514]u8 = undefined;
            const reply_len = icmp_mod.buildEchoReply(&reply_buf, echo) catch return;
            self.sendIpv4(src_ip, ipv4_mod.PROTO_ICMP, reply_buf[0..reply_len]) catch {};
        }
    }

    fn processUdp(self: *NetworkStack, payload: []const u8) void {
        const udp_hdr = udp_mod.parseHeader(payload) orelse return;
        if (udp_hdr.dst_port == dhcp_mod.PORT_CLIENT) {
            const dhcp_data = payload[udp_mod.UDP_HEADER_LEN..];
            const msg_type = dhcp_mod.parseResponse(dhcp_data, self.dhcp_xid, &self.dhcp_config) orelse return;
            self.handleDhcpMessage(msg_type);
        } else if (udp_hdr.src_port == dns_mod.PORT_DNS) {
            const dns_data = payload[udp_mod.UDP_HEADER_LEN..];
            if (dns_mod.parseResponse(dns_data, self.dns_xid)) |ip| {
                self.dns_result = ip;
            }
        }
    }

    fn handleDhcpMessage(self: *NetworkStack, msg_type: u8) void {
        if (msg_type == dhcp_mod.MSG_OFFER and !self.dhcp_config.bound) {
            self.sendDhcpRequest() catch {};
        } else if (msg_type == dhcp_mod.MSG_ACK) {
            self.dhcp_config.bound = true;
            if (self.arp_table.lookup(self.dhcp_config.server_id)) |mac| {
                self.arp_table.insert(self.dhcp_config.gateway, mac);
                self.arp_table.insert(self.dhcp_config.dns_server, mac);
            }
            serial.writeString("  \x1b[90m[\x1b[92m  ok  \x1b[90m]\x1b[0m \x1b[96mdhcp\x1b[90m: \x1b[97mBound to IP \x1b[0m");
            self.printIp(self.dhcp_config.ip);
            serial.writeString("\x1b[90m · \x1b[97mgateway \x1b[0m");
            self.printIp(self.dhcp_config.gateway);
            serial.writeString("\x1b[90m · \x1b[97mdns \x1b[0m");
            self.printIp(self.dhcp_config.dns_server);
            serial.writeString("\x1b[0m\n");
        }
    }

    pub fn printIp(_: *const NetworkStack, ip: [4]u8) void {
        for (ip, 0..) |octet, i| {
            if (i > 0) serial.writeChar('.');
            printDec(octet);
        }
    }

    pub fn startDhcp(self: *NetworkStack) !void {
        var dhcp_buf: [512]u8 = undefined;
        const dhcp_len = try dhcp_mod.buildDiscover(&dhcp_buf, self.device.mac, self.dhcp_xid);
        try self.sendUdpBroadcast(dhcp_mod.PORT_CLIENT, dhcp_mod.PORT_SERVER, dhcp_buf[0..dhcp_len]);
    }

    fn sendDhcpRequest(self: *NetworkStack) !void {
        var dhcp_buf: [512]u8 = undefined;
        const dhcp_len = try dhcp_mod.buildRequest(
            &dhcp_buf,
            self.device.mac,
            self.dhcp_xid,
            self.dhcp_config.ip,
            self.dhcp_config.server_id,
        );
        try self.sendUdpBroadcast(dhcp_mod.PORT_CLIENT, dhcp_mod.PORT_SERVER, dhcp_buf[0..dhcp_len]);
    }

    pub fn sendUdpBroadcast(self: *NetworkStack, src_port: u16, dst_port: u16, payload: []const u8) !void {
        var udp_buf: [1514]u8 = undefined;
        const udp_hdr_len = try udp_mod.writeHeader(&udp_buf, src_port, dst_port, @intCast(payload.len));
        @memcpy(udp_buf[udp_hdr_len .. udp_hdr_len + payload.len], payload);
        const total_udp_len = udp_hdr_len + payload.len;

        try self.sendRawIpv4(
            frame_mod.BROADCAST_MAC,
            IP_ZERO,
            IP_BROADCAST,
            ipv4_mod.PROTO_UDP,
            udp_buf[0..total_udp_len],
        );
    }

    pub fn sendUdp(self: *NetworkStack, dst_ip: [4]u8, src_port: u16, dst_port: u16, payload: []const u8) !void {
        var udp_buf: [1514]u8 = undefined;
        const udp_hdr_len = try udp_mod.writeHeader(&udp_buf, src_port, dst_port, @intCast(payload.len));
        @memcpy(udp_buf[udp_hdr_len .. udp_hdr_len + payload.len], payload);
        const total_udp_len = udp_hdr_len + payload.len;

        const src_ip = if (self.dhcp_config.bound) self.dhcp_config.ip else IP_ZERO;
        const csum = udp_mod.calculateChecksum(src_ip, dst_ip, udp_buf[0..total_udp_len]);
        udp_buf[6] = @intCast((csum >> 8) & 0xFF);
        udp_buf[7] = @intCast(csum & 0xFF);

        try self.sendIpv4(dst_ip, ipv4_mod.PROTO_UDP, udp_buf[0..total_udp_len]);
    }

    pub fn ensureGatewayArp(self: *NetworkStack) !void {
        if (!self.dhcp_config.bound) return;
        if (self.arp_table.lookup(self.dhcp_config.gateway) != null) return;
        try self.sendArpRequest(self.dhcp_config.gateway);
        var iter: usize = 0;
        while (self.arp_table.lookup(self.dhcp_config.gateway) == null and iter < 50_000) : (iter += 1) {
            self.poll();
            io.ioWait();
        }
    }

    pub fn resolveDns(self: *NetworkStack, hostname: []const u8) ![4]u8 {
        if (!self.dhcp_config.bound) return error.NotBound;
        try self.ensureGatewayArp();

        const dns_servers = [_][4]u8{
            self.dhcp_config.dns_server,
            DNS_FALLBACK_GOOGLE,
            DNS_FALLBACK_CLOUDFLARE,
        };

        for (dns_servers) |dns_ip| {
            if (try self.queryDnsServer(dns_ip, hostname)) |ip| {
                return ip;
            }
        }

        return error.DnsTimeout;
    }

    fn queryDnsServer(self: *NetworkStack, dns_ip: [4]u8, hostname: []const u8) !?[4]u8 {
        var attempt: usize = 0;
        while (attempt < MAX_DNS_RETRIES) : (attempt += 1) {
            self.dns_result = null;
            var dns_buf: [512]u8 = undefined;
            const qlen = try dns_mod.buildQuery(&dns_buf, hostname, self.dns_xid);
            try self.sendUdp(dns_ip, 49153, dns_mod.PORT_DNS, dns_buf[0..qlen]);

            const wait_iters = 100_000 * (attempt + 1);
            var iter: usize = 0;
            while (self.dns_result == null and iter < wait_iters) : (iter += 1) {
                self.poll();
                io.ioWait();
            }

            if (self.dns_result) |ip| return ip;
            serial.writeString("[net] DNS query timeout; retrying...\n");
        }
        return null;
    }

    pub fn connectTcp(self: *NetworkStack, remote_ip: [4]u8, remote_port: u16) !void {
        if (!self.dhcp_config.bound) return error.NotBound;
        try self.ensureGatewayArp();

        const local_port = self.next_local_port;
        self.next_local_port +%= 1;
        if (self.next_local_port < 50000) self.next_local_port = 50000;

        self.tcp_client = tcp_mod.TcpClient.init(self.dhcp_config.ip, remote_ip, local_port, remote_port, 0x1234_5678);
        self.tcp_rx_len = 0;

        var attempt: usize = 0;
        while (attempt < MAX_SYN_RETRIES) : (attempt += 1) {
            var syn_buf: [64]u8 = undefined;
            const syn_len = if (attempt == 0)
                try self.tcp_client.?.buildSyn(&syn_buf)
            else
                try self.tcp_client.?.buildSynRetransmit(&syn_buf);

            try self.sendIpv4(remote_ip, ipv4_mod.PROTO_TCP, syn_buf[0..syn_len]);

            const wait_iters = BASE_SYN_ITERS * (attempt + 1);
            var iter: usize = 0;
            while (self.tcp_client.?.state != .established and iter < wait_iters) : (iter += 1) {
                self.poll();
                io.ioWait();
            }

            if (self.tcp_client.?.state == .established) return;
            serial.writeString("[net] TCP SYN timeout; retransmitting...\n");
        }

        return error.TcpConnectTimeout;
    }

    pub fn sendTcpData(self: *NetworkStack, data: []const u8) !void {
        const client = &(self.tcp_client orelse return error.NotConnected);
        if (client.state != .established) return error.NotConnected;

        var offset: usize = 0;
        const TCP_MSS: usize = 1460;
        while (offset < data.len) {
            const chunk_len = @min(data.len - offset, TCP_MSS);
            const chunk = data[offset .. offset + chunk_len];
            try self.sendChunkWithRetry(client, chunk);
            offset += chunk_len;
        }
    }

    fn sendChunkWithRetry(self: *NetworkStack, client: *tcp_mod.TcpClient, chunk: []const u8) !void {
        const start_seq = client.seq;
        const target_seq = start_seq +% @as(u32, @intCast(chunk.len));
        client.seq = target_seq;

        var attempt: usize = 0;
        while (attempt < MAX_CHUNK_RETRIES) : (attempt += 1) {
            var tcp_buf: [1514]u8 = undefined;
            const total_len = try client.buildDataSegment(&tcp_buf, start_seq, chunk);
            try self.sendIpv4(client.remote_ip, ipv4_mod.PROTO_TCP, tcp_buf[0..total_len]);

            const wait_iters = BASE_CHUNK_ITERS * (attempt + 1);
            var iter: usize = 0;
            while (!tcp_mod.isSeqGe(client.unacked_seq, target_seq) and iter < wait_iters) : (iter += 1) {
                self.poll();
                io.ioWait();
            }

            if (tcp_mod.isSeqGe(client.unacked_seq, target_seq)) return;
            serial.writeString("[net] TCP ACK timeout; retransmitting segment...\n");
        }

        return error.TcpAckTimeout;
    }

    pub fn readTcpData(self: *NetworkStack, dest: []u8) usize {
        if (self.tcp_rx_len == 0) return 0;
        const to_read = @min(dest.len, self.tcp_rx_len);
        @memcpy(dest[0..to_read], self.tcp_rx_buf[0..to_read]);
        const remaining = self.tcp_rx_len - to_read;
        if (remaining > 0) {
            @memmove(self.tcp_rx_buf[0..remaining], self.tcp_rx_buf[to_read .. to_read + remaining]);
        }
        self.tcp_rx_len = remaining;
        return to_read;
    }

    pub fn closeTcp(self: *NetworkStack) !void {
        const client = &(self.tcp_client orelse return);
        if (client.state == .established) {
            var fin_buf: [64]u8 = undefined;
            const fin_len = try client.buildFin(&fin_buf);
            try self.sendIpv4(client.remote_ip, ipv4_mod.PROTO_TCP, fin_buf[0..fin_len]);
        }
    }

    pub fn sendIpv4(self: *NetworkStack, dst_ip: [4]u8, protocol: u8, payload: []const u8) !void {
        const dst_mac = self.resolveMac(dst_ip) orelse {
            try self.sendArpRequest(dst_ip);
            return error.WaitingForArp;
        };
        const src_ip = if (self.dhcp_config.bound) self.dhcp_config.ip else IP_ZERO;
        try self.sendRawIpv4(dst_mac, src_ip, dst_ip, protocol, payload);
    }

    fn resolveMac(self: *const NetworkStack, dst_ip: [4]u8) ?[6]u8 {
        if (std.mem.eql(u8, &dst_ip, &IP_BROADCAST)) return frame_mod.BROADCAST_MAC;
        return self.arp_table.lookup(dst_ip) orelse {
            if (self.dhcp_config.bound) {
                return self.arp_table.lookup(self.dhcp_config.gateway);
            }
            return null;
        };
    }

    fn sendArpRequest(self: *NetworkStack, target_ip: [4]u8) !void {
        var arp_buf: [64]u8 = undefined;
        const my_ip = if (self.dhcp_config.bound) self.dhcp_config.ip else IP_ZERO;
        const len = try arp_mod.buildArpRequest(&arp_buf, self.device.mac, my_ip, target_ip);

        var frame_buf: [128]u8 = undefined;
        try frame_mod.writeHeader(&frame_buf, frame_mod.BROADCAST_MAC, self.device.mac, frame_mod.ETHERTYPE_ARP);
        @memcpy(frame_buf[frame_mod.ETHERNET_HEADER_LEN .. frame_mod.ETHERNET_HEADER_LEN + len], arp_buf[0..len]);

        try self.device.sendPacket(frame_buf[0 .. frame_mod.ETHERNET_HEADER_LEN + len]);
    }

    fn sendArpReply(self: *NetworkStack, target_mac: [6]u8, target_ip: [4]u8) void {
        var arp_buf: [64]u8 = undefined;
        const len = arp_mod.buildArpReply(
            &arp_buf,
            self.device.mac,
            self.dhcp_config.ip,
            target_mac,
            target_ip,
        ) catch return;

        var frame_buf: [128]u8 = undefined;
        frame_mod.writeHeader(&frame_buf, target_mac, self.device.mac, frame_mod.ETHERTYPE_ARP) catch return;
        @memcpy(frame_buf[frame_mod.ETHERNET_HEADER_LEN .. frame_mod.ETHERNET_HEADER_LEN + len], arp_buf[0..len]);

        self.device.sendPacket(frame_buf[0 .. frame_mod.ETHERNET_HEADER_LEN + len]) catch {};
    }

    fn sendRawIpv4(
        self: *NetworkStack,
        dst_mac: [6]u8,
        src_ip: [4]u8,
        dst_ip: [4]u8,
        protocol: u8,
        payload: []const u8,
    ) !void {
        var frame_buf: [1514]u8 = undefined;
        try frame_mod.writeHeader(&frame_buf, dst_mac, self.device.mac, frame_mod.ETHERTYPE_IPV4);

        const ip_offset = frame_mod.ETHERNET_HEADER_LEN;
        const ip_hdr_len = try ipv4_mod.writeHeader(
            frame_buf[ip_offset..],
            src_ip,
            dst_ip,
            protocol,
            @intCast(payload.len),
            self.packet_id,
        );
        self.packet_id +%= 1;

        const payload_offset = ip_offset + ip_hdr_len;
        @memcpy(frame_buf[payload_offset .. payload_offset + payload.len], payload);

        const total_frame_len = payload_offset + payload.len;
        try self.device.sendPacket(frame_buf[0..total_frame_len]);
    }

    pub fn poll(self: *NetworkStack) void {
        var rx_buf: [1514]u8 = undefined;
        while (self.device.pollReceive(&rx_buf)) |len| {
            if (len > 0) {
                self.handleIncoming(rx_buf[0..len]);
            }
        }
    }
};

fn printDec(val: u8) void {
    if (val >= 100) {
        serial.writeChar('0' + (val / 100));
        serial.writeChar('0' + ((val / 10) % 10));
        serial.writeChar('0' + (val % 10));
    } else if (val >= 10) {
        serial.writeChar('0' + (val / 10));
        serial.writeChar('0' + (val % 10));
    } else {
        serial.writeChar('0' + val);
    }
}
