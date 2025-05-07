const std = @import("std");
const Editor = @import("editor.zig");
const Context = Editor.Context;
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const DrawCtx = graph.ImmediateDrawingContext;
const snapV3 = Editor.snapV3;
const util3d = @import("util_3d.zig");
const cubeFromBounds = Editor.cubeFromBounds;
const Solid = Editor.Solid;
const AABB = Editor.AABB;
const raycast = @import("raycast_solid.zig");
const Gui = graph.Gui;
const fgd = @import("fgd.zig");

pub fn draw3Dview(self: *Context, screen_area: graph.Rect, draw: *graph.ImmediateDrawingContext, win: *graph.SDL.Window, font: *graph.FontInterface) !void {
    try self.draw_state.ctx.beginNoClear(screen_area.dim());
    // draw_nd "draw no depth" is for any immediate drawing after the depth buffer has been cleared.
    // "draw" still has depth buffer
    const draw_nd = &self.draw_state.ctx;
    const x: i32 = @intFromFloat(screen_area.x);
    const y: i32 = @intFromFloat(screen_area.y);
    const w: i32 = @intFromFloat(screen_area.w);
    const h: i32 = @intFromFloat(screen_area.h);
    graph.c.glViewport(x, y, w, h);
    graph.c.glScissor(x, y, w, h);
    const old_screen_dim = draw.screen_dimensions;
    defer draw.screen_dimensions = old_screen_dim;
    draw.screen_dimensions = .{ .x = screen_area.w, .y = screen_area.h };

    graph.c.glEnable(graph.c.GL_SCISSOR_TEST);
    defer graph.c.glDisable(graph.c.GL_SCISSOR_TEST);
    const mat = graph.za.Mat4.identity();

    const view_3d = self.draw_state.cam3d.getMatrix(screen_area.w / screen_area.h, 1, self.draw_state.cam_far_plane);

    var it = self.meshmap.iterator();
    while (it.next()) |mesh| {
        if (!self.draw_state.draw_tools) {
            if (self.tool_res_map.contains(mesh.key_ptr.*))
                continue;
        }
        mesh.value_ptr.*.mesh.drawSimple(view_3d, mat, self.draw_state.basic_shader);
    }

    if (false) { //draw displacment vert
        var d_it = self.ecs.iterator(.displacement);
        while (d_it.next()) |disp| {
            for (disp.verts.items) |v|
                draw.point3D(v, 0xffffffff);
        }
    }

    {
        var ent_it = self.ecs.iterator(.entity);
        while (ent_it.next()) |ent| {
            ent.drawEnt(self, view_3d, draw, draw_nd);
        }
    }
    { //sky stuff
        const trans = graph.za.Mat4.fromTranslate(self.draw_state.cam3d.pos);
        const c = graph.c;
        c.glDepthMask(c.GL_FALSE);
        c.glDepthFunc(c.GL_LEQUAL);
        defer c.glDepthFunc(c.GL_LESS);
        defer c.glDepthMask(c.GL_TRUE);

        for (self.skybox.meshes.items, 0..) |*sk, i| {
            sk.draw(.{ .texture = self.skybox.textures.items[i].id, .shader = self.skybox.shader }, view_3d, trans);
        }
    }
    try draw.flush(null, self.draw_state.cam3d);

    if (self.edit_state.btn_x_trans == .rising or self.edit_state.btn_y_trans == .rising)
        self.edit_state.state = .face_manip;

    if (win.isBindState(self.config.keys.select.b, .rising)) {
        self.edit_state.state = .select;
        const pot = self.screenRay(screen_area, view_3d);
        if (pot.len > 0) {
            self.edit_state.id = pot[0].id;
        }
        //var rcast_timer = try std.time.Timer.start();
        //defer std.debug.print("Rcast took {d} us\n", .{rcast_timer.read() / std.time.ns_per_us});
    }

    switch (self.edit_state.state) {
        else => {},
        .texture_apply => {
            //BUG: we need to remove the side from its current batch
            blk: {
                const tid = self.asset_browser.selected_mat_vpk_id orelse break :blk;
                //Raycast into world and apply texture to the face we hit
                if (self.edit_state.rmouse == .high) {
                    const pot = self.screenRay(screen_area, view_3d);
                    if (pot.len == 0) break :blk;
                    if (try self.ecs.getOptPtr(pot[0].id, .solid)) |solid| {
                        if (pot[0].side_id == null or pot[0].side_id.? >= solid.sides.items.len) break :blk;
                        const si = pot[0].side_id.?;
                        solid.sides.items[si].tex_id = tid;
                        //TODO this is slow, only rebuild the face
                        try solid.rebuild(pot[0].id, self);
                        try self.rebuildMeshesIfDirty();
                    }
                }
            }
        },
        .cube_draw => {
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
            const ray = self.camRay(screen_area, view_3d);
            switch (st.state) {
                .start => {
                    if (win.isBindState(self.config.keys.cube_draw_plane_up.b, .rising))
                        st.plane_z += snap;
                    if (win.isBindState(self.config.keys.cube_draw_plane_down.b, .rising))
                        st.plane_z -= snap;
                    if (win.isBindState(self.config.keys.cube_draw_plane_raycast.b, .high)) {
                        const pot = self.screenRay(screen_area, view_3d);
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
                        }
                    }
                },
                .cubic => {
                    //const cc = cubeFromBounds(st.start, st.end);
                    //draw.cube(cc[0], cc[1], 0xffffff88);
                    //draw.cube(st.start, st.end.sub(st.start), 0xffffffee);
                },
            }
        },
        .model_place => {
            // if self.asset_browser.selected_model_vpk_id exists,
            // do a raycast into the world and draw a model at nearest intersection with solid
            if (self.asset_browser.selected_model_vpk_id) |res_id| {
                const omod = self.models.get(res_id);
                if (omod != null and omod.? != null) {
                    const mod = omod.?.?;
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
                            var bb = AABB{ .a = Vec3.new(0, 0, 0), .b = Vec3.new(16, 16, 16), .origin_offset = Vec3.new(8, 8, 8) };
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
                                .model_id = res_id,
                                .sprite = null,
                            });
                            try self.ecs.attach(new, .bounding_box, bb);
                        }
                    }
                }
            }
        },
    }

    if (self.edit_state.id) |id| {
        switch (self.edit_state.state) {
            else => {},
            .face_manip => {
                if (try self.ecs.getOptPtr(id, .solid)) |solid| {
                    var gizmo_is_active = false;
                    const v = solid.verts.items;
                    if (solid.verts.items.len > 0) {
                        var last = solid.verts.items[solid.verts.items.len - 1];
                        //const vs = side.verts.items;
                        for (0..solid.verts.items.len) |ti| {
                            draw_nd.line3D(last, v[ti], 0xf7a94a8f);
                            draw_nd.point3D(v[ti], 0xff0000ff);
                            last = v[ti];
                        }
                    }
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
                            const rci = if (win.isBindState(self.config.keys.grab_far.b, .high)) @min(1, rc.len) else 0;
                            self.edit_state.face_id = rc[rci].side_index;
                            self.edit_state.face_origin = rc[rci].point;
                        }
                    }
                }
            },
            .select => {
                const dupe = win.isBindState(self.config.keys.duplicate.b, .high);
                if (try self.ecs.getOptPtr(id, .solid)) |solid| {
                    if (try self.ecs.getOpt(id, .bounding_box)) |bb| {
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
                            const COLOR_MOVE = 0xe8a130_ee;
                            const COLOR_DUPE = 0xfc35ac_ee;
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
                            const color: u32 = if (dupe) COLOR_DUPE else COLOR_MOVE;
                            solid.drawEdgeOutline(draw_nd, color, 0xff0000ff, dist);
                            //const v = solid.verts.items;
                            //var last = v[v.len - 1].add(dist);
                            //for (0..v.len) |ti| {
                            //    draw_nd.line3D(last, v[ti].add(dist), color);
                            //    draw_nd.point3D(v[ti].add(dist), 0xff0000ff);
                            //    last = v[ti].add(dist);
                            //}
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
                        copy_ent.drawEnt(self, view_3d, draw, draw_nd);

                        //draw.cube(orr, Vec3.new(16, 16, 16), 0xff000022);
                        if (self.edit_state.rmouse == .rising) {
                            const bb = try self.ecs.getPtr(id, .bounding_box);
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
            },
        }
    }
    try draw.flush(null, self.draw_state.cam3d);
    graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
    //Crosshair
    const cw = 4;
    const crossp = screen_area.center().sub(.{ .x = cw, .y = cw });
    draw_nd.rect(graph.Rec(
        crossp.x,
        crossp.y,
        cw * 2,
        cw * 2,
    ), 0xffffffff);
    { // text stuff
        const fh = 20;
        const col = 0xff_ff_ffff;
        var tpos = screen_area.pos();
        draw.textFmt(tpos, "grid: {d:.2}", .{self.edit_state.grid_snap}, font, fh, col);
        tpos.y += fh;
        const p = self.draw_state.cam3d.pos;
        draw.textFmt(tpos, "pos: {d:.2} {d:.2} {d:.2}", .{ p.data[0], p.data[1], p.data[2] }, font, fh, col);
        tpos.y += fh;
        draw.textFmt(tpos, "tool: {s}", .{@tagName(self.edit_state.state)}, font, fh, col);
    }
    //var ent_it = self.ecs.iterator(.entity);
    //while (ent_it.next()) |ent| {
    //    const dist = ent.origin.distance(self.draw_state.cam3d.pos);
    //    if (dist > ENT_RENDER_DIST)
    //        continue;
    //    if (self.fgd_ctx.base.get(ent.class)) |base| {
    //        if (self.icon_map.get(base.iconsprite)) |isp| {
    //            draw.cubeFrame(ent.origin.sub(Vec3.new(8, 8, 8)), Vec3.new(16, 16, 16), 0x00ff00ff);
    //            draw.billboard(ent.origin, .{ .x = 16, .y = 16 }, isp.rect(), isp, self.draw_state.cam3d);
    //        }
    //    }
    //}
    //if (self.edit_state.lmouse == .rising) {
    //    const rc = util3d.screenSpaceRay(screen_area.dim(), self.edit_state.trans_begin, view_3d);

    //    //std.debug.print("Putting {} {}\n", .{ ray_world, ray_endw });
    //    try self.temp_line_array.append([2]Vec3{ rc[0], rc[0].add(rc[1].scale(1000)) });
    //}
    //for (self.temp_line_array.items) |tl| {
    //    draw.line3D(tl[0], tl[1], 0xff00ffff);
    //}
    try draw_nd.flush(null, self.draw_state.cam3d);
}

pub fn drawInspector(self: *Context, screen_area: graph.Rect, os9gui: *graph.Os9Gui) !void {
    if (try os9gui.beginTlWindow(screen_area)) {
        defer os9gui.endTlWindow();
        const gui = &os9gui.gui;
        if (gui.getArea()) |win_area| {
            const area = win_area.inset(6 * os9gui.scale);
            _ = try gui.beginLayout(Gui.SubRectLayout, .{ .rect = area }, .{});
            defer gui.endLayout();

            //_ = try os9gui.beginH(2);
            //defer os9gui.endL();
            if (try os9gui.beginVScroll(&self.misc_gui_state.scroll_a, .{ .sw = area.w, .sh = 1000000 })) |scr| {
                defer os9gui.endVScroll(scr);
                os9gui.label("Current Tool: {s}", .{@tagName(self.edit_state.state)});
                if (self.edit_state.id) |id| {
                    if (try self.ecs.getOptPtr(id, .entity)) |ent| {
                        if (self.fgd_ctx.base.get(ent.class)) |base| {
                            os9gui.label("{s}", .{base.name});
                            scr.layout.pushHeight(400);
                            _ = try os9gui.beginL(Gui.TableLayout{ .columns = 2, .item_height = 30 });
                            for (base.fields.items) |f| {
                                os9gui.label("{s}", .{f.name});
                                switch (f.type) {
                                    .choices => |ch| {
                                        if (ch.items.len == 2 and std.mem.eql(u8, ch.items[0][0], "0")) {
                                            var chekd: bool = false;
                                            _ = os9gui.checkbox("", &chekd);

                                            continue;
                                        }
                                        const Ctx = struct {
                                            kvs: []const fgd.EntClass.Field.Type.KV,
                                            index: usize = 0,
                                            pub fn next(ctx: *@This()) ?struct { usize, []const u8 } {
                                                if (ctx.index >= ctx.kvs.len)
                                                    return null;
                                                defer ctx.index += 1;
                                                return .{ ctx.index, ctx.kvs[ctx.index][1] };
                                            }
                                        };
                                        var index: usize = 0;
                                        var ctx = Ctx{
                                            .kvs = ch.items,
                                        };
                                        try os9gui.combo(
                                            "{s}",
                                            .{ch.items[0][1]},
                                            &index,
                                            ch.items.len,
                                            &ctx,
                                            Ctx.next,
                                        );
                                    },
                                    else => os9gui.label("{s}", .{f.default}),
                                }
                            }
                            os9gui.endL();
                        }
                    }
                    if (try self.ecs.getOptPtr(id, .solid)) |solid| {
                        os9gui.label("Solid with {d} sides", .{solid.sides.items.len});
                        for (solid.sides.items) |side| {
                            os9gui.label("Texture: {s}", .{side.material});
                        }
                        blk: {
                            if (self.edit_state.state == .face_manip) {
                                const fid = self.edit_state.face_id orelse break :blk;
                                if (fid >= solid.sides.items.len) break :blk;
                                const side = &solid.sides.items[fid];
                                const old_scale = side.u.scale;
                                const old_scalev = side.v.scale;
                                os9gui.sliderEx(&side.u.scale, 0.1, 10, "Scale u", .{});
                                os9gui.sliderEx(&side.v.scale, 0.1, 10, "Scale v", .{});
                                os9gui.sliderEx(side.v.axis.xMut(), 0, 1, "axis v", .{});
                                os9gui.sliderEx(side.v.axis.yMut(), 0, 1, "axis v", .{});
                                os9gui.sliderEx(side.v.axis.zMut(), 0, 1, "axis v", .{});
                                if (side.u.scale != old_scale or side.v.scale != old_scalev) {
                                    //rebuild
                                    try solid.rebuild(id, self);
                                    try self.rebuildMeshesIfDirty();
                                }
                            }
                        }
                    }
                    //scr.layout.padding.top = 0;
                    //scr.layout.padding.bottom = 0;
                    //{
                    //    var eit = self.vpkctx.extensions.iterator();
                    //    var i: usize = 0;
                    //    while (eit.next()) |item| {
                    //        if (os9gui.button(item.key_ptr.*))
                    //            expanded.items[i] = !expanded.items[i];

                    //        if (expanded.items[i]) {
                    //            var pm = item.value_ptr.iterator();
                    //            while (pm.next()) |p| {
                    //                var cc = p.value_ptr.iterator();
                    //                if (!std.mem.startsWith(u8, p.key_ptr.*, textbox.arraylist.items))
                    //                    continue;
                    //                _ = os9gui.label("{s}", .{p.key_ptr.*});
                    //                while (cc.next()) |c| {
                    //                    if (os9gui.buttonEx("        {s}", .{c.key_ptr.*}, .{})) {
                    //                        const sl = try self.vpkctx.getFileTemp(item.key_ptr.*, p.key_ptr.*, c.key_ptr.*);
                    //                        displayed_slice.clearRetainingCapacity();
                    //                        try displayed_slice.appendSlice(sl.?);
                    //                    }
                    //                }
                    //            }
                    //        }
                    //        i += 1;
                    //    }
                    //}

                    //os9gui.slider(&index, 0, 1000);
                    //scr.layout.pushHeight(area.w);
                    //const ar = gui.getArea() orelse return;
                    //gui.drawRectTextured(ar, 0xffffffff, graph.Rec(0, 0, 1, 1), .{ .id = index, .w = 1, .h = 1 });
                }
            }
            {
                _ = try os9gui.beginV();
                defer os9gui.endL();
                //try os9gui.textbox2(&textbox, .{});

                //os9gui.gui.drawText(displayed_slice.items, ar.pos(), 40, 0xff, os9gui.font);
            }
        }
    }
}
