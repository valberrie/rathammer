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
const eql = std.mem.eql;

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
