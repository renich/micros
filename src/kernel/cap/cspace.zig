// MicrOS (µOS) Capability Space (CSpace)
// Local per-domain capability table for object authorization and delegation.

const std = @import("std");
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

pub const CSpace = struct {
    entries: []align(4096) Capability,
    capacity: usize,

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
        };
        return cspace;
    }

    pub fn deinit(self: *CSpace, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        allocator.destroy(self);
    }

    pub fn insert(self: *CSpace, cap: Capability) CapError!u32 {
        if (!cap.isValid()) return CapError.InvalidHandle;
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
        const cap = self.entries[handle];
        if (!cap.isValid()) return null;
        return cap;
    }

    pub fn drop(self: *CSpace, handle: u32) CapError!void {
        if (handle >= self.capacity) return CapError.InvalidHandle;
        if (!self.entries[handle].isValid()) return CapError.InvalidHandle;
        self.entries[handle] = Capability.NULL_CAP;
    }

    pub fn revoke(self: *CSpace, handle: u32) CapError!void {
        if (handle >= self.capacity) return CapError.InvalidHandle;
        if (!self.entries[handle].isValid()) return CapError.InvalidHandle;
        if (!self.entries[handle].hasRight(Rights.REVOKE)) return CapError.PermissionDenied;
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
