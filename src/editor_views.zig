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
const ecs = @import("ecs.zig");

pub fn draw3Dview(self: *Context, screen_area: graph.Rect, draw: *graph.ImmediateDrawingContext, win: *graph.SDL.Window, os9gui: *graph.Os9Gui) !void {
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
        if (!self.draw_state.tog.tools) {
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

    try draw.flush(null, self.draw_state.cam3d);
    const vis_mask = Editor.EcsT.getComponentMask(&.{ .invisible, .deleted });
    {
        var ent_it = self.ecs.iterator(.entity);
        while (ent_it.next()) |ent| {
            if (self.ecs.intersects(ent_it.i, vis_mask))
                continue;
            try ent.drawEnt(self, view_3d, draw, draw_nd, .{});
        }
    }

    if (win.isBindState(self.config.keys.undo.b, .rising)) {
        self.undoctx.undo(self);
    }
    if (win.isBindState(self.config.keys.redo.b, .rising)) {
        self.undoctx.redo(self);
    }

    if (win.isBindState(self.config.keys.toggle_select_mode.b, .rising))
        self.selection.toggle();

    if (win.isBindState(self.config.keys.select.b, .rising)) {
        const pot = self.screenRay(screen_area, view_3d);
        if (pot.len > 0) {
            try self.selection.put(pot[0].id);
        }
    }
    if (win.isBindState(self.config.keys.clear_selection.b, .rising))
        self.selection.clear();
    if (win.isBindState(self.config.keys.delete_selected.b, .rising)) {
        const selection = self.selection.getSlice();
        if (selection.len > 0) {
            const ustack = try self.undoctx.pushNew();
            for (selection) |id| {
                try ustack.append(try undo.UndoCreateDestroy.create(self.undoctx.alloc, id, .destroy));
            }
            undo.applyRedo(ustack.items, self);
            self.selection.clear();
        }
    }

    const td = tools.ToolData{
        .screen_area = screen_area,
        .view_3d = &view_3d,
        .draw = draw,
        .win = win,
        .is_first_frame = self.edit_state.last_frame_tool_index != self.edit_state.tool_index,
    };
    if (self.edit_state.tool_index < self.tools.tools.items.len) {
        const vt = self.tools.tools.items[self.edit_state.tool_index];
        try vt.runTool_fn(vt, td, self);
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
        const fh = os9gui.style.config.text_h;
        const col = 0xff_ff_ffff;
        const p = self.draw_state.cam3d.pos;

        const SINGLE_COLOR = 0xfcc858ff;
        const MANY_COLOR = 0xfc58d6ff;

        var mt = graph.MultiLineText.start(draw, screen_area.pos(), os9gui.font);
        mt.textFmt("grid: {d:.2}", .{self.edit_state.grid_snap}, fh, col);
        mt.textFmt("pos: {d:.2} {d:.2} {d:.2}", .{ p.data[0], p.data[1], p.data[2] }, fh, col);
        mt.textFmt("select: {s}", .{@tagName(self.selection.mode)}, fh, switch (self.selection.mode) {
            .one => SINGLE_COLOR,
            .many => MANY_COLOR,
        });
        if (self.selection.mode == .many)
            mt.textFmt("Selected: {d}", .{self.selection.multi.items.len}, fh, col);
        {
            //TODO put an actual dt here
            const notify_slice = try self.notifier.getSlice(16);
            for (notify_slice) |n| {
                mt.text(n.msg, fh, n.color);
            }
        }
        mt.drawBgRect(0x99, fh * 30);
    }
    try draw_nd.flush(null, self.draw_state.cam3d);
    self.drawToolbar(graph.Rec(0, screen_area.h - 100, 1000, 1000), draw);
    try draw.flush(null, null);
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
                if (self.getCurrentTool()) |tool| {
                    if (tool.guiDoc_fn) |gd| gd(tool, os9gui, self, scr.layout);
                    if (tool.gui_fn) |gf| gf(tool, os9gui, self, scr.layout);
                }
                //os9gui.label("Current Tool: {s}", .{@tagName(self.edit_state.state)});
                if (self.selection.single_id) |id| {
                    if (try self.ecs.getOptPtr(id, .entity)) |ent| {
                        if (os9gui.button("force populate kvs")) {
                            if (self.fgd_ctx.base.get(ent.class)) |base| {
                                const kvs = if (try self.ecs.getOptPtr(id, .key_values)) |kv| kv else blk: {
                                    try self.ecs.attach(id, .key_values, ecs.KeyValues.init(self.alloc));
                                    break :blk try self.ecs.getPtr(id, .key_values);
                                };
                                for (base.fields.items) |field| {
                                    try kvs.map.put(field.name, field.default);
                                }
                            }
                        }
                        //if (self.fgd_ctx.base.get(ent.class)) |base| {
                        //    os9gui.label("{s}", .{base.name});
                        //    scr.layout.pushHeight(400);
                        //    _ = try os9gui.beginL(Gui.TableLayout{
                        //        .columns = 2,
                        //        .item_height = os9gui.style.config.default_item_h,
                        //    });
                        //    for (base.fields.items) |f| {
                        //        os9gui.label("{s}", .{f.name});
                        //        switch (f.type) {
                        //            .choices => |ch| {
                        //                if (ch.items.len == 2 and std.mem.eql(u8, ch.items[0][0], "0")) {
                        //                    var chekd: bool = false;
                        //                    _ = os9gui.checkbox("", &chekd);

                        //                    continue;
                        //                }
                        //                const Ctx = struct {
                        //                    kvs: []const fgd.EntClass.Field.Type.KV,
                        //                    index: usize = 0,
                        //                    pub fn next(ctx: *@This()) ?struct { usize, []const u8 } {
                        //                        if (ctx.index >= ctx.kvs.len)
                        //                            return null;
                        //                        defer ctx.index += 1;
                        //                        return .{ ctx.index, ctx.kvs[ctx.index][1] };
                        //                    }
                        //                };
                        //                var index: usize = 0;
                        //                var ctx = Ctx{
                        //                    .kvs = ch.items,
                        //                };
                        //                try os9gui.combo(
                        //                    "{s}",
                        //                    .{ch.items[0][1]},
                        //                    &index,
                        //                    ch.items.len,
                        //                    &ctx,
                        //                    Ctx.next,
                        //                );
                        //            },
                        //            else => os9gui.label("{s}", .{f.default}),
                        //        }
                        //    }
                        //    os9gui.endL();
                        //}
                    }
                    if (try self.ecs.getOptPtr(id, .key_values)) |kvs| {
                        os9gui.hr();
                        var it = kvs.map.iterator();
                        scr.layout.pushHeight(400);
                        _ = try os9gui.beginL(Gui.TableLayout{
                            .columns = 2,

                            .item_height = os9gui.style.config.default_item_h,
                        });
                        while (it.next()) |item| {
                            os9gui.label("{s}", .{item.key_ptr.*});
                            os9gui.label("{s}", .{item.value_ptr.*});
                        }
                        os9gui.endL();
                    }
                    if (try self.ecs.getOptPtr(id, .solid)) |solid| {
                        os9gui.label("Solid with {d} sides", .{solid.sides.items.len});
                        for (solid.sides.items) |side| {
                            os9gui.label("Texture: {s}", .{side.material});
                        }
                        {
                            //if (self.edit_state.state == .face_manip) {
                            //    const fid = self.edit_state.face_id orelse break :blk;
                            //    if (fid >= solid.sides.items.len) break :blk;
                            //    const side = &solid.sides.items[fid];
                            //    const old_scale = side.u.scale;
                            //    const old_scalev = side.v.scale;
                            //    os9gui.sliderEx(&side.u.scale, 0.1, 10, "Scale u", .{});
                            //    os9gui.sliderEx(&side.v.scale, 0.1, 10, "Scale v", .{});
                            //    os9gui.sliderEx(side.v.axis.xMut(), 0, 1, "axis v", .{});
                            //    os9gui.sliderEx(side.v.axis.yMut(), 0, 1, "axis v", .{});
                            //    os9gui.sliderEx(side.v.axis.zMut(), 0, 1, "axis v", .{});
                            //    if (side.u.scale != old_scale or side.v.scale != old_scalev) {
                            //        //rebuild
                            //        try solid.rebuild(id, self);
                            //        try self.rebuildMeshesIfDirty();
                            //    }
                            //}
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
