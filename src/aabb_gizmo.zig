const std = @import("std");
const graph = @import("graph");
const BtnState = graph.SDL.ButtonState;
const Vec3 = graph.za.Vec3;
const util3d = @import("util_3d.zig");

start_point: Vec3 = Vec3.zero(),
start_norm: Vec3 = Vec3.zero(),
active: bool = false,

pub fn aabbGizmo(self: *@This(), min_: *Vec3, max_: *Vec3, rc: [2]Vec3, btn: BtnState, snap: f32, draw: *graph.ImmediateDrawingContext) [2]Vec3 {
    const cube1 = util3d.cubeFromBounds(min_.*, max_.*);
    const min = cube1[0];
    const max = cube1[0].add(cube1[1]);
    var ret = [2]Vec3{ min, max };
    switch (btn) {
        .low => {
            self.active = false;
        },
        .rising => {
            if (util3d.doesRayIntersectBBZ(rc[0], rc[1], min, max)) |inter| {
                self.start_point = inter;
                if (util3d.pointBBIntersectionNormal(min, max, inter)) |norm| {
                    self.start_norm = norm;
                    self.active = true;
                }
            }
        },
        .high, .falling => {
            if (self.active) {
                if (util3d.planeNormalGizmo(self.start_point, self.start_norm, rc)) |inter| {
                    const sign = self.start_norm.dot(Vec3.set(1));
                    _, const p_unsnapped = inter;
                    const p = util3d.snapV3(p_unsnapped, snap);
                    ret[0] = if (sign > 0) min else min.add(p);
                    ret[1] = if (sign < 0) max else max.add(p);

                    draw.line3D(self.start_point, self.start_point.add(p), 0x00ffffff);
                }
                if (btn == .falling) {
                    min_.* = ret[0];
                    max_.* = ret[1];
                }
            }
            if (btn == .falling)
                self.active = false;
        },
    }
    const cc = util3d.cubeFromBounds(ret[0], ret[1]);
    draw.cubeFrame(cc[0], cc[1], 0xff0000ff);
    return ret;
}
