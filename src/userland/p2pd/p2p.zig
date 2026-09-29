// MicrOS (µOS) Sovereign Peer-to-Peer Mutual TLS & Noise Wire Protocol
// SPEC-TECH-P2P-001: Freestanding P2P transport, Ed25519 node identity, and mesh discovery.
// Zero libc, capability-safe, bounded execution.

const std = @import("std");

pub const P2P_MAGIC: u32 = 0x50325031; // 'P2P1'
pub const BEACON_MAGIC: u32 = 0x50325042; // 'P2PB'
pub const PROTOCOL_VERSION: u16 = 2;
pub const MAX_PAYLOAD_LEN: usize = 65536;
pub const MAX_PEERS: usize = 64;
pub const NODE_ID_LEN: usize = 32;
pub const PUBKEY_LEN: usize = 32;
pub const SIGNATURE_LEN: usize = 64;
pub const NONCE_LEN: usize = 32;
pub const MAC_LEN: usize = 32;
pub const KEY_LEN: usize = 32;

pub const MessageType = enum(u16) {
    handshake_init = 1,
    handshake_resp = 2,
    peer_ping = 3,
    peer_pong = 4,
    discovery_beacon = 5,
    chunk_request = 6,
    chunk_response = 7,
    actor_dispatch = 8,
    actor_result = 9,
    merkle_sync_request = 10,
    merkle_sync_response = 11,
};

pub const FrameHeader = extern struct {
    magic: u32 align(1),
    version: u16 align(1),
    msg_type: MessageType align(1),
    payload_len: u32 align(1),
    source_id: [NODE_ID_LEN]u8 align(1),
    sequence: u32 align(1),
    mac: [MAC_LEN]u8 align(1),

    pub fn isValid(self: *const FrameHeader) bool {
        if (self.magic != P2P_MAGIC) return false;
        if (self.version != PROTOCOL_VERSION) return false;
        if (self.payload_len > MAX_PAYLOAD_LEN) return false;
        return true;
    }

    pub fn headerAuthBytes(self: *const FrameHeader) []const u8 {
        const total = @sizeOf(FrameHeader) - MAC_LEN;
        const bytes: *const [@sizeOf(FrameHeader)]u8 = @ptrCast(self);
        return bytes[0..total];
    }
};

pub fn computeMac(key: *const [KEY_LEN]u8, header_auth_bytes: []const u8, payload: []const u8) [MAC_LEN]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{ .key = key.* });
    hasher.update(header_auth_bytes);
    hasher.update(payload);
    var out_mac: [MAC_LEN]u8 = undefined;
    hasher.final(&out_mac);
    return out_mac;
}

pub fn verifyMac(key: *const [KEY_LEN]u8, header_auth_bytes: []const u8, payload: []const u8, expected_mac: *const [MAC_LEN]u8) bool {
    const computed = computeMac(key, header_auth_bytes, payload);
    return std.crypto.timing_safe.eql([MAC_LEN]u8, computed, expected_mac.*);
}

pub fn computeNodeId(pubkey: *const [PUBKEY_LEN]u8) [NODE_ID_LEN]u8 {
    var out_id: [NODE_ID_LEN]u8 = undefined;
    std.crypto.hash.Blake3.hash(pubkey, &out_id, .{});
    return out_id;
}

pub const NodeIdentity = struct {
    key_pair: std.crypto.sign.Ed25519.KeyPair,
    node_id: [NODE_ID_LEN]u8,

    pub fn fromSeed(seed: [32]u8) !NodeIdentity {
        const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
        const nid = computeNodeId(&kp.public_key.bytes);
        return NodeIdentity{
            .key_pair = kp,
            .node_id = nid,
        };
    }

    pub fn deriveSessionKey(
        init_pubkey: *const [PUBKEY_LEN]u8,
        resp_pubkey: *const [PUBKEY_LEN]u8,
        challenge_a: *const [NONCE_LEN]u8,
        challenge_b: *const [NONCE_LEN]u8,
    ) [KEY_LEN]u8 {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update("MicrOS-P2P-v2:session:");
        hasher.update(init_pubkey);
        hasher.update(resp_pubkey);
        hasher.update(challenge_a);
        hasher.update(challenge_b);
        var out_key: [KEY_LEN]u8 = undefined;
        hasher.final(&out_key);
        return out_key;
    }

    pub fn signRoleChallenge(
        self: *const NodeIdentity,
        role: []const u8,
        peer_pubkey: *const [PUBKEY_LEN]u8,
        challenge: *const [NONCE_LEN]u8,
    ) ![SIGNATURE_LEN]u8 {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(role);
        hasher.update(&self.key_pair.public_key.bytes);
        hasher.update(peer_pubkey);
        hasher.update(challenge);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);

        const sig = try self.key_pair.sign(&digest, null);
        return sig.toBytes();
    }

    pub fn verifyRoleSignature(
        signer_pubkey: *const [PUBKEY_LEN]u8,
        role: []const u8,
        expected_peer_pubkey: *const [PUBKEY_LEN]u8,
        challenge: *const [NONCE_LEN]u8,
        sig_bytes: *const [SIGNATURE_LEN]u8,
    ) bool {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(role);
        hasher.update(signer_pubkey);
        hasher.update(expected_peer_pubkey);
        hasher.update(challenge);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);

        const pubkey = std.crypto.sign.Ed25519.PublicKey.fromBytes(signer_pubkey.*) catch return false;
        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes.*);
        sig.verify(&digest, pubkey) catch return false;
        return true;
    }

    pub fn signChallenge(self: *const NodeIdentity, challenge: *const [NONCE_LEN]u8) ![SIGNATURE_LEN]u8 {
        const sig = try self.key_pair.sign(challenge, null);
        return sig.toBytes();
    }

    pub fn verifySignature(pubkey_bytes: *const [PUBKEY_LEN]u8, challenge: *const [NONCE_LEN]u8, sig_bytes: *const [SIGNATURE_LEN]u8) bool {
        const pubkey = std.crypto.sign.Ed25519.PublicKey.fromBytes(pubkey_bytes.*) catch return false;
        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes.*);
        sig.verify(challenge, pubkey) catch return false;
        return true;
    }
};

pub const DiscoveryBeacon = extern struct {
    magic: u32 align(1) = BEACON_MAGIC,
    version: u16 align(1) = PROTOCOL_VERSION,
    port: u16 align(1) = 8080,
    node_id: [NODE_ID_LEN]u8 align(1),
    pubkey: [PUBKEY_LEN]u8 align(1),
    capability_mask: u16 align(1) = 0x0003,
    padding: [2]u8 align(1) = [_]u8{0} ** 2,

    pub fn serialize(self: *const DiscoveryBeacon, out_buf: *[74]u8) void {
        const bytes: *const [74]u8 = @ptrCast(self);
        @memcpy(out_buf, bytes);
    }

    pub fn deserialize(in_buf: *const [74]u8) ?DiscoveryBeacon {
        const beacon: *const DiscoveryBeacon = @ptrCast(in_buf);
        if (beacon.magic != BEACON_MAGIC or beacon.version != PROTOCOL_VERSION) {
            return null;
        }
        const derived_id = computeNodeId(&beacon.pubkey);
        if (!std.mem.eql(u8, &derived_id, &beacon.node_id)) {
            return null;
        }
        return beacon.*;
    }
};

pub const PeerEntry = struct {
    node_id: [NODE_ID_LEN]u8,
    pubkey: [PUBKEY_LEN]u8,
    ip: [4]u8,
    port: u16,
    capabilities: u16,
    last_seen_ticks: u64,
    authenticated: bool,
    last_seen_sequence: u32 = 0,
    session_key: [KEY_LEN]u8 = [_]u8{0} ** KEY_LEN,
};

pub const PeerTable = struct {
    peers: [MAX_PEERS]?PeerEntry = [_]?PeerEntry{null} ** MAX_PEERS,
    count: usize = 0,

    pub fn init() PeerTable {
        return PeerTable{};
    }

    pub fn find(self: *const PeerTable, node_id: *const [NODE_ID_LEN]u8) ?usize {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.peers[i]) |p| {
                if (std.mem.eql(u8, &p.node_id, node_id)) return i;
            }
        }
        return null;
    }

    pub fn upsert(self: *PeerTable, entry: PeerEntry) !void {
        if (self.find(&entry.node_id)) |idx| {
            self.peers[idx] = entry;
            return;
        }
        if (self.count < MAX_PEERS) {
            self.peers[self.count] = entry;
            self.count += 1;
            return;
        }
        var oldest_idx: usize = 0;
        var oldest_ticks: u64 = std.math.maxInt(u64);
        for (0..self.count) |i| {
            if (self.peers[i]) |p| {
                if (p.last_seen_ticks < oldest_ticks) {
                    oldest_ticks = p.last_seen_ticks;
                    oldest_idx = i;
                }
            }
        }
        self.peers[oldest_idx] = entry;
    }

    pub fn pruneStale(self: *PeerTable, current_ticks: u64, timeout_ticks: u64) usize {
        var pruned: usize = 0;
        var i: usize = 0;
        while (i < self.count) {
            if (self.peers[i]) |p| {
                if (current_ticks > p.last_seen_ticks and (current_ticks - p.last_seen_ticks) > timeout_ticks) {
                    self.removeIndex(i);
                    pruned += 1;
                    continue;
                }
            }
            i += 1;
        }
        return pruned;
    }

    fn removeIndex(self: *PeerTable, idx: usize) void {
        var j = idx;
        while (j + 1 < self.count) : (j += 1) {
            self.peers[j] = self.peers[j + 1];
        }
        self.peers[self.count - 1] = null;
        self.count -= 1;
    }
};

pub const HandshakeInitPayload = extern struct {
    initiator_pubkey: [PUBKEY_LEN]u8 align(1),
    nonce: [NONCE_LEN]u8 align(1),
    signature: [SIGNATURE_LEN]u8 align(1),
};

pub const HandshakeRespPayload = extern struct {
    responder_pubkey: [PUBKEY_LEN]u8 align(1),
    nonce: [NONCE_LEN]u8 align(1),
    signature: [SIGNATURE_LEN]u8 align(1),
    session_status: u16 align(1),
    padding: [2]u8 align(1) = [_]u8{0} ** 2,
};

pub fn serializeFrame(
    header: *const FrameHeader,
    payload: []const u8,
    key: *const [KEY_LEN]u8,
    out_buf: []u8,
) !usize {
    const total_len = @sizeOf(FrameHeader) + payload.len;
    if (out_buf.len < total_len) return error.BufferTooSmall;

    var h_copy = header.*;
    h_copy.version = PROTOCOL_VERSION;
    h_copy.payload_len = @intCast(payload.len);
    h_copy.mac = computeMac(key, h_copy.headerAuthBytes(), payload);

    const hdr_bytes: *const [@sizeOf(FrameHeader)]u8 = @ptrCast(&h_copy);
    @memcpy(out_buf[0..@sizeOf(FrameHeader)], hdr_bytes);
    if (payload.len > 0) {
        @memcpy(out_buf[@sizeOf(FrameHeader)..total_len], payload);
    }
    return total_len;
}

pub fn parseFrame(
    in_buf: []const u8,
    key: *const [KEY_LEN]u8,
    out_header: *FrameHeader,
) ![]const u8 {
    if (in_buf.len < @sizeOf(FrameHeader)) return error.BufferTooShort;
    const hdr_bytes: *[@sizeOf(FrameHeader)]u8 = @ptrCast(out_header);
    @memcpy(hdr_bytes, in_buf[0..@sizeOf(FrameHeader)]);
    if (!out_header.isValid()) return error.InvalidFrameHeader;

    const total_len = @sizeOf(FrameHeader) + out_header.payload_len;
    if (in_buf.len < total_len) return error.IncompletePayload;

    const payload = in_buf[@sizeOf(FrameHeader)..total_len];
    if (!verifyMac(key, out_header.headerAuthBytes(), payload, &out_header.mac)) {
        return error.MacVerificationFailed;
    }

    return payload;
}

pub const P2pDaemon = struct {
    allocator: std.mem.Allocator,
    identity: NodeIdentity,
    peers: PeerTable,
    port: u16,
    active: bool,
    beacon_sequence: u32 = 0,
    consumed_nonces: [MAX_PEERS][NONCE_LEN]u8 = [_][NONCE_LEN]u8{[_]u8{0} ** NONCE_LEN} ** MAX_PEERS,
    consumed_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, seed: [32]u8, port: u16) !P2pDaemon {
        const id = try NodeIdentity.fromSeed(seed);
        return P2pDaemon{
            .allocator = allocator,
            .identity = id,
            .peers = PeerTable.init(),
            .port = port,
            .active = true,
        };
    }

    pub fn isNonceConsumed(self: *const P2pDaemon, nonce: *const [NONCE_LEN]u8) bool {
        for (self.consumed_nonces[0..self.consumed_count]) |*cn| {
            if (std.mem.eql(u8, cn, nonce)) return true;
        }
        return false;
    }

    pub fn markNonceConsumed(self: *P2pDaemon, nonce: *const [NONCE_LEN]u8) void {
        if (self.consumed_count < MAX_PEERS) {
            self.consumed_nonces[self.consumed_count] = nonce.*;
            self.consumed_count += 1;
        } else {
            for (0..MAX_PEERS - 1) |i| {
                self.consumed_nonces[i] = self.consumed_nonces[i + 1];
            }
            self.consumed_nonces[MAX_PEERS - 1] = nonce.*;
        }
    }

    pub fn formatBeacon(self: *P2pDaemon, out_buf: *[74]u8) void {
        const beacon = DiscoveryBeacon{
            .node_id = self.identity.node_id,
            .pubkey = self.identity.key_pair.public_key.bytes,
            .port = self.port,
        };
        beacon.serialize(out_buf);
        self.beacon_sequence = if (self.beacon_sequence == std.math.maxInt(u32)) 1 else self.beacon_sequence + 1;
    }

    pub fn handleIncomingBeacon(self: *P2pDaemon, in_buf: *const [74]u8, src_ip: [4]u8, current_ticks: u64) !bool {
        const beacon = DiscoveryBeacon.deserialize(in_buf) orelse return false;
        if (std.mem.eql(u8, &beacon.node_id, &self.identity.node_id)) {
            return false;
        }
        try self.peers.upsert(.{
            .node_id = beacon.node_id,
            .pubkey = beacon.pubkey,
            .ip = src_ip,
            .port = beacon.port,
            .capabilities = beacon.capability_mask,
            .last_seen_ticks = current_ticks,
            .authenticated = false,
        });
        return true;
    }

    pub fn peerCount(self: *const P2pDaemon) usize {
        return self.peers.count;
    }

    pub fn getPeer(self: *const P2pDaemon, idx: usize) ?PeerEntry {
        if (idx < self.peers.count) {
            return self.peers.peers[idx];
        }
        return null;
    }

    pub fn formatPeerSummary(peer: *const PeerEntry, out_buf: []u8) []const u8 {
        const hex_chars = "0123456789abcdef";
        var id_short: [8]u8 = undefined;
        for (0..4) |i| {
            id_short[i * 2] = hex_chars[(peer.node_id[i] >> 4) & 0x0F];
            id_short[i * 2 + 1] = hex_chars[peer.node_id[i] & 0x0F];
        }
        const res = std.fmt.bufPrint(out_buf, "Node {s}... at {d}.{d}.{d}.{d}:{d} (caps: 0x{x:0>4})", .{
            id_short,
            peer.ip[0],
            peer.ip[1],
            peer.ip[2],
            peer.ip[3],
            peer.port,
            peer.capabilities,
        }) catch return "";
        return res;
    }

    pub fn createHandshakeInit(
        self: *P2pDaemon,
        peer_pubkey: *const [PUBKEY_LEN]u8,
        peer_challenge: *const [NONCE_LEN]u8,
    ) !HandshakeInitPayload {
        const sig = try self.identity.signRoleChallenge(
            "MicrOS-P2P-v2:init:",
            peer_pubkey,
            peer_challenge,
        );
        return HandshakeInitPayload{
            .initiator_pubkey = self.identity.key_pair.public_key.bytes,
            .nonce = peer_challenge.*,
            .signature = sig,
        };
    }

    fn verifyAndConsumeNonce(
        self: *P2pDaemon,
        nonce: *const [NONCE_LEN]u8,
        expected: *const [NONCE_LEN]u8,
    ) !void {
        if (!std.mem.eql(u8, nonce, expected)) {
            return error.InvalidHandshakeNonce;
        }
        if (self.isNonceConsumed(nonce)) {
            return error.ReplayDetected;
        }
        self.markNonceConsumed(nonce);
    }

    fn authenticatePeerSession(
        self: *P2pDaemon,
        pubkey: *const [32]u8,
        session_key: [32]u8,
    ) bool {
        var i: usize = 0;
        while (i < self.peers.count) : (i += 1) {
            if (self.peers.peers[i]) |*p| {
                if (std.mem.eql(u8, &p.pubkey, pubkey)) {
                    p.authenticated = true;
                    p.session_key = session_key;
                    p.last_seen_sequence = 0;
                    return true;
                }
            }
        }
        return false;
    }

    pub fn processHandshakeInit(
        self: *P2pDaemon,
        init_payload: *const HandshakeInitPayload,
        expected_challenge: *const [NONCE_LEN]u8,
        response_challenge: *const [NONCE_LEN]u8,
    ) !HandshakeRespPayload {
        try self.verifyAndConsumeNonce(&init_payload.nonce, expected_challenge);

        const valid = NodeIdentity.verifyRoleSignature(
            &init_payload.initiator_pubkey,
            "MicrOS-P2P-v2:init:",
            &self.identity.key_pair.public_key.bytes,
            &init_payload.nonce,
            &init_payload.signature,
        );
        if (!valid) return error.InvalidHandshakeSignature;

        const resp_sig = try self.identity.signRoleChallenge(
            "MicrOS-P2P-v2:resp:",
            &init_payload.initiator_pubkey,
            response_challenge,
        );

        const session_key = NodeIdentity.deriveSessionKey(
            &init_payload.initiator_pubkey,
            &self.identity.key_pair.public_key.bytes,
            expected_challenge,
            response_challenge,
        );

        _ = self.authenticatePeerSession(&init_payload.initiator_pubkey, session_key);

        return HandshakeRespPayload{
            .responder_pubkey = self.identity.key_pair.public_key.bytes,
            .nonce = response_challenge.*,
            .signature = resp_sig,
            .session_status = 1,
        };
    }

    pub fn processHandshakeResp(
        self: *P2pDaemon,
        resp_payload: *const HandshakeRespPayload,
        expected_nonce: *const [NONCE_LEN]u8,
        original_challenge: *const [NONCE_LEN]u8,
    ) !void {
        if (resp_payload.session_status != 1) return error.HandshakeRejected;
        try self.verifyAndConsumeNonce(&resp_payload.nonce, expected_nonce);

        const valid = NodeIdentity.verifyRoleSignature(
            &resp_payload.responder_pubkey,
            "MicrOS-P2P-v2:resp:",
            &self.identity.key_pair.public_key.bytes,
            &resp_payload.nonce,
            &resp_payload.signature,
        );
        if (!valid) return error.InvalidHandshakeSignature;

        const session_key = NodeIdentity.deriveSessionKey(
            &self.identity.key_pair.public_key.bytes,
            &resp_payload.responder_pubkey,
            original_challenge,
            expected_nonce,
        );

        if (!self.authenticatePeerSession(&resp_payload.responder_pubkey, session_key)) {
            return error.PeerNotFound;
        }
    }

    pub fn receiveVerifiedFrame(
        self: *P2pDaemon,
        in_buf: []const u8,
        out_header: *FrameHeader,
        current_ticks: u64,
    ) ![]const u8 {
        if (in_buf.len < @sizeOf(FrameHeader)) return error.BufferTooShort;
        const hdr_bytes: *[@sizeOf(FrameHeader)]u8 = @ptrCast(out_header);
        @memcpy(hdr_bytes, in_buf[0..@sizeOf(FrameHeader)]);
        if (!out_header.isValid()) return error.InvalidFrameHeader;

        const peer_idx = self.peers.find(&out_header.source_id) orelse return error.UnknownPeer;
        const peer = &(self.peers.peers[peer_idx] orelse return error.UnknownPeer);

        if (!peer.authenticated) return error.UnauthenticatedPeer;

        // Strict monotonic sequence enforcement per peer (anti-replay)
        if (out_header.sequence <= peer.last_seen_sequence) {
            return error.ReplayDetected;
        }

        const payload = try parseFrame(in_buf, &peer.session_key, out_header);
        peer.last_seen_sequence = out_header.sequence;
        peer.last_seen_ticks = current_ticks;
        return payload;
    }
};

// === Colocated Unit Tests ===

test "P2pDaemon lifecycle and beacon exchange" {
    const seed = [_]u8{0x77} ** 32;
    var daemon = try P2pDaemon.init(std.testing.allocator, seed, 8080);
    try std.testing.expect(daemon.active);
    try std.testing.expectEqual(@as(usize, 0), daemon.peerCount());

    var self_beacon: [74]u8 = undefined;
    daemon.formatBeacon(&self_beacon);
    try std.testing.expectEqual(@as(u32, 1), daemon.beacon_sequence);

    // Self beacon must be rejected to prevent self-looping on broadcast
    const self_handled = try daemon.handleIncomingBeacon(&self_beacon, [_]u8{ 192, 168, 100, 1 }, 100);
    try std.testing.expect(!self_handled);
    try std.testing.expectEqual(@as(usize, 0), daemon.peerCount());

    // Peer beacon from another node must be accepted
    const peer_seed = [_]u8{0x88} ** 32;
    var peer_daemon = try P2pDaemon.init(std.testing.allocator, peer_seed, 8080);
    var peer_beacon: [74]u8 = undefined;
    peer_daemon.formatBeacon(&peer_beacon);

    const peer_handled = try daemon.handleIncomingBeacon(&peer_beacon, [_]u8{ 192, 168, 100, 2 }, 100);
    try std.testing.expect(peer_handled);
    try std.testing.expectEqual(@as(usize, 1), daemon.peerCount());

    const peer_opt = daemon.getPeer(0);
    try std.testing.expect(peer_opt != null);

    var summary_buf: [128]u8 = undefined;
    const summary = P2pDaemon.formatPeerSummary(&peer_opt.?, &summary_buf);
    try std.testing.expect(summary.len > 0);
}

test "P2P node identity generation and signature verification" {
    const seed = [_]u8{0x42} ** 32;
    const node = try NodeIdentity.fromSeed(seed);

    const challenge = [_]u8{0x17} ** NONCE_LEN;
    const sig = try node.signChallenge(&challenge);

    const valid = NodeIdentity.verifySignature(&node.key_pair.public_key.bytes, &challenge, &sig);
    try std.testing.expect(valid);

    var wrong_challenge = challenge;
    wrong_challenge[0] ^= 0xFF;
    const invalid = NodeIdentity.verifySignature(&node.key_pair.public_key.bytes, &wrong_challenge, &sig);
    try std.testing.expect(!invalid);
}

test "P2P discovery beacon serialization and node ID verification" {
    const seed = [_]u8{0x99} ** 32;
    const node = try NodeIdentity.fromSeed(seed);

    var beacon = DiscoveryBeacon{
        .node_id = node.node_id,
        .pubkey = node.key_pair.public_key.bytes,
        .port = 8080,
    };

    var buf: [74]u8 = undefined;
    beacon.serialize(&buf);

    const parsed = DiscoveryBeacon.deserialize(&buf);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqual(beacon.port, parsed.?.port);
    try std.testing.expectEqualStrings(&beacon.node_id, &parsed.?.node_id);

    // Tampered pubkey must fail deserialization check
    buf[40] ^= 0xAA;
    const tampered = DiscoveryBeacon.deserialize(&buf);
    try std.testing.expect(tampered == null);
}

test "P2P peer table upsert, lookup, and stale pruning" {
    var table = PeerTable.init();
    const id1 = [_]u8{0x01} ** 32;
    const id2 = [_]u8{0x02} ** 32;

    try table.upsert(.{
        .node_id = id1,
        .pubkey = [_]u8{0x11} ** 32,
        .ip = [_]u8{ 192, 168, 1, 10 },
        .port = 8080,
        .capabilities = 3,
        .last_seen_ticks = 100,
        .authenticated = true,
    });

    try table.upsert(.{
        .node_id = id2,
        .pubkey = [_]u8{0x22} ** 32,
        .ip = [_]u8{ 192, 168, 1, 11 },
        .port = 8080,
        .capabilities = 3,
        .last_seen_ticks = 50,
        .authenticated = false,
    });

    try std.testing.expectEqual(@as(usize, 2), table.count);
    try std.testing.expect(table.find(&id1) != null);
    try std.testing.expect(table.find(&id2) != null);

    // Prune entries older than 40 ticks at tick 100 (id2 was seen at 50, diff=50 > 40)
    const pruned = table.pruneStale(100, 40);
    try std.testing.expectEqual(@as(usize, 1), pruned);
    try std.testing.expectEqual(@as(usize, 1), table.count);
    try std.testing.expect(table.find(&id1) != null);
    try std.testing.expect(table.find(&id2) == null);
}

test "P2P wire frame serialization and integrity parsing with BLAKE3 MAC" {
    const key = [_]u8{0x33} ** KEY_LEN;
    const header = FrameHeader{
        .magic = P2P_MAGIC,
        .version = PROTOCOL_VERSION,
        .msg_type = .peer_ping,
        .payload_len = 0,
        .source_id = [_]u8{0x77} ** 32,
        .sequence = 42,
        .mac = [_]u8{0} ** MAC_LEN,
    };

    const payload = "Sovereign P2P Ping Payload";
    var frame_buf: [256]u8 = undefined;
    const frame_len = try serializeFrame(&header, payload, &key, &frame_buf);

    var parsed_header: FrameHeader = undefined;
    const parsed_payload = try parseFrame(frame_buf[0..frame_len], &key, &parsed_header);

    try std.testing.expectEqual(MessageType.peer_ping, parsed_header.msg_type);
    try std.testing.expectEqual(@as(u32, 42), parsed_header.sequence);
    try std.testing.expectEqualStrings(payload, parsed_payload);

    // Corrupted MAC triggers MacVerificationFailed
    frame_buf[frame_len - 1] ^= 0x01;
    const err = parseFrame(frame_buf[0..frame_len], &key, &parsed_header);
    try std.testing.expectError(error.MacVerificationFailed, err);
}

test "P2P mutual cryptographic handshake authentication" {
    const seed_a = [_]u8{0x11} ** 32;
    const seed_b = [_]u8{0x22} ** 32;

    var node_a = try P2pDaemon.init(std.testing.allocator, seed_a, 8080);
    var node_b = try P2pDaemon.init(std.testing.allocator, seed_b, 8081);

    // Node A discovers Node B via beacon
    var beacon_b: [74]u8 = undefined;
    node_b.formatBeacon(&beacon_b);
    _ = try node_a.handleIncomingBeacon(&beacon_b, [_]u8{ 192, 168, 100, 2 }, 10);
    try std.testing.expectEqual(false, node_a.peers.peers[0].?.authenticated);

    // Node B discovers Node A via beacon
    var beacon_a: [74]u8 = undefined;
    node_a.formatBeacon(&beacon_a);
    _ = try node_b.handleIncomingBeacon(&beacon_a, [_]u8{ 192, 168, 100, 1 }, 10);
    try std.testing.expectEqual(false, node_b.peers.peers[0].?.authenticated);

    // Node A initiates handshake with Node B's challenge
    const challenge_for_a = [_]u8{0xAA} ** NONCE_LEN;
    const challenge_for_b = [_]u8{0xBB} ** NONCE_LEN;
    const init_payload = try node_a.createHandshakeInit(&node_b.identity.key_pair.public_key.bytes, &challenge_for_a);

    // Node B verifies Node A's response to challenge_for_a, returns response to challenge_for_b
    const resp_payload = try node_b.processHandshakeInit(&init_payload, &challenge_for_a, &challenge_for_b);
    try std.testing.expectEqual(true, node_b.peers.peers[0].?.authenticated);

    // Node A verifies Node B's response to challenge_for_b
    try node_a.processHandshakeResp(&resp_payload, &challenge_for_b, &challenge_for_a);
    try std.testing.expectEqual(true, node_a.peers.peers[0].?.authenticated);

    // Keys derived must be identical
    try std.testing.expectEqualSlices(u8, &node_a.peers.peers[0].?.session_key, &node_b.peers.peers[0].?.session_key);

    // Tampered signature rejection with fresh challenge
    const fresh_b = [_]u8{0xDD} ** NONCE_LEN;
    const fresh_resp = try node_b.identity.signRoleChallenge(
        "MicrOS-P2P-v2:resp:",
        &node_a.identity.key_pair.public_key.bytes,
        &fresh_b,
    );
    var tampered_payload = resp_payload;
    tampered_payload.nonce = fresh_b;
    tampered_payload.signature = fresh_resp;
    tampered_payload.signature[0] ^= 0xFF;
    try std.testing.expectError(
        error.InvalidHandshakeSignature,
        node_a.processHandshakeResp(&tampered_payload, &fresh_b, &challenge_for_a),
    );
}

test "p2p replay rejected" {
    const seed_a = [_]u8{0x55} ** 32;
    const seed_b = [_]u8{0x66} ** 32;

    var node_a = try P2pDaemon.init(std.testing.allocator, seed_a, 8080);
    var node_b = try P2pDaemon.init(std.testing.allocator, seed_b, 8081);

    var beacon_b: [74]u8 = undefined;
    node_b.formatBeacon(&beacon_b);
    _ = try node_a.handleIncomingBeacon(&beacon_b, [_]u8{ 192, 168, 1, 20 }, 10);

    var beacon_a: [74]u8 = undefined;
    node_a.formatBeacon(&beacon_a);
    _ = try node_b.handleIncomingBeacon(&beacon_a, [_]u8{ 192, 168, 1, 10 }, 10);

    const challenge_a = [_]u8{0x12} ** NONCE_LEN;
    const challenge_b = [_]u8{0x34} ** NONCE_LEN;
    const init_p = try node_a.createHandshakeInit(&node_b.identity.key_pair.public_key.bytes, &challenge_a);
    const resp_p = try node_b.processHandshakeInit(&init_p, &challenge_a, &challenge_b);
    try node_a.processHandshakeResp(&resp_p, &challenge_b, &challenge_a);

    // 1. Replay attack rejection: reused challenge nonce in handshake
    try std.testing.expectError(
        error.ReplayDetected,
        node_b.processHandshakeInit(&init_p, &challenge_a, &challenge_b),
    );

    // 2. Role reflection attack rejection: reflecting init signature to resp fails
    const fresh_reflect_nonce = [_]u8{0x99} ** NONCE_LEN;
    const reflect_init = try node_a.createHandshakeInit(&node_b.identity.key_pair.public_key.bytes, &fresh_reflect_nonce);
    var reflected_resp = resp_p;
    reflected_resp.nonce = fresh_reflect_nonce;
    reflected_resp.signature = reflect_init.signature;
    try std.testing.expectError(
        error.InvalidHandshakeSignature,
        node_a.processHandshakeResp(&reflected_resp, &fresh_reflect_nonce, &challenge_a),
    );

    // 3. Frame transmission and sequence replay rejection
    const peer_b_in_a = node_a.peers.peers[0].?;
    const header = FrameHeader{
        .magic = P2P_MAGIC,
        .version = PROTOCOL_VERSION,
        .msg_type = .peer_ping,
        .payload_len = 0,
        .source_id = node_a.identity.node_id,
        .sequence = 1,
        .mac = [_]u8{0} ** MAC_LEN,
    };

    var frame_buf: [256]u8 = undefined;
    const frame_len = try serializeFrame(&header, "ping", &peer_b_in_a.session_key, &frame_buf);

    var parsed_hdr: FrameHeader = undefined;
    const rx_payload = try node_b.receiveVerifiedFrame(frame_buf[0..frame_len], &parsed_hdr, 20);
    try std.testing.expectEqualStrings("ping", rx_payload);

    // Replaying identical sequence 1 must be rejected with error.ReplayDetected
    try std.testing.expectError(
        error.ReplayDetected,
        node_b.receiveVerifiedFrame(frame_buf[0..frame_len], &parsed_hdr, 25),
    );

    // Frame with stale sequence 0 must also be rejected
    var stale_hdr = header;
    stale_hdr.sequence = 0;
    var stale_buf: [256]u8 = undefined;
    const stale_len = try serializeFrame(&stale_hdr, "stale", &peer_b_in_a.session_key, &stale_buf);
    try std.testing.expectError(
        error.ReplayDetected,
        node_b.receiveVerifiedFrame(stale_buf[0..stale_len], &parsed_hdr, 30),
    );

    // 4. Tampered byte rejection: modifying any payload byte fails MAC verification
    var tampered_buf: [256]u8 = undefined;
    var next_hdr = header;
    next_hdr.sequence = 2;
    const next_len = try serializeFrame(&next_hdr, "valid payload", &peer_b_in_a.session_key, &tampered_buf);
    tampered_buf[next_len - 1] ^= 0x55;
    try std.testing.expectError(
        error.MacVerificationFailed,
        node_b.receiveVerifiedFrame(tampered_buf[0..next_len], &parsed_hdr, 35),
    );
}
