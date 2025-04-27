const std = @import("std");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const util3d = @import("util_3d.zig");
const BtnState = graph.SDL.ButtonState;

pub const Gizmo = struct {
    start: Vec3 = Vec3.zero(),
    selected_axis: enum {
        x,
        y,
        z,
        xy,
        xz,
        yz,
        none, //Must be last element

        pub fn index(self: @This()) ?usize {
            if (self == .none)
                return null;
            return @intFromEnum(self);
        }

        pub fn setFromIndex(self: *@This(), index_: usize) void {
            const info = @typeInfo(@This());
            const count = info.Enum.fields.len;
            if (index_ > count - 1)
                return; //Silentily fail
            self.* = @enumFromInt(index_);
        }

        pub fn getPlaneNorm(self: @This(), norm: Vec3) Vec3 {
            var n = norm;
            switch (self) {
                else => {},
                .x => n.data[0] = 0,
                .y => n.data[1] = 0,
                .z => n.data[2] = 0,
                .xy => return Vec3.new(0, 0, 1),
                .xz => return Vec3.new(0, 1, 0),
                .yz => return Vec3.new(1, 0, 0),
            }
            return n.norm();
        }

        pub fn getDistance(self: @This(), dist: Vec3) Vec3 {
            const V = Vec3.new;
            return switch (self) {
                else => dist,
                .x => V(dist.x(), 0, 0),
                .y => V(0, dist.y(), 0),
                .z => V(0, 0, dist.z()),

                .xy => V(dist.x(), dist.y(), 0),
                .xz => V(dist.x(), 0, dist.z()),
                .yz => V(0, dist.y(), dist.z()),
            };
        }
    } = .none,

    /// Returns true if the gizmo is being dragged
    pub fn handle(
        self: *@This(),
        orig: Vec3,
        orig_mut: *Vec3,
        camera_pos: Vec3,
        lmouse: BtnState,
        draw: *graph.ImmediateDrawingContext,
        screen_area: graph.Vec2f,
        view: graph.za.Mat4,
        mouse_pos: graph.Vec2f,
    ) BtnState {
        //const sa = self.edit_state.selected_axis;
        const gizmo_size = orig.distance(camera_pos) / 64 * 20;
        const oz = gizmo_size / 20;
        const tr = oz * 3;
        const pz = gizmo_size / 2;
        const cube_orig = [_]Vec3{
            orig.add(Vec3.new(oz, 0, 0)), //xyz
            orig.add(Vec3.new(0, oz, 0)),
            orig.add(Vec3.new(0, 0, oz)),
            orig.add(Vec3.new(tr, tr, 0)), //xy
            orig.add(Vec3.new(tr, 0, tr)), //xz
            orig.add(Vec3.new(0, tr, tr)), //yz
        };
        const cubes = [cube_orig.len]Vec3{
            Vec3.new(gizmo_size, oz, oz),
            Vec3.new(oz, gizmo_size, oz),
            Vec3.new(oz, oz, gizmo_size),
            Vec3.new(pz, pz, oz / 2), //xy
            Vec3.new(pz, oz / 2, pz), //xz
            Vec3.new(oz / 2, pz, pz), //xz
        };
        const colors = [cube_orig.len]u32{
            0xff0000ff,
            0xff00ff,
            0xffff,
            0xffff00ff,
            0xff00ffff,
            0xffffff,
        };
        for (cube_orig, 0..) |co, i| {
            draw.cube(co, cubes[i], colors[i]);
        }

        switch (lmouse) {
            .rising => {
                const rc = util3d.screenSpaceRay(screen_area, mouse_pos, view);
                //TODO do a depth test
                for (cubes, 0..) |cu, ci| {
                    const co = cube_orig[ci];
                    if (util3d.doesRayIntersectBBZ(rc[0], rc[1], co, co.add(cu))) |inter| {
                        draw.point3D(inter, 0x7f_ff_ff_ff);
                        self.selected_axis.setFromIndex(ci);
                        //Now that we intersect, e
                        self.start = util3d.doesRayIntersectPlane(
                            rc[0],
                            rc[1],
                            orig,
                            self.selected_axis.getPlaneNorm(camera_pos.sub(orig)),
                            //self.edit_state.selected_plane_norm,
                        ) orelse Vec3.zero(); //This should never be null
                        break;
                    }
                }
                return .rising;
            },
            .high => {
                if (self.selected_axis == .none)
                    return .low;
                const rc = util3d.screenSpaceRay(screen_area, mouse_pos, view);
                if (util3d.doesRayIntersectPlane(
                    rc[0],
                    rc[1],
                    orig,
                    self.selected_axis.getPlaneNorm(camera_pos.sub(orig)),
                )) |end| {
                    const diff = end.sub(self.start);
                    orig_mut.* = orig.add(self.selected_axis.getDistance(diff));
                    return .high; //The gizmo is active
                }
            },
            .low => self.selected_axis = .none,
            .falling => return .falling,
        }
        return .low;
    }
};
