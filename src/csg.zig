const std = @import("std");
const graph = @import("graph");
const meshutil = graph.meshutil;
const Mesh = meshutil.Mesh;
const Vec3 = graph.za.Vec3_f64;
const Vec2 = graph.Vec2f;
const vmf = @import("vmf.zig");
const Side = vmf.Side;
const editor = @import("editor.zig");
const StringStorage = @import("string.zig").StringStorage;
// This is a direct implementation of the quake method outlined in:
// https://github.com/jakgor471/vmf-files_webgl
//
// A fantastic pdf

pub var gen_time: u64 = 0;

/// This context exists as the csg generation requires lots of shortlived allocations.
/// Most of the functions will clobber whatever is in their corresponding array list and return the slice.
pub const Context = struct {
    const Self = @This();
    const INIT_CAPACITY = 20;
    const EPSILON: f64 = 2E-14;
    const SideClass = enum {
        back,
        front,
        on,
    };
    alloc: std.mem.Allocator,
    base_winding: [4]Vec3,
    winding_a: std.ArrayList(Vec3),
    winding_b: std.ArrayList(Vec3),

    triangulate_index: std.ArrayList(u32),
    uvs: std.ArrayList(Vec2),

    clip_winding_sides: std.ArrayList(SideClass),
    clip_winding_dists: std.ArrayList(f64),

    pub fn init(alloc: std.mem.Allocator) !@This() {
        return .{
            .alloc = alloc,
            .base_winding = undefined,
            .winding_a = try std.ArrayList(Vec3).initCapacity(alloc, INIT_CAPACITY),
            .winding_b = try std.ArrayList(Vec3).initCapacity(alloc, INIT_CAPACITY),

            .triangulate_index = try std.ArrayList(u32).initCapacity(alloc, INIT_CAPACITY),
            .uvs = try std.ArrayList(Vec2).initCapacity(alloc, INIT_CAPACITY),
            .clip_winding_sides = try std.ArrayList(SideClass).initCapacity(alloc, INIT_CAPACITY),
            .clip_winding_dists = try std.ArrayList(f64).initCapacity(alloc, INIT_CAPACITY),
        };
    }

    pub fn deinit(self: *Self) void {
        self.winding_a.deinit();
        self.winding_b.deinit();
        self.triangulate_index.deinit();
        self.uvs.deinit();
        self.clip_winding_sides.deinit();
        self.clip_winding_dists.deinit();
    }

    pub fn genMesh(self: *Self, sides: []const Side, alloc: std.mem.Allocator, strstore: *StringStorage) !editor.Solid {
        const MAPSIZE = std.math.maxInt(i32);
        var timer = try std.time.Timer.start();
        var ret = editor.Solid.init(alloc);
        try ret.sides.resize(sides.len);
        for (sides, 0..) |side, si| {
            const plane = Plane.fromTri(side.plane.tri);

            self.winding_a.clearRetainingCapacity();
            var wind_a = &self.winding_a;
            try wind_a.appendSlice(try self.baseWinding(plane, @floatFromInt(MAPSIZE / 2)));

            var wind_b = &self.winding_b;

            for (sides) |subside| {
                const pl2 = Plane.fromTri(subside.plane.tri);
                if (plane.norm.dot(pl2.norm) > 1 - EPSILON)
                    continue;

                try self.clipWinding(wind_a.*, wind_b, pl2);
                const temp = wind_a;
                wind_a = wind_b;
                wind_b = temp;
            }

            if (wind_a.items.len < 3)
                continue;

            for (wind_a.items) |*item| {
                item.* = roundVec(item.*);
            }
            //const ret = map.getPtr(side.material) orelse continue;

            ret.sides.items[si] = .{
                .verts = std.ArrayList(graph.za.Vec3).init(alloc),
                .index = std.ArrayList(u32).init(alloc),
                .material = try strstore.store(side.material),
                .u = .{
                    .axis = side.uaxis.axis,
                    .trans = @floatCast(side.uaxis.translation),
                    .scale = @floatCast(side.uaxis.scale),
                },
                .v = .{
                    .axis = side.vaxis.axis,
                    .trans = @floatCast(side.vaxis.translation),
                    .scale = @floatCast(side.vaxis.scale),
                },
            };
            const indexs = try self.triangulate(wind_a.items, 0);
            //const uvs = try self.calcUVCoords(wind_a.items, side, @intCast(ret.tex.w), @intCast(ret.tex.h));
            _ = timer.reset();
            try ret.sides.items[si].index.appendSlice(indexs);
            try ret.sides.items[si].verts.ensureUnusedCapacity(wind_a.items.len);
            for (wind_a.items) |vert| {
                try ret.sides.items[si].verts.append(
                    vert.cast(f32),
                    //.{
                    //.x = @floatCast(vert.x() * scale),
                    //.y = @floatCast(vert.y() * scale),
                    //.z = @floatCast(vert.z() * scale), }
                );
            }
            gen_time += timer.read();
        }
        return ret;
    }
    //Generate indicies into trianglnes that can be drawin with the uknow, opengl draw indexed
    pub fn triangulate(self: *Self, winding: []const Vec3, offset: u32) ![]const u32 {
        self.triangulate_index.clearRetainingCapacity();
        const ret = &self.triangulate_index;
        if (winding.len < 3) return ret.items;

        for (1..winding.len - 1) |i| {
            const ii: u32 = @intCast(i);
            try ret.append(0 + offset);
            try ret.append(ii + 1 + offset);
            try ret.append(ii + offset);
        }

        return ret.items;
    }
    pub fn clipWinding(self: *Self, winding_in: std.ArrayList(Vec3), winding_out: *std.ArrayList(Vec3), plane: Plane) !void {
        self.clip_winding_sides.clearRetainingCapacity();
        self.clip_winding_dists.clearRetainingCapacity();
        var sides = &self.clip_winding_sides;
        var dists = &self.clip_winding_dists;
        for (winding_in.items) |wind| {
            const dist = plane.norm.dot(wind) - plane.dist;
            try dists.append(dist);
            if (dist > EPSILON) {
                try sides.append(.front);
            } else if (dist < -EPSILON) {
                try sides.append(.back);
            } else {
                try sides.append(.on);
            }
        }
        const front = winding_out;
        front.clearRetainingCapacity();
        if (winding_in.items.len == 0) return;
        try sides.append(sides.items[0]);
        try dists.append(dists.items[0]);

        for (winding_in.items, 0..) |p_cur, i| {
            if (sides.items[i] == .on) {
                try front.append(p_cur);
                continue;
            }
            if (sides.items[i] == .front)
                try front.append(p_cur);

            if (sides.items[i + 1] == .on or sides.items[i] == sides.items[i + 1])
                continue;

            const p_next = winding_in.items[(i + 1) % winding_in.items.len];
            const t = dists.items[i] / (dists.items[i] - dists.items[i + 1]);

            const v = p_next.sub(p_cur).scale(t);
            try front.append(p_cur.add(v));
        }
    }

    pub fn calcUVCoords(self: *Self, winding: []const graph.za.Vec3, side: editor.Side, tex_w: u32, tex_h: u32) ![]const Vec2 {
        self.uvs.clearRetainingCapacity();
        const uvs = &self.uvs;
        var umin: f32 = std.math.floatMax(f32);
        var vmin: f32 = std.math.floatMax(f32);
        const tw: f64 = @floatFromInt(tex_w);
        const th: f64 = @floatFromInt(tex_h);
        for (winding) |item| {
            const uv = .{
                .x = @as(f32, @floatCast(item.dot(side.u.axis) / (tw * side.u.scale) + side.u.trans / tw)),
                .y = @as(f32, @floatCast(item.dot(side.v.axis) / (th * side.v.scale) + side.v.trans / th)),
            };
            try uvs.append(uv);
            umin = @min(umin, uv.x);
            vmin = @min(vmin, uv.y);
        }
        const uoff = @floor(umin);
        const voff = @floor(vmin);
        for (uvs.items) |*uv| {
            uv.x -= uoff;
            uv.y -= voff;
        }

        return uvs.items;
    }

    pub fn baseWinding(self: *Self, plane: Plane, size: f64) ![]const Vec3 {
        const global_up = try getGlobalUp(plane.norm);
        const right = plane.norm.cross(global_up).norm().scale(size / 2);

        const up = plane.norm.cross(right);
        const offset = plane.norm.scale(plane.dist);
        self.base_winding[0] = offset.add(right.scale(-1)).add(up);
        self.base_winding[1] = offset.add(right.scale(-1)).add(up.scale(-1));
        self.base_winding[2] = offset.add(right).add(up.scale(-1));
        self.base_winding[3] = offset.add(right).add(up);
        return &self.base_winding;
    }
};

pub fn getGlobalUp(norm: Vec3) !Vec3 {
    var axis: ?usize = null;
    var max = -std.math.floatMax(f64);
    const dat: [3]f64 = norm.data;
    for (dat, 0..) |comp, i| {
        const abs = @abs(comp);
        if (abs > max) {
            max = abs;
            axis = i;
        }
    }
    if (axis == null)
        return error.invalidVector;
    if (axis == 1)
        return Vec3.new(1, 0, 0);
    return Vec3.new(0, 1, 0);
}

pub fn roundVec(v: Vec3) Vec3 {
    var a = v;
    const R: f64 = 128;
    const rr = @Vector(3, f64){ R, R, R };
    a.data = @round(v.data * rr) / rr;
    return a;
}

const Plane = struct {
    norm: Vec3,
    dist: f64,
    pub fn fromTri(tri: [3]Vec3) @This() {
        const v1 = tri[1].sub(tri[0]);
        const v2 = tri[2].sub(tri[0]);
        const norm = v1.cross(v2).norm();
        return .{
            .norm = norm,
            .dist = norm.dot(tri[0]),
        };
    }
};
