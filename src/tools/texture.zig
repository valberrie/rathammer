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
const Gui = guis.Gui;
const iArea = guis.iArea;
const iWindow = guis.iWindow;
const Wg = guis.Widget;
const util3d = @import("../util_3d.zig");
const ecs = @import("../ecs.zig");
const undo = @import("../undo.zig");
const snapV3 = util3d.snapV3;

//TODO when selection changes, change the gui

// doing the justify buttns
// idk, annoying
pub const TextureTool = struct {
    pub threadlocal var tool_id: tools.ToolReg = tools.initToolReg;
    const GuiBtnEnum = enum {
        reset,
        j_left,
        j_fit,
        j_right,

        j_top,
        j_bottom,
        j_center,

        u_flip,
        v_flip,
        swap,
    };
    const GuiTextEnum = enum {
        uscale,
        vscale,
        utrans,
        vtrans,
        lightmap,

        un_x,
        un_y,
        un_z,

        vn_x,
        vn_y,
        vn_z,
    };
    vt: i3DTool,
    id: ?ecs.EcsT.Id = null,
    face_index: ?u32 = 0,

    state: enum { pick, apply } = .apply,
    ed: *Editor,

    // Only used for a pointer
    // todo, fix the gui stuff
    cb_vt: iArea = undefined,
    win_ptr: ?*iWindow = null,

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

    pub fn buildGui(vt: *i3DTool, inspector: *tools.Inspector, area_vt: *iArea, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.win_ptr = win;
        const doc =
            \\This is the Texture tool.
            \\Right click applies the selected texture
            \\Holding q and right clicking picks the texture
        ;
        const H = struct {
            fn param(s: *TextureTool, id: GuiTextEnum) Wg.TextboxOptions {
                return .{
                    .commit_cb = &TextureTool.textbox_cb,
                    .commit_vt = &s.cb_vt,
                    .user_id = @intFromEnum(id),
                };
            }

            fn btn(s: *TextureTool, id: GuiBtnEnum) Wg.Button.Opts {
                return .{
                    .cb_vt = &s.cb_vt,
                    .cb_fn = &TextureTool.btn_cb,
                    .id = @intFromEnum(id),
                };
            }
        };
        var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = area_vt.area };
        ly.pushHeight(Wg.TextView.heightForN(gui, 4));
        area_vt.addChildOpt(gui, win, Wg.TextView.build(gui, ly.getArea(), &.{doc}, win, .{ .mode = .split_on_space }));
        area_vt.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "Reset face", H.btn(self, .reset)));
        const tex_w = area_vt.area.w / 2;
        ly.pushHeight(tex_w);
        const t_ar = ly.getArea() orelse return;
        inspector.selectedTextureWidget(area_vt, gui, win, t_ar);

        //Begin all selected face stuff
        const e_id = self.id orelse return;
        const f_id = self.face_index orelse return;
        const solid = (self.ed.getComponent(e_id, .solid)) orelse return;
        if (f_id >= solid.sides.items.len) return;
        const side = &solid.sides.items[f_id];

        {
            const Tb = Wg.TextboxNumber.build;
            ly.pushCount(5);
            var tly = guis.TableLayout{ .columns = 2, .item_height = ly.item_height, .bounds = ly.getArea() orelse return };
            area_vt.addChildOpt(gui, win, Wg.Text.buildStatic(gui, tly.getArea(), "X", null));
            area_vt.addChildOpt(gui, win, Wg.Text.buildStatic(gui, tly.getArea(), "Y", null));
            if (guis.label(area_vt, gui, win, tly.getArea(), "Scale", .{})) |ar|
                area_vt.addChildOpt(gui, win, Tb(gui, ar, side.u.scale, win, H.param(self, .uscale)));

            if (guis.label(area_vt, gui, win, tly.getArea(), "Scale ", .{})) |ar|
                area_vt.addChildOpt(gui, win, Tb(gui, ar, side.v.scale, win, H.param(self, .vscale)));

            if (guis.label(area_vt, gui, win, tly.getArea(), "Trans ", .{})) |ar|
                area_vt.addChildOpt(gui, win, Tb(gui, ar, side.u.trans, win, H.param(self, .utrans)));

            if (guis.label(area_vt, gui, win, tly.getArea(), "Trans ", .{})) |ar|
                area_vt.addChildOpt(gui, win, Tb(gui, ar, side.v.trans, win, H.param(self, .vtrans)));

            if (guis.label(area_vt, gui, win, tly.getArea(), "Axis ", .{})) |ar| {
                var hy = guis.HorizLayout{ .bounds = ar, .count = 3 };
                const a = side.u.axis;
                area_vt.addChildOpt(gui, win, Tb(gui, hy.getArea(), a.x(), win, H.param(self, .un_x)));
                area_vt.addChildOpt(gui, win, Tb(gui, hy.getArea(), a.y(), win, H.param(self, .un_y)));
                area_vt.addChildOpt(gui, win, Tb(gui, hy.getArea(), a.z(), win, H.param(self, .un_z)));
            }
            if (guis.label(area_vt, gui, win, tly.getArea(), "Axis ", .{})) |ar| {
                var hy = guis.HorizLayout{ .bounds = ar, .count = 3 };
                const a = side.v.axis;
                area_vt.addChildOpt(gui, win, Tb(gui, hy.getArea(), a.x(), win, H.param(self, .vn_x)));
                area_vt.addChildOpt(gui, win, Tb(gui, hy.getArea(), a.y(), win, H.param(self, .vn_y)));
                area_vt.addChildOpt(gui, win, Tb(gui, hy.getArea(), a.z(), win, H.param(self, .vn_z)));
            }
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, tly.getArea(), "flip", H.btn(self, .u_flip)));
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, tly.getArea(), "flip", H.btn(self, .v_flip)));

            if (guis.label(area_vt, gui, win, tly.getArea(), "lux scale (hu / luxel): ", .{})) |ar|
                area_vt.addChildOpt(gui, win, Tb(gui, ar, side.lightmapscale, win, H.param(self, .lightmap)));
        }
        if (guis.label(area_vt, gui, win, ly.getArea(), "Justify: ", .{})) |ar| {
            var hy = guis.HorizLayout{ .bounds = ar, .count = 6 };
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "left", H.btn(self, .j_left)));
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "right", H.btn(self, .j_right)));
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "fit", H.btn(self, .j_fit)));

            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "top", H.btn(self, .j_top)));
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "bot", H.btn(self, .j_bottom)));
            area_vt.addChildOpt(gui, win, Wg.Button.build(gui, hy.getArea(), "cent", H.btn(self, .j_center)));
        }
        area_vt.addChildOpt(gui, win, Wg.Button.build(gui, ly.getArea(), "swap axis", H.btn(self, .swap)));
    }

    fn textbox_cb(vt: *iArea, _: *Gui, string: []const u8, id: usize) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cb_vt", vt));

        self.textboxErr(string, id) catch return;
    }

    fn textboxErr(self: *@This(), string: []const u8, id: usize) !void {
        const num = std.fmt.parseFloat(f32, string) catch return;
        const sel = (self.getCurrentlySelected(self.ed) catch null) orelse return;
        const side = sel.side;
        const old = undo.UndoTextureManip.State{ .u = side.u, .v = side.v, .tex_id = side.tex_id, .lightmapscale = side.lightmapscale };
        var new = old;
        switch (@as(GuiTextEnum, @enumFromInt(id))) {
            .uscale => new.u.scale = num,
            .vscale => new.v.scale = num,
            .utrans => new.u.trans = num,
            .vtrans => new.v.trans = num,
            .lightmap => {
                if (num < 1) return;
                new.lightmapscale = @intFromFloat(num);
            },
            .un_x => new.u.axis.xMut().* = num,
            .un_y => new.u.axis.yMut().* = num,
            .un_z => new.u.axis.zMut().* = num,
            .vn_x => new.v.axis.xMut().* = num,
            .vn_y => new.v.axis.yMut().* = num,
            .vn_z => new.v.axis.zMut().* = num,
        }
        if (!old.eql(new)) {
            if (self.win_ptr) |win|
                win.needs_rebuild = true;
            const ustack = try self.ed.undoctx.pushNewFmt("texture manip", .{});
            try ustack.append(try undo.UndoTextureManip.create(
                self.ed.undoctx.alloc,
                old,
                new,
                self.id orelse return,
                self.face_index orelse return,
            ));
            undo.applyRedo(ustack.items, self.ed);
        }
    }

    pub fn btn_cb(vt: *iArea, id: usize, gui: *Gui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cb_vt", vt));
        self.btn_cbErr(id, gui, win) catch return;
    }
    pub fn btn_cbErr(self: *@This(), id: usize, _: *Gui, _: *guis.iWindow) !void {
        const sel = (self.getCurrentlySelected(self.ed) catch null) orelse return;
        const side = sel.side;
        const old = undo.UndoTextureManip.State{ .u = side.u, .v = side.v, .tex_id = side.tex_id, .lightmapscale = side.lightmapscale };
        var new = old;
        const btn_k = @as(GuiBtnEnum, @enumFromInt(id));
        switch (btn_k) {
            .j_fit, .j_left, .j_right, .j_top, .j_bottom, .j_center => {
                const res = side.justify(sel.solid.verts.items, switch (btn_k) {
                    .j_fit => .fit,
                    .j_left => .left,
                    .j_right => .right,
                    .j_top => .top,
                    .j_bottom => .bottom,
                    .j_center => .center,
                    else => unreachable,
                });
                new.u = res.u;
                new.v = res.v;
            },
            .u_flip => new.u.axis = new.u.axis.scale(-1),
            .v_flip => new.v.axis = new.v.axis.scale(-1),
            .swap => std.mem.swap(Vec3, &new.u.axis, &new.v.axis),
            .reset => {
                const norm = side.normal(sel.solid);
                side.resetUv(norm);
                //TODO put this into the undo stack
                sel.solid.rebuild(self.id orelse return, self.ed) catch return;
                self.ed.draw_state.meshes_dirty = true;
            },
        }
        if (!old.eql(new)) {
            if (self.win_ptr) |win|
                win.needs_rebuild = true;
            const ustack = try self.ed.undoctx.pushNewFmt("texture manip", .{});
            try ustack.append(try undo.UndoTextureManip.create(
                self.ed.undoctx.alloc,
                old,
                new,
                self.id orelse return,
                self.face_index orelse return,
            ));
            undo.applyRedo(ustack.items, self.ed);
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

                                    if (f.side.u.axis.dot(duped.u.axis) > 0.5) {
                                        duped.u.axis = f.side.u.axis;
                                        duped.u.trans = f.side.u.trans;
                                        duped.u.scale = f.side.u.scale;
                                    } else {
                                        duped.u.trans = f.side.v.trans;
                                        duped.u.scale = f.side.v.scale;
                                    }
                                    if (f.side.v.axis.dot(duped.v.axis) > 0.5) {
                                        duped.v.axis = f.side.v.axis;
                                        duped.v.trans = f.side.v.trans;
                                        duped.v.scale = f.side.v.scale;
                                    } else {
                                        duped.v.trans = f.side.u.trans;
                                        duped.v.scale = f.side.u.scale;
                                    }

                                    break :src duped;
                                }
                            }
                            break :src side.*;
                        };

                        const old = undo.UndoTextureManip.State{ .u = side.u, .v = side.v, .tex_id = side.tex_id, .lightmapscale = side.lightmapscale };
                        const new = undo.UndoTextureManip.State{ .u = source.u, .v = source.v, .tex_id = res_id, .lightmapscale = side.lightmapscale };

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
