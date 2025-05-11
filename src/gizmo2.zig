const std = @import("std");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const util3d = @import("util_3d.zig");

pub fn drawGizmo(orig: Vec3, draw: *graph.ImmediateDrawingContext, camera_pos: Vec3) void {
    const gizmo_size = orig.distance(camera_pos) / 64 * 20;
    const oz = gizmo_size / 20;
    //const tr = oz * 3;
    const pz = gizmo_size / 2;
    const cube_orig = [_]Vec3{
        orig.add(Vec3.new(-pz, -pz, -oz / 2)), //xy plane(rot axis z)
        orig.add(Vec3.new(-pz, -oz / 2, -pz)),
        orig.add(Vec3.new(-oz / 2, -pz, -pz)),
    };
    const cube_ext = [cube_orig.len]Vec3{
        Vec3.new(pz * 2, pz * 2, oz),
        Vec3.new(pz * 2, oz, pz * 2),
        Vec3.new(oz, pz * 2, pz * 2),
    };
    const colors = [cube_orig.len]u32{
        0xff0000ff,
        0xff00ff,
        0xffff,
    };
    for (cube_orig, 0..) |ori, i| {
        draw.cube(ori, cube_ext[i], colors[i]);
    }
}
