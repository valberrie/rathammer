const std = @import("std");
const edit = @import("editor.zig");
const graph = @import("graph");
const Editor = edit.Context;
const util3d = @import("util_3d.zig");
const Vec3 = graph.za.Vec3;
const cubeFromBounds = util3d.cubeFromBounds;
const ButtonState = graph.SDL.ButtonState;
const snapV3 = util3d.snapV3;
const Solid = edit.Solid;
const vpk = @import("vpk.zig");
const raycast = @import("raycast_solid.zig");
const undo = @import("undo.zig");
const DrawCtx = graph.ImmediateDrawingContext;
const Gui = graph.Gui;
const Os9Gui = graph.gui_app.Os9Gui;

pub const i3DTool = struct {
    deinit_fn: *const fn (*@This(), std.mem.Allocator) void,
    runTool_fn: *const fn (*@This(), ToolData, *Editor) void,
    guiDoc_fn: ?*const fn (*@This(), *Os9Gui, *Editor) void = null,
    tool_icon_fn: *const fn (*@This(), *DrawCtx, *Editor, graph.Rect) void,
    gui_fn: ?*const fn (*@This(), *Os9Gui, *Editor, *Gui.VerticalLayout) void = null,
};

pub const ToolData = struct {
    view_3d: *const graph.za.Mat4,
    screen_area: graph.Rect,
    draw: *DrawCtx,
    win: *graph.SDL.Window,
    is_first_frame: bool,
};

pub const TranslateInput = struct {
    dupe: bool,
};

pub const CubeDraw = struct {
    vt: i3DTool,

    use_custom_height: bool = false,
    custom_height: u32 = 16,

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

    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        cubeDraw(editor, td) catch return;
    }

    pub fn guiDoc(_: *i3DTool, os9gui: *Os9Gui, editor: *Editor) void {
        os9gui.label("This is the draw cube tool.", .{});
        os9gui.label("Left click to start drawing the cube.", .{});
        os9gui.hr();
        os9gui.label("To change the z, hold {s} and left click", .{editor.config.keys.cube_draw_plane_raycast.b.name()});
        os9gui.label("Or, press {s} or {s} to move up and down", .{
            editor.config.keys.cube_draw_plane_up.b.name(),
            editor.config.keys.cube_draw_plane_down.b.name(),
        });
    }

    pub fn doGui(vt: *i3DTool, os9gui: *Os9Gui, editor: *Editor, vl: *Gui.VerticalLayout) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (editor.asset_browser.selected_mat_vpk_id) |id| {
            os9gui.label("texture: ", .{});
            const bound = os9gui.gui.layout.last_requested_bounds orelse return;
            vl.pushHeight(bound.w / 2);
            const tex = editor.getTexture(id);
            const area = os9gui.gui.getArea() orelse return;
            os9gui.gui.drawRectTextured(area, 0xffffffff, tex.rect(), tex);

            _ = os9gui.checkbox("Use custom height", &self.use_custom_height);
            if (self.use_custom_height) {
                os9gui.sliderEx(&self.custom_height, 1, 512, "Height", .{});
                self.custom_height = @intFromFloat(util3d.snap1(@floatFromInt(self.custom_height), editor.edit_state.grid_snap));
            }
            os9gui.label("This stuff doesn't actually work", .{});
        } else {
            os9gui.label("First select a texture by opening texture browser alt+t ", .{});
        }
    }
};

pub const FastFaceManip = struct {
    vt: i3DTool,

    state: enum {
        start,
        active,
    } = .start,
    face_id: i32 = -1,
    start: Vec3 = Vec3.zero(),

    fn reset(self: *@This()) void {
        self.face_id = -1;
        self.state = .start;
    }

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{ .vt = .{
            .deinit_fn = &@This().deinit,
            .runTool_fn = &@This().runTool,
            .tool_icon_fn = &@This().drawIcon,
            .guiDoc_fn = &@This().guiDoc,
        } };
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
        alloc.destroy(self);
    }

    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        if (td.is_first_frame)
            self.reset();

        const id = (editor.edit_state.id) orelse return;
        const solid = editor.ecs.getOptPtr(id, .solid) catch return orelse return;
        const draw_nd = &editor.draw_state.ctx;
        solid.drawEdgeOutline(draw_nd, 0xf7a94a8f, 0xff0000ff, Vec3.zero());
        const rm = editor.edit_state.rmouse;
        const lm = editor.edit_state.lmouse;
        switch (self.state) {
            .start => {
                if (rm == .rising or lm == .rising) {
                    const r = editor.camRay(td.screen_area, td.view_3d.*);
                    const rc = raycast.doesRayIntersectSolid(r[0], r[1], solid, &editor.csgctx) catch return;
                    if (rc.len > 0) {
                        const rci = if (editor.edit_state.rmouse == .rising) @min(1, rc.len) else 0;
                        self.face_id = @intCast(rc[rci].side_index);
                        self.start = rc[rci].point;
                        self.state = .active;
                    }
                }
            },
            .active => {
                for (solid.sides.items, 0..) |side, s_i| {
                    if (self.face_id == s_i) {
                        draw_nd.convexPolyIndexed(side.index.items, solid.verts.items, 0xff000088);
                        //Side_normal
                        //self.start
                        if (side.index.items.len < 3) return;
                        const ind = side.index.items;
                        const ver = solid.verts.items;
                        const plane_norm = util3d.trianglePlane([3]Vec3{ ver[ind[0]], ver[ind[1]], ver[ind[2]] });
                        const r = editor.camRay(td.screen_area, td.view_3d.*);
                        const u = r[1];
                        const proj = u.sub(plane_norm.scale(u.dot(plane_norm)));

                        if (util3d.doesRayIntersectPlane(r[0], r[1], self.start, proj)) |inter| {
                            td.draw.point3D(inter, 0xff0000ff);
                            const cc = util3d.cubeFromBounds(self.start, inter);
                            td.draw.cube(cc[0], cc[1], 0xff00ffff);
                        }
                    }
                }
                if (rm != .high and lm != .high)
                    self.reset();
            },
        }
    }

    pub fn guiDoc(_: *i3DTool, os9gui: *Os9Gui, editor: *Editor) void {
        os9gui.label("This is the Fast face tool.", .{});
        os9gui.hr();
        _ = editor;
    }
};

pub const Translate = struct {
    vt: i3DTool,

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{ .vt = .{
            .deinit_fn = &@This().deinit,
            .runTool_fn = &@This().runTool,
            .tool_icon_fn = &@This().drawIcon,
            .guiDoc_fn = &@This().guiDoc,
        } };
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

    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        if (editor.edit_state.id) |id| {
            translate(editor, id, td) catch return;
        }
    }

    pub fn guiDoc(_: *i3DTool, os9gui: *Os9Gui, editor: *Editor) void {
        os9gui.label("This is the translate tool.", .{});
        os9gui.label("Select an object with {s}", .{editor.config.keys.select.b.name()});
        os9gui.label("While you drag the gizmo, press right click to commit the change.", .{});
        os9gui.label("Optionally, hold {s} to duplicate the object.", .{editor.config.keys.duplicate.b.name()});
        os9gui.hr();
    }
};

pub const PlaceModel = struct {
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

    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        modelPlace(editor, td) catch return;
    }
};

pub const TranslateFace = struct {
    vt: i3DTool,

    pub fn create(alloc: std.mem.Allocator) !*i3DTool {
        var obj = try alloc.create(@This());
        obj.* = .{ .vt = .{
            .deinit_fn = &@This().deinit,
            .runTool_fn = &@This().runTool,
            .tool_icon_fn = &@This().drawIcon,
            .guiDoc_fn = &@This().guiDoc,
        } };
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

    pub fn runTool(vt: *i3DTool, td: ToolData, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        _ = self;
        if (editor.edit_state.id) |id| {
            faceTranslate(editor, id, td) catch return;
        }
    }

    pub fn guiDoc(_: *i3DTool, os9gui: *Os9Gui, editor: *Editor) void {
        os9gui.label("This is the face translate tool.", .{});
        os9gui.label("Select a solid with {s}", .{editor.config.keys.select.b.name()});
        os9gui.label("left click selects the near face.", .{});
        os9gui.label("right click selects the far face.", .{});
        os9gui.label("Once you drag the gizmo, press right click to commit the change.", .{});
    }
};

//TODO tools should be virtual functions
//Combined with the new ecs it would allow for dynamic linking of new tools and components

pub fn translate(self: *Editor, selected_id: edit.EcsT.Id, td: ToolData) !void {
    const id = selected_id;
    const draw_nd = &self.draw_state.ctx;
    const draw = td.draw;
    const dupe = td.win.isBindState(self.config.keys.duplicate.b, .high);
    const bb = try self.ecs.getOptPtr(id, .bounding_box) orelse return;
    const COLOR_MOVE = 0xe8a130_ee;
    const COLOR_DUPE = 0xfc35ac_ee;
    const color: u32 = if (dupe) COLOR_DUPE else COLOR_MOVE;
    if (try self.ecs.getOptPtr(id, .solid)) |solid| {
        const mid_i = bb.a.add(bb.b).scale(0.5);
        var mid = mid_i;
        const giz_active = self.edit_state.gizmo.handle(
            mid,
            &mid,
            self.draw_state.cam3d.pos,
            self.edit_state.lmouse,
            draw_nd,
            td.screen_area.dim(),
            td.view_3d.*,
            self.edit_state.trans_begin,
        );

        solid.drawEdgeOutline(draw_nd, 0xff00ff, 0xff0000ff, Vec3.zero());
        if (giz_active == .rising) {
            try solid.removeFromMeshMap(id, self);
        }
        if (giz_active == .falling) {
            try solid.translate(id, Vec3.zero(), self); //Dummy to put it bake in the mesh batch

            //Draw it here too so we it doesn't flash for a single frame
            const dist = snapV3(mid.sub(mid_i), self.edit_state.grid_snap);
            try solid.drawImmediate(draw, self, dist, null);
        }

        if (giz_active == .high) {
            const dist = snapV3(mid.sub(mid_i), self.edit_state.grid_snap);
            try solid.drawImmediate(draw, self, dist, null);
            if (dupe) { //Draw original
                try solid.drawImmediate(draw, self, Vec3.zero(), null);
            }
            solid.drawEdgeOutline(draw_nd, color, 0xff0000ff, dist);
            if (self.edit_state.rmouse == .rising) {
                if (dupe) {
                    const new = try self.ecs.createEntity();
                    try self.ecs.destroyEntity(new);

                    const ustack = try self.undoctx.pushNew();
                    try ustack.append(try undo.UndoDupe.create(self.undoctx.alloc, id, new));
                    try ustack.append(try undo.UndoTranslate.create(
                        self.undoctx.alloc,
                        dist,
                        new,
                    ));
                    undo.applyRedo(ustack.items, self);
                } else {
                    const ustack = try self.undoctx.pushNew();
                    try ustack.append(try undo.UndoTranslate.create(
                        self.undoctx.alloc,
                        dist,
                        id,
                    ));
                    undo.applyRedo(ustack.items, self);
                }
            }
        }
    }
    if (try self.ecs.getOptPtr(id, .entity)) |ent| {
        var orig = ent.origin;
        const giz_active = self.edit_state.gizmo.handle(
            orig,
            &orig,
            self.draw_state.cam3d.pos,
            self.edit_state.lmouse,
            draw_nd,
            td.screen_area.dim(),
            td.view_3d.*,
            self.edit_state.trans_begin,
        );
        if (giz_active == .high) {
            const orr = snapV3(orig, self.edit_state.grid_snap);
            const dist = snapV3(orig.sub(ent.origin), self.edit_state.grid_snap);
            var copy_ent = ent.*;
            copy_ent.origin = orr;
            copy_ent.drawEnt(self, td.view_3d.*, draw, draw_nd, .{ .frame_color = color, .draw_model_bb = true });

            //draw.cube(orr, Vec3.new(16, 16, 16), 0xff000022);
            if (self.edit_state.rmouse == .rising) {
                if (dupe) {
                    const new = try self.ecs.createEntity();
                    try self.ecs.destroyEntity(new);

                    const ustack = try self.undoctx.pushNew();
                    try ustack.append(try undo.UndoDupe.create(self.undoctx.alloc, id, new));
                    try ustack.append(try undo.UndoTranslate.create(
                        self.undoctx.alloc,
                        dist,
                        new,
                    ));
                    undo.applyRedo(ustack.items, self);
                } else {
                    const ustack = try self.undoctx.pushNew();
                    try ustack.append(try undo.UndoTranslate.create(
                        self.undoctx.alloc,
                        dist,
                        id,
                    ));
                    undo.applyRedo(ustack.items, self);
                }
            }
        }
    }
}

pub fn faceTranslate(self: *Editor, id: edit.EcsT.Id, td: ToolData) !void {
    const draw_nd = &self.draw_state.ctx;
    if (try self.ecs.getOptPtr(id, .solid)) |solid| {
        var gizmo_is_active = false;
        solid.drawEdgeOutline(draw_nd, 0xf7a94a8f, 0xff0000ff, Vec3.zero());
        for (solid.sides.items, 0..) |side, s_i| {
            if (self.edit_state.face_id == s_i) {
                draw_nd.convexPolyIndexed(side.index.items, solid.verts.items, 0xff000088);
                const origin_i = self.edit_state.face_origin;
                var origin = origin_i;
                const giz_active = self.edit_state.gizmo.handle(
                    origin,
                    &origin,
                    self.draw_state.cam3d.pos,
                    self.edit_state.lmouse,
                    draw_nd,
                    td.screen_area.dim(),
                    td.view_3d.*,
                    self.edit_state.trans_begin,
                );
                gizmo_is_active = giz_active != .low;
                if (giz_active == .rising) {
                    try solid.removeFromMeshMap(id, self);
                }
                if (giz_active == .falling) {
                    try solid.translate(id, Vec3.zero(), self); //Dummy to put it bake in the mesh batch
                    self.edit_state.face_origin = origin;
                }

                if (giz_active == .high) {
                    const dist = snapV3(origin.sub(origin_i), self.edit_state.grid_snap);
                    try solid.drawImmediate(
                        td.draw,
                        self,
                        dist,
                        s_i,
                    );
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
                        self.edit_state.face_origin = origin;
                        self.edit_state.gizmo.start = origin;
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
                self.edit_state.face_id = rc[rci].side_index;
                self.edit_state.face_origin = rc[rci].point;
            }
        }
    }
}

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
                var bb = edit.AABB{ .a = Vec3.new(0, 0, 0), .b = Vec3.new(16, 16, 16), .origin_offset = Vec3.new(8, 8, 8) };
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
                try ustack.append(try undo.UndoCreate.create(self.undoctx.alloc, new));
                undo.applyRedo(ustack.items, self);
            }
        }
    }
}

pub const CubeDrawInput = struct {
    plane_up: bool,
    plane_down: bool,
    send_raycast: bool,
};

pub fn cubeDraw(self: *Editor, td: ToolData) !void {
    const draw = td.draw;
    const st = &self.edit_state.cube_draw;
    if (td.is_first_frame) { //First frame, reset state
        st.state = .start;
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
    switch (st.state) {
        .start => {
            const plane_up = td.win.isBindState(self.config.keys.cube_draw_plane_up.b, .rising);
            const plane_down = td.win.isBindState(self.config.keys.cube_draw_plane_down.b, .rising);
            const send_raycast = td.win.isBindState(self.config.keys.cube_draw_plane_raycast.b, .high);
            if (plane_up)
                st.plane_z += snap;
            if (plane_down)
                st.plane_z -= snap;
            if (send_raycast) {
                const pot = self.screenRay(td.screen_area, td.view_3d.*);
                if (pot.len > 0) {
                    const inter = pot[0].point;
                    const cc = snapV3(inter, snap);
                    helper.drawGrid(inter, cc.z(), draw, snap, 11);
                    if (self.edit_state.lmouse == .rising) {
                        st.plane_z = cc.z();
                    }
                }
            } else if (util3d.doesRayIntersectPlane(ray[0], ray[1], Vec3.new(0, 0, st.plane_z), Vec3.new(0, 0, 1))) |inter| {
                //user has a xy plane
                //can reposition using keys or doing a raycast into world
                helper.drawGrid(inter, st.plane_z, draw, snap, 11);

                const cc = snapV3(inter, snap);
                draw.point3D(cc, 0xff0000ee);

                if (self.edit_state.lmouse == .rising) {
                    st.start = cc;
                    st.state = .planar;
                }
            }
        },
        .planar => {
            if (util3d.doesRayIntersectPlane(ray[0], ray[1], Vec3.new(0, 0, st.plane_z), Vec3.new(0, 0, 1))) |inter| {
                helper.drawGrid(inter, st.plane_z, draw, snap, 11);
                const in = snapV3(inter, snap);
                const cc = cubeFromBounds(st.start, in.add(Vec3.new(0, 0, snap)));
                draw.cube(cc[0], cc[1], 0xffffff88);

                if (self.edit_state.lmouse == .rising) {
                    st.state = .cubic;
                    st.end = in;
                    st.end.data[2] += snap;

                    //Put it into the
                    const new = try self.ecs.createEntity();
                    const newsolid = try Solid.initFromCube(self.alloc, st.start, st.end, self.asset_browser.selected_mat_vpk_id orelse 0);
                    try self.ecs.attach(new, .solid, newsolid);
                    try self.ecs.attach(new, .bounding_box, .{});
                    const solid_ptr = try self.ecs.getPtr(new, .solid);
                    try solid_ptr.translate(new, Vec3.zero(), self);
                    {
                        const ustack = try self.undoctx.pushNew();
                        try ustack.append(try undo.UndoCreate.create(self.undoctx.alloc, new));
                        undo.applyRedo(ustack.items, self);
                    }
                }
            }
        },
        .cubic => {
            //const cc = cubeFromBounds(st.start, st.end);
            //draw.cube(cc[0], cc[1], 0xffffff88);
            //draw.cube(st.start, st.end.sub(st.start), 0xffffffee);
        },
    }
}
