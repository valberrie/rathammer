const std = @import("std");
const Editor = @import("editor.zig");
const Context = Editor.Context;
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const views = @import("editor_views.zig");
const PaneReg = views.PaneReg;
const iPane = views.iPane;
const DrawCtx = graph.ImmediateDrawingContext;

pub const Ctx2dView = struct {
    pub threadlocal var tool_id: PaneReg.TableReg = PaneReg.initTableReg;

    vt: iPane,

    cam: graph.Camera2D = .{
        .cam_area = graph.Rec(0, 0, 1000, 1000),
        .screen_area = graph.Rec(0, 0, 0, 0),
    },

    pub fn draw_fn(vt: *iPane, screen_area: graph.Rect, editor: *Context, draw: *DrawCtx, win: *graph.SDL.Window) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.draw2dView(editor, screen_area, draw, win) catch return;
    }

    pub fn create(alloc: std.mem.Allocator) !*iPane {
        var ret = try alloc.create(@This());
        ret.* = .{
            .vt = .{
                .deinit_fn = &@This().deinit,
                .draw_fn = &@This().draw_fn,
            },
        };
        return &ret.vt;
    }

    pub fn deinit(vt: *iPane, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }

    pub fn draw2dView(self: *@This(), ed: *Context, screen_area: graph.Rect, draw: *DrawCtx, win: *graph.SDL.Window) !void {
        self.cam.screen_area = screen_area;
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

        try draw.flush(null, null);
        draw.rect(screen_area, 0xffff);
        draw.rect(graph.Rec(0, 0, 10, 10), 0xff_00_00_ff);
        if (win.mouse.middle == .high) {
            self.cam.pan(win.mouse.delta);
        }
        if (win.mouse.wheel_delta.y != 0) {
            self.cam.zoom(win.mouse.wheel_delta.y * 0.1, win.mouse.pos, null, null);
        }

        graph.c.glPolygonMode(graph.c.GL_FRONT_AND_BACK, graph.c.GL_LINE);
        defer graph.c.glPolygonMode(graph.c.GL_FRONT_AND_BACK, graph.c.GL_FILL);

        const cb = self.cam.cam_area;
        const view_2d = graph.za.orthographic(cb.x, cb.x + cb.w, cb.y + cb.h, cb.y, -100000, 1);
        const view_3d = graph.za.orthographic(cb.x, cb.x + cb.w, cb.y + cb.h, cb.y, -4096, 4096).rotate(90, Vec3.new(1, 0, 0));
        {
            var ent_it = ed.ecs.iterator(.entity);
            while (ent_it.next()) |ent| {
                try ent.drawEnt(ed, view_3d, draw, draw, .{});
            }
        }
        var it = ed.meshmap.iterator();
        const c = graph.c;
        const model = graph.za.Mat4.identity();
        while (it.next()) |mesh| {
            if (!ed.draw_state.tog.tools) {
                if (ed.tool_res_map.contains(mesh.key_ptr.*))
                    continue;
            }
            graph.c.glUseProgram(ed.draw_state.basic_shader);
            graph.GL.passUniform(ed.draw_state.basic_shader, "view", view_3d);
            graph.GL.passUniform(ed.draw_state.basic_shader, "model", model);
            graph.c.glBindVertexArray(mesh.value_ptr.*.lines_vao);
            graph.c.glDrawElements(c.GL_LINES, @as(c_int, @intCast(mesh.value_ptr.*.lines_index.items.len)), graph.c.GL_UNSIGNED_INT, null);
            //mesh.value_ptr.*.mesh.drawSimple(view_3d, mat, ed.draw_state.basic_shader);
        }
        try draw.flushCustomMat(view_2d, view_3d);
    }
};

pub const CrapCam = struct {
    area: graph.Rect,
    pub fn getMatrix(self: @This(), aspect_ratio: f32, near: f32, far: f32) graph.za.Mat4 {
        _ = aspect_ratio;
        const cb = self.area;
        const view = graph.za.orthographic(cb.x, cb.x + cb.w, cb.y + cb.h, cb.y, near, far);
        return view;
    }
};
