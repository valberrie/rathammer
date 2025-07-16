const std = @import("std");
const edit = @import("editor.zig");
const graph = @import("graph");
const Editor = edit.Context;
const util3d = @import("util_3d.zig");
const Vec3 = graph.za.Vec3;
const cubeFromBounds = util3d.cubeFromBounds;
const ButtonState = graph.SDL.ButtonState;
const snapV3 = util3d.snapV3;
const vpk = @import("vpk.zig");
const raycast = @import("raycast_solid.zig");
const undo = @import("undo.zig");
const DrawCtx = graph.ImmediateDrawingContext;
const Gui = graph.Gui;
const Os9Gui = graph.gui_app.Os9Gui;
const Gizmo = @import("gizmo.zig").Gizmo;
const ecs = @import("ecs.zig");
const Solid = ecs.Solid;
const VtableReg = @import("vtable_reg.zig").VtableReg;
const guis = graph.RGui;
const RGui = guis.Gui;
const iArea = guis.iArea;
const iWindow = guis.iWindow;
const Wg = guis.Widget;
const gridutil = @import("grid.zig");

pub usingnamespace @import("tools/cube_draw.zig");
pub usingnamespace @import("tools/texture.zig");
pub usingnamespace @import("tools/translate.zig");

pub const Inspector = @import("windows/inspector.zig").InspectorWindow;
//todo
//extrude tool
//clipping tool
//  click on a face twice
//  if points lie on same plane, infer clipping normal to be perpendicular to that plane

pub const ToolRegistry = VtableReg(i3DTool);
pub const ToolReg = ToolRegistry.TableReg;
pub const initToolReg = ToolRegistry.initTableReg;
//pub const ToolReg = ?usize;
//pub const initToolReg = null;
pub const i3DTool = struct {
    deinit_fn: *const fn (*@This(), std.mem.Allocator) void,
    runTool_fn: *const fn (*@This(), ToolData, *Editor) ToolError!void,
    tool_icon_fn: *const fn (*@This(), *DrawCtx, *Editor, graph.Rect) void,
    gui_fn: ?*const fn (*@This(), *Os9Gui, *Editor, *Gui.VerticalLayout) void = null,
    guiDoc_fn: ?*const fn (*@This(), *Os9Gui, *Editor, *Gui.VerticalLayout) void = null,

    gui_build_cb: ?*const fn (*@This(), *Inspector, *iArea, *RGui, *iWindow) void = null,
};

pub const ToolError = error{
    fatal,
    nonfatal,
};

/// Everything required to be a tool:
const ExampleTool = struct {
    /// This field gets set when calling ToolRegistry.register(ExampleTool);
    /// Allows code to reference tools by type at runtime.
    pub threadlocal var tool_id: ToolReg = initToolReg;
    vt: i3DTool,

    /// Called when ToolRegistry.register(@This()) is called
    pub fn create(_: std.mem.Allocator) *i3DTool {}
    //implement functions to fill out all non optional fields of i3DTool
};

pub const ToolData = struct {
    view_3d: *const graph.za.Mat4,
    screen_area: graph.Rect,
    draw: *DrawCtx,
    state: enum { init, reinit, normal },
};

pub const ToolRegistryOld = struct {
    const Self = @This();

    tools: std.ArrayList(*i3DTool),
    alloc: std.mem.Allocator,
    name_map: std.StringHashMap(usize),

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .alloc = alloc,
            .tools = std.ArrayList(*i3DTool).init(alloc),
            .name_map = std.StringHashMap(usize).init(alloc),
        };
    }

    fn assertTool(comptime T: type) void {
        if (!@hasDecl(T, "tool_id"))
            @compileError("Tools must declare a: pub threadlocal var tool_id: ToolReg = initToolReg;");
        if (@TypeOf(T.tool_id) != ToolReg)
            @compileError("Invalid type for tool_id, should be ToolReg");
    }

    pub fn register(self: *Self, name: []const u8, comptime T: type) !void {
        assertTool(T);

        const alloc_name = try self.alloc.dupe(u8, name);
        if (T.tool_id != null)
            return error.toolAlreadyRegistered;

        const id = self.tools.items.len;
        try self.tools.append(try T.create(self.alloc));
        T.tool_id = id;
        try self.name_map.put(alloc_name, id);
    }

    pub fn getToolId(self: *Self, comptime T: type) !usize {
        _ = self;
        assertTool(T);
        return T.tool_id orelse error.toolNotRegistered;
    }

    pub fn deinit(self: *Self) void {
        var it = self.name_map.keyIterator();
        while (it.next()) |item| {
            self.alloc.free(item.*);
        }
        self.name_map.deinit();
        for (self.tools.items) |item|
            item.deinit_fn(item, self.alloc);
        self.tools.deinit();
    }
};

pub const VertexTranslate = struct {
    const Self = @This();
    pub threadlocal var tool_id: ToolReg = initToolReg;
    const SelectedVertex = struct {
        id: ecs.EcsT.Id,
        vert_index: u16,
        vert: Vec3,
    };
    const Sel = std.MultiArrayList(struct {
        vert: Vec3,
        index: u32,
    });

    //How will the vertex translation work?
    //Selection works like normal selection, but uses mouse clicks or whatever.
    //only verticies of selected objects can be selected
    //if vert_sel > 0, a translate gizmo is active
    //This tool can easily create invalid geometry, maybe warn user?
    //
    //How do we determine if we have intersected a vertex.
    //perpendicalr distance from line to point is easy to find?
    //distance we want to accept depends on our distance from vertex

    vt: i3DTool,
    //selected_verts: std.ArrayList(SelectedVertex),
    selected: std.AutoHashMap(ecs.EcsT.Id, Sel),

    /// The perpendicular distance between a vertex and the mouse's ray must be smaller to be a
    /// candidate for selection.
    /// Measured in hammer units (hu).
    /// In the future, maybe scale this with by the distance from the camera? Seems unnecessary from testing.
    ray_vertex_distance_max: f32 = 5,

    selection_mode: enum {
        /// Add or remove all candidate verticies.
        many,
        /// Add or remove the first vertex encountered.
        /// This a cheap way to let users fix overlapping verticies within a solid.
        one,
    } = .many,

    gizmo: Gizmo = .{},
    gizmo_position: Vec3 = Vec3.zero(),

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var self = try alloc.create(@This());
        self.* = .{
            .vt = .{
                .deinit_fn = &deinit,
                .tool_icon_fn = &drawIcon,
                .runTool_fn = &runTool,
                .gui_build_cb = &buildGui,
            },
            .selected = std.AutoHashMap(ecs.EcsT.Id, Sel).init(alloc),
            //.selected_verts = std.ArrayList(SelectedVertex).init(alloc),
        };
        return &self.vt;
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.reset();
        //self.selected_verts.deinit();
        self.selected.deinit();
        alloc.destroy(self);
    }

    fn reset(self: *Self) void {
        //self.selected_verts.clearRetainingCapacity();
        self.gizmo_position = Vec3.zero();
        var it = self.selected.valueIterator();
        while (it.next()) |item|
            item.deinit(self.selected.allocator);
        self.selected.clearRetainingCapacity();
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("vertex.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn runTool(vt: *i3DTool, td: ToolData, ed: *Editor) ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.runVertex(td, ed) catch return error.fatal;
    }

    fn addOrRemoveVert(self: *Self, id: ecs.EcsT.Id, vert_index: u16, vert: Vec3) !void {
        const res = try self.selected.getOrPut(id);
        if (!res.found_existing) {
            res.value_ptr.* = .{};
        }

        for (res.value_ptr.items(.index), 0..) |item, vi| {
            if (item == vert_index) {
                _ = res.value_ptr.swapRemove(vi);
                return;
            }
        }
        try res.value_ptr.append(self.selected.allocator, .{ .vert = vert, .index = vert_index });
    }

    fn setGizmoPositionToMean(self: *Self) void {
        self.gizmo_position = Vec3.zero();
        var count: usize = 0;

        var it = self.selected.valueIterator();
        while (it.next()) |sel| {
            const verts = sel.items(.vert);
            count += verts.len;
            for (verts) |v|
                self.gizmo_position = self.gizmo_position.add(v);
        }
        if (count == 0) //prevent div by zero
            return;

        self.gizmo_position = self.gizmo_position.scale(1 / @as(f32, @floatFromInt(count)));
    }

    pub fn runVertex(self: *Self, td: ToolData, ed: *Editor) !void {
        if (td.state == .init)
            self.reset();
        const draw_nd = &ed.draw_state.ctx;
        const selected_slice = ed.selection.getSlice();
        const lm = ed.edit_state.lmouse;
        const r = ed.camRay(td.screen_area, td.view_3d.*);
        const POT_VERT_COLOR = 0x66CDAAff;
        var this_frame_had_selection = false;

        const ar = ed.frame_arena.allocator();
        var id_mapper = std.AutoHashMap(ecs.EcsT.Id, void).init(ar);

        solid_loop: for (selected_slice) |sel| {
            if (ed.getComponent(sel, .solid)) |solid| {
                try id_mapper.put(sel, {});
                solid.drawEdgeOutline(draw_nd, 0x00ff00ff, 0x0, Vec3.zero());

                if (this_frame_had_selection and self.selection_mode == .one)
                    continue :solid_loop;

                for (solid.verts.items, 0..) |vert, v_i| {
                    const proj = util3d.projectPointOntoRay(r[0], r[1], vert);
                    const distance = proj.distance(vert);
                    if (distance < self.ray_vertex_distance_max) {
                        draw_nd.point3D(vert, POT_VERT_COLOR);
                        if (lm == .rising) {
                            this_frame_had_selection = true;
                            try self.addOrRemoveVert(sel, @intCast(v_i), vert);
                        }
                    }
                }
            }
        }
        if (this_frame_had_selection) {
            self.setGizmoPositionToMean();
        }
        const SEL_VERT_COLOR = 0xBA55D3ff;
        {
            var it = self.selected.iterator();
            var to_remove = std.ArrayList(ecs.EcsT.Id).init(ar);
            while (it.next()) |item| {
                //Remove any verts that don't belong to a globally selected solid
                if (!id_mapper.contains(item.key_ptr.*)) {
                    try to_remove.append(item.key_ptr.*);

                    //We deinit here so we can quickly remove after loop
                    item.value_ptr.deinit(self.selected.allocator);
                    continue; //Don't draw, memory has been freed
                }
                const verts = item.value_ptr.items(.vert);
                for (verts) |v|
                    draw_nd.point3D(v, SEL_VERT_COLOR);
            }
            for (to_remove.items) |rem| {
                _ = self.selected.remove(rem);
            }
        }

        if (self.selected.count() > 0) {
            const origin = self.gizmo_position;
            var origin_mut = origin;
            const giz_active = self.gizmo.handle(
                origin,
                &origin_mut,
                ed.draw_state.cam3d.pos,
                ed.edit_state.lmouse,
                draw_nd,
                td.screen_area,
                td.view_3d.*,
                //ed.edit_state.mpos,
                ed,
            );

            const commit = ed.edit_state.rmouse == .rising;
            const real_commit = giz_active == .high and commit;

            const dist = ed.grid.snapV3(origin_mut.sub(origin));
            for (selected_slice) |id| {
                const manip_verts = self.selected.getPtr(id) orelse continue;
                const solid = ed.getComponent(id, .solid) orelse continue;
                //solid.drawEdgeOutline(draw_nd, 0xff00ff, 0xff0000ff, Vec3.zero());

                switch (giz_active) {
                    .low => {},
                    .rising => {
                        try solid.removeFromMeshMap(id, ed);
                    },
                    .falling => {
                        try solid.translate(id, Vec3.zero(), ed, Vec3.zero(), null); //Dummy to put it bake in the mesh batch

                        //Draw it here too so we it doesn't flash for a single frame
                        try solid.drawImmediate(td.draw, ed, dist, null);
                    },

                    .high => {
                        try solid.drawImmediate(td.draw, ed, dist, manip_verts.items(.index));
                        //if (dupe) { //Draw original
                        //    try solid.drawImmediate(draw, self, Vec3.zero(), null);
                        //}
                        //solid.drawEdgeOutline(draw_nd, color, 0xff0000ff, dist);
                    },
                }
            }
            if (real_commit) {
                const ustack = try ed.undoctx.pushNewFmt("vertex translate ", .{});
                for (selected_slice) |id| {
                    const manip_verts = self.selected.getPtr(id) orelse continue;
                    if (manip_verts.items(.index).len == 0) continue;

                    try ustack.append(try undo.UndoVertexTranslate.create(
                        ed.undoctx.alloc,
                        id,
                        dist,
                        manip_verts.items(.index),
                        null,
                    ));
                }
                undo.applyRedo(ustack.items, ed);
            }
        }
    }

    pub fn buildGui(vt: *i3DTool, _: *Inspector, area_vt: *iArea, gui: *RGui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const doc =
            \\This is the vertex translate tool.
            \\Select a solid with 'E'
            \\Mouse over the verticies and left click to add the vertex
        ;
        var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = area_vt.area };
        ly.pushHeight(Wg.TextView.heightForN(gui, 4));
        area_vt.addChildOpt(gui, win, Wg.TextView.build(gui, ly.getArea(), &.{doc}, win, .{
            .mode = .split_on_space,
        }));

        //area_vt.addChildOpt(gui, vt, Wg.Checkbox.build(gui, ly.getArea(), "select one", .{ .bool_ptr = &self. }, null));
        if (guis.label(area_vt, gui, win, ly.getArea(), "Selection mode", .{})) |ar|
            area_vt.addChildOpt(gui, win, Wg.Combo.build(gui, ar, &self.selection_mode, .{}));
    }
};
//double computeDistance(vec3 A, vec3 B, vec3 C) {
//    vec3 d = (C - B) / C.distance(B);
//    vec3 v = A - B;
//    double t = v.dot(d);
//    vec3 P = B + t * d;
//    return P.distance(A);
//}

//TODO How do tools register keybindings?

pub const FastFaceManip = struct {
    pub threadlocal var tool_id: ToolReg = initToolReg;

    //TODO during the .start mode, do a sort on the raycast to determine nearest solid
    const Selected = struct {
        id: ecs.EcsT.Id,
        face_id: u16,
    };
    vt: i3DTool,

    state: enum {
        start,
        active,
    } = .start,
    face_id: i32 = -1,
    start: Vec3 = Vec3.zero(),
    right: bool = false,
    main_id: ?ecs.EcsT.Id = null,

    draw_grid: bool = true,

    selected: std.ArrayList(Selected),

    fn reset(self: *@This()) void {
        self.face_id = -1;
        self.state = .start;
        self.right = false;
        self.selected.clearRetainingCapacity();
    }

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{
                .deinit_fn = &@This().deinit,
                .runTool_fn = &@This().runTool,
                .tool_icon_fn = &@This().drawIcon,
                .guiDoc_fn = &@This().guiDoc,
                .gui_build_cb = &buildGui,
            },
            .selected = std.ArrayList(Selected).init(alloc),
        };
        return &obj.vt;
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("fast_face_manip.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.selected.deinit();
        alloc.destroy(self);
    }
    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.runToolErr(td, editor) catch return error.fatal;
    }

    pub fn runToolErr(self: *@This(), td: ToolData, editor: *Editor) !void {
        if (td.state == .init)
            self.reset();

        const draw_nd = &editor.draw_state.ctx;
        const selected_slice = editor.selection.getSlice();
        for (selected_slice) |sel| {
            if (editor.getComponent(sel, .solid)) |solid| {
                solid.drawEdgeOutline(draw_nd, 0xf7a94a8f, 0xff0000ff, Vec3.zero());
            }
        }

        //const id = (editor.selection.single_id) orelse return;
        //const solid = editor.ecs.getOptPtr(id, .solid) catch return orelse return;

        const rm = editor.edit_state.rmouse;
        const lm = editor.edit_state.lmouse;
        switch (self.state) {
            .start => {
                if (rm == .rising or lm == .rising) {
                    self.right = rm == .rising;
                    const rc = editor.camRay(td.screen_area, td.view_3d.*);
                    editor.rayctx.reset();
                    for (selected_slice) |s_id| {
                        try editor.rayctx.addPotentialSolid(&editor.ecs, rc[0], rc[1], &editor.csgctx, s_id);
                    }
                    const pot = editor.rayctx.sortFine();
                    if (pot.len > 0) {
                        const rci = if (editor.edit_state.rmouse == .rising) @min(1, pot.len - 1) else 0;
                        const p = pot[rci];
                        const solid = editor.getComponent(p.id, .solid) orelse return;
                        self.main_id = p.id;
                        self.face_id = @intCast(p.side_id orelse return);
                        self.state = .active;
                        self.start = p.point;
                        const norm = solid.sides.items[@intCast(self.face_id)].normal(solid);
                        const NORM_THRESH = 0.99;
                        for (selected_slice) |other| {
                            if (editor.getComponent(other, .solid)) |o_solid| {
                                for (o_solid.sides.items, 0..) |*side, fi| {
                                    if (norm.dot(side.normal(o_solid)) > NORM_THRESH) {
                                        //if (init_plane.eql(side.normal(o_solid))) {
                                        try self.selected.append(.{ .id = other, .face_id = @intCast(fi) });
                                        try o_solid.removeFromMeshMap(other, editor);
                                        break; //Only one side per solid can be coplanar
                                    }
                                }
                            }
                        }
                    }
                }
            },
            .active => {
                //for (self.selected.items) |id| {
                if (self.main_id) |id| {
                    if (editor.getComponent(id, .solid)) |solid| {
                        if (self.face_id >= 0 and self.face_id < solid.sides.items.len) {
                            const s_i: usize = @intCast(self.face_id);
                            const side = &solid.sides.items[s_i];
                            //if (self.face_id == s_i) {
                            //Side_normal
                            //self.start
                            if (side.index.items.len < 3) return;
                            const ind = side.index.items;
                            const ver = solid.verts.items;

                            //The projection of a vector u onto a plane with normal n is given by:
                            //v_proj = u - n.scale(u dot n), assuming n is normalized
                            const plane_norm = util3d.trianglePlane([3]Vec3{ ver[ind[0]], ver[ind[1]], ver[ind[2]] });
                            const ray = editor.camRay(td.screen_area, td.view_3d.*);
                            //const u = ray[1];
                            //const v_proj = u.sub(plane_norm.scale(u.dot(plane_norm)));

                            // By projecting the cam_norm onto the side's plane,
                            // we can use the resulting vector as a normal for a plane to raycast against
                            // The resulting plane's normal is as colinear with the cameras normal as we can get
                            // while still having the side's normal perpendicular (in the raycast plane)
                            //
                            // If cam_norm and side_norm are colinear the projection is near zero, in the future discard vectors below a threshold as they cause explosions

                            if (util3d.planeNormalGizmo(self.start, plane_norm, ray)) |inter_| {
                                _, const pos = inter_;
                                const dist = editor.grid.snapV3(pos);

                                if (self.draw_grid) {
                                    const counts = editor.grid.countV3(dist);
                                    const absd = Vec3{ .data = @abs(dist.data) };
                                    const width = @max(10, util3d.maxComp(absd));
                                    gridutil.drawGridAxis(
                                        self.start,
                                        counts,
                                        td.draw,
                                        editor.grid,
                                        Vec3.set(width),
                                    );
                                }
                                //if (util3d.doesRayIntersectPlane(ray[0], ray[1], self.start, v_proj)) |inter| {
                                //const dist_n = inter.sub(self.start); //How much of our movement lies along the normal
                                //const acc = dist_n.dot(plane_norm);

                                for (self.selected.items) |sel| {
                                    const solid_o = editor.getComponent(sel.id, .solid) orelse continue;
                                    if (sel.face_id >= solid_o.sides.items.len) continue;
                                    const s_io: usize = @intCast(sel.face_id);
                                    const side_o = &solid_o.sides.items[s_io];
                                    solid_o.drawImmediate(td.draw, editor, dist, side_o.index.items) catch return;
                                    draw_nd.convexPolyIndexed(side_o.index.items, solid_o.verts.items, 0xff000088, .{ .offset = dist });
                                }

                                const commit_btn = if (self.right) lm else rm;
                                if (commit_btn == .rising) {
                                    const ustack = editor.undoctx.pushNewFmt("translate {d} faces", .{self.selected.items.len}) catch return;
                                    for (self.selected.items) |sel| {
                                        const solid_o = editor.getComponent(sel.id, .solid) orelse continue;
                                        if (sel.face_id >= solid_o.sides.items.len) continue;
                                        ustack.append(undo.UndoSolidFaceTranslate.create(
                                            editor.undoctx.alloc,
                                            sel.id,
                                            sel.face_id,
                                            dist,
                                        ) catch return) catch return;
                                    }
                                    undo.applyRedo(ustack.items, editor);
                                }
                            } else {
                                draw_nd.convexPolyIndexed(side.index.items, solid.verts.items, 0xff000088, .{});
                            }
                        }

                        if (rm != .high and lm != .high) {
                            for (self.selected.items) |sel| {
                                const solid_o = editor.getComponent(sel.id, .solid) orelse continue;
                                try solid_o.rebuild(sel.id, editor);
                            }
                            self.reset();
                        }
                    }
                }
            },
        }
    }

    pub fn buildGui(vt: *i3DTool, _: *Inspector, area_vt: *iArea, gui: *RGui, win: *iWindow) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        const doc =
            \\This is the Fast Face tool.
            \\Select objects with 'E'.
            \\Left click selects the near face, right click selects the far face
            \\Click and drag and click the opposite mouse button to commit changes
            \\If in multi select mode, faces with a common normal will be manipulated
        ;
        var ly = guis.VerticalLayout{ .item_height = gui.style.config.default_item_h, .bounds = area_vt.area };
        ly.pushHeight(Wg.TextView.heightForN(gui, 4));
        area_vt.addChildOpt(gui, win, Wg.TextView.build(gui, ly.getArea(), &.{doc}, win, .{
            .mode = .split_on_space,
        }));
        const CB = Wg.Checkbox.build;
        area_vt.addChildOpt(gui, win, CB(gui, ly.getArea(), "Draw Grid", .{ .bool_ptr = &self.draw_grid }, null));
    }

    pub fn guiDoc(_: *i3DTool, os9gui: *Os9Gui, editor: *Editor, vl: *Gui.VerticalLayout) void {
        const hl = os9gui.style.config.text_h;
        vl.pushHeight(hl * 10);
        if (os9gui.textView(hl, 0xff)) |tvc| {
            var tv = tvc;
            tv.text("This is the Fast Face tool", .{});
            tv.text("Left click selects the near face, right click selects the far face.", .{});
            tv.text("Click and drag and click the opposite mouse button to commit changes", .{});
            tv.text("", .{});
            tv.text("If in multi select mode, faces with a common normal will be manipulated", .{});
            //tv.text("", .{});
        }
        _ = editor;
    }
};

//TODO change this to PlaceEntity
pub const PlaceModel = struct {
    pub threadlocal var tool_id: ToolReg = initToolReg;
    vt: i3DTool,

    ent_class: enum {
        prop_static,
        prop_dynamic,
        prop_physics, //TODO load mdl metadata and set this field Automatically
    } = .prop_static,

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{ .vt = .{
            .deinit_fn = &@This().deinit,
            .runTool_fn = &@This().runTool,
            .tool_icon_fn = &@This().drawIcon,
            .gui_fn = &@This().doGui,
        } };
        return &obj.vt;
    }

    pub fn doGui(vt: *i3DTool, os9gui: *Os9Gui, _: *Editor, _: *Gui.VerticalLayout) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        os9gui.enumCombo("New class: {s}", .{@tagName(self.ent_class)}, &self.ent_class) catch return;
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("place_model.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }

    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.modelPlace(editor, td) catch return error.fatal;
    }

    pub fn modelPlace(tool: *@This(), self: *Editor, td: ToolData) !void {
        const pot = self.screenRay(td.screen_area, td.view_3d.*);
        if (pot.len > 0) {
            const p = pot[0];
            const point = self.grid.snapV3(p.point);
            const mat1 = graph.za.Mat4.fromTranslate(point);
            const model_id = self.asset_browser.selected_model_vpk_id;
            const mod = blk: {
                const omod = self.models.get(model_id orelse break :blk null);
                if (omod != null and omod.?.mesh != null) {
                    const mod = omod.?.mesh.?;
                    break :blk mod;
                }
                break :blk null;
            };
            //zyx
            //const mat3 = mat1.mul(y1.mul(x1.mul(z)));
            if (mod) |m|
                m.drawSimple(td.view_3d.*, mat1, self.draw_state.basic_shader);
            //Draw the model at
            var bb = ecs.AABB{ .a = Vec3.new(0, 0, 0), .b = Vec3.new(16, 16, 16), .origin_offset = Vec3.new(8, 8, 8) };
            if (mod) |m| {
                bb.a = m.hull_min;
                bb.b = m.hull_max;
                bb.origin_offset = m.hull_min.scale(-1);
            }
            bb.setFromOrigin(point);
            const COLOR_FRAME = 0xe8a130_ee;
            self.draw_state.ctx.cubeFrame(bb.a, bb.b.sub(bb.a), COLOR_FRAME);
            if (self.edit_state.lmouse == .rising) {
                const new = try self.ecs.createEntity();
                try self.ecs.attach(new, .entity, .{
                    .origin = point,
                    .angle = Vec3.zero(),
                    .class = try self.storeString(@tagName(tool.ent_class)),
                    ._model_id = model_id,
                    ._sprite = null,
                });
                try self.ecs.attach(new, .bounding_box, bb);

                var kvs = ecs.KeyValues.init(self.alloc);
                if (model_id) |mid| {
                    if (self.vpkctx.namesFromId(mid)) |names| {
                        var string = std.ArrayList(u8).init(self.alloc);
                        try string.writer().print("{s}/{s}.{s}", .{ names.path, names.name, names.ext });
                        try kvs.map.put(try self.storeString("model"), .{ ._string = string, .sync = .model });
                    }
                }

                try self.ecs.attach(new, .key_values, kvs);

                const ustack = try self.undoctx.pushNewFmt("create entity", .{});
                try ustack.append(try undo.UndoCreateDestroy.create(self.undoctx.alloc, new, .create));
                undo.applyRedo(ustack.items, self);
            }
        }
    }
};

const Proportional = struct {
    const TranslateCtx = struct {
        norm: Vec3,
        froze: Vec3,
        t: f32,
        tl: f32,

        pub fn vertexOffset(s: *const @This(), v: Vec3, _: u32, _: u32) Vec3 {
            const dist = (v.sub(s.froze)).dot(s.norm) / -s.tl;

            //TODO put opt to disable hard grid snap
            return .{ .data = @round(s.norm.scale(dist * s.t).data) };
        }
    };
    const Self = @This();
    // when the selection changes, we need to recalculate the bb
    sel_map: std.AutoHashMap(ecs.EcsT.Id, void),
    bb_min: Vec3 = Vec3.zero(),
    bb_max: Vec3 = Vec3.zero(),

    state: enum { init, active } = .init,
    start: Vec3 = Vec3.zero(),
    start_n: Vec3 = Vec3.zero(),

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .sel_map = std.AutoHashMap(ecs.EcsT.Id, void).init(alloc),
        };
    }

    pub fn reset(self: *Self) void {
        self.sel_map.clearRetainingCapacity();
        self.state = .init;
    }

    pub fn deinit(self: *Self) void {
        self.sel_map.deinit();
    }

    fn rebuildBB(self: *Self, ed: *Editor) !void {
        const sel = ed.selection.getSlice();
        self.sel_map.clearRetainingCapacity();
        var min = Vec3.set(std.math.floatMax(f32));
        var max = Vec3.set(-std.math.floatMax(f32));

        for (sel) |s| {
            if (ed.getComponent(s, .bounding_box)) |b| {
                min = min.min(b.a);
                max = max.max(b.b);
            }
            try self.sel_map.put(s, {});
        }

        self.bb_min = min;
        self.bb_max = max;
    }

    fn needsRebuild(self: *Self, ed: *Editor) bool {
        const sel = ed.selection.getSlice();
        if (sel.len != self.sel_map.count()) return true;

        for (sel) |s| {
            if (!self.sel_map.contains(s)) return true;
        }
        return false;
    }

    fn addOrRemoveSelFromMeshMap(ed: *Editor, add: bool) !void {
        const sel = ed.selection.getSlice();
        for (sel) |id| {
            if (ed.getComponent(id, .solid)) |solid| {
                if (!add) try solid.removeFromMeshMap(id, ed) else try solid.translate(id, Vec3.zero(), ed, Vec3.zero(), null);
            }
        }
    }

    fn commit(self: *Self, ed: *Editor, ctx: TranslateCtx) !void {
        const selection = ed.selection.getSlice();
        const ustack = try ed.undoctx.pushNewFmt("scale", .{});
        for (selection) |id| {
            const solid = ed.getComponent(id, .solid) orelse continue;
            const temp_verts = try ed.frame_arena.allocator().alloc(Vec3, solid.verts.items.len);
            const index = try ed.frame_arena.allocator().alloc(u32, solid.verts.items.len);
            for (solid.verts.items, 0..) |v, i| {
                temp_verts[i] = ctx.vertexOffset(v, 0, 0);
                index[i] = @intCast(i);
            }

            try ustack.append(try undo.UndoVertexTranslate.create(
                ed.undoctx.alloc,
                id,
                Vec3.zero(),
                index,
                temp_verts,
            ));
        }
        undo.applyRedo(ustack.items, ed);
        self.reset();
    }

    pub fn runProp(self: *Self, ed: *Editor, td: ToolData) !void {
        if (td.state == .init)
            self.reset();

        if (self.needsRebuild(ed))
            try self.rebuildBB(ed);
        const draw_nd = &ed.draw_state.ctx;

        //draw.cube(cc[0], cc[1], 0xffffff88);
        const selected = ed.selection.getSlice();
        if (selected.len == 0) return;
        for (selected) |id| {
            if (ed.getComponent(id, .solid)) |solid| {
                solid.drawEdgeOutline(draw_nd, 0xff00ff, 0xff0000ff, Vec3.zero());
            }
        }
        draw_nd.point3D(self.start, 0xffff_00ff);
        const lm = ed.edit_state.lmouse;
        const rm = ed.edit_state.rmouse;
        const rc = ed.camRay(td.screen_area, td.view_3d.*);
        switch (self.state) {
            .init => {
                const cc = cubeFromBounds(self.bb_min, self.bb_max);
                draw_nd.cubeFrame(cc[0], cc[1], 0xff0000ff);
                if (lm == .rising) {
                    if (util3d.doesRayIntersectBBZ(rc[0], rc[1], self.bb_min, self.bb_max)) |inter| {
                        self.start = inter;
                        if (util3d.pointBBIntersectionNormal(self.bb_min, self.bb_max, inter)) |norm| {
                            self.start_n = norm;
                            self.state = .active;
                            try addOrRemoveSelFromMeshMap(ed, false);
                        }
                    }
                }
            },
            .active => {
                if (lm != .high) {
                    self.state = .init;
                    try addOrRemoveSelFromMeshMap(ed, true);
                    return;
                }
                if (util3d.planeNormalGizmo(self.start, self.start_n, rc)) |inter| {
                    //const dist_n =

                    const sign = self.start_n.dot(Vec3.set(1));
                    _, const p_unsnapped = inter;
                    const p = ed.grid.snapV3(p_unsnapped);
                    const bmin = if (sign > 0) self.bb_min else self.bb_min.add(p);
                    const bmax = if (sign < 0) self.bb_max else self.bb_max.add(p);
                    const fr0zen = if (sign > 0) self.bb_min else self.bb_max;

                    const total_len = (self.bb_min.sub(self.bb_max).dot(self.start_n));

                    const cc = cubeFromBounds(bmin, bmax);
                    draw_nd.line3D(self.start, self.start.add(p), 0x00ffffff);
                    draw_nd.cubeFrame(cc[0], cc[1], 0xff0000ff);

                    const ctx_ = TranslateCtx{
                        .froze = fr0zen,
                        .norm = self.start_n,
                        .t = p.dot(Vec3.set(1)),
                        .tl = total_len,
                    };
                    if (rm == .rising) {
                        try self.commit(ed, ctx_);
                    }
                    for (selected) |id| {
                        const solid = ed.getComponent(id, .solid) orelse continue;
                        solid.drawImmediateCustom(td.draw, ed, &ctx_, TranslateCtx.vertexOffset) catch return;
                    }
                }
            },
        }
    }
};

pub const TranslateFace = struct {
    pub threadlocal var tool_id: ToolReg = initToolReg;

    vt: i3DTool,
    gizmo: Gizmo,
    face_id: ?usize = null,
    face_origin: Vec3 = Vec3.zero(),

    //When there are more than 1 solids selected, do proportional editing instead
    prop: Proportional,

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{
            .vt = .{
                .deinit_fn = &@This().deinit,
                .runTool_fn = &@This().runTool,
                .tool_icon_fn = &@This().drawIcon,
                .guiDoc_fn = &@This().guiDoc,
            },
            .gizmo = .{},
            .prop = Proportional.init(alloc),
        };
        return &obj.vt;
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("face_translate.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.prop.deinit();
        alloc.destroy(self);
    }

    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.selection.getExclusive()) |id| {
            faceTranslate(self, editor, id, td) catch return error.fatal;
        } else {
            self.prop.runProp(editor, td) catch return error.fatal;
        }
    }

    pub fn guiDoc(_: *i3DTool, os9gui: *Os9Gui, editor: *Editor, vl: *Gui.VerticalLayout) void {
        const hl = os9gui.style.config.text_h;
        vl.pushHeight(hl * 10);
        if (os9gui.textView(hl, 0xff)) |tvc| {
            var tv = tvc;
            tv.text("This is the face translate tool.", .{});
            tv.text("Select a solid with {s}", .{editor.config.keys.select.b.name()});
            tv.text("left click selects the near face.", .{});
            tv.text("right click selects the far face.", .{});
            tv.text("Once you drag the gizmo, press right click to commit the change.", .{});
        }
    }
    pub fn faceTranslate(tool: *@This(), self: *Editor, id: ecs.EcsT.Id, td: ToolData) !void {
        const draw_nd = &self.draw_state.ctx;
        if (self.getComponent(id, .solid)) |solid| {
            var gizmo_is_active = false;
            solid.drawEdgeOutline(draw_nd, 0xf7a94a8f, 0xff0000ff, Vec3.zero());
            for (solid.sides.items, 0..) |side, s_i| {
                if (tool.face_id == s_i) {
                    draw_nd.convexPolyIndexed(side.index.items, solid.verts.items, 0xff000088, .{});
                    const origin_i = tool.face_origin;
                    var origin = origin_i;
                    const giz_active = tool.gizmo.handle(
                        origin,
                        &origin,
                        self.draw_state.cam3d.pos,
                        self.edit_state.lmouse,
                        draw_nd,
                        td.screen_area,
                        td.view_3d.*,
                        //self.edit_state.mpos,
                        self,
                    );
                    gizmo_is_active = giz_active != .low;
                    if (giz_active == .rising) {
                        try solid.removeFromMeshMap(id, self);
                    }
                    if (giz_active == .falling) {
                        try solid.translate(id, Vec3.zero(), self, Vec3.zero(), null); //Dummy to put it bake in the mesh batch
                        tool.face_origin = origin;
                    }

                    if (giz_active == .high) {
                        const dist = self.grid.snapV3(origin.sub(origin_i));
                        try solid.drawImmediate(td.draw, self, dist, side.index.items);
                        if (self.edit_state.rmouse == .rising) {
                            //try solid.translateSide(id, dist, self, s_i);
                            const ustack = try self.undoctx.pushNewFmt("translated face", .{});
                            try ustack.append(try undo.UndoSolidFaceTranslate.create(
                                self.undoctx.alloc,
                                id,
                                s_i,
                                dist,
                            ));
                            undo.applyRedo(ustack.items, self);
                            tool.face_origin = origin;
                            tool.gizmo.start = origin;
                            //Commit the changes
                        }
                    }
                }
            }
            if (!gizmo_is_active and (self.edit_state.lmouse == .rising or self.edit_state.rmouse == .rising)) {
                const r = self.camRay(td.screen_area, td.view_3d.*);
                //Find the face it intersects with
                const rc = (try raycast.doesRayIntersectSolid(
                    r[0],
                    r[1],
                    solid,
                    &self.csgctx,
                ));
                if (rc.len > 0) {
                    const rci = if (self.edit_state.rmouse == .rising) @min(1, rc.len) else 0;
                    tool.face_id = rc[rci].side_index;
                    tool.face_origin = rc[rci].point;
                }
            }
        }
    }
};

pub const Clipping = struct {
    pub threadlocal var tool_id: ToolReg = initToolReg;
    //How will this work.
    //Clipping works by defining a plane
    //if the first two points lie on the same face we can infer the desired plane's normal, this is a good default
    //
    //I think hammer only allows planes with a normal perpendicular to cardinal axis
    //In hammer the clip line can start or end outside the solid
    //Select a plane in world, put lines on that

    vt: i3DTool,
    plane_norm: Vec3 = Vec3.zero(),
    plane_p0: Vec3 = Vec3.zero(),
    selected_side: ?raycast.RcastItem = null,
    ray_vertex_distance_max: f32 = 5,

    points: [2]Vec3,
    state: enum {
        init,
        point0,
        point1,
        done,
    } = .init,

    grabbed: ?struct { ptr: *Vec3, init: Vec3 } = null,

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var clip = try alloc.create(@This());
        clip.* = .{
            .vt = .{
                .deinit_fn = &deinit,
                .tool_icon_fn = &drawIcon,
                .runTool_fn = &runTool,
            },
            .points = undefined,
        };
        return &clip.vt;
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }

    fn reset(self: *@This()) void {
        self.state = .init;
        self.selected_side = null;
        self.grabbed = null;
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("clipping.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn runTool(vt: *i3DTool, td: ToolData, ed: *Editor) ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.runToolErr(td, ed) catch return error.nonfatal;
    }

    fn commitGrab(self: *@This()) void {
        if (self.grabbed) |*g| {
            g.init = g.ptr.*;
        }
    }

    fn cancelGrab(self: *@This()) void {
        if (self.grabbed) |g| {
            g.ptr.* = g.init;
        }
        self.grabbed = null;
    }

    //TODO put gizmos on the points
    pub fn runToolErr(self: *@This(), td: ToolData, ed: *Editor) !void {
        if (td.state == .init)
            self.reset();

        const draw_nd = &ed.draw_state.ctx;
        const selected = ed.selection.getSlice();

        for (selected) |id| {
            if (ed.getComponent(id, .solid)) |solid| {
                solid.drawEdgeOutline(draw_nd, 0xff00ff, 0xff0000ff, Vec3.zero());
            }
        }

        const rc = ed.camRay(td.screen_area, td.view_3d.*);
        const lm = ed.edit_state.lmouse;
        switch (self.state) {
            .init => {
                const sel = ed.selection.getSlice();
                ed.rayctx.reset();

                for (sel) |s_id| {
                    try ed.rayctx.addPotentialSolid(&ed.ecs, rc[0], rc[1], &ed.csgctx, s_id);
                }
                const pot = ed.rayctx.sortFine();
                if (pot.len > 0) {
                    const inter = pot[0];
                    const solid = try ed.ecs.getPtr(inter.id, .solid);
                    const snapped = ed.grid.snapV3(inter.point);
                    draw_nd.point3D(snapped, 0xff_0000_ff);
                    if (lm != .rising) return;
                    const side_id = inter.side_id orelse return;
                    if (side_id >= solid.sides.items.len) return;
                    self.plane_p0 = snapped;
                    self.plane_norm = solid.sides.items[side_id].normal(solid);
                    self.selected_side = inter;
                    self.state = .point1;
                    self.points[0] = snapped;
                }
            },
            .point0, .point1 => {
                const sel_side = self.selected_side orelse {
                    self.reset();
                    return;
                };
                const solid = try ed.ecs.getPtr(sel_side.id, .solid);
                const side_o = solid.getSidePtr(sel_side.side_id) orelse return;
                draw_nd.convexPolyIndexed(side_o.index.items, solid.verts.items, 0xffff_88, .{});
                if (self.state == .point1)
                    draw_nd.point3D(self.points[0], 0xff_0000_ff);
                if (util3d.doesRayIntersectPlane(rc[0], rc[1], self.plane_p0, self.plane_norm)) |inter| {
                    const snapped = ed.grid.snapV3(inter);
                    draw_nd.point3D(snapped, 0xff_0000_ff);
                    if (lm != .rising) return;
                    self.points[if (self.state == .point0) 0 else 1] = snapped;
                    self.state = switch (self.state) {
                        else => {
                            self.reset();
                            return;
                        },
                        .point0 => .point1,
                        .point1 => .done,
                    };
                }
            },
            .done => {
                grab_blk: {
                    const grab = &(self.grabbed orelse break :grab_blk);
                    if (lm != .high) {
                        self.cancelGrab();
                        break :grab_blk;
                    }
                    if (util3d.doesRayIntersectPlane(rc[0], rc[1], self.plane_p0, self.plane_norm)) |inter|
                        grab.ptr.* = ed.grid.snapV3(inter);
                    const rm = ed.edit_state.rmouse;
                    if (rm == .rising)
                        self.commitGrab();
                }

                const p0 = self.points[0];
                const p1 = self.points[1];
                const diff = p0.sub(p1);
                const dist = diff.length();
                const dir = diff.norm();
                draw_nd.line3D(p0.add(dir.scale(-dist)), p0.add(dir.scale(dist)), 0xffff_ffff);
                for (self.points, 0..) |p, i| {
                    const proj = util3d.projectPointOntoRay(rc[0], rc[1], p);
                    const distance = proj.distance(p);
                    if (self.grabbed == null and distance < self.ray_vertex_distance_max) {
                        draw_nd.point3D(p, 0xff_ff);
                        if (lm == .rising) {
                            self.grabbed = .{ .ptr = &self.points[i], .init = p };
                        }
                    } else {
                        draw_nd.point3D(p, 0xff0000_ff);
                    }
                }

                const v1 = p0.add(self.plane_norm);
                const plane_n = util3d.trianglePlane(.{ p0, v1, p1 }).norm();
                { //Draw the cut plane
                    const r0 = p0.add(self.plane_norm.scale(100));
                    const r1 = p0.add(self.plane_norm.scale(-100));
                    const r2 = p1.add(self.plane_norm.scale(-100));
                    const r3 = p1.add(self.plane_norm.scale(100));
                    td.draw.convexPoly(&.{ r0, r1, r2, r3 }, 0xff000088);
                    draw_nd.convexPoly(&.{ r0, r1, r2, r3 }, 0xff000044);
                }
                if (ed.isBindState(ed.config.keys.clip_commit.b, .rising)) {
                    self.state = .init;
                    const sel_side = self.selected_side orelse return;
                    const solid = try ed.ecs.getPtr(sel_side.id, .solid);
                    var ret = try ed.clipctx.clipSolid(solid, p0, plane_n, ed.asset_browser.selected_mat_vpk_id);

                    ed.selection.clear();
                    const ustack = try ed.undoctx.pushNewFmt("Clip", .{});
                    try ustack.append(try undo.UndoCreateDestroy.create(ed.undoctx.alloc, sel_side.id, .destroy));

                    for (&ret) |*r| {
                        const new = try ed.ecs.createEntity();
                        try ustack.append(try undo.UndoCreateDestroy.create(ed.undoctx.alloc, new, .create));
                        try ed.ecs.attach(new, .solid, r.*);
                        try ed.ecs.attach(new, .bounding_box, .{});
                        const solid_ptr = try ed.ecs.getPtr(new, .solid);
                        try solid_ptr.translate(new, Vec3.zero(), ed, Vec3.zero(), null);
                    }
                    undo.applyRedo(ustack.items, ed);
                }
            },
        }
    }
};
