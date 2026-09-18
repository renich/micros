// MicrOS (µOS) Sovereign Peer-to-Peer Mutual TLS & Noise Wire Protocol
// SPEC-TECH-P2P-001: Freestanding P2P transport, Ed25519 node identity, and mesh discovery.
// Zero libc, capability-safe, bounded execution.

const std = @import("std");

pub const P2P_MAGIC: u32 = 0x50325031; // 'P2P1'
pub const BEACON_MAGIC: u32 = 0x50325042; // 'P2PB'
pub const PROTOCOL_VERSION: u16 = 1;
pub const MAX_PAYLOAD_LEN: usize = 65536;
pub const MAX_PEERS: usize = 64;
pub const NODE_ID_LEN: usize = 32;
pub const PUBKEY_LEN: usize = 32;
pub const SIGNATURE_LEN: usize = 64;
pub const NONCE_LEN: usize = 32;

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
};

pub const FrameHeader = extern struct {
    magic: u32 align(1),
    version: u16 align(1),
    msg_type: MessageType align(1),
    payload_len: u32 align(1),
    source_id: [NODE_ID_LEN]u8 align(1),
    sequence: u32 align(1),
    checksum: u32 align(1),

    pub fn isValid(self: *const FrameHeader) bool {
        if (self.magic != P2P_MAGIC) return false;
        if (self.version != PROTOCOL_VERSION) return false;
        if (self.payload_len > MAX_PAYLOAD_LEN) return false;
        return true;
    }
};

pub fn computeChecksum(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |b| {
        crc ^= @as(u32, b);
        var j: u8 = 0;
        while (j < 8) : (j += 1) {
            const mask: u32 = if ((crc & 1) != 0) 0xEDB88320 else 0;
            crc = (crc >> 1) ^ mask;
        }
    }
    return ~crc;
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
        return error.PeerTableFull;
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
    out_buf: []u8,
) !usize {
    const total_len = @sizeOf(FrameHeader) + payload.len;
    if (out_buf.len < total_len) return error.BufferTooSmall;

    var h_copy = header.*;
    h_copy.payload_len = @intCast(payload.len);
    h_copy.checksum = computeChecksum(payload);

    const hdr_bytes: *const [@sizeOf(FrameHeader)]u8 = @ptrCast(&h_copy);
    @memcpy(out_buf[0..@sizeOf(FrameHeader)], hdr_bytes);
    if (payload.len > 0) {
        @memcpy(out_buf[@sizeOf(FrameHeader)..total_len], payload);
    }
    return total_len;
}

pub fn parseFrame(
    in_buf: []const u8,
    out_header: *FrameHeader,
) ![]const u8 {
    if (in_buf.len < @sizeOf(FrameHeader)) return error.BufferTooShort;
    const hdr: *const FrameHeader = @ptrCast(in_buf[0..@sizeOf(FrameHeader)]);
    if (!hdr.isValid()) return error.InvalidFrameHeader;

    const total_len = @sizeOf(FrameHeader) + hdr.payload_len;
    if (in_buf.len < total_len) return error.IncompletePayload;

    const payload = in_buf[@sizeOf(FrameHeader)..total_len];
    if (computeChecksum(payload) != hdr.checksum) {
        return error.ChecksumMismatch;
    }

    out_header.* = hdr.*;
    return payload;
}

// === Colocated Unit Tests ===

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

test "P2P wire frame serialization and integrity parsing" {
    const header = FrameHeader{
        .magic = P2P_MAGIC,
        .version = PROTOCOL_VERSION,
        .msg_type = .peer_ping,
        .payload_len = 0,
        .source_id = [_]u8{0x77} ** 32,
        .sequence = 42,
        .checksum = 0,
    };

    const payload = "Sovereign P2P Ping Payload";
    var frame_buf: [256]u8 = undefined;
    const frame_len = try serializeFrame(&header, payload, &frame_buf);

    var parsed_header: FrameHeader = undefined;
    const parsed_payload = try parseFrame(frame_buf[0..frame_len], &parsed_header);

    try std.testing.expectEqual(MessageType.peer_ping, parsed_header.msg_type);
    try std.testing.expectEqual(@as(u32, 42), parsed_header.sequence);
    try std.testing.expectEqualStrings(payload, parsed_payload);

    // Corrupted checksum triggers ChecksumMismatch
    frame_buf[frame_len - 1] ^= 0x01;
    const err = parseFrame(frame_buf[0..frame_len], &parsed_header);
    try std.testing.expectError(error.ChecksumMismatch, err);
}
