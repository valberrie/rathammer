const std = @import("std");
const vmf = @import("vmf.zig");
const graph = @import("graph");

const Self = @This();

pub const VisGroupId = u8;
pub const MAX_VIS_GROUP = 128;
pub const BitSetT = std.bit_set.StaticBitSet(MAX_VIS_GROUP);

pub const Group = struct {
    name: []const u8,
    color: u32,
    id: VisGroupId,

    children: std.ArrayList(VisGroupId),
};

vmf_id_mapping: std.AutoHashMap(i32, VisGroupId),
// VisGroupId indexes into this
groups: std.ArrayList(Group),
alloc: std.mem.Allocator,

disabled: BitSetT,

pub fn init(alloc: std.mem.Allocator) Self {
    return .{
        .vmf_id_mapping = std.AutoHashMap(i32, VisGroupId).init(alloc),
        .groups = std.ArrayList(Group).init(alloc),
        .alloc = alloc,
        .disabled = BitSetT.initEmpty(),
    };
}

pub fn getRoot(self: *Self) ?*Group {
    if (self.groups.items.len > 0)
        return &self.groups.items[0];
    return null;
}

pub fn getMaskFromEditorInfo(self: *Self, info: *const vmf.EditorInfo) !BitSetT {
    var ret = BitSetT.initEmpty();
    for (info.visgroupid) |id| {
        if (self.vmf_id_mapping.get(id)) |g_id| {
            ret.set(g_id);
        } else {
            return error.invalidVisGroup;
        }
    }
    return ret;
}

pub fn setValueCascade(self: *Self, group_id: VisGroupId, shown: bool) void {
    self.recurSetValue(group_id, shown);
}

fn recurSetValue(self: *Self, id: VisGroupId, shown: bool) void {
    self.setValue(id, shown);
    if (id >= self.groups.items.len) return;
    for (self.groups.items[id].children.items) |group| {
        self.recurSetValue(group, shown);
    }
}

pub fn setValue(self: *Self, group_id: VisGroupId, shown: bool) void {
    if (group_id >= self.groups.items.len) return;
    self.disabled.setValue(group_id, !shown);
}

pub fn buildMappingFromVmf(self: *Self, vmf_visgroups: []const vmf.VisGroup, parent_i: ?u8) !void {
    for (vmf_visgroups) |gr| {
        if (!self.vmf_id_mapping.contains(gr.visgroupid)) {
            const index_o = self.groups.items.len;
            if (index_o > MAX_VIS_GROUP)
                return error.tooManyVisgroups;
            const index: VisGroupId = @intCast(index_o);
            try self.vmf_id_mapping.put(gr.visgroupid, index);
            try self.groups.append(.{
                .name = try self.alloc.dupe(u8, gr.name),
                .color = graph.ptypes.intColorFromVec3(gr.color.v, 1),
                .id = @intCast(index),
                .children = std.ArrayList(VisGroupId).init(self.alloc),
            });
            std.debug.print("PUtting visgroup {s}\n", .{gr.name});
            if (parent_i) |p| {
                try self.groups.items[p].children.append(index);
            }
            try self.buildMappingFromVmf(gr.visgroup, index);
        } else {
            std.debug.print("Duplicate vis group {s} with id {d}, omitting\n", .{ gr.name, gr.visgroupid });
        }
    }
}

pub fn deinit(self: *Self) void {
    self.vmf_id_mapping.deinit();
    for (self.groups.items) |*group| {
        self.alloc.free(group.name);
        group.children.deinit();
    }
    self.groups.deinit();
}
