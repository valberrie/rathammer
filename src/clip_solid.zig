const std = @import("std");
const ecs = @import("ecs.zig");
const Solid = ecs.Solid;
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const Side = ecs.Side;
//
// planes intersect if n1 cross n2 != 0

//For each face of solid
//  does intersect with clip_plane
//  categorize side a or b
//  store
//
//  for a sides

// classify right, left, planar

// for each side
//  for each vert
//      if this_vert_side != last_vert_side

pub const VertKind = enum {
    left,
    right,
    on,

    pub fn getW(plane_p0: Vec3, plane_norm: Vec3) f32 {
        return plane_norm.dot(plane_p0);
    }

    pub fn classify(plane_norm: Vec3, w: f32, v: Vec3) VertKind {
        const EPS = 0.001;
        const p = plane_norm.dot(v) - w;
        if (p > EPS)
            return .right;
        if (p < -EPS)
            return .left;
        return .on;
    }
};

test "classify" {
    const ex = std.testing.expectEqual;
    const p0 = Vec3.zero();
    const n = Vec3.new(1, 0, 0);
    const p = Vec3.new(10, 10, 10);
    const w = VertKind.getW(p0, n);
    try ex(.right, VertKind.classify(n, w, p));
    try ex(.left, VertKind.classify(n, w, Vec3.new(-10, 0, 0)));
    try ex(.on, VertKind.classify(n, w, Vec3.new(0, 0, 0)));

    const p1 = Vec3.new(11, -8, 3);
    const n1 = Vec3.new(1, 1, 1).norm();
    const w1 = VertKind.getW(p1, n1);
    try ex(.right, VertKind.classify(n1, w1, Vec3.new(12, 6, 9)));
    try ex(.left, VertKind.classify(n1, w1, Vec3.new(2, -15, 7)));
    try ex(.left, VertKind.classify(n1, w1, Vec3.new(0, 0, 0)));
}
//Vector3D Plane::lineIntersection(const Vector3D &start, const Vector3D &end) const {
//    Vector3D alongLine = end - start;
//    float t = (w - start.dot(normal)) / alongLine.dot(normal);
//    return start + alongLine * t;
//}
fn doesSegmentIntersectPlane(p0: Vec3, pn: Vec3, start: Vec3, end: Vec3) Vec3 {
    const dir = end.sub(start);
    const w = pn.dot(p0);
    const d = w - start.dot(pn) / dir.dot(pn);
    return start.add(dir.scale(d));
}

fn doesSegmentIntersectPlane2(p0: Vec3, pn: Vec3, start: Vec3, end: Vec3) ?Vec3 {
    const norm = end.sub(start).norm();
    const ln = norm.dot(pn);
    if (@abs(ln) < 0.0001)
        return null;

    const d = (p0.sub(start).dot(pn)) / ln;
    const d2 = end.sub(start).length();
    //0 d d2
    if (d > 0 and d < d2 or d < 0 and d > d2)
        return start.add(norm.scale(d));
    return null;
}

test "line segment plane" {
    const ex = std.testing.expectEqual;
    const thing = doesSegmentIntersectPlane;
    const p0 = Vec3.new(0, 0, 0);
    const pn = Vec3.new(1, 0, 0);
    const st = Vec3.new(-1, 0, 0);
    const end = Vec3.new(1, 0, 0);
    try ex(thing(p0, pn, st, end), Vec3.new(0, 0, 0));
}

pub const ClipCtx = struct {
    const Self = @This();

    verts: std.ArrayList(VertKind),
    alloc: std.mem.Allocator,

    pub fn clipSolid(self: *Self, solid: *const Solid, plane_p0: Vec3, plane_norm: Vec3) ![2]Solid {
        self.verts.clearRetainingCapacity();
        const w = VertKind.getW(plane_p0, plane_norm);
        var ret_verts = std.ArrayList(Vec3).init(self.alloc);
        for (solid.verts.items) |v| {
            try self.verts.append(VertKind.classify(plane_norm, w, v));
            try ret_verts.append(v);
        }

        var ret: [2]Solid = .{ Solid.init(self.alloc), Solid.init(self.alloc) };

        var split_side = Side.init(self.alloc);

        for (solid.sides.items) |side| {
            var left_side: Side = Side.init(self.alloc);
            var right_side: Side = Side.init(self.alloc);
            for (side.index.items, 0..) |vi, ii| {
                const k = self.verts.items[vi];
                switch (k) {
                    .left, .right => {
                        const si = switch (k) {
                            .left => &left_side,
                            .right => &right_side,
                            else => unreachable,
                        };
                        try si.index.append(vi);
                        const n_i = (ii + 1) % side.index.items.len;
                        const next_kind = self.verts.items[side.index.items[n_i]];
                        if (next_kind != .on and next_kind != k) {
                            const start = solid.verts.items[side.index.items[n_i]];
                            const end = solid.verts.items[vi];
                            const int = doesSegmentIntersectPlane(plane_p0, plane_norm, start, end);
                            const index: u32 = @intCast(ret_verts.items.len);
                            try ret_verts.append(int);
                            try left_side.index.append(index);
                            try right_side.index.append(index);
                            try split_side.index.append(index);
                            //Make a new vertex;

                        }
                    },
                    .on => {
                        //Put a new vert
                        try left_side.index.append(vi);
                        try right_side.index.append(vi);
                    },
                }
            }
            if (left_side.index.items.len > 0)
                try ret[0].sides.append(left_side);
            if (right_side.index.items.len > 0)
                try ret[1].sides.append(right_side);
        }
        try ret[0].verts.appendSlice(ret_verts.items);
        try ret[1].verts.appendSlice(ret_verts.items);
        if (split_side.index.items.len > 0) {
            sortPolygonPoints(split_side.index.items, plane_norm, ret_verts.items);
            try ret[0].sides.append(split_side);
            var duped = try split_side.dupe();
            duped.flipNormal();
            try ret[1].sides.append(duped);
        }
        return ret;
    }
};

pub fn sortPolygonPoints(points: []u32, pn: Vec3, verts: []const Vec3) void {
    const Ctx = struct {
        mean: Vec3,
        b0: Vec3,
        b1: Vec3,
        verts: []const Vec3,

        fn lessThan(ctx: @This(), ia: u32, ib: u32) bool {
            const va = ctx.verts[ia];
            const vb = ctx.verts[ib];

            const ar = va.sub(ctx.mean);
            const br = vb.sub(ctx.mean);
            const aa = std.math.atan2(ctx.b1.dot(ar), ctx.b0.dot(ar));
            const ba = std.math.atan2(ctx.b1.dot(br), ctx.b0.dot(br));
            return aa < ba;
        }
    };
    if (points.len == 0) return;
    var mean = Vec3.zero();
    for (points) |v|
        mean = mean.add(verts[v]);
    mean = mean.scale(1 / @as(f32, @floatFromInt(points.len)));

    const b0 = verts[points[0]].sub(mean).norm();
    const ctx: Ctx = .{ .mean = mean, .b0 = b0, .b1 = b0.cross(pn), .verts = verts };
    std.sort.insertion(u32, points, ctx, Ctx.lessThan);
}

test "clip solid" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const sol = try Solid.initFromCube(alloc, Vec3.new(-1, -1, -1), Vec3.new(1, 1, 1), 0);
    var ctx = ClipCtx{
        .verts = std.ArrayList(VertKind).init(alloc),
        .alloc = alloc,
    };
    const p0 = Vec3.new(0, 0, 0);
    const pn = Vec3.new(1, 1, 1).norm();
    const ret = try ctx.clipSolid(&sol, p0, pn);

    std.debug.print("\n", .{});
    const o = std.debug;
    const off = ret[0].printObj(0, "crass", o);
    _ = ret[1].printObj(off, "crass2", o);
}
