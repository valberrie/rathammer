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
const inspector = @import("inspector.zig");
const eql = std.mem.eql;
const VisGroup = @import("visgroup.zig");
const Os9Gui = graph.Os9Gui;

pub fn drawPauseMenu(editor: *Context, os9gui: *graph.Os9Gui, draw: *graph.ImmediateDrawingContext, paused: *bool) !enum { quit, nothing } {
    if (try os9gui.beginTlWindow(graph.Rec(0, 0, draw.screen_dimensions.x, draw.screen_dimensions.y))) {
        defer os9gui.endTlWindow();
        const vlayout = try os9gui.beginV();
        defer os9gui.endL();
        os9gui.label("You are paused", .{});
        if (os9gui.button("Unpause"))
            paused.* = false;
        if (os9gui.button("Quit"))
            return .quit;
        if (os9gui.button("Force autosave"))
            editor.autosaver.force = true;
        //try editor.writeToJsonFile(std.fs.cwd(), "serial.json");
        const ds = &editor.draw_state;
        _ = os9gui.checkbox("draw tools", &ds.tog.tools);
        _ = os9gui.checkbox("draw sprite", &ds.tog.sprite);
        _ = os9gui.checkbox("draw model", &ds.tog.models);
        _ = os9gui.sliderEx(&ds.tog.model_render_dist, 64, 1024 * 10, "Model render dist", .{});
        os9gui.label("num model {d}", .{editor.models.count()});
        os9gui.label("num mesh {d}", .{editor.meshmap.count()});

        try os9gui.enumCombo("cam move kind {s}", .{@tagName(editor.draw_state.cam3d.fwd_back_kind)}, &editor.draw_state.cam3d.fwd_back_kind);

        var needs_rebuild = false;
        if (editor.visgroups.getRoot()) |vg_| {
            const Help = struct {
                fn recur(vs: *VisGroup, vg: *VisGroup.Group, depth: usize, os9g: *Os9Gui, vl: *Gui.VerticalLayout, rebuild_: *bool, cascade_down: ?bool) void {
                    vl.padding.left = @floatFromInt(depth * 20);
                    var the_bool = !vs.disabled.isSet(vg.id);
                    const changed = os9g.checkbox(vg.name, &the_bool);
                    rebuild_.* = rebuild_.* or changed;
                    vs.disabled.setValue(vg.id, if (cascade_down) |cd| cd else !the_bool); //We invert the bool so the checkbox looks nice
                    for (vg.children.items) |id| {
                        recur(
                            vs,
                            &vs.groups.items[id],
                            depth + 2,
                            os9g,
                            vl,
                            rebuild_,
                            if (cascade_down) |cd| cd else (if (changed) !the_bool else null),
                        );
                        //_ = os9gui.buttonEx("{s} {d}", .{ group.name, group.id }, .{});
                    }
                }
            };
            Help.recur(&editor.visgroups, vg_, 0, os9gui, vlayout, &needs_rebuild, null);
        }
        if (needs_rebuild) {
            std.debug.print("Rebild\n", .{});
            var it = editor.ecs.iterator(.editor_info);
            while (it.next()) |info| {
                var copy = editor.visgroups.disabled;
                copy.setIntersection(info.vis_mask);
                if (copy.findFirstSet() != null) {
                    editor.ecs.attachComponent(it.i, .invisible, .{}) catch {}; // We discard error incase it is already attached
                    if (try editor.ecs.getOptPtr(it.i, .solid)) |solid|
                        try solid.removeFromMeshMap(it.i, editor);
                } else {
                    _ = try editor.ecs.removeComponentOpt(it.i, .invisible);
                    if (try editor.ecs.getOptPtr(it.i, .solid)) |solid|
                        try solid.rebuild(it.i, editor);
                }
            }
        }
    }
    return .nothing;
}

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

pub const Pane = enum {
    main_3d_view,
    asset_browser,
    inspector,
    model_preview,
    model_browser,
    about,
};
const Split = @import("splitter.zig");
pub const Tab = struct {
    split: []Split.Op,
    panes: []Pane,

    pub fn newSplit(s: []Split.Op, i: *usize, sp: []const Split.Op) []Split.Op {
        @memcpy(s[i.* .. i.* + sp.len], sp);
        defer i.* += sp.len;
        return s[i.* .. i.* + sp.len];
    }

    pub fn newPane(p: []Pane, pi: *usize, ps: []const Pane) []Pane {
        @memcpy(p[pi.* .. pi.* + ps.len], ps);
        defer pi.* += ps.len;
        return p[pi.* .. pi.* + ps.len];
    }
};

const CamState = graph.ptypes.Camera3D.MoveState;
pub fn drawPane(
    editor: *Context,
    pane: Pane,
    has_mouse: bool,
    cam_state: CamState,
    win: *graph.SDL.Window,
    pane_area: graph.Rect,
    draw: *graph.ImmediateDrawingContext,
    os9gui: *graph.Os9Gui,
) !void {
    switch (pane) {
        .main_3d_view => {
            editor.draw_state.cam3d.updateDebugMove(if (editor.draw_state.grab.is or has_mouse) cam_state else .{});
            editor.draw_state.grab.setGrab(has_mouse, win.keyHigh(.LSHIFT), win, pane_area.center());
            try draw3Dview(editor, pane_area, draw, win, os9gui);
        },
        .about => {
            if (try os9gui.beginTlWindow(pane_area)) {
                defer os9gui.endTlWindow();
                _ = try os9gui.beginV();
                defer os9gui.endL();
                os9gui.label("Hello this is the rat hammer", .{});
            }
        },
        .model_browser => try editor.asset_browser.drawEditWindow(pane_area, os9gui, editor, .model),
        .asset_browser => {
            try editor.asset_browser.drawEditWindow(pane_area, os9gui, editor, .texture);
        },
        .inspector => try inspector.drawInspector(editor, pane_area, os9gui),
        .model_preview => {
            try editor.asset_browser.drawModelPreview(
                win,
                pane_area,
                has_mouse,
                cam_state,
                editor,
                draw,
            );
        },
    }
}
