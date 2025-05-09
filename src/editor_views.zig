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
const undo = @import("undo.zig");
const tools = @import("tools.zig");

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
            ent.drawEnt(self, view_3d, draw, draw_nd, .{});
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

    if (win.isBindState(self.config.keys.undo.b, .rising)) {
        self.undoctx.undo(self);
    }
    if (win.isBindState(self.config.keys.redo.b, .rising)) {
        self.undoctx.redo(self);
    }

    if (win.isBindState(self.config.keys.select.b, .rising)) {
        self.edit_state.state = .select;
        const pot = self.screenRay(screen_area, view_3d);
        if (pot.len > 0) {
            const ustack = try self.undoctx.pushNew();
            if (self.edit_state.id) |last_id| {
                try ustack.append(try undo.SelectionUndo.create(self.undoctx.alloc, .deselect, last_id));
            }
            self.edit_state.id = pot[0].id;
            try ustack.append(try undo.SelectionUndo.create(self.undoctx.alloc, .select, pot[0].id));
            //try self.undoctx.push(try undo.SelectionUndo.create(self.undoctx.alloc, .select, pot[0].id));
        }
        //var rcast_timer = try std.time.Timer.start();
        //defer std.debug.print("Rcast took {d} us\n", .{rcast_timer.read() / std.time.ns_per_us});
    }

    const td = tools.ToolData{
        .screen_area = screen_area,
        .view_3d = &view_3d,
        .draw = draw,
    };
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
            try tools.cubeDraw(self, td, .{
                .plane_up = win.isBindState(self.config.keys.cube_draw_plane_up.b, .rising),
                .plane_down = win.isBindState(self.config.keys.cube_draw_plane_down.b, .rising),
                .send_raycast = win.isBindState(self.config.keys.cube_draw_plane_raycast.b, .high),
            });
        },
        .model_place => {
            // if self.asset_browser.selected_model_vpk_id exists,
            // do a raycast into the world and draw a model at nearest intersection with solid
            if (self.asset_browser.selected_model_vpk_id) |res_id| {
                try tools.modelPlace(self, res_id, screen_area, view_3d);
            }
        },
    }

    if (self.edit_state.id) |id| {
        switch (self.edit_state.state) {
            else => {},
            .face_manip => {
                try tools.faceTranslate(self, id, screen_area, view_3d, draw, .{
                    .grab_far = win.isBindState(self.config.keys.grab_far.b, .high),
                });
            },
            .select => {
                try tools.translate(self, .{
                    .dupe = win.isBindState(self.config.keys.duplicate.b, .high),
                }, id, td);
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
