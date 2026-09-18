// MicrOS (µOS) Execution Actor & Registry Subsystem
// Isolated computational unit: Address space + CSpace + Execution context.
// Eradicates legacy Unix process (PID) model with zero ambient authority.

const std = @import("std");
const cspace_mod = @import("cap/cspace.zig");
const CSpace = cspace_mod.CSpace;
const capability_mod = @import("cap/capability.zig");
const Capability = capability_mod.Capability;
const CapType = capability_mod.CapType;
const Rights = capability_mod.Rights;

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
    id: u32,
    name: [32]u8,
    name_len: usize,
    state: ActorState,
    supervisor_id: u32,
    cspace: *CSpace,
    page_table_base: u64,
    restart_count: u32,
    fiber_ctx: ?*anyopaque,

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
        if (page_table_base != 0 and (page_table_base & 0xFFF) != 0) {
            return error.UnalignedPageTable;
        }

        const actor = try allocator.create(Actor);
        errdefer allocator.destroy(actor);
        const cspace = try CSpace.init(allocator, cspace_capacity);
        errdefer cspace.deinit(allocator);

        var name_buf: [32]u8 = [_]u8{0} ** 32;
        const copy_len = @min(name.len, 32);
        @memcpy(name_buf[0..copy_len], name[0..copy_len]);

        actor.* = Actor{
            .id = id,
            .name = name_buf,
            .name_len = copy_len,
            .state = .ready,
            .supervisor_id = supervisor_id,
            .cspace = cspace,
            .page_table_base = page_table_base,
            .restart_count = 0,
            .fiber_ctx = null,
        };
        return actor;
    }

    pub fn deinit(self: *Actor, allocator: std.mem.Allocator) void {
        self.cspace.deinit(allocator);
        allocator.destroy(self);
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
        var i: usize = 0;
        while (i < self.cspace.capacity) : (i += 1) {
            const entry = self.cspace.entries[i];
            if (entry.isValid() and entry.cap_type == cap_type and entry.hasRight(required_rights)) {
                return true;
            }
        }
        return false;
    }
};

pub const ActorRegistry = struct {
    actors: [MAX_ACTORS]?*Actor,
    active_count: usize,

    pub fn init() ActorRegistry {
        return ActorRegistry{
            .actors = [_]?*Actor{null} ** MAX_ACTORS,
            .active_count = 0,
        };
    }

    pub fn get(self: *const ActorRegistry, id: u32) ?*Actor {
        if (id >= MAX_ACTORS) return null;
        return self.actors[id];
    }

    pub fn findFreeId(self: *const ActorRegistry) ?u32 {
        var id: u32 = 0;
        while (id < MAX_ACTORS) : (id += 1) {
            if (self.actors[id] == null) return id;
        }
        return null;
    }

    pub fn register(self: *ActorRegistry, actor: *Actor) ActorError!void {
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

        try self.register(actor);
        return actor;
    }

    pub var page_table_destructor: ?*const fn (u64) void = null;

    pub fn terminate(self: *ActorRegistry, allocator: std.mem.Allocator, id: u32) ActorError!void {
        if (id >= MAX_ACTORS) return ActorError.ActorNotFound;
        const actor = self.actors[id] orelse return ActorError.ActorNotFound;
        actor.state = .terminated;
        if (actor.page_table_base != 0) {
            if (page_table_destructor) |destroy_fn| {
                destroy_fn(actor.page_table_base);
            }
            actor.page_table_base = 0;
        }
        self.actors[id] = null;
        self.active_count -= 1;
        actor.deinit(allocator);
    }
};

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
    try std.testing.expectEqual(child, lookup);

    try registry.terminate(allocator, 0);
    try std.testing.expectEqual(@as(usize, 0), registry.active_count);
    try std.testing.expect(registry.get(0) == null);
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
