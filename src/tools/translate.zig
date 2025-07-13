const std = @import("std");
const tools = @import("../tools.zig");
const i3DTool = tools.i3DTool;
const guis = graph.RGui;
const RGui = guis.Gui;
const Wg = guis.Widget;
const gizmo2 = @import("../gizmo2.zig");
const Gizmo = @import("../gizmo.zig").Gizmo;
const Vec3 = graph.za.Vec3;
const snapV3 = util3d.snapV3;
const util3d = @import("../util_3d.zig");
const ecs = @import("../ecs.zig");
const undo = @import("../undo.zig");
const iArea = guis.iArea;
const iWindow = guis.iWindow;
const DrawCtx = graph.ImmediateDrawingContext;
const graph = @import("graph");
const edit = @import("../editor.zig");
const Editor = edit.Context;

pub const Translate = struct {
    pub threadlocal var tool_id: tools.ToolReg = tools.initToolReg;
    vt: i3DTool,

    gizmo_rotation: gizmo2.Gizmo,
    gizmo_translate: Gizmo,
    mode: enum {
        translate,
        rotate,
        pub fn next(self: *@This()) void {
            self.* = switch (self.*) {
                .translate => .rotate,
                .rotate => .translate,
            };
        }
    } = .translate,

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{
                .deinit_fn = &@This().deinit,
                .runTool_fn = &@This().runTool,
                .tool_icon_fn = &@This().drawIcon,
                .gui_build_cb = &buildGui,
            },
            .gizmo_rotation = .{},
            .gizmo_translate = .{},
            .mode = .translate,
        };
        return &obj.vt;
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("translate.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }

    pub fn runTool(vt: *i3DTool, td: tools.ToolData, editor: *Editor) tools.ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (td.state == .init)
            self.gizmo_rotation.reset();

        translate(self, editor, td) catch return error.fatal;
    }

    pub fn translate(tool: *Translate, self: *Editor, td: tools.ToolData) !void {
        const draw_nd = &self.draw_state.ctx;
        const draw = td.draw;
        const dupe = self.isBindState(self.config.keys.duplicate.b, .high);
        const COLOR_MOVE = 0xe8a130_ee;
        const COLOR_DUPE = 0xfc35ac_ee;
        const color: u32 = if (dupe) COLOR_DUPE else COLOR_MOVE;

        const last_id = self.selection.getLast() orelse return;
        var angle: ?Vec3 = null;
        var angle_delta: ?Vec3 = null;
        const giz_origin: ?Vec3 = blk: {
            const last_bb = self.getComponent(last_id, .bounding_box) orelse return;
            if (self.getComponent(last_id, .solid)) |solid| { //check Solid before Entity
                _ = solid;
                break :blk last_bb.a.add(last_bb.b).scale(0.5);
            } else if (self.getComponent(last_id, .entity)) |ent| {
                angle = Vec3.zero();
                //angle = ent.angle;
                break :blk ent.origin;
            }
            break :blk null;
        };
        if (self.selection.mode == .many)
            angle = null;
        if (giz_origin) |origin| {
            // Care must be taken if selection is changed while gizmo is active, as solids are removed from meshmaps
            var origin_mut = origin;
            const giz_active = tblk: {
                if (angle != null and tool.mode == .rotate) {
                    break :tblk tool.gizmo_rotation.drawGizmo(
                        origin,
                        &(angle.?),
                        self.draw_state.cam3d.pos,
                        self.edit_state.lmouse,
                        draw_nd,
                        td.screen_area.dim(),
                        td.view_3d.*,
                        self.edit_state.mpos,
                    );
                }
                break :tblk tool.gizmo_translate.handle(
                    origin,
                    &origin_mut,
                    self.draw_state.cam3d.pos,
                    self.edit_state.lmouse,
                    draw_nd,
                    td.screen_area,
                    td.view_3d.*,
                    //self.edit_state.mpos,
                    self,
                );
            };
            const commit = self.edit_state.rmouse == .rising;
            const real_commit = giz_active == .high and commit;
            const dist = snapV3(origin_mut.sub(origin), self.edit_state.grid_snap);
            const selected = self.selection.getSlice();
            const MAX_DRAWN_VERTS = 500;
            const draw_verts = selected.len < MAX_DRAWN_VERTS;
            for (selected) |id| {
                if (self.getComponent(id, .solid)) |solid| {
                    if (draw_verts)
                        solid.drawEdgeOutline(draw_nd, 0xff00ff, 0xff0000ff, Vec3.zero());
                    if (giz_active == .rising) {
                        try solid.removeFromMeshMap(id, self);
                    }
                    if (giz_active == .falling) {
                        try solid.translate(id, Vec3.zero(), self); //Dummy to put it bake in the mesh batch

                        //Draw it here too so we it doesn't flash for a single frame
                        try solid.drawImmediate(draw, self, dist, null);
                    }

                    if (giz_active == .high) {
                        try solid.drawImmediate(draw, self, dist, null);
                        if (dupe) { //Draw original
                            try solid.drawImmediate(draw, self, Vec3.zero(), null);
                        }
                        if (draw_verts)
                            solid.drawEdgeOutline(draw_nd, color, 0xff0000ff, dist);
                    }
                }
                if (self.getComponent(id, .entity)) |ent| {
                    const bb = self.getComponent(id, .bounding_box) orelse continue;
                    //TODO the angle function is usable but suboptimal.
                    //the gizmo always manipulates extrinsic angles, rather than relative to current rotation
                    //this is how the angles in the vmf are stored but make for unintuitive editing

                    const del = Vec3.set(1); //Pad the frame so in doesn't get drawn over by ent frame
                    const coo = bb.a.sub(del);
                    draw_nd.cubeFrame(coo, bb.b.sub(coo).add(del), color);
                    {
                        const switcher_sz = origin.distance(self.draw_state.cam3d.pos) / 64 * 5;
                        const orr = origin.add(Vec3.new(0, 0, switcher_sz * 5));
                        const co = orr.sub(Vec3.set(switcher_sz / 2));
                        const ce = Vec3.set(switcher_sz);
                        if (giz_active != .high)
                            draw_nd.cube(co, ce, 0xffffff88);
                        if (giz_active == .low and angle != null) {
                            const rc = util3d.screenSpaceRay(td.screen_area.dim(), self.edit_state.mpos, td.view_3d.*);
                            if (self.edit_state.lmouse == .rising) {
                                if (util3d.doesRayIntersectBBZ(rc[0], rc[1], co, co.add(ce))) |_| {
                                    tool.mode.next();
                                }
                            }
                        }
                    }
                    if (giz_active == .high) {
                        var copy_ent = ent.*;
                        copy_ent.origin = ent.origin.add(dist);
                        const old_rot = util3d.extEulerToQuat(copy_ent.angle);
                        const new_rot = util3d.extEulerToQuat(angle orelse Vec3.zero());
                        const ang = new_rot.mul(old_rot).extractEulerAngles();
                        copy_ent.angle = snapV3(Vec3.new(ang.y(), ang.z(), ang.x()), 15);
                        //copy_ent.angle = Vec3.new(ang.x(), ang.y(), ang.z());
                        //copy_ent.angle = angle orelse ent.angle;
                        try copy_ent.drawEnt(self, td.view_3d.*, draw, draw_nd, .{ .frame_color = color, .draw_model_bb = true });

                        if (commit) {
                            angle_delta = copy_ent.angle.sub(ent.angle);
                        }
                    }
                }
            }
            if (real_commit) {
                // If ignore_groups, do it as usual
                //If !ignore_groups
                //make a list of all new entity id's and the groups involved
                //if a group has an owner and is not in selected, dupe it aswell.
                //for each original group, create a new group.
                //iterate all created entites and update using mapping
                //if a group has an owner, set the new groups owner to duped

                var new_ent_list = std.ArrayList(ecs.EcsT.Id).init(self.frame_arena.allocator());
                //Map old groups to duped groups
                var group_mapper = std.AutoHashMap(ecs.Groups.GroupId, ecs.Groups.GroupId).init(self.frame_arena.allocator());

                const ustack = try self.undoctx.pushNewFmt("{s} of {d} entities", .{ if (dupe) "Dupe" else "Translation", selected.len });
                for (selected) |id| {
                    if (dupe) {
                        const duped = try self.ecs.dupeEntity(id);

                        try ustack.append(try undo.UndoCreateDestroy.create(self.undoctx.alloc, duped, .create));
                        try ustack.append(try undo.UndoTranslate.create(
                            self.undoctx.alloc,
                            dist,
                            angle_delta,
                            duped,
                        ));
                        if (!self.selection.ignore_groups) {
                            if (try self.ecs.getOpt(duped, .group)) |group| {
                                if (group.id != ecs.Groups.NO_GROUP) {
                                    if (!group_mapper.contains(group.id)) {
                                        try group_mapper.put(group.id, try self.groups.newGroup(null));
                                    }
                                    try new_ent_list.append(duped);
                                }
                            }
                        }
                    } else {
                        try ustack.append(try undo.UndoTranslate.create(
                            self.undoctx.alloc,
                            dist,
                            angle_delta,
                            id,
                        ));
                    }
                }
                if (dupe) {
                    var it = group_mapper.iterator();
                    while (it.next()) |item| {
                        if (self.groups.getOwner(item.key_ptr.*)) |owner| {
                            const duped = try self.ecs.dupeEntity(owner);

                            try ustack.append(try undo.UndoCreateDestroy.create(self.undoctx.alloc, duped, .create));
                            try self.groups.setOwner(item.value_ptr.*, duped);
                            //TODO set the group owner with undo stack
                        }
                    }
                    for (new_ent_list.items) |new_ent| {
                        const old_group = try self.ecs.get(new_ent, .group);
                        const new_group = group_mapper.get(old_group.id) orelse continue;
                        try ustack.append(
                            try undo.UndoChangeGroup.create(self.undoctx.alloc, old_group.id, new_group, new_ent),
                        );
                    }
                    //now iterate the new_ent_list and update the group mapping
                }
                undo.applyRedo(ustack.items, self);
            }
        }
    }

    pub fn buildGui(vt: *i3DTool, _: *tools.Inspector, area_vt: *iArea, gui: *RGui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const doc =
            \\This is the translate tool.
            \\Select objects with 'E'.
            \\Left Click and drag the gizmo.
            \\Right click to commit the translation.
            \\Hold 'Shift' to uncapture the mouse.
        ;
        var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = area_vt.area };
        area_vt.addChildOpt(gui, win, Wg.Text.buildStatic(gui, ly.getArea(), "translate tool", null));
        ly.pushHeight(Wg.TextView.heightForN(gui, 4));
        area_vt.addChildOpt(gui, win, Wg.TextView.build(gui, ly.getArea(), &.{doc}, win, .{
            .mode = .split_on_space,
        }));
    }
};
