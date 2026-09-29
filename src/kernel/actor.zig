// MicrOS (µOS) Execution Actor & Registry Subsystem
// Isolated computational unit: Address space + CSpace + Execution context.
// Eradicates legacy Unix process (PID) model with zero ambient authority.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("arch/x86_64/io.zig");
const cspace_mod = @import("cap/cspace.zig");
const CSpace = cspace_mod.CSpace;
const capability_mod = @import("cap/capability.zig");
const Capability = capability_mod.Capability;
const CapType = capability_mod.CapType;
const Rights = capability_mod.Rights;
const provenance_mod = @import("provenance.zig");

pub const GENESIS_ACTOR_ID: u32 = 0;
pub const MAX_ACTORS: usize = 64;

pub const ActorError = error{
    RegistryFull,
    ActorNotFound,
    InvalidStateTransition,
    UnalignedPageTable,
    PermissionDenied,
};

pub const ActorState = enum(u8) {
    uninitialized = 0,
    ready = 1,
    running = 2,
    paused = 3,
    faulted = 4,
    terminated = 5,
};

pub const Actor = struct {
    allocator: std.mem.Allocator,
    id: u32,
    name: [32]u8,
    name_len: usize,
    state: ActorState,
    supervisor_id: u32,
    cspace: *CSpace,
    page_table_base: u64,
    restart_count: u32,
    fiber_ctx: ?*anyopaque,
    source: ?[]const u8 = null,
    ref_count: std.atomic.Value(u32),
    gas_budget: u64 = 0,
    gas_used: u64 = 0,
    provenance: provenance_mod.ProvenanceType = .genesis,
    author_pubkey: [32]u8 = [_]u8{0} ** 32,
    signature: [64]u8 = [_]u8{0} ** 64,

    pub fn getBadgeText(self: *const Actor) []const u8 {
        return self.provenance.getBadgeText();
    }

    pub fn init(
        allocator: std.mem.Allocator,
        id: u32,
        name: []const u8,
        cspace_capacity: usize,
        page_table_base: u64,
    ) !*Actor {
        return initWithSupervisor(allocator, id, GENESIS_ACTOR_ID, name, cspace_capacity, page_table_base);
    }

    pub fn initWithSupervisor(
        allocator: std.mem.Allocator,
        id: u32,
        supervisor_id: u32,
        name: []const u8,
        cspace_capacity: usize,
        page_table_base: u64,
    ) !*Actor {
        if (id >= MAX_ACTORS) return ActorError.ActorNotFound;
        const cspace = try CSpace.init(allocator, cspace_capacity);
        errdefer cspace.deinit(allocator);

        const actor = try allocator.create(Actor);
        errdefer allocator.destroy(actor);
        var name_buf = [_]u8{0} ** 32;
        const copy_len = @min(name.len, 32);
        @memcpy(name_buf[0..copy_len], name[0..copy_len]);

        actor.* = .{
            .allocator = allocator,
            .id = id,
            .name = name_buf,
            .name_len = copy_len,
            .state = .ready,
            .supervisor_id = supervisor_id,
            .cspace = cspace,
            .page_table_base = page_table_base,
            .restart_count = 0,
            .fiber_ctx = null,
            .source = null,
            .ref_count = std.atomic.Value(u32).init(1),
        };
        return actor;
    }

    pub fn release(self: *Actor) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            asm volatile ("lfence" ::: .{ .memory = true });
            if (self.page_table_base != 0) {
                if (ActorRegistry.page_table_destructor) |destroy_fn| {
                    destroy_fn(self.page_table_base);
                }
                self.page_table_base = 0;
            }
            if (self.source) |src| {
                self.allocator.free(src);
                self.source = null;
            }
            self.cspace.deinit(self.allocator);
            self.allocator.destroy(self);
        }
    }

    pub fn deinit(self: *Actor, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.release();
    }

    pub fn getName(self: *const Actor) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn transitionTo(self: *Actor, new_state: ActorState) ActorError!void {
        const valid = switch (self.state) {
            .uninitialized => new_state == .ready,
            .ready => new_state == .running or new_state == .terminated,
            .running => new_state == .paused or new_state == .faulted or new_state == .terminated,
            .paused => new_state == .ready or new_state == .running or new_state == .terminated,
            .faulted => new_state == .ready or new_state == .terminated,
            .terminated => false,
        };
        if (!valid) return ActorError.InvalidStateTransition;
        self.state = new_state;
    }

    pub fn insertCap(self: *Actor, cap: Capability) cspace_mod.CapError!u32 {
        return self.cspace.insert(cap);
    }

    pub fn getCap(self: *const Actor, handle: u32) ?Capability {
        return self.cspace.get(handle);
    }

    pub fn dropCap(self: *Actor, handle: u32) cspace_mod.CapError!void {
        return self.cspace.drop(handle);
    }

    pub fn revokeCap(self: *Actor, handle: u32) cspace_mod.CapError!void {
        return self.cspace.revoke(handle);
    }

    pub fn validateCap(
        self: *const Actor,
        handle: u32,
        expected_type: CapType,
        required_rights: u16,
    ) cspace_mod.CapError!Capability {
        return self.cspace.validate(handle, expected_type, required_rights);
    }

    pub fn hasCap(self: *const Actor, cap_type: CapType, required_rights: u16) bool {
        return self.cspace.hasCap(cap_type, required_rights);
    }

    pub fn lookupCap(self: *const Actor, cap_type: CapType) ?Capability {
        return self.cspace.lookup(cap_type);
    }

    pub fn lookupCapWithRights(self: *const Actor, cap_type: CapType, required_rights: u16) ?Capability {
        return self.cspace.lookupWithRights(cap_type, required_rights);
    }

    pub fn authorizesPhysicalExtent(self: *const Actor, phys: u64, size: u64, required_rights: u16) bool {
        if (self.id == GENESIS_ACTOR_ID) return true;
        return self.cspace.authorizesPhysicalExtent(phys, size, required_rights);
    }
};

pub const ActorRegistry = struct {
    actors: [MAX_ACTORS]?*Actor,
    active_count: usize,
    lock: std.atomic.Value(u32),

    pub fn init() ActorRegistry {
        return ActorRegistry{
            .actors = [_]?*Actor{null} ** MAX_ACTORS,
            .active_count = 0,
            .lock = std.atomic.Value(u32).init(0),
        };
    }

    fn acquireLock(self: *ActorRegistry) u64 {
        const flags = if (!builtin.is_test) io.pushfqAndCli() else 0;
        while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            if (!builtin.is_test) io.pause();
        }
        return flags;
    }

    fn releaseLock(self: *ActorRegistry, flags: u64) void {
        self.lock.store(0, .release);
        if (!builtin.is_test) io.popfq(flags);
    }

    pub fn get(self: *ActorRegistry, id: u32) ?*Actor {
        const flags = self.acquireLock();
        defer self.releaseLock(flags);
        if (id >= MAX_ACTORS) return null;
        const actor = self.actors[id] orelse return null;
        _ = actor.ref_count.fetchAdd(1, .acquire);
        return actor;
    }

    pub fn findFreeId(self: *const ActorRegistry) ?u32 {
        var id: u32 = 0;
        while (id < MAX_ACTORS) : (id += 1) {
            if (self.actors[id] == null) return id;
        }
        return null;
    }

    pub fn register(self: *ActorRegistry, actor: *Actor) ActorError!void {
        const flags = self.acquireLock();
        defer self.releaseLock(flags);
        if (actor.id >= MAX_ACTORS) return ActorError.RegistryFull;
        if (self.actors[actor.id] != null) return ActorError.RegistryFull;
        self.actors[actor.id] = actor;
        self.active_count += 1;
    }

    pub fn spawn(
        self: *ActorRegistry,
        allocator: std.mem.Allocator,
        supervisor_id: u32,
        name: []const u8,
        cspace_capacity: usize,
        page_table_base: u64,
    ) !*Actor {
        const flags = self.acquireLock();
        defer self.releaseLock(flags);

        const id = self.findFreeId() orelse return ActorError.RegistryFull;
        const actor = try Actor.initWithSupervisor(
            allocator,
            id,
            supervisor_id,
            name,
            cspace_capacity,
            page_table_base,
        );
        errdefer actor.deinit(allocator);

        if (supervisor_id < MAX_ACTORS and self.actors[supervisor_id] != null) {
            actor.gas_budget = self.actors[supervisor_id].?.gas_budget;
        }

        if (self.actors[id] != null) return ActorError.RegistryFull;
        self.actors[id] = actor;
        self.active_count += 1;
        return actor;
    }

    pub var page_table_destructor: ?*const fn (u64) void = null;
    pub var actor_destructor: ?*const fn (std.mem.Allocator, *Actor) void = null;

    pub fn terminate(self: *ActorRegistry, allocator: std.mem.Allocator, id: u32) ActorError!void {
        if (id >= MAX_ACTORS) return ActorError.ActorNotFound;
        const flags = self.acquireLock();
        const actor = self.actors[id] orelse {
            self.releaseLock(flags);
            return ActorError.ActorNotFound;
        };
        self.actors[id] = null;
        self.active_count -= 1;
        self.releaseLock(flags);

        actor.state = .terminated;
        if (actor_destructor) |destruct_fn| {
            destruct_fn(allocator, actor);
        }
        actor.release();
    }
};

pub var active_registry: ?*ActorRegistry = null;

test "Genesis Actor initialization and capability insertion" {
    const allocator = std.testing.allocator;
    var actor = try Actor.init(allocator, GENESIS_ACTOR_ID, "genesis_actor", 32, 0x1000);
    defer actor.deinit(allocator);

    try std.testing.expectEqual(GENESIS_ACTOR_ID, actor.id);
    try std.testing.expectEqualStrings("genesis_actor", actor.getName());
    try std.testing.expectEqual(ActorState.ready, actor.state);

    const mem_cap = Capability{
        .cap_type = .memory_extent,
        .rights = Rights.READ | Rights.WRITE,
        .object_id = 1,
        .data_addr = 0x2000,
        .data_size = 4096,
    };

    const handle = try actor.insertCap(mem_cap);
    const retrieved = actor.getCap(handle).?;
    try std.testing.expectEqual(CapType.memory_extent, retrieved.cap_type);

    try actor.dropCap(handle);
    try std.testing.expect(actor.getCap(handle) == null);
}

test "Actor state machine transitions and invalid checks" {
    const allocator = std.testing.allocator;
    var actor = try Actor.init(allocator, 1, "test_state", 16, 0);
    defer actor.deinit(allocator);

    try std.testing.expectEqual(ActorState.ready, actor.state);
    try actor.transitionTo(.running);
    try std.testing.expectEqual(ActorState.running, actor.state);

    try actor.transitionTo(.paused);
    try std.testing.expectEqual(ActorState.paused, actor.state);

    try actor.transitionTo(.running);
    try actor.transitionTo(.faulted);
    try std.testing.expectEqual(ActorState.faulted, actor.state);

    try actor.transitionTo(.ready);
    try actor.transitionTo(.terminated);
    try std.testing.expectEqual(ActorState.terminated, actor.state);

    try std.testing.expectError(ActorError.InvalidStateTransition, actor.transitionTo(.running));
}

test "ActorRegistry spawn, query, and termination" {
    const allocator = std.testing.allocator;
    var registry = ActorRegistry.init();
    try std.testing.expectEqual(@as(usize, 0), registry.active_count);

    const child = try registry.spawn(allocator, GENESIS_ACTOR_ID, "child_worker", 16, 0x3000);
    try std.testing.expectEqual(@as(u32, 0), child.id);
    try std.testing.expectEqual(GENESIS_ACTOR_ID, child.supervisor_id);
    try std.testing.expectEqualStrings("child_worker", child.getName());
    try std.testing.expectEqual(@as(usize, 1), registry.active_count);

    const lookup = registry.get(0).?;
    defer lookup.release();
    try std.testing.expectEqual(child, lookup);

    try registry.terminate(allocator, 0);
    try std.testing.expectEqual(@as(usize, 0), registry.active_count);
    try std.testing.expect(registry.get(0) == null);
}

test "Actor reference counting prevents use-after-free during concurrent terminate" {
    const allocator = std.testing.allocator;
    var registry = ActorRegistry.init();

    _ = try registry.spawn(allocator, GENESIS_ACTOR_ID, "smp_worker", 16, 0x4000);
    const lookup = registry.get(0).?;
    try std.testing.expectEqual(@as(u32, 2), lookup.ref_count.load(.acquire));

    // Terminate removes actor from registry, but caller's reference remains valid
    try registry.terminate(allocator, 0);
    try std.testing.expect(registry.get(0) == null);
    try std.testing.expectEqual(@as(u32, 1), lookup.ref_count.load(.acquire));
    try std.testing.expectEqualStrings("smp_worker", lookup.getName());
    try std.testing.expectEqual(ActorState.terminated, lookup.state);

    // Releasing the remaining reference destroys the actor cleanly with 0 leaks
    lookup.release();
}

test "Capability delegation between supervisor and child actor" {
    const allocator = std.testing.allocator;
    var supervisor = try Actor.init(allocator, GENESIS_ACTOR_ID, "supervisor", 32, 0x1000);
    defer supervisor.deinit(allocator);

    var child = try Actor.initWithSupervisor(allocator, 1, GENESIS_ACTOR_ID, "worker", 32, 0x2000);
    defer child.deinit(allocator);

    const sup_cap = Capability{
        .cap_type = .memory_extent,
        .rights = Rights.READ | Rights.WRITE | Rights.GRANT,
        .object_id = 99,
        .data_addr = 0x5000,
        .data_size = 8192,
    };
    const sup_handle = try supervisor.insertCap(sup_cap);

    // Delegate attenuated read-only capability to child
    const child_handle = try supervisor.cspace.grant(
        sup_handle,
        child.cspace,
        Rights.READ,
    );
    const child_cap = child.getCap(child_handle).?;
    try std.testing.expectEqual(Rights.READ, child_cap.rights);
    try std.testing.expect(!child_cap.hasRight(Rights.WRITE));
    try std.testing.expect(!child_cap.canGrant());

    // Escalation attempt (requesting EXECUTE when parent lacks it) fails
    try std.testing.expectError(
        cspace_mod.CapError.PermissionDenied,
        supervisor.cspace.grant(sup_handle, child.cspace, Rights.EXECUTE),
    );
}

test "Actor physical memory extent capability authorization" {
    const allocator = std.testing.allocator;
    var actor = try Actor.init(allocator, 42, "sandboxed_actor", 32, 0x1000);
    defer actor.deinit(allocator);

    const mem_cap = Capability{
        .cap_type = .memory_extent,
        .rights = Rights.READ | Rights.WRITE,
        .object_id = 1,
        .data_addr = 0x20000,
        .data_size = 8192, // 0x20000 .. 0x22000
    };
    _ = try actor.insertCap(mem_cap);

    // Within bounds: authorized
    try std.testing.expect(actor.authorizesPhysicalExtent(0x20000, 4096, Rights.WRITE));
    try std.testing.expect(actor.authorizesPhysicalExtent(0x21000, 4096, Rights.WRITE));

    // Outside bounds: unauthorized
    try std.testing.expect(!actor.authorizesPhysicalExtent(0x1F000, 4096, Rights.WRITE));
    try std.testing.expect(!actor.authorizesPhysicalExtent(0x22000, 4096, Rights.WRITE));
    // Overlapping boundary overflow: unauthorized
    try std.testing.expect(!actor.authorizesPhysicalExtent(0x21000, 8192, Rights.WRITE));
    // Integer overflow attempts: unauthorized
    try std.testing.expect(!actor.authorizesPhysicalExtent(std.math.maxInt(u64) - 100, 200, Rights.WRITE));
}

test "Actor release destroys page tables only on final refcount drop" {
    const allocator = std.testing.allocator;
    var destroyed_pt: u64 = 0;
    const Destructor = struct {
        var pt_ref: *u64 = undefined;
        fn destroy(pt: u64) void {
            pt_ref.* = pt;
        }
    };
    Destructor.pt_ref = &destroyed_pt;
    ActorRegistry.page_table_destructor = Destructor.destroy;
    defer ActorRegistry.page_table_destructor = null;

    var actor = try Actor.init(allocator, 10, "test_ref", 16, 0x5000);
    _ = actor.ref_count.fetchAdd(1, .acquire);
    actor.release();
    try std.testing.expectEqual(@as(u64, 0), destroyed_pt);

    actor.release();
    try std.testing.expectEqual(@as(u64, 0x5000), destroyed_pt);
}

test "live-synth: G7 provenance badge tagging" {
    const allocator = std.testing.allocator;
    var actor_ai = try Actor.init(allocator, 11, "ai_synth", 16, 0);
    defer actor_ai.deinit(allocator);
    actor_ai.provenance = .ai;
    try std.testing.expectEqualStrings("[ai]", actor_ai.getBadgeText());

    var actor_peer = try Actor.init(allocator, 12, "peer_mesh", 16, 0);
    defer actor_peer.deinit(allocator);
    actor_peer.provenance = .peer;
    try std.testing.expectEqualStrings("[peer]", actor_peer.getBadgeText());

    var actor_gen = try Actor.init(allocator, 13, "gen_root", 16, 0);
    defer actor_gen.deinit(allocator);
    actor_gen.provenance = .genesis;
    try std.testing.expectEqualStrings("[gen]", actor_gen.getBadgeText());
}
