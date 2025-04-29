const std = @import("std");
const util3d = @import("util_3d.zig");
const graph = @import("graph");
const edit = @import("editor.zig");
const Vec3 = graph.za.Vec3;

pub fn doesRayIntersectSolid(r_o: Vec3, r_d: Vec3, solid: *const edit.Solid, editor: *edit.Context) !?struct { point: Vec3, side_index: usize } {
    for (solid.sides.items, 0..) |side, s_i| {
        if (side.verts.items.len < 3) continue;
        // triangulate using csg
        const ind = try editor.csgctx.triangulateAny(side.verts.items, 0);
        const ts = side.verts.items;
        for (0..@divExact(ind.len, 3)) |i_i| {
            const i = i_i * 3;

            if (util3d.mollerTrumboreIntersection(
                r_o,
                r_d,
                ts[ind[i]],
                ts[ind[i + 1]],
                ts[ind[i + 2]],
            )) |inter| {
                return .{ .point = inter, .side_index = s_i };
            }
        }
    }
    return null;
}

pub const RcastItem = struct {
    id: edit.EcsT.Id,
    dist: f32,
    point: graph.za.Vec3 = undefined,

    pub fn lessThan(_: void, a: @This(), b: @This()) bool {
        return a.dist < b.dist;
    }
};

pub const Ctx = struct {
    const Self = @This();
    raycast_pot: std.ArrayList(RcastItem),
    raycast_pot_fine: std.ArrayList(RcastItem),

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .raycast_pot = std.ArrayList(RcastItem).init(alloc),
            .raycast_pot_fine = std.ArrayList(RcastItem).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.raycast_pot.deinit();
        self.raycast_pot_fine.deinit();
    }
    pub fn doCast(self: *Self) void {
        //var rcast_timer = try std.time.Timer.start();
        //defer std.debug.print("Rcast took {d} us\n", .{rcast_timer.read() / std.time.ns_per_us});
        self.raycast_pot.clearRetainingCapacity();
        const editor = {};
        var bbit = editor.ecs.iterator(.bounding_box);
        while (bbit.next()) |bb| {
            //for (editor.set.dense.items, 0..) |solid, i| {
            //draw.cube(pos, ext, 0xffffffff);
            if (util3d.doesRayIntersectBBZ(editor.draw_state.cam3d.pos, editor.draw_state.cam3d.front, bb.a, bb.b)) |inter| {
                const len = inter.distance(editor.draw_state.cam3d.pos);
                try self.raycast_pot.append(.{ .id = bbit.i, .dist = len });
            }
        }
        if (true) {
            self.raycast_pot_fine.clearRetainingCapacity();
            for (self.raycast_pot.items) |bp_rc| {
                if (try editor.ecs.getOptPtr(bp_rc.id, .solid)) |solid| {
                    for (solid.sides.items) |side| {
                        if (side.verts.items.len < 3) continue;
                        // triangulate using csg
                        // for each tri call mollertrumbor, breaking if enc
                        const ind = try editor.csgctx.triangulateAny(side.verts.items, 0);
                        const ts = side.verts.items;
                        const ro = editor.draw_state.cam3d.pos;
                        const rd = editor.draw_state.cam3d.front;
                        for (0..@divExact(ind.len, 3)) |i_i| {
                            const i = i_i * 3;

                            if (util3d.mollerTrumboreIntersection(
                                ro,
                                rd,
                                ts[ind[i]],
                                ts[ind[i + 1]],
                                ts[ind[i + 2]],
                            )) |inter| {
                                const len = inter.distance(editor.draw_state.cam3d.pos);
                                try self.raycast_pot_fine.append(.{ .id = bp_rc.id, .dist = len, .point = inter });
                                break;
                            }
                        }
                    }
                } else {
                    try self.raycast_pot_fine.append(bp_rc);
                }
            }

            std.sort.insertion(RcastItem, self.raycast_pot_fine.items, {}, RcastItem.lessThan);
            if (self.raycast_pot_fine.items.len > 0) {
                editor.edit_state.id = self.raycast_pot_fine.items[0].id;
            }
        } else {
            std.sort.insertion(RcastItem, self.raycast_pot.items, {}, RcastItem.lessThan);
            if (self.raycast_pot.items.len > 0) {
                editor.edit_state.id = self.raycast_pot.items[0].id;
            }
        }
    }
};
