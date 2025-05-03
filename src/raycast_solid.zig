const std = @import("std");
const util3d = @import("util_3d.zig");
const graph = @import("graph");
const edit = @import("editor.zig");
const Vec3 = graph.za.Vec3;
const csg = @import("csg.zig");

const RaycastResult = struct {
    point: Vec3,
    side_index: usize,
};
threadlocal var RAYCAST_RESULT_BUFFER: [2]RaycastResult = undefined;
pub fn doesRayIntersectSolid(r_o: Vec3, r_d: Vec3, solid: *const edit.Solid, csgctx: *csg.Context) ![]const RaycastResult {
    var count: usize = 0;
    //TODO check all, this can intersect 0,1,2 times
    for (solid.sides.items, 0..) |side, s_i| {
        if (side.verts.items.len < 3) continue;
        // triangulate using csg
        const ind = try csgctx.triangulateAny(side.verts.items, 0);
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
                count += 1;
                if (count > 2)
                    return error.invalidSolid;
                RAYCAST_RESULT_BUFFER[count - 1] = .{ .point = inter, .side_index = s_i };

                //return .{ .point = inter, .side_index = s_i };
            }
        }
    }
    return RAYCAST_RESULT_BUFFER[0..count];
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
    pot: std.ArrayList(RcastItem),
    pot_fine: std.ArrayList(RcastItem),

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .pot = std.ArrayList(RcastItem).init(alloc),
            .pot_fine = std.ArrayList(RcastItem).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.pot.deinit();
        self.pot_fine.deinit();
    }

    pub fn findNearestSolid(self: *Self, ecs: *edit.EcsT, ray_o: Vec3, ray_d: Vec3, csgctx: *csg.Context, bb_only: bool) ![]const RcastItem {
        //var rcast_timer = try std.time.Timer.start();
        //defer std.debug.print("Rcast took {d} us\n", .{rcast_timer.read() / std.time.ns_per_us});
        self.pot.clearRetainingCapacity();
        var bbit = ecs.iterator(.bounding_box);
        while (bbit.next()) |bb| {
            if (util3d.doesRayIntersectBBZ(ray_o, ray_d, bb.a, bb.b)) |inter| {
                const len = inter.distance(ray_o);
                try self.pot.append(.{ .id = bbit.i, .dist = len });
            }
        }
        if (!bb_only) {
            self.pot_fine.clearRetainingCapacity();
            for (self.pot.items) |bp_rc| {
                if (try ecs.getOptPtr(bp_rc.id, .solid)) |solid| {
                    for (try doesRayIntersectSolid(ray_o, ray_d, solid, csgctx)) |in| {
                        const len = in.point.distance(ray_o);
                        try self.pot_fine.append(.{ .id = bp_rc.id, .dist = len, .point = in.point });
                    }
                } else {
                    try self.pot_fine.append(bp_rc);
                }
            }

            std.sort.insertion(RcastItem, self.pot_fine.items, {}, RcastItem.lessThan);
            return self.pot_fine.items;
        }
        std.sort.insertion(RcastItem, self.pot.items, {}, RcastItem.lessThan);
        return self.pot.items;
    }
};
