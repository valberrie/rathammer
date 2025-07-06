const std = @import("std");
const graph = @import("graph");
const _Vec = struct { x: f32, y: f32, z: f32 };
const Vec3 = graph.za.Vec3;
const util3d = @import("util_3d.zig");

pub fn snap1(comp: f32, snap: f32) f32 {
    return @round(comp / snap) * snap;
}
//Ideally we use the same functions to generate the solids and immediate draw.
//somekind of callback
//we have a draw.convexPolygonIndexed function
//just use an arena!

pub const Primitive = struct {
    verts: std.ArrayList(Vec3),
    solids: std.ArrayList(std.ArrayList(std.ArrayList(u32))),

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{
            .verts = std.ArrayList(Vec3).init(alloc),
            .solids = std.ArrayList(std.ArrayList(std.ArrayList(u32))).init(alloc),
        };
    }

    pub fn norm(self: *const @This(), ind: []const u32) Vec3 {
        if (ind.len < 3) return Vec3.zero();

        return util3d.trianglePlane(.{
            self.verts.items[ind[0]],
            self.verts.items[ind[1]],
            self.verts.items[ind[2]],
        });
    }

    //Ptr is invalid after calling again
    pub fn newSolid(self: *@This()) !*std.ArrayList(std.ArrayList(u32)) {
        const new = std.ArrayList(std.ArrayList(u32)).init(self.verts.allocator);
        try self.solids.append(new);
        return &self.solids.items[self.solids.items.len - 1];
    }

    pub fn newFace(self: *@This()) std.ArrayList(u32) {
        return std.ArrayList(u32).init(self.verts.allocator);
    }
};

pub fn cylinder(alloc: std.mem.Allocator, param: struct { r: f32, z: f32, num_segment: u32 = 16, snap: f32 = 1 }) !Primitive {
    const snap = 1;
    var prim = Primitive.init(alloc);
    const r = param.r;
    const num_segment = param.num_segment;
    const dtheta: f32 = std.math.tau / @as(f32, @floatFromInt(num_segment));
    const z = param.z;
    try prim.verts.resize(num_segment * 2);
    for (0..num_segment) |ni| {
        const fi: f32 = @floatFromInt(ni);

        const thet = fi * dtheta;
        const x_f = @cos(thet) * r;
        const y_f = @sin(thet) * r;
        const x = @round(x_f / snap) * snap;
        const y = @round(y_f / snap) * snap;

        prim.verts.items[ni] = Vec3.new(x, y, -z / 2);
        prim.verts.items[ni + num_segment] = Vec3.new(x, y, z / 2);
    }

    var faces = try prim.newSolid();
    {
        var face = prim.newFace();
        var opp_face = prim.newFace();
        for (0..num_segment) |nni| {
            const ni: u32 = @intCast(nni);
            try face.append(ni);
            try opp_face.append(num_segment - 1 - ni + num_segment);
        }
        try faces.append(face);
        try faces.append(opp_face);
    }

    for (0..num_segment) |nni| {
        var face = prim.newFace();
        const ni: u32 = @intCast(nni);
        const v0 = ni;
        const v1 = (ni + 1) % num_segment;
        try face.appendSlice(&.{
            v0, v1, v1 + num_segment, v0 + num_segment,
        });
        try faces.append(face);
    }

    return prim;
}

pub fn arch(alloc: std.mem.Allocator, wr: anytype) !void {
    const snap = 1;
    var verts = std.ArrayList(struct { x: f32, y: f32, z: f32 }).init(alloc);
    var faces = std.ArrayList(std.ArrayList(usize)).init(alloc);
    const r = 64;
    const r2 = r + 16;
    const num_segment = 10;
    const z = snap1(10, snap);
    try verts.resize(num_segment * 4);
    const dtheta: f32 = std.math.pi / @as(f32, num_segment - 1); //Do half only
    for (0..num_segment) |ni| {
        const fi: f32 = @floatFromInt(ni);

        const thet = fi * dtheta;
        const x1_f = @cos(thet) * r;
        const y1_f = @sin(thet) * r;

        const x2_f = @cos(thet) * r2;
        const y2_f = @sin(thet) * r2;

        const x1 = snap1(x1_f, snap);
        const y1 = snap1(y1_f, snap);
        const x2 = snap1(x2_f, snap);
        const y2 = snap1(y2_f, snap);

        verts.items[ni + num_segment * 0] = .{ .x = x1, .y = y1, .z = 0 }; //lower
        verts.items[ni + num_segment * 1] = .{ .x = x1, .y = y1, .z = z }; //lower far
        verts.items[ni + num_segment * 2] = .{ .x = x2, .y = y2, .z = 0 }; //upper
        verts.items[ni + num_segment * 3] = .{ .x = x2, .y = y2, .z = z }; //upper far
    }

    for (verts.items) |v|
        try wr.print("v {d} {d} {d}\n", .{ v.x, v.y, v.z });
    for (0..num_segment - 1) |ni| {
        faces.clearRetainingCapacity();
        const v0 = ni; //lower
        const v0z = ni + num_segment * 1; //lower far
        const v1z = (ni + 1) + num_segment * 1; //next far
        const v1 = (ni + 1); //next

        const fv0 = ni + num_segment * 2; //upper
        const fv0z = ni + num_segment * 3; //upper far

        const fv1 = (ni + 1) + num_segment * 2; //next upper
        const fv1z = (ni + 1) + num_segment * 3; //next upper far
        {
            var face = std.ArrayList(usize).init(alloc);
            try face.appendSlice(&.{ v0, v0z, v1z, v1 });
            try faces.append(face);
        }
        {
            var face = std.ArrayList(usize).init(alloc);
            try face.appendSlice(&.{ fv1, fv1z, fv0z, fv0 });
            try faces.append(face);
        }
        {
            var face = std.ArrayList(usize).init(alloc);
            try face.appendSlice(&.{ fv0, fv0z, v0z, v0 });
            try faces.append(face);
        }
        {
            var face = std.ArrayList(usize).init(alloc);
            try face.appendSlice(&.{ v1, v1z, fv1z, fv1 });
            try faces.append(face);
        }
        {
            var face = std.ArrayList(usize).init(alloc);
            try face.appendSlice(&.{ v0, v1, fv1, fv0 });
            try faces.append(face);
        }
        {
            var face = std.ArrayList(usize).init(alloc);
            try face.appendSlice(&.{ fv0z, fv1z, v1z, v0z });
            try faces.append(face);
        }
        try wr.print("o segment{d}\n", .{ni});
        for (faces.items) |face| {
            try wr.print("f", .{});
            for (face.items) |ind|
                try wr.print(" {d}", .{ind + 1});
            try wr.print("\n", .{});
        }
    }
}

test {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    std.debug.print("\n", .{});
    const outfile = try std.fs.cwd().createFile("/tmp/ass.obj", .{});
    defer outfile.close();
    try arch(alloc, outfile.writer());
}
