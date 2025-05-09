const std = @import("std");
const edit = @import("editor.zig");
const graph = @import("graph");
const Editor = edit.Context;
const util3d = @import("util_3d.zig");
const Vec3 = graph.za.Vec3;
const cubeFromBounds = edit.cubeFromBounds;
const ButtonState = graph.SDL.ButtonState;
const snapV3 = edit.snapV3;
const Solid = edit.Solid;
const vpk = @import("vpk.zig");
const raycast = @import("raycast_solid.zig");
const undo = @import("undo.zig");
const DrawCtx = graph.ImmediateDrawingContext;
// Anything with a bounding box can be translated

pub const i3DTool = struct {
    deinit_fn: *const fn (*@This(), std.mem.Allocator) void,
};

pub const ToolData = struct {
    view_3d: *const graph.za.Mat4,
    screen_area: graph.Rect,
    draw: *DrawCtx,
};

pub const TranslateInput = struct {
    dupe: bool,
};

//TODO tools should be virtual functions
//Combined with the new ecs it would allow for dynamic linking of new tools and components

pub fn translate(self: *Editor, input: TranslateInput, selected_id: edit.EcsT.Id, screen_area: graph.Rect, view_3d: graph.za.Mat4, draw: *graph.ImmediateDrawingContext) !void {
    const id = selected_id;
    const draw_nd = &self.draw_state.ctx;
    const dupe = input.dupe;
    const bb = try self.ecs.getOptPtr(id, .bounding_box) orelse return;
    const COLOR_MOVE = 0xe8a130_ee;
    const COLOR_DUPE = 0xfc35ac_ee;
    const color: u32 = if (dupe) COLOR_DUPE else COLOR_MOVE;
    if (try self.ecs.getOptPtr(id, .solid)) |solid| {
        const mid_i = bb.a.add(bb.b).scale(0.5);
        var mid = mid_i;
        const giz_active = self.edit_state.gizmo.handle(
            mid,
            &mid,
            self.draw_state.cam3d.pos,
            self.edit_state.lmouse,
            draw_nd,
            screen_area.dim(),
            view_3d,
            self.edit_state.trans_begin,
        );

        solid.drawEdgeOutline(draw_nd, 0xff00ff, 0xff0000ff, Vec3.zero());
        if (giz_active == .rising) {
            try solid.removeFromMeshMap(id, self);
        }
        if (giz_active == .falling) {
            try solid.translate(id, Vec3.zero(), self); //Dummy to put it bake in the mesh batch

        }

        if (giz_active == .high) {
            const dist = snapV3(mid.sub(mid_i), self.edit_state.grid_snap);
            try solid.drawImmediate(
                draw,
                self,
                dist,
                null,
            );
            if (dupe) { //Draw original
                try solid.drawImmediate(
                    draw,
                    self,
                    Vec3.zero(),
                    null,
                );
            }
            solid.drawEdgeOutline(draw_nd, color, 0xff0000ff, dist);
            if (self.edit_state.rmouse == .rising) {
                if (dupe) {
                    const new = try self.ecs.createEntity();
                    try self.ecs.destroyEntity(new);

                    const ustack = try self.undoctx.pushNew();
                    try ustack.append(try undo.UndoDupe.create(self.undoctx.alloc, id, new));
                    try ustack.append(try undo.UndoTranslate.create(
                        self.undoctx.alloc,
                        dist,
                        new,
                    ));
                    undo.applyRedo(ustack.items, self);
                } else {
                    const ustack = try self.undoctx.pushNew();
                    try ustack.append(try undo.UndoTranslate.create(
                        self.undoctx.alloc,
                        dist,
                        id,
                    ));
                    undo.applyRedo(ustack.items, self);
                }
            }
        }
    }
    if (try self.ecs.getOptPtr(id, .entity)) |ent| {
        var orig = ent.origin;
        const giz_active = self.edit_state.gizmo.handle(
            orig,
            &orig,
            self.draw_state.cam3d.pos,
            self.edit_state.lmouse,
            draw_nd,
            screen_area.dim(),
            view_3d,
            self.edit_state.trans_begin,
        );
        if (giz_active == .high) {
            const orr = snapV3(orig, self.edit_state.grid_snap);
            const dist = snapV3(orig.sub(ent.origin), self.edit_state.grid_snap);
            var copy_ent = ent.*;
            copy_ent.origin = orr;
            copy_ent.drawEnt(self, view_3d, draw, draw_nd, .{ .frame_color = color, .draw_model_bb = true });

            //draw.cube(orr, Vec3.new(16, 16, 16), 0xff000022);
            if (self.edit_state.rmouse == .rising) {
                if (dupe) {
                    const new = try self.ecs.createEntity();
                    try self.ecs.destroyEntity(new);

                    const ustack = try self.undoctx.pushNew();
                    try ustack.append(try undo.UndoDupe.create(self.undoctx.alloc, id, new));
                    try ustack.append(try undo.UndoTranslate.create(
                        self.undoctx.alloc,
                        dist,
                        new,
                    ));
                    undo.applyRedo(ustack.items, self);
                } else {
                    const ustack = try self.undoctx.pushNew();
                    try ustack.append(try undo.UndoTranslate.create(
                        self.undoctx.alloc,
                        dist,
                        id,
                    ));
                    undo.applyRedo(ustack.items, self);
                }
            }
        }
    }
}

pub const FaceTranslateInput = struct {
    grab_far: bool,
};

pub fn faceTranslate(self: *Editor, id: edit.EcsT.Id, screen_area: graph.Rect, view_3d: graph.za.Mat4, draw: *graph.ImmediateDrawingContext, input: FaceTranslateInput) !void {
    const draw_nd = &self.draw_state.ctx;
    if (try self.ecs.getOptPtr(id, .solid)) |solid| {
        var gizmo_is_active = false;
        solid.drawEdgeOutline(draw_nd, 0xf7a94a8f, 0xff0000ff, Vec3.zero());
        for (solid.sides.items, 0..) |_, s_i| {
            if (self.edit_state.face_id == s_i) {
                const origin_i = self.edit_state.face_origin;
                var origin = origin_i;
                const giz_active = self.edit_state.gizmo.handle(
                    origin,
                    &origin,
                    self.draw_state.cam3d.pos,
                    self.edit_state.lmouse,
                    draw_nd,
                    screen_area.dim(),
                    view_3d,
                    self.edit_state.trans_begin,
                );
                gizmo_is_active = giz_active != .low;
                if (giz_active == .rising) {
                    try solid.removeFromMeshMap(id, self);
                }
                if (giz_active == .falling) {
                    try solid.translate(id, Vec3.zero(), self); //Dummy to put it bake in the mesh batch
                    self.edit_state.face_origin = origin;
                }

                if (giz_active == .high) {
                    const dist = snapV3(origin.sub(origin_i), self.edit_state.grid_snap);
                    try solid.drawImmediate(
                        draw,
                        self,
                        dist,
                        s_i,
                    );
                    if (self.edit_state.rmouse == .rising) {
                        //try solid.translateSide(id, dist, self, s_i);
                        const ustack = try self.undoctx.pushNew();
                        try ustack.append(try undo.UndoSolidFaceTranslate.create(
                            self.undoctx.alloc,
                            id,
                            s_i,
                            dist,
                        ));
                        undo.applyRedo(ustack.items, self);
                        self.edit_state.face_origin = origin;
                        self.edit_state.gizmo.start = origin;
                        //Commit the changes
                    }
                }
            }
        }
        if (!gizmo_is_active and self.edit_state.lmouse == .rising) {
            const r = self.camRay(screen_area, view_3d);
            //Find the face it intersects with
            const rc = (try raycast.doesRayIntersectSolid(
                r[0],
                r[1],
                solid,
                &self.csgctx,
            ));
            if (rc.len > 0) {
                const rci = if (input.grab_far) @min(1, rc.len) else 0;
                self.edit_state.face_id = rc[rci].side_index;
                self.edit_state.face_origin = rc[rci].point;
            }
        }
    }
}

pub fn modelPlace(self: *Editor, model_id: vpk.VpkResId, screen_area: graph.Rect, view_3d: graph.za.Mat4) !void {
    const omod = self.models.get(model_id);
    if (omod != null and omod.?.mesh != null) {
        const mod = omod.?.mesh.?;
        const pot = self.screenRay(screen_area, view_3d);
        if (pot.len > 0) {
            const p = pot[0];
            const point = snapV3(p.point, self.edit_state.grid_snap);
            const mat1 = graph.za.Mat4.fromTranslate(point);
            //zyx
            //const mat3 = mat1.mul(y1.mul(x1.mul(z)));
            mod.drawSimple(view_3d, mat1, self.draw_state.basic_shader);
            //Draw the model at
            if (self.edit_state.lmouse == .rising) {
                const new = try self.ecs.createEntity();
                var bb = edit.AABB{ .a = Vec3.new(0, 0, 0), .b = Vec3.new(16, 16, 16), .origin_offset = Vec3.new(8, 8, 8) };
                bb.origin_offset = mod.hull_min.scale(-1);
                bb.a = mod.hull_min;
                bb.b = mod.hull_max;
                bb.setFromOrigin(point);
                try self.ecs.attach(new, .entity, .{
                    .origin = point,
                    .angle = Vec3.zero(),
                    .class = try self.storeString("prop_static"),
                    .model = null,
                    //.model = if (ent.model.len > 0) try self.storeString(ent.model) else null,
                    .model_id = model_id,
                    .sprite = null,
                });
                try self.ecs.attach(new, .bounding_box, bb);
                const ustack = try self.undoctx.pushNew();
                try ustack.append(try undo.UndoCreate.create(self.undoctx.alloc, new));
                undo.applyRedo(ustack.items, self);
            }
        }
    }
}

pub const CubeDrawInput = struct {
    plane_up: bool,
    plane_down: bool,
    send_raycast: bool,
};

pub fn cubeDraw(self: *Editor, tool_data: ToolData, input: CubeDrawInput) !void {
    const draw = tool_data.draw;
    const st = &self.edit_state.cube_draw;
    if (self.edit_state.last_frame_state != .cube_draw) { //First frame, reset state
        st.state = .start;
    }
    const helper = struct {
        fn drawGrid(inter: Vec3, plane_z: f32, d: *DrawCtx, snap: f32, count: usize) void {
            //const cpos = inter;
            const cpos = snapV3(inter, snap);
            const nline: f32 = @floatFromInt(count);

            const iline2: f32 = @floatFromInt(count / 2);

            const oth = @trunc(nline * snap / 2);
            for (0..count) |n| {
                const fnn: f32 = @floatFromInt(n);
                {
                    const start = Vec3.new((fnn - iline2) * snap + cpos.x(), cpos.y() - oth, plane_z);
                    const end = start.add(Vec3.new(0, 2 * oth, 0));
                    d.line3D(start, end, 0xffffffff);
                }
                const start = Vec3.new(cpos.x() - oth, (fnn - iline2) * snap + cpos.y(), plane_z);
                const end = start.add(Vec3.new(2 * oth, 0, 0));
                d.line3D(start, end, 0xffffffff);
            }
            //d.point3D(cpos, 0xff0000ee);
        }
    };
    const snap = self.edit_state.grid_snap;
    const ray = self.camRay(tool_data.screen_area, tool_data.view_3d.*);
    switch (st.state) {
        .start => {
            if (input.plane_up)
                st.plane_z += snap;
            if (input.plane_down)
                st.plane_z -= snap;
            if (input.send_raycast) {
                const pot = self.screenRay(tool_data.screen_area, tool_data.view_3d.*);
                if (pot.len > 0) {
                    const inter = pot[0].point;
                    const cc = snapV3(inter, snap);
                    helper.drawGrid(inter, cc.z(), draw, snap, 11);
                    if (self.edit_state.lmouse == .rising) {
                        st.plane_z = cc.z();
                    }
                }
            } else if (util3d.doesRayIntersectPlane(ray[0], ray[1], Vec3.new(0, 0, st.plane_z), Vec3.new(0, 0, 1))) |inter| {
                //user has a xy plane
                //can reposition using keys or doing a raycast into world
                helper.drawGrid(inter, st.plane_z, draw, snap, 11);

                const cc = snapV3(inter, snap);
                draw.point3D(cc, 0xff0000ee);

                if (self.edit_state.lmouse == .rising) {
                    st.start = cc;
                    st.state = .planar;
                }
            }
        },
        .planar => {
            if (util3d.doesRayIntersectPlane(ray[0], ray[1], Vec3.new(0, 0, st.plane_z), Vec3.new(0, 0, 1))) |inter| {
                helper.drawGrid(inter, st.plane_z, draw, snap, 11);
                const in = snapV3(inter, snap);
                const cc = cubeFromBounds(st.start, in.add(Vec3.new(0, 0, snap)));
                draw.cube(cc[0], cc[1], 0xffffff88);

                if (self.edit_state.lmouse == .rising) {
                    st.state = .cubic;
                    st.end = in;
                    st.end.data[2] += snap;

                    //Put it into the
                    const new = try self.ecs.createEntity();
                    const newsolid = try Solid.initFromCube(self.alloc, st.start, st.end, self.asset_browser.selected_mat_vpk_id orelse 0);
                    try self.ecs.attach(new, .solid, newsolid);
                    try self.ecs.attach(new, .bounding_box, .{});
                    const solid_ptr = try self.ecs.getPtr(new, .solid);
                    try solid_ptr.translate(new, Vec3.zero(), self);
                    {
                        const ustack = try self.undoctx.pushNew();
                        try ustack.append(try undo.UndoCreate.create(self.undoctx.alloc, new));
                        undo.applyRedo(ustack.items, self);
                    }
                }
            }
        },
        .cubic => {
            //const cc = cubeFromBounds(st.start, st.end);
            //draw.cube(cc[0], cc[1], 0xffffff88);
            //draw.cube(st.start, st.end.sub(st.start), 0xffffffee);
        },
    }
}
