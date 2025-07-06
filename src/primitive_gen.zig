const std = @import("std");

pub fn snap1(comp: f32, snap: f32) f32 {
    return @round(comp / snap) * snap;
}

pub fn cylinder(alloc: std.mem.Allocator, wr: anytype) !void {
    const snap = 1;
    var verts = std.ArrayList(struct { x: f32, y: f32, z: f32 }).init(alloc);
    var faces = std.ArrayList(std.ArrayList(usize)).init(alloc);
    const r = 10;
    const num_segment = 20;
    const dtheta: f32 = std.math.tau / @as(f32, num_segment);
    const z = 10;
    try verts.resize(num_segment * 2);
    for (0..num_segment) |ni| {
        const fi: f32 = @floatFromInt(ni);

        const thet = fi * dtheta;
        const x_f = @cos(thet) * r;
        const y_f = @sin(thet) * r;
        const x = @round(x_f / snap) * snap;
        const y = @round(y_f / snap) * snap;

        verts.items[ni] = .{ .x = x, .y = y, .z = 0 };
        verts.items[ni + num_segment] = .{ .x = x, .y = y, .z = z };
    }

    {
        var face = std.ArrayList(usize).init(alloc);
        var opp_face = std.ArrayList(usize).init(alloc);
        for (0..num_segment) |ni| {
            try face.append(ni);
            try opp_face.append(num_segment - 1 - ni + num_segment);
        }
        try faces.append(face);
        try faces.append(opp_face);
    }

    for (0..num_segment) |ni| {
        var face = std.ArrayList(usize).init(alloc);
        const v0 = ni;
        const v1 = (ni + 1) % num_segment;
        try face.appendSlice(&.{
            v0, v1, v1 + num_segment, v0 + num_segment,
        });
        try faces.append(face);
    }

    try wr.print("o hello\n", .{});
    for (verts.items) |v|
        try wr.print("v {d} {d} {d}\n", .{ v.x, v.y, v.z });
    for (faces.items) |face| {
        try wr.print("f", .{});
        for (face.items) |ind|
            try wr.print(" {d}", .{ind + 1});
        try wr.print("\n", .{});
    }
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
