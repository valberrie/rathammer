const edit = @import("editor.zig");
const graph = @import("graph");
const Editor = edit.Context;
const Vec3 = graph.za.Vec3;
const ButtonState = graph.SDL.ButtonState;
const snapV3 = edit.snapV3;
const vpk = @import("vpk.zig");
const raycast = @import("raycast_solid.zig");
// Anything with a bounding box can be translated

pub const TranslateInput = struct {
    dupe: bool,
};

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
                    //Dupe the solid
                    const new = try self.ecs.createEntity();
                    const duped = try solid.dupe();
                    try self.ecs.attach(new, .solid, duped);
                    try self.ecs.attach(new, .bounding_box, .{});
                    const solid_ptr = try self.ecs.getPtr(new, .solid);
                    try solid_ptr.translate(new, dist, self);
                } else {
                    try solid.translate(id, dist, self);
                }
                //Commit the changes
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
            var copy_ent = ent.*;
            copy_ent.origin = orr;
            copy_ent.drawEnt(self, view_3d, draw, draw_nd, .{ .frame_color = color, .draw_model_bb = true });

            //draw.cube(orr, Vec3.new(16, 16, 16), 0xff000022);
            if (self.edit_state.rmouse == .rising) {
                if (dupe) {
                    const new = try self.ecs.createEntity();
                    try self.ecs.attach(new, .entity, ent.dupe());
                    try self.ecs.attach(new, .bounding_box, bb.*);
                    const ent_ptr = try self.ecs.getPtr(new, .entity);
                    ent_ptr.origin = orr;
                    const bb_ptr = try self.ecs.getPtr(new, .bounding_box);
                    bb_ptr.setFromOrigin(orr);
                } else {
                    //Commit the changes
                    ent.origin = orr;
                    bb.setFromOrigin(orr);
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
                        try solid.translateSide(id, dist, self, s_i);
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
            }
        }
    }
}
