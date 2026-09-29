// MicrOS (µOS) Capability Space (CSpace)
// Local per-domain capability table for object authorization and delegation.

const std = @import("std");
const builtin = @import("builtin");
const io = @import("../arch/x86_64/io.zig");
const serial = @import("../serial.zig");
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

pub var unmap_extent_fn: ?*const fn (virt: u64, size: usize) bool = null;
pub var dma_quiescence_fn: ?*const fn (device_id: u32) bool = null;
pub var cap_denied_log_fn: ?*const fn (cap_type: CapType, held: u16, req: u16) void = null;

pub fn logCapDenied(cap_type: CapType, held: u16, req: u16) void {
    if (cap_denied_log_fn) |hook| {
        hook(cap_type, held, req);
    }
    if (!builtin.is_test) {
        serial.writeString("[cap] OVER-REACH DENIED: cap_type=");
        var buf: [64]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "{d} held=0x{x} req=0x{x}\n", .{ @intFromEnum(cap_type), held, req })) |s| {
            serial.writeString(s);
        } else |_| {}
    }
}

pub const CapabilitySlot = struct {
    cap: Capability = Capability.NULL_CAP,
    parent_cspace: ?*const CSpace = null,
    parent_slot: ?u32 = null,
    parent_gen: u32 = 0,
    generation: u32 = 1,
    is_valid: bool = false,
    was_allocated: bool = false,
};

pub const CSpace = struct {
    slots: []align(4096) CapabilitySlot,
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
        const slots = try allocator.allocWithOptions(CapabilitySlot, capacity, .fromByteUnits(4096), null);
        for (slots) |*slot| {
            slot.* = CapabilitySlot{};
        }

        cspace.* = CSpace{
            .slots = slots,
            .capacity = capacity,
            .lock = std.atomic.Value(u32).init(0),
        };
        return cspace;
    }

    pub fn deinit(self: *CSpace, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
        allocator.destroy(self);
    }

    fn isSlotLineageActive(self: *const CSpace, handle: u32) bool {
        var cur_cs: *const CSpace = self;
        var cur_h: u32 = handle;
        var depth: usize = 0;
        while (depth < 64) : (depth += 1) {
            if (cur_h >= cur_cs.capacity) return false;
            const s = cur_cs.slots[cur_h];
            if (!s.is_valid or !s.cap.isValid()) return false;
            if (s.parent_cspace) |p_cs| {
                if (s.parent_slot) |p_h| {
                    if (p_h >= p_cs.capacity) return false;
                    const p_s = p_cs.slots[p_h];
                    if (!p_s.is_valid or p_s.generation != s.parent_gen) return false;
                    cur_cs = p_cs;
                    cur_h = p_h;
                    continue;
                }
            }
            return true;
        }
        return false;
    }

    pub fn insert(self: *CSpace, cap: Capability) CapError!u32 {
        if (!cap.isValid()) return CapError.InvalidHandle;
        const flags = self.acquireLock();
        defer self.releaseLock(flags);

        var idx: usize = 0;
        while (idx < self.capacity) : (idx += 1) {
            if (!self.slots[idx].is_valid) {
                self.slots[idx] = CapabilitySlot{
                    .cap = cap,
                    .parent_cspace = null,
                    .parent_slot = null,
                    .parent_gen = 0,
                    .generation = self.slots[idx].generation +% 1,
                    .is_valid = true,
                    .was_allocated = true,
                };
                return @intCast(idx);
            }
        }
        return CapError.TableFull;
    }

    fn insertChild(
        self: *CSpace,
        cap: Capability,
        parent_cs: *const CSpace,
        parent_h: u32,
        parent_g: u32,
    ) CapError!u32 {
        if (!cap.isValid()) return CapError.InvalidHandle;
        const flags = self.acquireLock();
        defer self.releaseLock(flags);

        var idx: usize = 0;
        while (idx < self.capacity) : (idx += 1) {
            if (!self.slots[idx].is_valid) {
                self.slots[idx] = CapabilitySlot{
                    .cap = cap,
                    .parent_cspace = parent_cs,
                    .parent_slot = parent_h,
                    .parent_gen = parent_g,
                    .generation = self.slots[idx].generation +% 1,
                    .is_valid = true,
                    .was_allocated = true,
                };
                return @intCast(idx);
            }
        }
        return CapError.TableFull;
    }

    pub fn get(self: *const CSpace, handle: u32) ?Capability {
        if (handle >= self.capacity) return null;
        const flags = self.acquireLock();
        defer self.releaseLock(flags);

        if (!self.isSlotLineageActive(handle)) {
            if (self.slots[handle].is_valid) {
                const slot_ptr: *CapabilitySlot = @constCast(&self.slots[handle]);
                slot_ptr.is_valid = false;
                slot_ptr.cap = Capability.NULL_CAP;
                slot_ptr.generation +%= 1;
            }
            return null;
        }
        return self.slots[handle].cap;
    }

    pub fn drop(self: *CSpace, handle: u32) CapError!void {
        if (handle >= self.capacity) return CapError.InvalidHandle;
        const flags = self.acquireLock();
        defer self.releaseLock(flags);

        if (!self.slots[handle].is_valid) return CapError.InvalidHandle;
        self.slots[handle].is_valid = false;
        self.slots[handle].cap = Capability.NULL_CAP;
        self.slots[handle].generation +%= 1;
    }

    fn inWorklist(list: []const u32, target: u32) bool {
        for (list) |w| {
            if (w == target) return true;
        }
        return false;
    }

    fn isChildOf(slot: CapabilitySlot, self: *const CSpace, cur: u32) bool {
        if (!slot.is_valid) return false;
        const matching_cspace = (slot.parent_cspace == null or slot.parent_cspace == self);
        return matching_cspace and slot.parent_slot != null and slot.parent_slot.? == cur;
    }

    fn buildRevocationWorklist(self: *const CSpace, root: u32, worklist: []u32) usize {
        worklist[0] = root;
        var count: usize = 1;
        var head: usize = 0;
        while (head < count and head < self.capacity) : (head += 1) {
            const cur = worklist[head];
            for (0..self.capacity) |i| {
                const idx: u32 = @intCast(i);
                if (!isChildOf(self.slots[idx], self, cur)) continue;
                if (inWorklist(worklist[0..count], idx)) continue;
                if (count >= worklist.len or count >= self.capacity) continue;
                worklist[count] = idx;
                count += 1;
            }
        }
        return count;
    }

    fn invalidateSlotCommandment12(self: *CSpace, target_h: u32) CapError!void {
        const target_cap = self.slots[target_h].cap;
        const is_mem_or_dev = (target_cap.cap_type == .memory_extent or target_cap.cap_type == .hardware_device);
        if (is_mem_or_dev and target_cap.data_addr != 0 and target_cap.data_size != 0) {
            if (unmap_extent_fn) |unmap_fn| {
                const len: usize = std.math.cast(usize, target_cap.data_size) orelse 0;
                if (!unmap_fn(target_cap.data_addr, len)) return CapError.PermissionDenied;
            }
        }
        if (dma_quiescence_fn) |dma_fn| {
            _ = dma_fn(target_cap.object_id);
        }
        self.slots[target_h].is_valid = false;
        self.slots[target_h].cap = Capability.NULL_CAP;
        self.slots[target_h].generation +%= 1;
    }

    pub fn revoke(self: *CSpace, handle: u32) CapError!void {
        if (handle >= self.capacity) return CapError.InvalidHandle;
        const flags = self.acquireLock();
        defer self.releaseLock(flags);

        const slot = self.slots[handle];
        if (!slot.was_allocated) return CapError.InvalidHandle;
        if (!slot.is_valid) return;
        if (!slot.cap.hasRight(Rights.REVOKE)) return CapError.PermissionDenied;

        var worklist: [DEFAULT_CSPACE_CAPACITY]u32 = undefined;
        const count = buildRevocationWorklist(self, handle, &worklist);

        var rev_idx = count;
        while (rev_idx > 0) {
            rev_idx -= 1;
            const target_h = worklist[rev_idx];
            self.invalidateSlotCommandment12(target_h) catch |err| {
                if (target_h == handle) return err;
            };
        }
    }

    pub fn mintSubToken(
        self: *const CSpace,
        src_handle: u32,
        target_cspace: *CSpace,
        restricted_mask: u16,
    ) CapError!u32 {
        if (src_handle >= self.capacity) return CapError.InvalidHandle;
        const flags = self.acquireLock();
        if (!self.isSlotLineageActive(src_handle)) {
            self.releaseLock(flags);
            return CapError.InvalidHandle;
        }
        const src_slot = self.slots[src_handle];
        if (!src_slot.cap.hasRight(Rights.GRANT)) {
            self.releaseLock(flags);
            return CapError.PermissionDenied;
        }

        // Reject escalation: requesting rights not held by source
        if ((restricted_mask & ~src_slot.cap.rights) != 0) {
            self.releaseLock(flags);
            return CapError.PermissionDenied;
        }
        const final_rights = src_slot.cap.rights & restricted_mask;
        if (final_rights == Rights.NONE) {
            self.releaseLock(flags);
            return CapError.PermissionDenied;
        }

        var delegated_cap = src_slot.cap;
        delegated_cap.rights = final_rights;
        const src_gen = src_slot.generation;
        self.releaseLock(flags);

        return target_cspace.insertChild(delegated_cap, self, src_handle, src_gen);
    }

    pub fn mintSubTokenByType(
        self: *const CSpace,
        cap_type: CapType,
        target_cspace: *CSpace,
        restricted_mask: u16,
    ) CapError!u32 {
        const flags = self.acquireLock();
        var found_handle: ?u32 = null;
        var i: usize = 0;
        while (i < self.capacity) : (i += 1) {
            if (self.isSlotLineageActive(@intCast(i))) {
                const entry = self.slots[i].cap;
                if (entry.cap_type == cap_type and entry.hasRight(Rights.GRANT)) {
                    found_handle = @intCast(i);
                    break;
                }
            }
        }
        self.releaseLock(flags);
        const handle = found_handle orelse return CapError.InvalidHandle;
        return self.mintSubToken(handle, target_cspace, restricted_mask);
    }

    pub fn grant(
        self: *const CSpace,
        src_handle: u32,
        target_cspace: *CSpace,
        rights_mask: u16,
    ) CapError!u32 {
        return self.mintSubToken(src_handle, target_cspace, rights_mask);
    }

    pub fn lookup(self: *const CSpace, cap_type: CapType) ?Capability {
        const flags = self.acquireLock();
        defer self.releaseLock(flags);

        var i: usize = 0;
        while (i < self.capacity) : (i += 1) {
            if (self.isSlotLineageActive(@intCast(i))) {
                const entry = self.slots[i].cap;
                if (entry.cap_type == cap_type) {
                    return entry;
                }
            }
        }
        return null;
    }

    pub fn lookupWithRights(
        self: *const CSpace,
        cap_type: CapType,
        required_rights: u16,
    ) ?Capability {
        const flags = self.acquireLock();
        defer self.releaseLock(flags);

        var best_match: ?Capability = null;
        for (0..self.capacity) |i| {
            if (!self.isSlotLineageActive(@intCast(i))) continue;
            const entry = self.slots[i].cap;
            if (entry.cap_type != cap_type) continue;
            if (entry.hasRight(required_rights)) return entry;
            if (best_match == null or entry.rights > best_match.?.rights) {
                best_match = entry;
            }
        }
        const held = if (best_match) |b| b.rights else 0;
        logCapDenied(cap_type, held, required_rights);
        return null;
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

        for (0..self.capacity) |i| {
            if (!self.isSlotLineageActive(@intCast(i))) continue;
            const entry = self.slots[i].cap;
            if (entry.cap_type == cap_type and entry.hasRight(required_right)) {
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

        for (0..self.capacity) |i| {
            if (!self.isSlotLineageActive(@intCast(i))) continue;
            const entry = self.slots[i].cap;
            const is_mem_or_dev = (entry.cap_type == .memory_extent or entry.cap_type == .hardware_device);
            if (!is_mem_or_dev or !entry.hasRight(required_rights)) continue;

            const ext_start = entry.data_addr;
            const ext_size = entry.data_size;
            if (ext_size > std.math.maxInt(u64) - ext_start) continue;

            const ext_end = ext_start + ext_size;
            if (phys >= ext_start and phys_end <= ext_end) return true;
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
var test_unmap_result: bool = true;
fn mockUnmapExtent(virt: u64, size: usize) bool {
    test_unmapped_virt = virt;
    test_unmapped_size = size;
    return test_unmap_result;
}

test "CSpace revoking memory_extent invokes unmap and TLB flush hook" {
    const cspace = try CSpace.init(std.testing.allocator, 16);
    defer cspace.deinit(std.testing.allocator);

    unmap_extent_fn = mockUnmapExtent;
    defer unmap_extent_fn = null;
    test_unmapped_virt = 0;
    test_unmapped_size = 0;
    test_unmap_result = true;

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

test "CSpace revoking pinned memory_extent rejects revocation" {
    const cspace = try CSpace.init(std.testing.allocator, 16);
    defer cspace.deinit(std.testing.allocator);

    unmap_extent_fn = mockUnmapExtent;
    defer unmap_extent_fn = null;
    test_unmap_result = false;

    const mem_cap = Capability{
        .cap_type = .memory_extent,
        .rights = Rights.READ | Rights.WRITE | Rights.REVOKE,
        .object_id = 1,
        .data_addr = 0x4000_0000,
        .data_size = 4096,
    };
    const h = try cspace.insert(mem_cap);
    try std.testing.expectError(CapError.PermissionDenied, cspace.revoke(h));
    try std.testing.expect(cspace.get(h) != null);
}

test "G3: capability attenuation enforced at lookup" {
    const allocator = std.testing.allocator;
    var root = try CSpace.init(allocator, 16);
    defer root.deinit(allocator);

    var child = try CSpace.init(allocator, 16);
    defer child.deinit(allocator);

    const fb_h = try root.insert(.{
        .cap_type = .framebuffer,
        .rights = Rights.READ | Rights.WRITE | Rights.GRANT,
        .object_id = 1,
        .data_addr = 0xE000_0000,
        .data_size = 1024 * 768 * 4,
    });
    const stor_h = try root.insert(.{
        .cap_type = .storage_device,
        .rights = Rights.ALL,
        .object_id = 2,
        .data_addr = 0,
        .data_size = 1048576,
    });

    // Parent mints sub-token with restricted bitmask:
    // Window/FB has READ|WRITE; storage has READ only. No network, no actor_control.
    _ = try root.mintSubToken(fb_h, child, Rights.READ | Rights.WRITE);
    _ = try root.mintSubToken(stor_h, child, Rights.READ);

    // Enforced at lookup
    const fb_cap = child.lookup(.framebuffer);
    try std.testing.expect(fb_cap != null);
    try std.testing.expectEqual(Rights.READ | Rights.WRITE, fb_cap.?.rights);

    const stor_cap = child.lookupWithRights(.storage_device, Rights.READ);
    try std.testing.expect(stor_cap != null);

    // Over-reach lookup for storage WRITE fails
    const stor_write = child.lookupWithRights(.storage_device, Rights.WRITE);
    try std.testing.expect(stor_write == null);

    // Over-reach lookup for network_device fails
    const net_cap = child.lookup(.network_device);
    try std.testing.expect(net_cap == null);
}

var last_denied_cap_type: CapType = .null_cap;
var last_denied_held: u16 = 0;
var last_denied_req: u16 = 0;
var denied_hook_called: bool = false;

fn testCapDeniedHook(cap_type: CapType, held: u16, req: u16) void {
    last_denied_cap_type = cap_type;
    last_denied_held = held;
    last_denied_req = req;
    denied_hook_called = true;
}

test "G3: capability over-reach denied and logged" {
    const allocator = std.testing.allocator;
    var space = try CSpace.init(allocator, 16);
    defer space.deinit(allocator);

    cap_denied_log_fn = testCapDeniedHook;
    defer cap_denied_log_fn = null;
    denied_hook_called = false;

    _ = try space.insert(.{
        .cap_type = .storage_device,
        .rights = Rights.READ,
        .object_id = 10,
        .data_addr = 0,
        .data_size = 4096,
    });

    // Attempting lookup with WRITE right must fail and log
    const res = space.lookupWithRights(.storage_device, Rights.WRITE);
    try std.testing.expect(res == null);
    try std.testing.expect(denied_hook_called);
    try std.testing.expectEqual(CapType.storage_device, last_denied_cap_type);
    try std.testing.expectEqual(Rights.READ, last_denied_held);
    try std.testing.expectEqual(Rights.WRITE, last_denied_req);

    // Attempting lookup for unheld cap type logs with held=0
    denied_hook_called = false;
    const res_net = space.lookupWithRights(.network_device, Rights.READ);
    try std.testing.expect(res_net == null);
    try std.testing.expect(denied_hook_called);
    try std.testing.expectEqual(CapType.network_device, last_denied_cap_type);
    try std.testing.expectEqual(@as(u16, 0), last_denied_held);
    try std.testing.expectEqual(Rights.READ, last_denied_req);
}

test "G3: attenuation chains narrow monotonically (child of child)" {
    const allocator = std.testing.allocator;
    var root = try CSpace.init(allocator, 16);
    defer root.deinit(allocator);

    var child = try CSpace.init(allocator, 16);
    defer child.deinit(allocator);

    var grandchild = try CSpace.init(allocator, 16);
    defer grandchild.deinit(allocator);

    const root_h = try root.insert(.{
        .cap_type = .storage_device,
        .rights = Rights.ALL,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 65536,
    });

    // Root mints to child with READ | WRITE | GRANT
    const child_h = try root.mintSubToken(root_h, child, Rights.READ | Rights.WRITE | Rights.GRANT);

    // Child mints to grandchild with READ only (no GRANT, no WRITE)
    const gchild_h = try child.mintSubToken(child_h, grandchild, Rights.READ);
    const gchild_cap = grandchild.get(gchild_h).?;
    try std.testing.expectEqual(Rights.READ, gchild_cap.rights);

    // Grandchild cannot escalate to WRITE or GRANT
    try std.testing.expectError(CapError.PermissionDenied, grandchild.mintSubToken(gchild_h, root, Rights.WRITE));
    try std.testing.expectError(CapError.PermissionDenied, grandchild.mintSubToken(gchild_h, root, Rights.READ));

    // Monotonic narrowing verified at lookup
    try std.testing.expect(grandchild.lookupWithRights(.storage_device, Rights.READ) != null);
    try std.testing.expect(grandchild.lookupWithRights(.storage_device, Rights.WRITE) == null);
}

test "G6: depth-3 cascading revocation invalidates all descendants" {
    const allocator = std.testing.allocator;
    var space = try CSpace.init(allocator, 16);
    defer space.deinit(allocator);

    // Token A (root)
    const token_a = try space.insert(.{
        .cap_type = .storage_device,
        .rights = Rights.READ | Rights.WRITE | Rights.GRANT | Rights.REVOKE,
        .object_id = 100,
        .data_addr = 0,
        .data_size = 4096,
    });

    // Token B derived from Token A
    const token_b = try space.mintSubToken(token_a, space, Rights.READ | Rights.WRITE | Rights.GRANT | Rights.REVOKE);
    // Token C derived from Token B
    const token_c = try space.mintSubToken(token_b, space, Rights.READ | Rights.WRITE);

    // Verify all 3 tokens are active
    try std.testing.expect(space.get(token_a) != null);
    try std.testing.expect(space.get(token_b) != null);
    try std.testing.expect(space.get(token_c) != null);

    // Revoke Token A -> must cascade to Token B and Token C
    try space.revoke(token_a);

    // Fail-closed: all descendants deny, none linger
    try std.testing.expect(space.get(token_a) == null);
    try std.testing.expect(space.get(token_b) == null);
    try std.testing.expect(space.get(token_c) == null);
}

test "G6: sibling isolation on cascading revocation" {
    const allocator = std.testing.allocator;
    var space = try CSpace.init(allocator, 16);
    defer space.deinit(allocator);

    // Root token
    const root = try space.insert(.{
        .cap_type = .storage_device,
        .rights = Rights.ALL,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 4096,
    });

    // Sub-tokens A and B
    const token_a = try space.mintSubToken(root, space, Rights.READ | Rights.WRITE | Rights.GRANT | Rights.REVOKE);
    const token_b = try space.mintSubToken(root, space, Rights.READ | Rights.WRITE | Rights.GRANT | Rights.REVOKE);

    // A's children
    const child_a1 = try space.mintSubToken(token_a, space, Rights.READ);
    const child_a2 = try space.mintSubToken(token_a, space, Rights.READ);

    // B's children
    const child_b1 = try space.mintSubToken(token_b, space, Rights.READ);
    const child_b2 = try space.mintSubToken(token_b, space, Rights.READ);

    // Revoke Token A
    try space.revoke(token_a);

    // Token A and its children die
    try std.testing.expect(space.get(token_a) == null);
    try std.testing.expect(space.get(child_a1) == null);
    try std.testing.expect(space.get(child_a2) == null);

    // Sibling Token B and its children live
    try std.testing.expect(space.get(token_b) != null);
    try std.testing.expect(space.get(child_b1) != null);
    try std.testing.expect(space.get(child_b2) != null);
}

test "G6: double-revoke idempotence and revoke-without-REVOKE denial" {
    const allocator = std.testing.allocator;
    var space = try CSpace.init(allocator, 16);
    defer space.deinit(allocator);

    const revokable = try space.insert(.{
        .cap_type = .framebuffer,
        .rights = Rights.READ | Rights.WRITE | Rights.REVOKE,
        .object_id = 1,
        .data_addr = 0xE000_0000,
        .data_size = 1024,
    });

    // First revocation succeeds
    try space.revoke(revokable);
    try std.testing.expect(space.get(revokable) == null);

    // Double-revoke idempotence: second revocation succeeds cleanly without error
    try space.revoke(revokable);

    // Token without REVOKE right cannot be revoked
    const unrevokable = try space.insert(.{
        .cap_type = .framebuffer,
        .rights = Rights.READ | Rights.WRITE,
        .object_id = 2,
        .data_addr = 0xE000_1000,
        .data_size = 1024,
    });

    try std.testing.expectError(CapError.PermissionDenied, space.revoke(unrevokable));
    try std.testing.expect(space.get(unrevokable) != null);
}

test "P0-C3: depth-64 iterative cascade stress test without Ring-0 recursion" {
    const allocator = std.testing.allocator;
    var space = try CSpace.init(allocator, 64);
    defer space.deinit(allocator);

    // Mint linear chain of 64 tokens: slot 0 -> slot 1 -> ... -> slot 63
    const root = try space.insert(.{
        .cap_type = .storage_device,
        .rights = Rights.ALL,
        .object_id = 1,
        .data_addr = 0,
        .data_size = 4096,
    });
    try std.testing.expectEqual(@as(u32, 0), root);

    var prev_handle = root;
    var i: usize = 1;
    while (i < 64) : (i += 1) {
        const next_handle = try space.mintSubToken(prev_handle, space, Rights.ALL);
        try std.testing.expectEqual(@as(u32, @intCast(i)), next_handle);
        prev_handle = next_handle;
    }

    // Verify all 64 slots are valid and active
    var check_idx: usize = 0;
    while (check_idx < 64) : (check_idx += 1) {
        try std.testing.expect(space.get(@intCast(check_idx)) != null);
    }

    // Revoke root token (slot 0) — must iteratively cascade across all 64 slots
    try space.revoke(root);

    // Verify every single descendant slot died fail-closed
    check_idx = 0;
    while (check_idx < 64) : (check_idx += 1) {
        try std.testing.expect(space.get(@intCast(check_idx)) == null);
    }
}

var test_dma_quiesced_dev: ?u32 = null;
fn mockDmaQuiescence(device_id: u32) bool {
    test_dma_quiesced_dev = device_id;
    return true;
}

test "Commandment 12: revoking hardware_device enforces unmap and DMA quiescence" {
    const allocator = std.testing.allocator;
    var space = try CSpace.init(allocator, 16);
    defer space.deinit(allocator);

    unmap_extent_fn = mockUnmapExtent;
    defer unmap_extent_fn = null;
    test_unmapped_virt = 0;
    test_unmapped_size = 0;
    test_unmap_result = true;

    dma_quiescence_fn = mockDmaQuiescence;
    defer dma_quiescence_fn = null;
    test_dma_quiesced_dev = null;

    const hw_h = try space.insert(.{
        .cap_type = .hardware_device,
        .rights = Rights.READ | Rights.WRITE | Rights.REVOKE,
        .object_id = 0x8086,
        .data_addr = 0xFEB0_0000,
        .data_size = 8192,
    });

    try space.revoke(hw_h);

    try std.testing.expectEqual(@as(u64, 0xFEB0_0000), test_unmapped_virt);
    try std.testing.expectEqual(@as(usize, 8192), test_unmapped_size);
    try std.testing.expectEqual(@as(?u32, 0x8086), test_dma_quiesced_dev);
    try std.testing.expect(space.get(hw_h) == null);
}

test "G6: cross-CSpace cascading revocation fail-closed" {
    const allocator = std.testing.allocator;
    var root_cs = try CSpace.init(allocator, 16);
    defer root_cs.deinit(allocator);

    var child_cs = try CSpace.init(allocator, 16);
    defer child_cs.deinit(allocator);

    var gchild_cs = try CSpace.init(allocator, 16);
    defer gchild_cs.deinit(allocator);

    const root_h = try root_cs.insert(.{
        .cap_type = .storage_device,
        .rights = Rights.ALL,
        .object_id = 99,
        .data_addr = 0,
        .data_size = 4096,
    });

    const child_h = try root_cs.mintSubToken(root_h, child_cs, Rights.READ | Rights.WRITE | Rights.GRANT | Rights.REVOKE);
    const gchild_h = try child_cs.mintSubToken(child_h, gchild_cs, Rights.READ);

    try std.testing.expect(root_cs.get(root_h) != null);
    try std.testing.expect(child_cs.get(child_h) != null);
    try std.testing.expect(gchild_cs.get(gchild_h) != null);

    // Revoke root token in root_cs
    try root_cs.revoke(root_h);

    // Cross-CSpace query fails closed immediately
    try std.testing.expect(root_cs.get(root_h) == null);
    try std.testing.expect(child_cs.get(child_h) == null);
    try std.testing.expect(gchild_cs.get(gchild_h) == null);
}
