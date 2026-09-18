// MicrOS (µOS) Cryptographic Capability Delegation & Remote Actor Compute Engine
// SPEC-TECH-P2P-003: Ed25519-signed capability tokens, attenuation, and remote actor supervision.
// Zero libc, freestanding, capability-safe, bounded execution.

const std = @import("std");

pub const NODE_ID_LEN: usize = 32;
pub const PUBKEY_LEN: usize = 32;
pub const SIGNATURE_LEN: usize = 64;
pub const HASH_SIZE: usize = 32;

pub const RIGHT_READ_CAS: u64 = 0x01;
pub const RIGHT_WRITE_CAS: u64 = 0x02;
pub const RIGHT_SPAWN_ACTOR: u64 = 0x04;
pub const RIGHT_SUPERVISE_ACTOR: u64 = 0x08;
pub const RIGHT_DELEGATE: u64 = 0x10;

pub const TOKEN_PAYLOAD_SIZE: usize = 128;
pub const TOKEN_TOTAL_SIZE: usize = 192;
pub const MAX_REMOTE_ACTORS: usize = 32;

pub const CapabilityToken = extern struct {
    issuer_id: [NODE_ID_LEN]u8 align(1),
    subject_id: [NODE_ID_LEN]u8 align(1),
    rights: u64 align(1),
    resource_hash: [HASH_SIZE]u8 align(1),
    issued_at_ticks: u64 align(1),
    expires_at_ticks: u64 align(1),
    nonce: u64 align(1),
    signature: [SIGNATURE_LEN]u8 align(1),

    pub fn getPayloadBytes(self: *const CapabilityToken) *const [TOKEN_PAYLOAD_SIZE]u8 {
        const raw_ptr: [*]const u8 = @ptrCast(self);
        return @ptrCast(raw_ptr[0..TOKEN_PAYLOAD_SIZE]);
    }

    pub fn sign(self: *CapabilityToken, key_pair: *const std.crypto.sign.Ed25519.KeyPair) !void {
        const payload = self.getPayloadBytes();
        const sig = try key_pair.sign(payload, null);
        self.signature = sig.toBytes();
    }

    pub fn verify(
        self: *const CapabilityToken,
        issuer_pubkey_bytes: *const [PUBKEY_LEN]u8,
        current_ticks: u64,
        subject: ?*const [NODE_ID_LEN]u8,
        required_rights: u64,
    ) !void {
        if (current_ticks > self.expires_at_ticks) return error.TokenExpired;
        if (current_ticks < self.issued_at_ticks) return error.TokenNotYetValid;
        if ((self.rights & required_rights) != required_rights) return error.InsufficientRights;

        if (subject) |sub| {
            if (!isZeroSlice(&self.subject_id) and !std.mem.eql(u8, &self.subject_id, sub)) {
                return error.SubjectMismatch;
            }
        }

        const pubkey = try std.crypto.sign.Ed25519.PublicKey.fromBytes(issuer_pubkey_bytes.*);
        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(self.signature);
        try sig.verify(self.getPayloadBytes(), pubkey);
    }

    pub fn attenuate(
        self: *const CapabilityToken,
        delegator_kp: *const std.crypto.sign.Ed25519.KeyPair,
        new_subject: *const [NODE_ID_LEN]u8,
        attenuated_rights: u64,
        new_expiration_ticks: u64,
        new_nonce: u64,
    ) !CapabilityToken {
        if ((self.rights & RIGHT_DELEGATE) == 0) return error.DelegationNotPermitted;
        if ((attenuated_rights & ~self.rights) != 0) return error.CannotEscalateRights;
        if (new_expiration_ticks > self.expires_at_ticks) return error.CannotExtendExpiration;

        var derived = CapabilityToken{
            .issuer_id = self.subject_id,
            .subject_id = new_subject.*,
            .rights = attenuated_rights,
            .resource_hash = self.resource_hash,
            .issued_at_ticks = self.issued_at_ticks,
            .expires_at_ticks = new_expiration_ticks,
            .nonce = new_nonce,
            .signature = [_]u8{0} ** SIGNATURE_LEN,
        };
        try derived.sign(delegator_kp);
        return derived;
    }
};

fn isZeroSlice(s: []const u8) bool {
    for (s) |b| {
        if (b != 0) return false;
    }
    return true;
}

pub const RemoteActorDispatch = extern struct {
    token: CapabilityToken align(1),
    manifest_hash: [HASH_SIZE]u8 align(1),
    actor_id: u32 align(1),
    memory_limit_pages: u32 align(1),

    pub fn serialize(self: *const RemoteActorDispatch, out_buf: *[@sizeOf(RemoteActorDispatch)]u8) void {
        const raw_bytes: *const [@sizeOf(RemoteActorDispatch)]u8 = @ptrCast(self);
        @memcpy(out_buf, raw_bytes);
    }

    pub fn deserialize(in_buf: *const [@sizeOf(RemoteActorDispatch)]u8) RemoteActorDispatch {
        const ptr: *const RemoteActorDispatch = @ptrCast(in_buf);
        return ptr.*;
    }
};

pub const RemoteActorResult = extern struct {
    actor_id: u32 align(1),
    exit_code: u32 align(1),
    output_hash: [HASH_SIZE]u8 align(1),
    execution_ticks: u64 align(1),

    pub fn serialize(self: *const RemoteActorResult, out_buf: *[@sizeOf(RemoteActorResult)]u8) void {
        const raw_bytes: *const [@sizeOf(RemoteActorResult)]u8 = @ptrCast(self);
        @memcpy(out_buf, raw_bytes);
    }

    pub fn deserialize(in_buf: *const [@sizeOf(RemoteActorResult)]u8) RemoteActorResult {
        const ptr: *const RemoteActorResult = @ptrCast(in_buf);
        return ptr.*;
    }
};

pub const RemoteActorState = enum(u8) {
    idle = 0,
    running = 1,
    completed = 2,
    failed = 3,
    terminated = 4,
};

pub const RemoteActorEntry = struct {
    actor_id: u32,
    node_id: [NODE_ID_LEN]u8,
    state: RemoteActorState,
    started_ticks: u64,
    exit_code: u32,
    output_hash: [HASH_SIZE]u8,
};

pub const RemoteSupervisor = struct {
    count: usize,
    entries: [MAX_REMOTE_ACTORS]RemoteActorEntry,

    pub fn init() RemoteSupervisor {
        return RemoteSupervisor{
            .count = 0,
            .entries = undefined,
        };
    }

    pub fn registerActor(self: *RemoteSupervisor, actor_id: u32, node_id: *const [NODE_ID_LEN]u8, start_ticks: u64) !void {
        if (self.count >= MAX_REMOTE_ACTORS) return error.SupervisorFull;
        self.entries[self.count] = RemoteActorEntry{
            .actor_id = actor_id,
            .node_id = node_id.*,
            .state = .running,
            .started_ticks = start_ticks,
            .exit_code = 0,
            .output_hash = [_]u8{0} ** HASH_SIZE,
        };
        self.count += 1;
    }

    pub fn updateResult(self: *RemoteSupervisor, actor_id: u32, exit_code: u32, output_hash: *const [HASH_SIZE]u8) !void {
        for (self.entries[0..self.count]) |*e| {
            if (e.actor_id == actor_id) {
                e.exit_code = exit_code;
                e.output_hash = output_hash.*;
                e.state = if (exit_code == 0) .completed else .failed;
                return;
            }
        }
        return error.ActorNotFound;
    }

    pub fn terminateActor(self: *RemoteSupervisor, actor_id: u32) !void {
        for (self.entries[0..self.count]) |*e| {
            if (e.actor_id == actor_id) {
                e.state = .terminated;
                return;
            }
        }
        return error.ActorNotFound;
    }

    pub fn findActor(self: *const RemoteSupervisor, actor_id: u32) ?*const RemoteActorEntry {
        for (self.entries[0..self.count]) |*e| {
            if (e.actor_id == actor_id) return e;
        }
        return null;
    }
};

test "CapabilityToken signing and verification" {
    const seed = [_]u8{0x55} ** 32;
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);

    var token = CapabilityToken{
        .issuer_id = [_]u8{0x01} ** NODE_ID_LEN,
        .subject_id = [_]u8{0x02} ** NODE_ID_LEN,
        .rights = RIGHT_SPAWN_ACTOR | RIGHT_SUPERVISE_ACTOR,
        .resource_hash = [_]u8{0x99} ** HASH_SIZE,
        .issued_at_ticks = 100,
        .expires_at_ticks = 500,
        .nonce = 12345,
        .signature = undefined,
    };
    try token.sign(&kp);

    const subject = [_]u8{0x02} ** NODE_ID_LEN;
    try token.verify(&kp.public_key.bytes, 250, &subject, RIGHT_SPAWN_ACTOR);

    // Expired token rejection
    const exp_err = token.verify(&kp.public_key.bytes, 501, &subject, RIGHT_SPAWN_ACTOR);
    try std.testing.expectError(error.TokenExpired, exp_err);

    // Subject mismatch rejection
    const wrong_subject = [_]u8{0x03} ** NODE_ID_LEN;
    const sub_err = token.verify(&kp.public_key.bytes, 250, &wrong_subject, RIGHT_SPAWN_ACTOR);
    try std.testing.expectError(error.SubjectMismatch, sub_err);

    // Insufficient rights rejection
    const right_err = token.verify(&kp.public_key.bytes, 250, &subject, RIGHT_WRITE_CAS);
    try std.testing.expectError(error.InsufficientRights, right_err);
}

test "CapabilityToken attenuation and privilege bounds" {
    const parent_seed = [_]u8{0x66} ** 32;
    const parent_kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(parent_seed);

    const child_seed = [_]u8{0x77} ** 32;
    const child_kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(child_seed);

    var root_token = CapabilityToken{
        .issuer_id = [_]u8{0x10} ** NODE_ID_LEN,
        .subject_id = [_]u8{0x20} ** NODE_ID_LEN,
        .rights = RIGHT_READ_CAS | RIGHT_SPAWN_ACTOR | RIGHT_DELEGATE,
        .resource_hash = [_]u8{0xAA} ** HASH_SIZE,
        .issued_at_ticks = 50,
        .expires_at_ticks = 1000,
        .nonce = 1,
        .signature = undefined,
    };
    try root_token.sign(&parent_kp);

    const grandchild_subject = [_]u8{0x30} ** NODE_ID_LEN;
    // Attenuate: reduce rights to only RIGHT_READ_CAS, reduce expiry to 600
    const child_token = try root_token.attenuate(
        &child_kp,
        &grandchild_subject,
        RIGHT_READ_CAS,
        600,
        2,
    );

    try std.testing.expectEqual(RIGHT_READ_CAS, child_token.rights);
    try std.testing.expectEqual(@as(u64, 600), child_token.expires_at_ticks);

    // Escalation must fail
    const escalate_err = root_token.attenuate(
        &child_kp,
        &grandchild_subject,
        RIGHT_READ_CAS | RIGHT_WRITE_CAS,
        500,
        3,
    );
    try std.testing.expectError(error.CannotEscalateRights, escalate_err);

    // Extension of expiration must fail
    const extend_err = root_token.attenuate(
        &child_kp,
        &grandchild_subject,
        RIGHT_READ_CAS,
        1500,
        4,
    );
    try std.testing.expectError(error.CannotExtendExpiration, extend_err);
}

test "RemoteActorDispatch and RemoteActorResult binary serialization" {
    const dispatch = RemoteActorDispatch{
        .token = std.mem.zeroes(CapabilityToken),
        .manifest_hash = [_]u8{0x88} ** HASH_SIZE,
        .actor_id = 42,
        .memory_limit_pages = 256,
    };

    var dispatch_buf: [@sizeOf(RemoteActorDispatch)]u8 = undefined;
    dispatch.serialize(&dispatch_buf);

    const parsed_dispatch = RemoteActorDispatch.deserialize(&dispatch_buf);
    try std.testing.expectEqual(@as(u32, 42), parsed_dispatch.actor_id);
    try std.testing.expectEqual(@as(u32, 256), parsed_dispatch.memory_limit_pages);
    try std.testing.expectEqualStrings(&dispatch.manifest_hash, &parsed_dispatch.manifest_hash);

    const result = RemoteActorResult{
        .actor_id = 42,
        .exit_code = 0,
        .output_hash = [_]u8{0x77} ** HASH_SIZE,
        .execution_ticks = 1500,
    };

    var result_buf: [@sizeOf(RemoteActorResult)]u8 = undefined;
    result.serialize(&result_buf);

    const parsed_result = RemoteActorResult.deserialize(&result_buf);
    try std.testing.expectEqual(@as(u32, 42), parsed_result.actor_id);
    try std.testing.expectEqual(@as(u32, 0), parsed_result.exit_code);
    try std.testing.expectEqual(@as(u64, 1500), parsed_result.execution_ticks);
}

test "RemoteSupervisor lifecycle and state tracking" {
    var sup = RemoteSupervisor.init();
    const node1 = [_]u8{0x01} ** NODE_ID_LEN;

    try sup.registerActor(101, &node1, 100);
    try std.testing.expectEqual(@as(usize, 1), sup.count);

    const actor = sup.findActor(101);
    try std.testing.expect(actor != null);
    try std.testing.expectEqual(RemoteActorState.running, actor.?.state);

    const out_hash = [_]u8{0x55} ** HASH_SIZE;
    try sup.updateResult(101, 0, &out_hash);
    try std.testing.expectEqual(RemoteActorState.completed, actor.?.state);
    try std.testing.expectEqualStrings(&out_hash, &actor.?.output_hash);

    try sup.terminateActor(101);
    try std.testing.expectEqual(RemoteActorState.terminated, actor.?.state);
}
