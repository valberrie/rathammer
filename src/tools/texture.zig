const tools = @import("../tools.zig");
const i3DTool = tools.i3DTool;
const Vec3 = graph.za.Vec3;
const Mat3 = graph.za.Mat3;
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

pub const TextureTool = struct {
    pub threadlocal var tool_id: tools.ToolReg = tools.initToolReg;
    const GuiBtnEnum = enum {
        reset,
    };
    vt: i3DTool,
    id: ?ecs.EcsT.Id = null,
    face_index: ?u32 = 0,

    state: enum { pick, apply } = .apply,
    ed: *Editor,

    // Only used for a pointer
    // todo, fix the gui stuff
    cb_vt: iArea = undefined,

    //Left click to select a face,
    //right click to apply texture to any face
    pub fn create(alloc: std.mem.Allocator, ed: *Editor) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{
                .deinit_fn = &@This().deinit,
                .runTool_fn = &@This().runTool,
                .tool_icon_fn = &@This().drawIcon,
                .gui_build_cb = &buildGui,
            },
            .ed = ed,
        };
        return &obj.vt;
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("texture_tool.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }

    pub fn runTool(vt: *i3DTool, td: tools.ToolData, editor: *Editor) tools.ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.run(td, editor) catch return error.fatal;
    }

    pub fn buildGui(vt: *i3DTool, inspector: *tools.Inspector, area_vt: *iArea, gui: *RGui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const doc =
            \\This is the Texture tool.
            \\Right click applies the selected texture
            \\Holding q and right clicking picks the texture
        ;
        var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = area_vt.area };
        ly.pushHeight(Wg.TextView.heightForN(gui, 4));
        area_vt.addChildOpt(gui, win, Wg.TextView.build(gui, ly.getArea(), &.{doc}, win, .{ .mode = .split_on_space }));
        area_vt.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "Reset face", .{
            .cb_vt = &self.cb_vt,
            .cb_fn = &btn_cb,
            .id = @intFromEnum(GuiBtnEnum.reset),
        }));
        const tex_w = area_vt.area.w / 2;
        ly.pushHeight(tex_w);
        const ar = ly.getArea() orelse return;
        inspector.selectedTextureWidget(area_vt, gui, win, ar);

        //Begin all selected face stuff
        const e_id = self.id orelse return;
        const f_id = self.face_index orelse return;
        const solid = (self.ed.getComponent(e_id, .solid)) orelse return;
        if (f_id >= solid.sides.items.len) return;
        const side = &solid.sides.items[f_id];
        _ = side;
    }

    pub fn btn_cb(vt: *iArea, id: usize, _: *RGui, _: *guis.iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cb_vt", vt));
        switch (@as(GuiBtnEnum, @enumFromInt(id))) {
            .reset => {
                const e_id = self.id orelse return;
                const f_id = self.face_index orelse return;
                const solid = (self.ed.getComponent(e_id, .solid)) orelse return;
                if (f_id >= solid.sides.items.len) return;
                const side = &solid.sides.items[f_id];
                const norm = side.normal(solid);
                side.resetUv(norm);
                solid.rebuild(e_id, self.ed) catch return;
                self.ed.draw_state.meshes_dirty = true;
            },
        }
    }

    fn getCurrentlySelected(self: *TextureTool, editor: *Editor) !?struct { solid: *ecs.Solid, side: *ecs.Side } {
        const id = self.id orelse return null;
        const solid = editor.getComponent(id, .solid) orelse return null;
        if (self.face_index == null or self.face_index.? >= solid.sides.items.len) return null;

        return .{ .solid = solid, .side = &solid.sides.items[self.face_index.?] };
    }

    fn run(self: *TextureTool, td: tools.ToolData, editor: *Editor) !void {
        if (editor.edit_state.lmouse == .rising) {
            const pot = editor.screenRay(td.screen_area, td.view_3d.*);
            if (pot.len > 0) {
                self.id = pot[0].id;
                self.face_index = pot[0].side_id;
            }
        }
        blk: {
            if (editor.edit_state.rmouse == .rising) {
                const dupe = editor.isBindState(editor.config.keys.texture_wrap.b, .high);
                const pick = editor.isBindState(editor.config.keys.texture_eyedrop.b, .high);

                const res_id = (editor.asset_browser.selected_mat_vpk_id) orelse break :blk;
                const pot = editor.screenRay(td.screen_area, td.view_3d.*);
                if (pot.len == 0) break :blk;
                const solid = editor.getComponent(pot[0].id, .solid) orelse break :blk;
                if (pot[0].side_id == null or pot[0].side_id.? >= solid.sides.items.len) break :blk;
                const side = &solid.sides.items[pot[0].side_id.?];
                self.state = if (pick) .pick else .apply;
                switch (self.state) {
                    .apply => {
                        const source = src: {
                            if (dupe) {
                                if (try self.getCurrentlySelected(editor)) |f| {
                                    var duped = side.*;
                                    duped.u.trans = f.side.u.trans;
                                    duped.v.trans = f.side.v.trans;
                                    duped.u.scale = f.side.u.scale;
                                    duped.v.scale = f.side.v.scale;
                                    break :src duped;
                                }
                            }
                            break :src side.*;
                        };

                        const old = undo.UndoTextureManip.State{ .u = side.u, .v = side.v, .tex_id = side.tex_id };
                        const new = undo.UndoTextureManip.State{ .u = source.u, .v = source.v, .tex_id = res_id };

                        const ustack = try editor.undoctx.pushNewFmt("texture manip", .{});
                        try ustack.append(try undo.UndoTextureManip.create(editor.undoctx.alloc, old, new, pot[0].id, pot[0].side_id.?));
                        undo.applyRedo(ustack.items, editor);
                    },
                    .pick => {
                        editor.asset_browser.selected_mat_vpk_id = side.tex_id;
                    },
                }
            }
        }

        //Draw a red outline around the face
        if (try self.getCurrentlySelected(editor)) |sel| {
            const v = sel.solid.verts.items;
            const ind = sel.side.index.items;
            if (ind.len > 0) {
                var last = v[ind[ind.len - 1]];
                for (0..ind.len) |ti| {
                    const p = v[ind[ti]];
                    editor.draw_state.ctx.line3D(last, p, 0xff0000ff);
                    last = p;
                }
            }
        }
    }
};
