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
const gizmo2 = @import("gizmo2.zig");
const Gizmo = @import("gizmo.zig").Gizmo;
const ecs = @import("ecs.zig");
const Solid = ecs.Solid;

//todo
//extrude tool
//clipping tool
//  click on a face twice
//  if points lie on same plane, infer clipping normal to be perpendicular to that plane

pub const ToolReg = ?usize;
pub const initToolReg = null;
pub const i3DTool = struct {
    deinit_fn: *const fn (*@This(), std.mem.Allocator) void,
    runTool_fn: *const fn (*@This(), ToolData, *Editor) ToolError!void,
    guiDoc_fn: ?*const fn (*@This(), *Os9Gui, *Editor, *Gui.VerticalLayout) void = null,
    tool_icon_fn: *const fn (*@This(), *DrawCtx, *Editor, graph.Rect) void,
    gui_fn: ?*const fn (*@This(), *Os9Gui, *Editor, *Gui.VerticalLayout) void = null,
};

const ToolError = error{
    fatal,
    nonfatal,
};

/// Everything required to be a tool:
const ExampleTool = struct {
    /// This field gets set when calling ToolRegistry.register(ExampleTool);
    /// Allows code to reference tools by type at runtime.
    pub threadlocal var tool_id: ToolReg = initToolReg;
    vt: i3DTool,

    pub fn create(_: std.mem.Allocator) *i3DTool {}
    //implement functions to fill out all non optional fields of i3DTool
};

pub const ToolData = struct {
    view_3d: *const graph.za.Mat4,
    screen_area: graph.Rect,
    draw: *DrawCtx,
    win: *graph.SDL.Window,
    is_first_frame: bool,
};

pub const ToolRegistry = struct {
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

//TODO How do tools register keybindings?
pub const CubeDraw = struct {
    pub threadlocal var tool_id: ToolReg = initToolReg;
    vt: i3DTool,

    use_custom_height: bool = false,
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
            .guiDoc_fn = &@This().guiDoc,
            .gui_fn = &@This().doGui,
        } };
        return &obj.vt;
    }

    pub fn drawIcon(vt: *i3DTool, draw: *DrawCtx, editor: *Editor, r: graph.Rect) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        const rec = editor.asset.getRectFromName("cube_draw.png") orelse graph.Rec(0, 0, 0, 0);
        draw.rectTex(r, rec, editor.asset_atlas);
    }

    pub fn deinit(vt: *i3DTool, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }

    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        cubeDraw(self, editor, td) catch return error.fatal;
    }

    pub fn guiDoc(_: *i3DTool, os9gui: *Os9Gui, editor: *Editor, vl: *Gui.VerticalLayout) void {
        const hl = os9gui.style.config.text_h;
        vl.pushHeight(hl * 10);
        if (os9gui.textView(hl, 0xff)) |tvc| {
            var tv = tvc;
            tv.text("This is the draw cube tool.", .{});
            tv.text("Left click to start drawing the cube.", .{});
            //os9gui.hr();
            tv.text("To change the z, hold {s} and left click against a surface", .{editor.config.keys.cube_draw_plane_raycast.b.name()});
            tv.text("Or, press {s} or {s} to move the grid up and down", .{
                editor.config.keys.cube_draw_plane_up.b.name(),
                editor.config.keys.cube_draw_plane_down.b.name(),
            });
            tv.text("Left click to finish the cube", .{});
        }
    }

    pub fn doGui(vt: *i3DTool, os9gui: *Os9Gui, editor: *Editor, vl: *Gui.VerticalLayout) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));

        if (editor.asset_browser.selected_mat_vpk_id) |id| {
            os9gui.label("texture: ", .{});
            const bound = os9gui.gui.layout.last_requested_bounds orelse return;
            vl.pushHeight(bound.w / 2);
            const tex = editor.getTexture(id) catch return;
            const area = os9gui.gui.getArea() orelse return;
            os9gui.gui.drawRectTextured(graph.Rec(area.x, area.y, area.h, area.h), 0xffffffff, tex.rect(), tex);

            _ = os9gui.checkbox("Use custom height", &self.use_custom_height);
            if (self.use_custom_height) {
                _ = os9gui.checkbox("Snap", &self.snap_height);
                if (self.snap_height) {
                    const gs: i64 = @intFromFloat(editor.edit_state.grid_snap);
                    const ch: i64 = @intFromFloat(self.custom_height);
                    var h: i64 = std.math.clamp(@divTrunc(ch, gs), 0, 16);
                    os9gui.sliderEx(&h, 1, 16, "Height {d}", .{h * gs});
                    self.custom_height = @floatFromInt(h * gs);
                    //self.custom_height = @intFromFloat(util3d.snap1(@floatFromInt(self.custom_height), editor.edit_state.grid_snap));
                } else {
                    os9gui.sliderEx(&self.custom_height, 1, 1024, "Height", .{});
                }
            }
            os9gui.enumCombo("Advance state to: {s}", .{@tagName(self.post_state)}, &self.post_state) catch return;
        } else {
            os9gui.label("First select a texture by opening texture browser alt+t ", .{});
        }
    }
    pub fn cubeDraw(tool: *@This(), self: *Editor, td: ToolData) !void {
        const draw = td.draw;
        if (td.is_first_frame) { //First frame, reset state
            tool.state = .start;
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
                const plane_up = td.win.isBindState(self.config.keys.cube_draw_plane_up.b, .rising);
                const plane_down = td.win.isBindState(self.config.keys.cube_draw_plane_down.b, .rising);
                const send_raycast = td.win.isBindState(self.config.keys.cube_draw_plane_raycast.b, .high);
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
                    const height = if (tool.use_custom_height) tool.custom_height else snap;
                    const in = snapV3(inter, snap);
                    const cc = cubeFromBounds(tool.start, in.add(Vec3.new(0, 0, height)));
                    draw.cube(cc[0], cc[1], 0xffffff88);

                    if (self.edit_state.lmouse == .rising) {
                        tool.end = in;
                        tool.end.data[2] += height;

                        //Put it into the
                        const new = try self.ecs.createEntity();
                        const newsolid = try Solid.initFromCube(self.alloc, tool.start, tool.end, self.asset_browser.selected_mat_vpk_id orelse 0);
                        try self.ecs.attach(new, .solid, newsolid);
                        try self.ecs.attach(new, .bounding_box, .{});
                        const solid_ptr = try self.ecs.getPtr(new, .solid);
                        try solid_ptr.translate(new, Vec3.zero(), self);
                        {
                            const ustack = try self.undoctx.pushNew();
                            try ustack.append(try undo.UndoCreateDestroy.create(self.undoctx.alloc, new, .create));
                            undo.applyRedo(ustack.items, self);
                        }
                        switch (tool.post_state) {
                            .reset => tool.state = .start,
                            .switch_to_fast_face => {
                                const tid = try self.tools.getToolId(FastFaceManip);
                                self.edit_state.tool_index = tid;
                                self.selection.setToSingle(new);
                            },
                            .switch_to_translate => {
                                const tid = try self.tools.getToolId(Translate);
                                self.edit_state.tool_index = tid;
                                self.selection.setToSingle(new);
                            },
                        }
                    }
                }
            },
        }
    }
};

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
        if (td.is_first_frame)
            self.reset();

        const draw_nd = &editor.draw_state.ctx;
        const selected_slice = editor.selection.getSlice();
        for (selected_slice) |sel| {
            if (try editor.ecs.getOptPtr(sel, .solid)) |solid| {
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
                    const r = editor.camRay(td.screen_area, td.view_3d.*);
                    for (selected_slice) |sel| {
                        const solid = try editor.ecs.getOptPtr(sel, .solid) orelse continue;
                        const rc = try raycast.doesRayIntersectSolid(r[0], r[1], solid, &editor.csgctx);
                        if (rc.len > 0) {
                            const rci = if (editor.edit_state.rmouse == .rising) @min(1, rc.len) else 0;
                            try self.selected.append(.{ .id = sel, .face_id = @intCast(rc[rci].side_index) });
                            self.main_id = sel;

                            self.face_id = @intCast(rc[rci].side_index);
                            self.start = rc[rci].point;
                            self.state = .active;
                            try solid.removeFromMeshMap(sel, editor);

                            const init_plane = solid.sides.items[@intCast(self.face_id)].normal(solid);
                            for (selected_slice) |other| {
                                if (other == sel)
                                    continue;
                                if (try editor.ecs.getOptPtr(other, .solid)) |o_solid| {
                                    for (o_solid.sides.items, 0..) |*side, fi| {
                                        if (init_plane.eql(side.normal(o_solid))) {
                                            try self.selected.append(.{ .id = other, .face_id = @intCast(fi) });
                                            try o_solid.removeFromMeshMap(other, editor);
                                            break; //Only one side per solid can be coplanar
                                        }
                                    }
                                }
                            }
                            break;
                        }
                    }
                }
            },
            .active => {
                //for (self.selected.items) |id| {
                if (self.main_id) |id| {
                    if (try editor.ecs.getOptPtr(id, .solid)) |solid| {
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
                            const u = ray[1];
                            const v_proj = u.sub(plane_norm.scale(u.dot(plane_norm)));
                            // By projecting the cam_norm onto the side's plane,
                            // we can use the resulting vector as a normal for a plane to raycast against
                            // The resulting plane's normal is as colinear with the cameras normal as we can get
                            // while still having the side's normal perpendicular (in the raycast plane)
                            //
                            // If cam_norm and side_norm are colinear the projection is near zero, in the future discard vectors below a threshold as they cause explosions

                            if (util3d.doesRayIntersectPlane(ray[0], ray[1], self.start, v_proj)) |inter| {
                                const dist_n = inter.sub(self.start); //How much of our movement lies along the normal
                                const acc = dist_n.dot(plane_norm);
                                const dist = snapV3(plane_norm.scale(acc), editor.edit_state.grid_snap);

                                for (self.selected.items) |sel| {
                                    const solid_o = try editor.ecs.getOptPtr(sel.id, .solid) orelse continue;
                                    if (sel.face_id >= solid_o.sides.items.len) continue;
                                    const s_io: usize = @intCast(sel.face_id);
                                    const side_o = &solid_o.sides.items[s_io];
                                    solid_o.drawImmediate(td.draw, editor, dist, s_io) catch return;
                                    draw_nd.convexPolyIndexed(side_o.index.items, solid_o.verts.items, 0xff000088, .{ .offset = dist });
                                }

                                const commit_btn = if (self.right) lm else rm;
                                if (commit_btn == .rising) {
                                    const ustack = editor.undoctx.pushNew() catch return;
                                    for (self.selected.items) |sel| {
                                        const solid_o = try editor.ecs.getOptPtr(sel.id, .solid) orelse continue;
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
                                const solid_o = try editor.ecs.getOptPtr(sel.id, .solid) orelse continue;
                                try solid_o.rebuild(sel.id, editor);
                            }
                            self.reset();
                        }
                    }
                }
            },
        }
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

pub const Translate = struct {
    pub threadlocal var tool_id: ToolReg = initToolReg;
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
                .guiDoc_fn = &@This().guiDoc,
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

    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (td.is_first_frame)
            self.gizmo_rotation.reset();

        translate(self, editor, td) catch return error.fatal;
    }

    pub fn guiDoc(_: *i3DTool, os9gui: *Os9Gui, editor: *Editor, vl: *Gui.VerticalLayout) void {
        const hl = os9gui.style.config.text_h;
        vl.pushHeight(hl * 10);
        if (os9gui.textView(hl, 0xff)) |tvc| {
            var tv = tvc;

            tv.text("This is the translate tool.", .{});
            tv.text("Select an object with {s}", .{editor.config.keys.select.b.name()});
            tv.text("While you drag the gizmo, press right click to commit the change.", .{});
            tv.text("Optionally, hold {s} to duplicate the object.", .{editor.config.keys.duplicate.b.name()});
        }
        os9gui.hr();
    }

    pub fn translate(tool: *Translate, self: *Editor, td: ToolData) !void {
        const draw_nd = &self.draw_state.ctx;
        const draw = td.draw;
        const dupe = td.win.isBindState(self.config.keys.duplicate.b, .high);
        const COLOR_MOVE = 0xe8a130_ee;
        const COLOR_DUPE = 0xfc35ac_ee;
        const color: u32 = if (dupe) COLOR_DUPE else COLOR_MOVE;

        const last_id = self.selection.getLast() orelse return;
        var angle: ?Vec3 = null;
        const giz_origin: ?Vec3 = blk: {
            const last_bb = try self.ecs.getOptPtr(last_id, .bounding_box) orelse return;
            if (try self.ecs.getOptPtr(last_id, .solid)) |solid| { //check Solid before Entity
                _ = solid;
                break :blk last_bb.a.add(last_bb.b).scale(0.5);
            } else if (try self.ecs.getOptPtr(last_id, .entity)) |ent| {
                angle = ent.angle;
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
                    td.screen_area.dim(),
                    td.view_3d.*,
                    self.edit_state.mpos,
                );
            };
            const commit = self.edit_state.rmouse == .rising;
            const ustack = if (giz_active == .high and commit) try self.undoctx.pushNew() else null;
            for (self.selection.getSlice()) |id| {
                if (try self.ecs.getOptPtr(id, .solid)) |solid| {
                    solid.drawEdgeOutline(draw_nd, 0xff00ff, 0xff0000ff, Vec3.zero());
                    if (giz_active == .rising) {
                        try solid.removeFromMeshMap(id, self);
                    }
                    if (giz_active == .falling) {
                        try solid.translate(id, Vec3.zero(), self); //Dummy to put it bake in the mesh batch

                        //Draw it here too so we it doesn't flash for a single frame
                        const dist = snapV3(origin_mut.sub(origin), self.edit_state.grid_snap);
                        try solid.drawImmediate(draw, self, dist, null);
                    }

                    if (giz_active == .high) {
                        const dist = snapV3(origin_mut.sub(origin), self.edit_state.grid_snap);
                        try solid.drawImmediate(draw, self, dist, null);
                        if (dupe) { //Draw original
                            try solid.drawImmediate(draw, self, Vec3.zero(), null);
                        }
                        solid.drawEdgeOutline(draw_nd, color, 0xff0000ff, dist);
                        if (commit) {
                            if (dupe) {
                                const new = try self.ecs.createEntity();
                                try self.ecs.destroyEntity(new);

                                try ustack.?.append(try undo.UndoDupe.create(self.undoctx.alloc, id, new));
                                try ustack.?.append(try undo.UndoTranslate.create(
                                    self.undoctx.alloc,
                                    dist,
                                    null,
                                    new,
                                ));
                            } else {
                                try ustack.?.append(try undo.UndoTranslate.create(
                                    self.undoctx.alloc,
                                    dist,
                                    null,
                                    id,
                                ));
                            }
                        }
                    }
                }
                if (try self.ecs.getOptPtr(id, .entity)) |ent| {
                    const bb = try self.ecs.getOptPtr(id, .bounding_box) orelse continue;
                    //TODO put the angle gizmo back
                    //const angle = ent.angle;
                    //TODO the angle function is usable but suboptimal.
                    //the gizmo always manipulates extrinsic angles, rather than relative to current rotation
                    //this is how the angles in the vmf are stored but make for unintuitive editing

                    const del = Vec3.set(1); //Pad the frame so in doesn't get drawn over by ent frame
                    const coo = bb.a.sub(del);
                    draw_nd.cubeFrame(coo, bb.b.sub(coo).add(del), color);
                    if (giz_active == .low and angle != null) {
                        const switcher_sz = origin.distance(self.draw_state.cam3d.pos) / 64 * 5;
                        const orr = origin.add(Vec3.new(0, 0, switcher_sz * 5));
                        const co = orr.sub(Vec3.set(switcher_sz / 2));
                        const ce = Vec3.set(switcher_sz);
                        draw_nd.cube(co, ce, 0xffffff88);
                        const rc = util3d.screenSpaceRay(td.screen_area.dim(), self.edit_state.mpos, td.view_3d.*);
                        if (self.edit_state.lmouse == .rising) {
                            if (util3d.doesRayIntersectBBZ(rc[0], rc[1], co, co.add(ce))) |_| {
                                tool.mode.next();
                            }
                        }
                    }
                    if (giz_active == .high) {
                        const dist = snapV3(origin_mut.sub(origin), self.edit_state.grid_snap);
                        var copy_ent = ent.*;
                        copy_ent.origin = ent.origin.add(dist);
                        copy_ent.angle = angle orelse ent.angle;
                        try copy_ent.drawEnt(self, td.view_3d.*, draw, draw_nd, .{ .frame_color = color, .draw_model_bb = false });

                        if (commit) {
                            const angle_delta = copy_ent.angle.sub(ent.angle);
                            if (dupe) {
                                const new = try self.ecs.createEntity();
                                try self.ecs.destroyEntity(new);

                                try ustack.?.append(try undo.UndoDupe.create(self.undoctx.alloc, id, new));
                                try ustack.?.append(try undo.UndoTranslate.create(
                                    self.undoctx.alloc,
                                    dist,
                                    angle_delta,
                                    new,
                                ));
                            } else {
                                try ustack.?.append(try undo.UndoTranslate.create(
                                    self.undoctx.alloc,
                                    dist,
                                    angle_delta,
                                    id,
                                ));
                            }
                        }
                    }
                }
            }
            if (ustack != null)
                undo.applyRedo(ustack.?.items, self);
        }

        //for(self.selection.getSlice())

        //var do_gizmo = false;
        //var gizmo_origin =

    }
};

pub const TextureTool = struct {
    pub threadlocal var tool_id: ToolReg = initToolReg;
    vt: i3DTool,
    id: ?ecs.EcsT.Id = null,
    face_index: ?u32 = 0,

    //Left click to select a face,
    //right click to apply texture to any face
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

    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.run(td, editor) catch return error.fatal;
    }

    pub fn doGui(vt: *i3DTool, os9gui: *Os9Gui, editor: *Editor, vl: *Gui.VerticalLayout) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        self.doGuiErr(os9gui, editor, vl) catch return;
    }

    pub fn doGuiErr(self: *@This(), os9gui: *Os9Gui, editor: *Editor, vl: *Gui.VerticalLayout) !void {
        _ = vl;
        if (try self.getCurrentlySelected(editor)) |sel| {
            os9gui.label("u", .{});
            try os9gui.textboxNumber(&sel.side.u.scale);
        }
    }

    fn getCurrentlySelected(self: *TextureTool, editor: *Editor) !?struct { solid: *ecs.Solid, side: *ecs.Side } {
        const id = self.id orelse return null;
        const solid = try editor.ecs.getOptPtr(id, .solid) orelse return null;
        if (self.face_index == null or self.face_index.? >= solid.sides.items.len) return null;

        return .{ .solid = solid, .side = &solid.sides.items[self.face_index.?] };
    }

    fn run(self: *TextureTool, td: ToolData, editor: *Editor) !void {
        if (editor.edit_state.lmouse == .rising) {
            const pot = editor.screenRay(td.screen_area, td.view_3d.*);
            if (pot.len > 0) {
                self.id = pot[0].id;
                self.face_index = pot[0].side_id;
            }
        }
        blk: {
            if (editor.edit_state.rmouse == .rising) {
                const dupe = td.win.isBindState(editor.config.keys.duplicate.b, .high);
                const res_id = (editor.asset_browser.selected_mat_vpk_id) orelse break :blk;
                const pot = editor.screenRay(td.screen_area, td.view_3d.*);
                if (pot.len == 0) break :blk;
                const solid = try editor.ecs.getOptPtr(pot[0].id, .solid) orelse break :blk;
                if (pot[0].side_id == null or pot[0].side_id.? >= solid.sides.items.len) break :blk;
                const side = &solid.sides.items[pot[0].side_id.?];
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

                const ustack = try editor.undoctx.pushNew();
                try ustack.append(try undo.UndoTextureManip.create(editor.undoctx.alloc, old, new, pot[0].id, pot[0].side_id.?));
                undo.applyRedo(ustack.items, editor);
            }
        }

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

pub const PlaceModel = struct {
    pub threadlocal var tool_id: ToolReg = initToolReg;
    vt: i3DTool,

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{ .vt = .{
            .deinit_fn = &@This().deinit,
            .runTool_fn = &@This().runTool,
            .tool_icon_fn = &@This().drawIcon,
        } };
        return &obj.vt;
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
        _ = self;
        modelPlace(editor, td) catch return error.fatal;
    }
};

pub const TranslateFace = struct {
    pub threadlocal var tool_id: ToolReg = initToolReg;
    vt: i3DTool,
    gizmo: Gizmo,
    face_id: ?usize = null,
    face_origin: Vec3 = Vec3.zero(),

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{ .vt = .{
            .deinit_fn = &@This().deinit,
            .runTool_fn = &@This().runTool,
            .tool_icon_fn = &@This().drawIcon,
            .guiDoc_fn = &@This().guiDoc,
        }, .gizmo = .{} };
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
        alloc.destroy(self);
    }

    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) ToolError!void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.selection.single_id) |id| {
            faceTranslate(self, editor, id, td) catch return error.fatal;
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
        if (try self.ecs.getOptPtr(id, .solid)) |solid| {
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
                        td.screen_area.dim(),
                        td.view_3d.*,
                        self.edit_state.mpos,
                    );
                    gizmo_is_active = giz_active != .low;
                    if (giz_active == .rising) {
                        try solid.removeFromMeshMap(id, self);
                    }
                    if (giz_active == .falling) {
                        try solid.translate(id, Vec3.zero(), self); //Dummy to put it bake in the mesh batch
                        tool.face_origin = origin;
                    }

                    if (giz_active == .high) {
                        const dist = snapV3(origin.sub(origin_i), self.edit_state.grid_snap);
                        try solid.drawImmediate(td.draw, self, dist, s_i);
                        if (self.edit_state.rmouse == .rising) {
                            //try solid.translateSide(id, dist, self, s_i);
                            const ustack = try self.undoctx.pushNew();
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

pub fn modelPlace(self: *Editor, td: ToolData) !void {
    const model_id = self.asset_browser.selected_model_vpk_id orelse return;
    const omod = self.models.get(model_id);
    if (omod != null and omod.?.mesh != null) {
        const mod = omod.?.mesh.?;
        const pot = self.screenRay(td.screen_area, td.view_3d.*);
        if (pot.len > 0) {
            const p = pot[0];
            const point = snapV3(p.point, self.edit_state.grid_snap);
            const mat1 = graph.za.Mat4.fromTranslate(point);
            //zyx
            //const mat3 = mat1.mul(y1.mul(x1.mul(z)));
            mod.drawSimple(td.view_3d.*, mat1, self.draw_state.basic_shader);
            //Draw the model at
            if (self.edit_state.lmouse == .rising) {
                const new = try self.ecs.createEntity();
                var bb = ecs.AABB{ .a = Vec3.new(0, 0, 0), .b = Vec3.new(16, 16, 16), .origin_offset = Vec3.new(8, 8, 8) };
                bb.origin_offset = mod.hull_min.scale(-1);
                bb.a = mod.hull_min;
                bb.b = mod.hull_max;
                bb.setFromOrigin(point);
                try self.ecs.attach(new, .entity, .{
                    .origin = point,
                    .angle = Vec3.zero(),
                    .class = try self.storeString("prop_static"),
                    .model = null,
                    //.model = if (ent.model.len > 0) try self.storeString(ent.model) else null,
                    .model_id = model_id,
                    .sprite = null,
                });
                try self.ecs.attach(new, .bounding_box, bb);
                const ustack = try self.undoctx.pushNew();
                try ustack.append(try undo.UndoCreateDestroy.create(self.undoctx.alloc, new, .create));
                undo.applyRedo(ustack.items, self);
            }
        }
    }
}
