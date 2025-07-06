const tools = @import("../tools.zig");
const i3DTool = tools.i3DTool;
const Vec3 = graph.za.Vec3;
const graph = @import("graph");
const std = @import("std");
const DrawCtx = graph.ImmediateDrawingContext;
const edit = @import("../editor.zig");
const Editor = edit.Context;
const guis = graph.RGui;
const RGui = guis.Gui;
const iArea = guis.iArea;
const iWindow = guis.iWindow;
const Wg = guis.Widget;
const util3d = @import("../util_3d.zig");
const ecs = @import("../ecs.zig");
const undo = @import("../undo.zig");
const snapV3 = util3d.snapV3;

pub const CubeDraw = struct {
    pub threadlocal var tool_id: tools.ToolReg = tools.initToolReg;
    vt: i3DTool,

    primitive: enum {
        cube,
        arch,
        cylinder,
    } = .cube,
    height_setting: enum {
        grid,
        custom,
        min_w,
        max_w,
    } = .grid,
    snap_height: bool = true,
    custom_height: f32 = 16,
    state: enum { start, planar } = .start,
    start: Vec3 = undefined,
    end: Vec3 = undefined,
    z: f32 = 0,

    plane_z: f32 = 0,

    post_state: enum {
        reset,
        switch_to_fast_face,
        switch_to_translate,
    } = .reset,

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{ .vt = .{
            .deinit_fn = &@This().deinit,
            .runTool_fn = &@This().runTool,
            .tool_icon_fn = &@This().drawIcon,
            .gui_build_cb = &buildGui,
        } };
        return &obj.vt;
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("cube_draw.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn buildGui(vt: *i3DTool, inspector: *tools.Inspector, area_vt: *iArea, gui: *RGui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const doc =
            \\This is the cube draw tool
            \\Select a texture with alt-t
            \\left click to add the start point.
            \\Click again to finish cube.
            \\
            \\Change the height of the draw plane with x and z
            \\Or, hold q and aim at a entity, left click to set this as the new position.
            \\Change the grid size with 'R' and 'F'
        ;
        var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = area_vt.area };
        ly.pushHeight(Wg.TextView.heightForN(gui, 7));
        area_vt.addChildOpt(gui, win, Wg.TextView.build(gui, ly.getArea(), &.{doc}, win, .{
            .mode = .split_on_space,
        }));

        if (guis.label(area_vt, gui, win, ly.getArea(), "Post draw state", .{})) |ar|
            area_vt.addChildOpt(gui, win, Wg.Combo.build(gui, ar, &self.post_state, .{}));
        if (guis.label(area_vt, gui, win, ly.getArea(), "Height mode", .{})) |ar|
            area_vt.addChildOpt(gui, win, Wg.Combo.build(gui, ar, &self.height_setting, .{}));

        if (guis.label(area_vt, gui, win, ly.getArea(), "Custom height", .{})) |ar|
            area_vt.addChildOpt(gui, win, Wg.TextboxNumber.build(gui, ar, &self.custom_height, win, .{}));
        if (guis.label(area_vt, gui, win, ly.getArea(), "Primitive", .{})) |ar|
            area_vt.addChildOpt(gui, win, Wg.Combo.build(gui, ar, &self.primitive, .{}));

        const tex_w = area_vt.area.w / 2;
        ly.pushHeight(tex_w);
        const ar = ly.getArea() orelse return;
        inspector.selectedTextureWidget(area_vt, gui, win, ar);
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }

    pub fn runTool(vt: *i3DTool, td: tools.ToolData, editor: *Editor) tools.ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        cubeDraw(self, editor, td) catch return error.fatal;
    }

    fn getHeight(self: *const @This(), ed: *Editor, p2: Vec3) f32 {
        const dim = self.start.sub(p2);
        return switch (self.height_setting) {
            .grid => ed.edit_state.grid_snap,
            .custom => self.custom_height,
            .min_w => @min(@abs(dim.x()), @abs(dim.y())),
            .max_w => @max(@abs(dim.x()), @abs(dim.y())),
        };
    }

    pub fn cubeDraw(tool: *@This(), self: *Editor, td: tools.ToolData) !void {
        const draw = td.draw;
        switch (td.state) {
            .init, .reinit => tool.state = .start,
            .normal => {},
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
        const ray = self.camRay(td.screen_area, td.view_3d.*);
        switch (tool.state) {
            .start => {
                const plane_up = self.isBindState(self.config.keys.cube_draw_plane_up.b, .rising);
                const plane_down = self.isBindState(self.config.keys.cube_draw_plane_down.b, .rising);
                const send_raycast = self.isBindState(self.config.keys.cube_draw_plane_raycast.b, .high);
                if (plane_up)
                    tool.plane_z += snap;
                if (plane_down)
                    tool.plane_z -= snap;
                if (send_raycast) {
                    const pot = self.screenRay(td.screen_area, td.view_3d.*);
                    if (pot.len > 0) {
                        const inter = pot[0].point;
                        const cc = snapV3(inter, snap);
                        helper.drawGrid(inter, cc.z(), draw, snap, 11);
                        if (self.edit_state.lmouse == .rising) {
                            tool.plane_z = cc.z();
                        }
                    }
                } else if (util3d.doesRayIntersectPlane(ray[0], ray[1], Vec3.new(0, 0, tool.plane_z), Vec3.new(0, 0, 1))) |inter| {
                    //user has a xy plane
                    //can reposition using keys or doing a raycast into world
                    helper.drawGrid(inter, tool.plane_z, draw, snap, 11);

                    const cc = snapV3(inter, snap);
                    draw.point3D(cc, 0xff0000ee);

                    if (self.edit_state.lmouse == .rising) {
                        tool.start = cc;
                        tool.state = .planar;
                    }
                }
            },
            .planar => {
                if (util3d.doesRayIntersectPlane(ray[0], ray[1], Vec3.new(0, 0, tool.plane_z), Vec3.new(0, 0, 1))) |inter| {
                    helper.drawGrid(inter, tool.plane_z, draw, snap, 11);
                    const in = snapV3(inter, snap);
                    const height = tool.getHeight(self, in);
                    const cc = util3d.cubeFromBounds(tool.start, in.add(Vec3.new(0, 0, height)));
                    draw.cube(cc[0], cc[1], 0xffffff88);

                    if (self.edit_state.lmouse == .rising) {
                        tool.end = in;
                        tool.end.data[2] += height;

                        //Put it into the
                        if (ecs.Solid.initFromCube(self.alloc, tool.start, tool.end, self.asset_browser.selected_mat_vpk_id orelse 0)) |newsolid| {
                            const new = try self.ecs.createEntity();
                            try self.ecs.attach(new, .solid, newsolid);
                            try self.ecs.attach(new, .bounding_box, .{});
                            const solid_ptr = try self.ecs.getPtr(new, .solid);
                            try solid_ptr.translate(new, Vec3.zero(), self);
                            {
                                const ustack = try self.undoctx.pushNewFmt("draw cube", .{});
                                try ustack.append(try undo.UndoCreateDestroy.create(self.undoctx.alloc, new, .create));
                                undo.applyRedo(ustack.items, self);
                            }
                            switch (tool.post_state) {
                                .reset => tool.state = .start,
                                .switch_to_fast_face => {
                                    const tid = try self.tools.getId(tools.FastFaceManip);
                                    self.edit_state.tool_index = tid;
                                    try self.selection.setToSingle(new);
                                },
                                .switch_to_translate => {
                                    const tid = try self.tools.getId(tools.Translate);
                                    self.edit_state.tool_index = tid;
                                    try self.selection.setToSingle(new);
                                },
                            }
                        } else |a| {
                            std.debug.print("Invalid cube {!}\n", .{a});
                        }
                    }
                }
            },
        }
    }
};
