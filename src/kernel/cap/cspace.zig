// MicrOS (µOS) Capability Space (CSpace)
// Local per-domain capability table for object authorization and delegation.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("../arch/x86_64/io.zig");
const capability_mod = @import("capability.zig");
const Capability = capability_mod.Capability;
const CapType = capability_mod.CapType;
const Rights = capability_mod.Rights;

pub const CapError = error{
    InvalidHandle,
    TableFull,
    PermissionDenied,
    TypeMismatch,
};

pub const DEFAULT_CSPACE_CAPACITY: usize = 256;

pub var unmap_extent_fn: ?*const fn (virt: u64, size: usize) void = null;

pub const CSpace = struct {
    entries: []align(4096) Capability,
    capacity: usize,
    lock: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn acquireLock(self: *const CSpace) u64 {
        const flags = if (!builtin.is_test) io.pushfqAndCli() else 0;
        const lock_ptr: *std.atomic.Value(u32) = @constCast(&self.lock);
        while (lock_ptr.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            if (!builtin.is_test) io.pause();
        }
        return flags;
    }

    fn releaseLock(self: *const CSpace, flags: u64) void {
        const lock_ptr: *std.atomic.Value(u32) = @constCast(&self.lock);
        lock_ptr.store(0, .release);
        if (!builtin.is_test) io.popfq(flags);
    }

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !*CSpace {
        const cspace = try allocator.create(CSpace);
        errdefer allocator.destroy(cspace);
        const entries = try allocator.allocWithOptions(Capability, capacity, .fromByteUnits(4096), null);
        for (entries) |*entry| {
            entry.* = Capability.NULL_CAP;
        }

        cspace.* = CSpace{
            .entries = entries,
            .capacity = capacity,
            .lock = std.atomic.Value(u32).init(0),
        };
        return cspace;
    }

    pub fn deinit(self: *CSpace, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.destroy(self);
    }

    pub fn insert(self: *CSpace, cap: Capability) CapError!u32 {
        if (!cap.isValid()) return CapError.InvalidHandle;
        const flags = self.acquireLock();
        defer self.releaseLock(flags);

        var idx: usize = 0;
        while (idx < self.capacity) : (idx += 1) {
            if (!self.entries[idx].isValid()) {
                self.entries[idx] = cap;
                return @intCast(idx);
            }
        }
        return CapError.TableFull;
    }

    pub fn get(self: *const CSpace, handle: u32) ?Capability {
        if (handle >= self.capacity) return null;
        const flags = self.acquireLock();
        defer self.releaseLock(flags);

        const cap = self.entries[handle];
        if (!cap.isValid()) return null;
        return cap;
    }

    pub fn drop(self: *CSpace, handle: u32) CapError!void {
        if (handle >= self.capacity) return CapError.InvalidHandle;
        const flags = self.acquireLock();
        defer self.releaseLock(flags);

        if (!self.entries[handle].isValid()) return CapError.InvalidHandle;
        self.entries[handle] = Capability.NULL_CAP;
    }

    pub fn revoke(self: *CSpace, handle: u32) CapError!void {
        if (handle >= self.capacity) return CapError.InvalidHandle;
        const flags = self.acquireLock();
        defer self.releaseLock(flags);

        const cap = self.entries[handle];
        if (!cap.isValid()) return CapError.InvalidHandle;
        if (!cap.hasRight(Rights.REVOKE)) return CapError.PermissionDenied;

        // Invalidate VMM page table mappings and flush TLB for revoked memory extents
        if (cap.cap_type == .memory_extent and cap.data_addr != 0 and cap.data_size != 0) {
            if (unmap_extent_fn) |unmap_fn| {
                const len: usize = std.math.cast(usize, cap.data_size) orelse 0;
                unmap_fn(cap.data_addr, len);
            }
        }

        self.entries[handle] = Capability.NULL_CAP;
    }

    pub fn grant(
        self: *const CSpace,
        src_handle: u32,
        target_cspace: *CSpace,
        rights_mask: u16,
    ) CapError!u32 {
        const src_cap = self.get(src_handle) orelse return CapError.InvalidHandle;
        if (!src_cap.hasRight(Rights.GRANT)) return CapError.PermissionDenied;

        // Reject escalation: requesting rights not held by source
        if ((rights_mask & ~src_cap.rights) != 0) return CapError.PermissionDenied;
        const final_rights = src_cap.rights & rights_mask;
        if (final_rights == Rights.NONE) return CapError.PermissionDenied;

        var delegated_cap = src_cap;
        delegated_cap.rights = final_rights;
        return target_cspace.insert(delegated_cap);
    }

    pub fn validate(
        self: *const CSpace,
        handle: u32,
        expected_type: CapType,
        required_rights: u16,
    ) CapError!Capability {
        const cap = self.get(handle) orelse return CapError.InvalidHandle;
        if (cap.cap_type != expected_type) return CapError.TypeMismatch;
        if (!cap.hasRight(required_rights)) return CapError.PermissionDenied;
        return cap;
    }

    pub fn hasCap(self: *const CSpace, cap_type: CapType, required_right: u16) bool {
        const flags = self.acquireLock();
        defer self.releaseLock(flags);

        var i: usize = 0;
        while (i < self.capacity) : (i += 1) {
            const entry = self.entries[i];
            if (entry.isValid() and entry.cap_type == cap_type and entry.hasRight(required_right)) {
                return true;
            }
        }
        return false;
    }

    pub fn authorizesPhysicalExtent(self: *const CSpace, phys: u64, size: u64, required_rights: u16) bool {
        if (size == 0) return true;
        if (size > std.math.maxInt(u64) - phys) return false;
        const phys_end = phys + size;

        const flags = self.acquireLock();
        defer self.releaseLock(flags);

        var i: usize = 0;
        while (i < self.capacity) : (i += 1) {
            const entry = self.entries[i];
            if (entry.isValid() and entry.cap_type == .memory_extent and entry.hasRight(required_rights)) {
                const ext_start = entry.data_addr;
                const ext_size = entry.data_size;
                if (ext_size <= std.math.maxInt(u64) - ext_start) {
                    const ext_end = ext_start + ext_size;
                    if (phys >= ext_start and phys_end <= ext_end) return true;
                }
            }
        }
        return false;
    }
};

test "CSpace allocation, insertion, validation, grant, and revocation" {
    const allocator = std.testing.allocator;
    var cspace1 = try CSpace.init(allocator, 16);
    defer cspace1.deinit(allocator);

    var cspace2 = try CSpace.init(allocator, 16);
    defer cspace2.deinit(allocator);

    const cap = Capability{
        .cap_type = .framebuffer,
        .rights = Rights.READ | Rights.WRITE | Rights.GRANT | Rights.REVOKE,
        .object_id = 42,
        .data_addr = 0xE000_0000,
        .data_size = 1024 * 768 * 4,
    };

    const handle1 = try cspace1.insert(cap);
    try std.testing.expectEqual(@as(u32, 0), handle1);

    // Reject NULL_CAP insertion
    try std.testing.expectError(CapError.InvalidHandle, cspace1.insert(Capability.NULL_CAP));

    // Validate capability type and rights
    const validated = try cspace1.validate(handle1, .framebuffer, Rights.READ | Rights.WRITE);
    try std.testing.expectEqual(@as(u64, 0xE000_0000), validated.data_addr);

    // Grant attenuated capability to cspace2 (only READ right)
    const handle2 = try cspace1.grant(handle1, cspace2, Rights.READ);
    const delegated = cspace2.get(handle2).?;
    try std.testing.expect(delegated.hasRight(Rights.READ));
    try std.testing.expect(!delegated.hasRight(Rights.WRITE));
    try std.testing.expect(!delegated.hasRight(Rights.GRANT));

    // Reject grant escalation (cspace2 only has READ, cannot grant WRITE or EXECUTE)
    try std.testing.expectError(CapError.PermissionDenied, cspace2.grant(handle2, cspace1, Rights.WRITE));

    // Reject revoke without REVOKE right (delegated has only READ)
    try std.testing.expectError(CapError.PermissionDenied, cspace2.revoke(handle2));

    // Unprivileged holder drops its own local slot cleanly via drop()
    try cspace2.drop(handle2);
    try std.testing.expect(cspace2.get(handle2) == null);

    // Revoke from cspace1 (has REVOKE right)
    try cspace1.revoke(handle1);
    try std.testing.expect(cspace1.get(handle1) == null);
}

test "SPEC-TECH-MIN-001: Formal Attenuation Matrix & Monotonic Security Gate Audit" {
    const allocator = std.testing.allocator;
    var root_cspace = try CSpace.init(allocator, 32);
    defer root_cspace.deinit(allocator);

    var child_cspace = try CSpace.init(allocator, 32);
    defer child_cspace.deinit(allocator);

    // 1. memory_extent: READ | WRITE | EXECUTE | GRANT -> attenuated to READ | EXECUTE
    const mem_cap = Capability{
        .cap_type = .memory_extent,
        .rights = Rights.READ | Rights.WRITE | Rights.EXECUTE | Rights.GRANT,
        .object_id = 1,
        .data_addr = 0x4000_0000,
        .data_size = 4096 * 16,
    };
    const mem_h = try root_cspace.insert(mem_cap);
    const child_mem_h = try root_cspace.grant(mem_h, child_cspace, Rights.READ | Rights.EXECUTE);
    const child_mem = child_cspace.get(child_mem_h).?;
    try std.testing.expect(child_mem.hasRight(Rights.READ | Rights.EXECUTE));
    try std.testing.expect(!child_mem.hasRight(Rights.WRITE));
    try std.testing.expect(!child_mem.hasRight(Rights.GRANT));
    try std.testing.expectEqual(mem_cap.rights, child_mem.rights | mem_cap.rights);

    // 2. ipc_ring: ALL -> attenuated to READ
    const ring_cap = Capability{
        .cap_type = .ipc_ring,
        .rights = Rights.ALL,
        .object_id = 2,
        .data_addr = 0x5000_0000,
        .data_size = 4096,
    };
    const ring_h = try root_cspace.insert(ring_cap);
    const child_ring_h = try root_cspace.grant(ring_h, child_cspace, Rights.READ);
    const child_ring = child_cspace.get(child_ring_h).?;
    try std.testing.expect(child_ring.hasRight(Rights.READ));
    try std.testing.expect(!child_ring.hasRight(Rights.WRITE));

    // 3. irq_endpoint: only WRITE (signal & ack), reject unheld rights
    const irq_cap = Capability{
        .cap_type = .irq_endpoint,
        .rights = Rights.WRITE | Rights.GRANT,
        .object_id = 11,
        .data_addr = 0,
        .data_size = 0,
    };
    const irq_h = try root_cspace.insert(irq_cap);
    try std.testing.expectError(CapError.PermissionDenied, root_cspace.grant(irq_h, child_cspace, Rights.EXECUTE));

    // 4. framebuffer: READ | WRITE (reject EXECUTE)
    const fb_cap = Capability{
        .cap_type = .framebuffer,
        .rights = Rights.READ | Rights.WRITE | Rights.GRANT,
        .object_id = 3,
        .data_addr = 0xE000_0000,
        .data_size = 1280 * 800 * 4,
    };
    const fb_h = try root_cspace.insert(fb_cap);
    try std.testing.expectError(CapError.PermissionDenied, root_cspace.grant(fb_h, child_cspace, Rights.EXECUTE));

    // 5. storage_device: READ | WRITE | ALL -> attenuated to READ (read-only mount)
    const storage_cap = Capability{
        .cap_type = .storage_device,
        .rights = Rights.ALL,
        .object_id = 4,
        .data_addr = 0,
        .data_size = 1048576,
    };
    const stor_h = try root_cspace.insert(storage_cap);
    const ro_stor_h = try root_cspace.grant(stor_h, child_cspace, Rights.READ);
    const ro_stor = child_cspace.get(ro_stor_h).?;
    try std.testing.expect(ro_stor.hasRight(Rights.READ));
    try std.testing.expect(!ro_stor.hasRight(Rights.WRITE));

    // 6. actor_control: WRITE (spawn, kill, suspend)
    const actor_cap = Capability{
        .cap_type = .actor_control,
        .rights = Rights.WRITE | Rights.GRANT,
        .object_id = 5,
        .data_addr = 0,
        .data_size = 0,
    };
    const act_h = try root_cspace.insert(actor_cap);
    const delegated_act_h = try root_cspace.grant(act_h, child_cspace, Rights.WRITE);
    const delegated_act = child_cspace.get(delegated_act_h).?;
    try std.testing.expect(delegated_act.hasRight(Rights.WRITE));
    try std.testing.expect(!delegated_act.hasRight(Rights.GRANT));
}

var test_unmapped_virt: u64 = 0;
var test_unmapped_size: usize = 0;
fn mockUnmapExtent(virt: u64, size: usize) void {
    test_unmapped_virt = virt;
    test_unmapped_size = size;
}

test "CSpace revoking memory_extent invokes unmap and TLB flush hook" {
    const cspace = try CSpace.init(std.testing.allocator, 16);
    defer cspace.deinit(std.testing.allocator);

    unmap_extent_fn = mockUnmapExtent;
    defer unmap_extent_fn = null;
    test_unmapped_virt = 0;
    test_unmapped_size = 0;

    const mem_cap = Capability{
        .cap_type = .memory_extent,
        .rights = Rights.READ | Rights.WRITE | Rights.REVOKE,
        .object_id = 1,
        .data_addr = 0x4000_0000,
        .data_size = 8192,
    };
    const h = try cspace.insert(mem_cap);
    try cspace.revoke(h);

    try std.testing.expectEqual(@as(u64, 0x4000_0000), test_unmapped_virt);
    try std.testing.expectEqual(@as(usize, 8192), test_unmapped_size);
    try std.testing.expect(cspace.get(h) == null);
}
