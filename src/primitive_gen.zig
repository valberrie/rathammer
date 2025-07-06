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

    pub fn draw(self: *const @This(), dctx: *graph.ImmediateDrawingContext, center: Vec3) void {
        const min_gray = 0x44;
        const max_gray = 0xdd;
        const v1 = Vec3.new(1, 0, 0);
        for (self.solids.items) |sol| {
            for (sol.items) |face| {
                const n = self.norm(face.items);
                const amt = @abs(v1.dot(n));
                const gray: u32 = @intFromFloat(@min((0xff - min_gray) * amt + min_gray, max_gray));
                const color = gray << 24 | gray << 16 | gray << 8 | 0xff;
                dctx.convexPolyIndexed(face.items, self.verts.items, color, .{
                    .offset = center,
                });
            }
        }
    }
};

pub fn cylinder(alloc: std.mem.Allocator, param: struct {
    r: f32,
    z: f32,
    num_segment: u32 = 16,
    snap: f32 = 1,
    axis: Axis = .z,
}) !Primitive {
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

        prim.verts.items[ni] = param.axis.Vec(x, y, -z / 2);
        prim.verts.items[ni + num_segment] = param.axis.Vec(x, y, z / 2);
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
            v0 + num_segment,
            v1 + num_segment,
            v1,
            v0,
        });
        try faces.append(face);
    }

    return prim;
}
pub const Axis = enum {
    x,
    y,
    z,

    /// Primitives that have an orientation like a cylinder specify
    /// their shape by a 2d coordinates x,y and depth z
    pub fn Vec(self: @This(), x: f32, y: f32, z: f32) Vec3 {
        return switch (self) {
            .x => Vec3.new(z, y, x),
            .y => Vec3.new(x, z, y),
            .z => Vec3.new(x, y, z),
        };
    }
};

pub fn arch(alloc: std.mem.Allocator, param: struct {
    r: f32,
    r2: f32,
    num_segment: u32 = 16,
    snap: f32 = 1,
    z: f32,
    invert: bool,
    axis: Axis = .z,
    theta_deg: f32 = 180,
}) !Primitive {
    var prim = Primitive.init(alloc);
    const snap = param.snap;
    const r = param.r;
    const r2 = param.r2;
    const num_segment = param.num_segment;
    const z = param.z;
    try prim.verts.resize(num_segment * 4);
    const dtheta: f32 = std.math.degreesToRadians(param.theta_deg) / @as(f32, @floatFromInt(num_segment - 1)); //Do half only
    const f: f32 = if (param.invert) -1 else 1;
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

        prim.verts.items[ni + num_segment * 0] = param.axis.Vec(f * x1, f * y1, -z / 2); //lower
        prim.verts.items[ni + num_segment * 1] = param.axis.Vec(f * x1, f * y1, z / 2); //lower far
        prim.verts.items[ni + num_segment * 2] = param.axis.Vec(f * x2, f * y2, -z / 2); //upper
        prim.verts.items[ni + num_segment * 3] = param.axis.Vec(f * x2, f * y2, z / 2); //upper far
    }

    for (0..num_segment - 1) |nni| {
        const ni: u32 = @intCast(nni);
        const v0 = ni; //lower
        const v0z = ni + num_segment * 1; //lower far
        const v1z = (ni + 1) + num_segment * 1; //next far
        const v1 = (ni + 1); //next

        const fv0 = ni + num_segment * 2; //upper
        const fv0z = ni + num_segment * 3; //upper far

        const fv1 = (ni + 1) + num_segment * 2; //next upper
        const fv1z = (ni + 1) + num_segment * 3; //next upper far
        try rectPrism(
            &prim,
            v0,
            v1,
            fv1,
            fv0,
            v0z,
            v1z,
            fv1z,
            fv0z,
        );
    }
    return prim;
}

//Here is a picture
// f is far
// z is behind
//
// fv1 v1
//
// fv0 v0
fn rectPrism(
    prim: *Primitive,
    v0: u32, //winding ccw
    v1: u32,
    fv1: u32,
    fv0: u32,
    v0z: u32,
    v1z: u32,
    fv1z: u32,
    fv0z: u32,
) !void {
    const faces = try prim.newSolid();
    {
        var face = prim.newFace();
        try face.appendSlice(&.{ v0, v0z, v1z, v1 });
        try faces.append(face);
    }
    {
        var face = prim.newFace();
        try face.appendSlice(&.{ fv1, fv1z, fv0z, fv0 });
        try faces.append(face);
    }
    {
        var face = prim.newFace();
        try face.appendSlice(&.{ fv0, fv0z, v0z, v0 });
        try faces.append(face);
    }
    {
        var face = prim.newFace();
        try face.appendSlice(&.{ v1, v1z, fv1z, fv1 });
        try faces.append(face);
    }
    {
        var face = prim.newFace();
        try face.appendSlice(&.{ v0, v1, fv1, fv0 });
        try faces.append(face);
    }
    {
        var face = prim.newFace();
        try face.appendSlice(&.{ fv0z, fv1z, v1z, v0z });
        try faces.append(face);
    }
}

//TODO Finish this and make arch use it too
pub fn cube(alloc: std.mem.Allocator, param: struct { size: Vec3 }) !Primitive {
    var prim = Primitive.init(alloc);

    const s = param.size;
    const x = s.x();
    const y = s.y();
    const z = s.z();

    const verts = [8]Vec3{
        Vec3.new(-x, -y, z),
        Vec3.new(-x, y, z),
        Vec3.new(x, y, z),
        Vec3.new(x, -y, z),

        Vec3.new(-x, -y, -z),
        Vec3.new(-x, y, -z),
        Vec3.new(x, y, -z),
        Vec3.new(x, -y, -z),
    };
    try prim.verts.appendSlice(&verts);
    try rectPrism(&prim, 0, 1, 2, 3, 4, 5, 6, 7);

    return prim;
}

test {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    std.debug.print("\n", .{});
    const outfile = try std.fs.cwd().createFile("/tmp/ass.obj", .{});
    defer outfile.close();
    try arch(alloc, outfile.writer());
}
