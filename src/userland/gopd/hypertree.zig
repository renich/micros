// MicrOS (µOS) Binary Reactive Hypermedia Streaming Protocol (µHTML / HyperTree)
// SPEC-TECH-UI-001: Compact 32-byte node records, fine-grained reactive dirty tracking,
// AABB damage computation, and 24-byte bidirectional UI event dispatch. Freestanding, zero libc.

const std = @import("std");

pub const MAX_PAYLOAD_BYTES: usize = 4096;
pub const MAX_NODES: usize = 256;

pub const NodeType = enum(u8) {
    none = 0,
    container = 1,
    text = 2,
    button = 3,
    input = 4,
    canvas = 5,
    icon = 6,
    divider = 7,
};

pub const NodeFlags = struct {
    pub const NONE: u8 = 0x00;
    pub const VISIBLE: u8 = 0x01;
    pub const DIRTY: u8 = 0x02;
    pub const FOCUSED: u8 = 0x04;
    pub const HOVERED: u8 = 0x08;
    pub const CLICKABLE: u8 = 0x10;
    pub const DISABLED: u8 = 0x20;
};

pub const HyperNode = extern struct {
    id: u32,
    parent_id: u32,
    node_type: NodeType,
    flags: u8,
    layout_dir: u8, // 0 = row, 1 = column
    reserved: u8,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    color_fg: u32,
    color_bg: u32,
    payload_len: u16,
    payload_offset: u16,

    pub fn isVisible(self: *const HyperNode) bool {
        return (self.flags & NodeFlags.VISIBLE) != 0;
    }

    pub fn isDirty(self: *const HyperNode) bool {
        return (self.flags & NodeFlags.DIRTY) != 0;
    }

    pub fn isClickable(self: *const HyperNode) bool {
        return (self.flags & NodeFlags.CLICKABLE) != 0 and (self.flags & NodeFlags.DISABLED) == 0;
    }

    pub fn contains(self: *const HyperNode, px: i16, py: i16) bool {
        if (!self.isVisible()) return false;
        if (px < self.x) return false;
        if (py < self.y) return false;
        if (px >= self.x + @as(i16, @intCast(self.width))) return false;
        if (py >= self.y + @as(i16, @intCast(self.height))) return false;
        return true;
    }
};

comptime {
    std.debug.assert(@sizeOf(HyperNode) == 32);
}

pub const UiEventKind = enum(u8) {
    none = 0,
    click = 1,
    mouse_down = 2,
    mouse_up = 3,
    mouse_move = 4,
    key_down = 5,
    key_up = 6,
    focus_gain = 7,
    focus_loss = 8,
    scroll = 9,
};

pub const UiEvent = extern struct {
    target_node_id: u32,
    event_kind: UiEventKind,
    modifier_keys: u8,
    char_code: u16,
    mouse_x: i16,
    mouse_y: i16,
    delta: i16,
    reserved: u16,
    timestamp_ticks: u64,
};

comptime {
    std.debug.assert(@sizeOf(UiEvent) == 24);
}

pub const DamageRect = struct {
    min_x: i16 = 32767,
    min_y: i16 = 32767,
    max_x: i16 = -32768,
    max_y: i16 = -32768,

    pub fn isEmpty(self: *const DamageRect) bool {
        return self.min_x > self.max_x or self.min_y > self.max_y;
    }

    pub fn include(self: *DamageRect, x: i16, y: i16, w: u16, h: u16) void {
        const x2 = x + @as(i16, @intCast(w));
        const y2 = y + @as(i16, @intCast(h));
        if (x < self.min_x) self.min_x = x;
        if (y < self.min_y) self.min_y = y;
        if (x2 > self.max_x) self.max_x = x2;
        if (y2 > self.max_y) self.max_y = y2;
    }
};

pub const HyperTree = struct {
    allocator: std.mem.Allocator,
    nodes: [MAX_NODES]HyperNode,
    node_active: [MAX_NODES]bool,
    node_count: usize,
    payload_arena: [MAX_PAYLOAD_BYTES]u8,
    payload_used: usize,
    focused_node_id: ?u32,

    pub fn init(allocator: std.mem.Allocator) HyperTree {
        return HyperTree{
            .allocator = allocator,
            .nodes = [_]HyperNode{std.mem.zeroes(HyperNode)} ** MAX_NODES,
            .node_active = [_]bool{false} ** MAX_NODES,
            .node_count = 0,
            .payload_arena = [_]u8{0} ** MAX_PAYLOAD_BYTES,
            .payload_used = 0,
            .focused_node_id = null,
        };
    }

    pub fn insertNode(self: *HyperTree, node: HyperNode, payload: []const u8) !u32 {
        if (self.node_count >= MAX_NODES) return error.TreeFull;
        if (self.payload_used + payload.len > MAX_PAYLOAD_BYTES) return error.PayloadOutOfMemory;

        var slot: ?usize = null;
        for (0..MAX_NODES) |i| {
            if (!self.node_active[i]) {
                slot = i;
                break;
            }
        }
        const idx = slot orelse return error.TreeFull;

        const p_offset: u16 = @intCast(self.payload_used);
        @memcpy(self.payload_arena[self.payload_used .. self.payload_used + payload.len], payload);
        self.payload_used += payload.len;

        var new_node = node;
        new_node.id = @intCast(idx + 1);
        new_node.payload_offset = p_offset;
        new_node.payload_len = @intCast(payload.len);
        new_node.flags |= NodeFlags.DIRTY | NodeFlags.VISIBLE;

        self.nodes[idx] = new_node;
        self.node_active[idx] = true;
        self.node_count += 1;
        return new_node.id;
    }

    pub fn getNode(self: *const HyperTree, id: u32) ?*const HyperNode {
        if (id == 0 or id > MAX_NODES) return null;
        const idx = id - 1;
        if (!self.node_active[idx]) return null;
        return &self.nodes[idx];
    }

    pub fn getNodeMut(self: *HyperTree, id: u32) ?*HyperNode {
        if (id == 0 or id > MAX_NODES) return null;
        const idx = id - 1;
        if (!self.node_active[idx]) return null;
        return &self.nodes[idx];
    }

    pub fn updateBounds(self: *HyperTree, id: u32, x: i16, y: i16, w: u16, h: u16) !void {
        const node = self.getNodeMut(id) orelse return error.NodeNotFound;
        node.x = x;
        node.y = y;
        node.width = w;
        node.height = h;
        node.flags |= NodeFlags.DIRTY;
    }

    pub fn removeNode(self: *HyperTree, id: u32) !void {
        if (id == 0 or id > MAX_NODES) return error.NodeNotFound;
        const idx = id - 1;
        if (!self.node_active[idx]) return error.NodeNotFound;

        self.node_active[idx] = false;
        self.node_count -= 1;
        if (self.focused_node_id == id) self.focused_node_id = null;

        // Recursively remove children
        for (0..MAX_NODES) |i| {
            if (self.node_active[i] and self.nodes[i].parent_id == id) {
                try self.removeNode(@intCast(i + 1));
            }
        }
    }

    pub fn hitTest(self: *const HyperTree, px: i16, py: i16) ?u32 {
        var deepest: ?u32 = null;
        for (0..MAX_NODES) |i| {
            if (!self.node_active[i]) continue;
            const node = &self.nodes[i];
            if (node.contains(px, py) and node.isClickable()) {
                deepest = node.id;
            }
        }
        return deepest;
    }

    pub fn computeDamage(self: *const HyperTree) DamageRect {
        var damage = DamageRect{};
        for (0..MAX_NODES) |i| {
            if (!self.node_active[i]) continue;
            const node = &self.nodes[i];
            if (node.isDirty()) {
                damage.include(node.x, node.y, node.width, node.height);
            }
        }
        return damage;
    }

    pub fn clearDirty(self: *HyperTree) void {
        for (0..MAX_NODES) |i| {
            if (self.node_active[i]) {
                self.nodes[i].flags &= ~NodeFlags.DIRTY;
            }
        }
    }

    pub fn getNodePayload(self: *const HyperTree, id: u32) ?[]const u8 {
        const node = self.getNode(id) orelse return null;
        if (node.payload_len == 0) return "";
        const start = node.payload_offset;
        const end = start + node.payload_len;
        return self.payload_arena[start..end];
    }
};

test "HyperNode and UiEvent binary sizes and alignment" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(HyperNode));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(UiEvent));
}

test "HyperTree insertion, mutation, hit-testing, and dirty damage computation" {
    const allocator = std.testing.allocator;
    var tree = HyperTree.init(allocator);

    const root_id = try tree.insertNode(HyperNode{
        .id = 0,
        .parent_id = 0,
        .node_type = .container,
        .flags = NodeFlags.VISIBLE,
        .layout_dir = 1,
        .reserved = 0,
        .x = 0,
        .y = 0,
        .width = 1280,
        .height = 800,
        .color_fg = 0xFFFFFF,
        .color_bg = 0x1E1E2E,
        .payload_len = 0,
        .payload_offset = 0,
    }, "root_container");

    try std.testing.expectEqual(@as(u32, 1), root_id);
    try std.testing.expectEqualStrings("root_container", tree.getNodePayload(root_id).?);

    const btn_id = try tree.insertNode(HyperNode{
        .id = 0,
        .parent_id = root_id,
        .node_type = .button,
        .flags = NodeFlags.VISIBLE | NodeFlags.CLICKABLE,
        .layout_dir = 0,
        .reserved = 0,
        .x = 100,
        .y = 100,
        .width = 120,
        .height = 40,
        .color_fg = 0xFFFFFF,
        .color_bg = 0x89B4FA,
        .payload_len = 0,
        .payload_offset = 0,
    }, "Launch Studio");

    try std.testing.expectEqual(@as(u32, 2), btn_id);
    try std.testing.expectEqualStrings("Launch Studio", tree.getNodePayload(btn_id).?);

    // Hit-testing
    try std.testing.expectEqual(btn_id, tree.hitTest(150, 120));
    try std.testing.expect(tree.hitTest(50, 50) == null);

    // Initial damage rect encompasses both dirty nodes
    const damage1 = tree.computeDamage();
    try std.testing.expect(!damage1.isEmpty());
    try std.testing.expectEqual(@as(i16, 0), damage1.min_x);
    try std.testing.expectEqual(@as(i16, 0), damage1.min_y);
    try std.testing.expectEqual(@as(i16, 1280), damage1.max_x);
    try std.testing.expectEqual(@as(i16, 800), damage1.max_y);

    // Clear dirty flags
    tree.clearDirty();
    const damage2 = tree.computeDamage();
    try std.testing.expect(damage2.isEmpty());

    // Update button position
    try tree.updateBounds(btn_id, 200, 200, 150, 50);
    const damage3 = tree.computeDamage();
    try std.testing.expect(!damage3.isEmpty());
    try std.testing.expectEqual(@as(i16, 200), damage3.min_x);
    try std.testing.expectEqual(@as(i16, 200), damage3.min_y);
    try std.testing.expectEqual(@as(i16, 350), damage3.max_x);
    try std.testing.expectEqual(@as(i16, 250), damage3.max_y);

    // Remove button and verify tree count
    try tree.removeNode(btn_id);
    try std.testing.expectEqual(@as(usize, 1), tree.node_count);
    try std.testing.expect(tree.getNode(btn_id) == null);
}
