const std = @import("std");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const Mat4 = graph.za.Mat4;
const SparseSet = graph.SparseSet;
const meshutil = graph.meshutil;
const vmf = @import("vmf.zig");
const vdf = @import("vdf.zig");
const vpk = @import("vpk.zig");
const csg = @import("csg.zig");
const vtf = @import("vtf.zig");
const fgd = @import("fgd.zig");
const vvd = @import("vvd.zig");
const gameinfo = @import("gameinfo.zig");
const profile = @import("profile.zig");
const Gui = graph.Gui;
const StringStorage = @import("string.zig").StringStorage;
const Skybox = @import("skybox.zig").Skybox;
const Gizmo = @import("gizmo.zig").Gizmo;
const raycast = @import("raycast_solid.zig");
const DrawCtx = graph.ImmediateDrawingContext;
const texture_load_thread = @import("texture_load_thread.zig");
const assetbrowse = @import("asset_browser.zig");
const Conf = @import("config.zig");
const undo = @import("undo.zig");
const tool_def = @import("tools.zig");
const util = @import("util.zig");
const Autosaver = @import("autosave.zig").Autosaver;
const NotifyCtx = @import("notify.zig").NotifyCtx;
const Selection = @import("selection.zig");

const util3d = @import("util_3d.zig");

pub const ResourceId = struct {
    vpk_id: vpk.VpkResId,
};

export fn saveFileCallback(udo: ?*anyopaque, filelist: [*c]const [*c]const u8, index: c_int) void {
    if (udo) |ud| {
        const editor: *Context = @alignCast(@ptrCast(ud));

        editor.file_selection.mutex.lock();
        defer editor.file_selection.mutex.unlock();

        if (filelist == 0 or filelist[0] == 0) {
            editor.file_selection.has_file = .failed;
            return;
        }

        const first = std.mem.span(filelist[0]);
        if (first.len == 0) {
            editor.file_selection.has_file = .failed;
            return;
        }

        editor.file_selection.file_buf.clearRetainingCapacity();
        editor.file_selection.file_buf.appendSlice(first) catch return;
        editor.file_selection.has_file = .has;
    }
    _ = index;
}

const JsonCamera = struct {
    yaw: f32,
    pitch: f32,
    move_speed: f32,
    fov: f32,
    pos: Vec3,

    pub fn fromCam(cam: graph.Camera3D) @This() {
        return .{
            .yaw = cam.yaw,
            .pitch = cam.pitch,
            .move_speed = cam.move_speed,
            .fov = cam.fov,
            .pos = cam.pos,
        };
    }

    pub fn setCam(self: @This(), cam: *graph.Camera3D) void {
        const info = @typeInfo(@This());
        inline for (info.Struct.fields) |f| {
            @field(cam, f.name) = @field(self, f.name);
        }
    }
};

const JsonEditor = struct {
    cam: JsonCamera,
};

pub threadlocal var mesh_build_time = profile.BasicProfiler.init();
pub const MeshBatch = struct {
    const Self = @This();
    tex: graph.Texture,
    tex_res_id: vpk.VpkResId,
    mesh: meshutil.Mesh,
    contains: std.AutoHashMap(EcsT.Id, void),
    is_dirty: bool = false,

    notify_vt: texture_load_thread.DeferredNotifyVtable,
    // Each batch needs to keep track of:
    // needs_rebuild
    // contained_solids:ent_id

    pub fn deinit(self: *@This()) void {
        self.mesh.deinit();
        //self.tex.deinit();
        self.contains.deinit();
    }

    pub fn rebuildIfDirty(self: *Self, editor: *Context) !void {
        if (self.is_dirty) {
            self.is_dirty = false;
            return self.rebuild(editor);
        }
    }

    pub fn notify(vt: *texture_load_thread.DeferredNotifyVtable, id: vpk.VpkResId, editor: *Context) void {
        const self: *@This() = @alignCast(@fieldParentPtr("notify_vt", vt));
        if (id == self.tex_res_id) {
            self.tex = (editor.textures.get(id) orelse return);
            self.mesh.diffuse_texture = self.tex.id;
            self.is_dirty = true;
        }
    }

    pub fn rebuild(self: *Self, editor: *Context) !void {
        //Clear self.mesh
        //For solid in contains:
        //for side in solid:
        //if side.texid == this.tex_id
        //  rebuild
        self.mesh.clearRetainingCapacity();
        var it = self.contains.iterator();
        while (it.next()) |id| {
            if (editor.ecs.getOptPtr(id.key_ptr.*, .solid) catch null) |solid| {
                for (solid.sides.items) |*side| {
                    if (side.tex_id == self.tex_res_id) {
                        try side.rebuild(solid, self, editor);
                    }
                }
            }
            if (editor.ecs.getOptPtr(id.key_ptr.*, .displacement) catch null) |disp| {
                try disp.rebuild(self, editor);
            }
        }
        self.mesh.setData();
    }
};
/// Solid mesh storage:
/// Solids are stored as entities in the ecs.
/// The actual mesh data is stored in `Meshmap'.
/// There is one MeshBatch per material. So if there are n materials in use by a map we have n draw calls regardless of the number of solids.
/// This means that modifying a solids verticies or uvs requires the rebuilding of any mesh batches the solid's materials use.
///
/// Every MeshBatch has a hashset 'contains' which stores the ecs ids of all solids it contains
pub const MeshMap = std.AutoHashMap(vpk.VpkResId, *MeshBatch);
pub const Side = struct {
    pub const UVaxis = struct {
        axis: Vec3 = Vec3.zero(),
        trans: f32 = 0,
        scale: f32 = 0.25,
    };
    //Used to disable when a displacment is created on a side
    omit_from_batch: bool = false,
    index: std.ArrayList(u32) = undefined,
    u: UVaxis = .{},
    v: UVaxis = .{},
    tex_id: vpk.VpkResId = 0,
    tw: i32 = 0,
    th: i32 = 0,

    /// This field is allocated by StringStorage.
    /// It is only used to keep track of textures that are missing, so they are persisted across save/load.
    /// the actual material assigned is stored in `tex_id`
    material: []const u8 = "",
    pub fn deinit(self: @This()) void {
        self.index.deinit();
    }

    pub fn rebuild(side: *@This(), solid: *Solid, batch: *MeshBatch, editor: *Context) !void {
        if (side.omit_from_batch)
            return;
        side.tex_id = batch.tex_res_id;
        side.tw = batch.tex.w;
        side.th = batch.tex.h;
        const mesh = &batch.mesh;

        try mesh.vertices.ensureUnusedCapacity(side.index.items.len);

        const uvs = try editor.csgctx.calcUVCoordsIndexed(
            solid.verts.items,
            side.index.items,
            side.*,
            @intCast(batch.tex.w),
            @intCast(batch.tex.h),
        );
        const offset = mesh.vertices.items.len;
        for (side.index.items, 0..) |v_i, i| {
            const v = solid.verts.items[v_i];
            try mesh.vertices.append(.{
                .x = v.x(),
                .y = v.y(),
                .z = v.z(),
                .u = uvs[i].x(),
                .v = uvs[i].y(),
                .nx = 0,
                .ny = 0,
                .nz = 0,
                .color = 0xffffffff,
            });
        }
        const indexs = try editor.csgctx.triangulateIndex(@intCast(side.index.items.len), @intCast(offset));
        try mesh.indicies.appendSlice(indexs);
    }

    pub fn serial(self: @This(), editor: *Context, jw: anytype) !void {
        try jw.beginObject();
        {
            try jw.objectField("index");
            try editor.writeComponentToJson(jw, self.index);
            try jw.objectField("u");
            try editor.writeComponentToJson(jw, self.u);
            try jw.objectField("v");
            try editor.writeComponentToJson(jw, self.v);
            try jw.objectField("tex_id");
            try editor.writeComponentToJson(jw, self.tex_id);
        }
        try jw.endObject();
    }
};

pub const AABB = struct {
    a: Vec3 = Vec3.zero(),
    b: Vec3 = Vec3.zero(),

    origin_offset: Vec3 = Vec3.zero(),

    pub fn setFromOrigin(self: *@This(), new_origin: Vec3) void {
        const delta = new_origin.sub(self.a.add(self.origin_offset));
        self.a = self.a.add(delta);
        self.b = self.b.add(delta);
    }

    pub fn initFromJson(_: std.json.Value, _: anytype) !@This() {
        return error.notAllowed;
    }
};

pub const Displacement = struct {
    const Self = @This();
    verts: std.ArrayList(Vec3) = undefined,
    index: std.ArrayList(u32) = undefined,
    tex_id: vpk.VpkResId = 0,
    parent_id: EcsT.Id = 0,
    parent_side_i: usize = 0,
    power: u32 = 0,

    pub fn init(alloc: std.mem.Allocator, tex_id: vpk.VpkResId, parent_: EcsT.Id, parent_s: usize, dispinfo: *const vmf.DispInfo) Self {
        return .{
            .verts = std.ArrayList(Vec3).init(alloc),
            .index = std.ArrayList(u32).init(alloc),
            .tex_id = tex_id,
            .parent_id = parent_,
            .parent_side_i = parent_s,
            .power = @intCast(dispinfo.power),
        };
    }

    pub fn deinit(self: *Self) void {
        self.verts.deinit();
        self.index.deinit();
    }

    pub fn rebuild(self: *Self, batch: *MeshBatch, editor: *Context) !void {
        self.tex_id = batch.tex_res_id;
        const solid = try editor.ecs.getOptPtr(self.parent_id, .solid) orelse return;
        if (self.parent_side_i >= solid.sides.items.len) return;
        const side = &solid.sides.items[self.parent_side_i];
        const mesh = &batch.mesh;
        try mesh.vertices.ensureUnusedCapacity(self.verts.items.len);
        try mesh.indicies.ensureUnusedCapacity(self.index.items.len);
        const uvs = try editor.csgctx.calcUVCoords(
            solid.verts.items,
            side.*,
            @intCast(batch.tex.w),
            @intCast(batch.tex.h),
        );
        const vper_row = std.math.pow(u32, 2, self.power) + 1;
        const t = 1.0 / (@as(f32, @floatFromInt(vper_row)) - 1);
        const offset = mesh.vertices.items.len;
        if (self.verts.items.len != vper_row * vper_row) return;
        const uv0 = uvs[1];
        const uv1 = uvs[2];
        const uv2 = uvs[0];
        const uv3 = uvs[3];

        for (self.verts.items, 0..) |v, i| {
            const ri: f32 = @floatFromInt(i / vper_row);
            const ci: f32 = @floatFromInt(i % vper_row);

            const inter0 = uv0.lerp(uv1, ri * t);
            const inter1 = uv2.lerp(uv3, ri * t);
            const uv = inter0.lerp(inter1, ci * t);

            try mesh.vertices.append(.{
                .x = v.x(),
                .y = v.y(),
                .z = v.z(),
                .u = uv.x(),
                .v = uv.y(),
                .nx = 0,
                .ny = 0,
                .nz = 0,
                .color = 0xffffffff,
            });
        }
        for (self.index.items) |ind| {
            try mesh.indicies.append(ind + @as(u32, @intCast(offset)));
        }
    }
};

pub const Solid = struct {
    const Self = @This();
    sides: std.ArrayList(Side) = undefined,
    verts: std.ArrayList(Vec3) = undefined,
    parent_entity: ?EcsT.Id = null,

    /// Bounding box is used during broad phase ray tracing
    /// they are recomputed along with vertex arrays
    pub fn init(alloc: std.mem.Allocator) Solid {
        return .{ .sides = std.ArrayList(Side).init(alloc), .verts = std.ArrayList(Vec3).init(alloc) };
    }

    //pub fn initFromJson(v: std.json.Value, editor: *Context) !@This() {
    //    //var ret = init(editor.alloc);
    //    return editor.readComponentFromJson(v, Self);
    //}

    pub fn dupe(self: *const Self) !Self {
        const ret_sides = try self.sides.clone();
        for (ret_sides.items) |*side| {
            const ind = try side.index.clone();
            side.index = ind;
        }
        return .{
            .sides = ret_sides,
            .verts = try self.verts.clone(),
        };
    }

    pub fn initFromCube(alloc: std.mem.Allocator, v1: Vec3, v2: Vec3, tex_id: vpk.VpkResId) !Solid {
        var ret = init(alloc);
        //const Va = std.ArrayList(Vec3);
        //const Ia = std.ArrayList(u32);
        const cc = util3d.cubeFromBounds(v1, v2);
        const N = Vec3.new;
        const o = cc[0];
        const e = cc[1];
        const verts = [8]Vec3{
            o.add(N(0, 0, 0)),
            o.add(N(e.x(), 0, 0)),
            o.add(N(e.x(), e.y(), 0)),
            o.add(N(0, e.y(), 0)),

            o.add(N(0, 0, e.z())),
            o.add(N(e.x(), 0, e.z())),
            o.add(N(e.x(), e.y(), e.z())),
            o.add(N(0, e.y(), e.z())),
        };
        const vis = [6][4]u32{
            .{ 0, 1, 2, 3 }, //-z
            .{ 7, 6, 5, 4 }, //+z
            //
            .{ 3, 7, 4, 0 }, //-x
            .{ 5, 6, 2, 1 }, //+x
            //
            .{ 4, 5, 1, 0 }, //-y
            .{ 6, 7, 3, 2 }, //+y
        };
        const Uvs = [6][2]Vec3{
            .{ N(1, 0, 0), N(0, 1, 0) },
            .{ N(1, 0, 0), N(0, -1, 0) },
            .{ N(0, -1, 0), N(0, 0, -1) },

            .{ N(0, 1, 0), N(0, 0, -1) },
            .{ N(1, 0, 0), N(0, 0, -1) },
            .{ N(-1, 0, 0), N(0, 0, -1) },
        };
        try ret.verts.appendSlice(&verts);
        for (vis, 0..) |face, i| {
            var ind = std.ArrayList(u32).init(alloc);
            //try ind.appendSlice(&.{ 1, 2, 0, 2, 3, 0 });

            try ind.appendSlice(&face);
            try ret.sides.append(.{
                .index = ind,
                .u = .{ .axis = Uvs[i][0], .trans = 0, .scale = 0.25 },
                .v = .{ .axis = Uvs[i][1], .trans = 0, .scale = 0.25 },
                .material = "",
                .tex_id = tex_id,
            });
        }
        return ret;
    }

    pub fn deinit(self: *Self) void {
        for (self.sides.items) |side|
            side.deinit();
        self.sides.deinit();
        self.verts.deinit();
    }

    pub fn recomputeBounds(self: *Self, aabb: *AABB) void {
        var min = Vec3.set(std.math.floatMax(f32));
        var max = Vec3.set(-std.math.floatMax(f32));
        for (self.verts.items) |s| {
            min = min.min(s);
            max = max.max(s);
        }
        aabb.a = min;
        aabb.b = max;
    }

    pub fn translateSide(self: *@This(), id: EcsT.Id, vec: Vec3, editor: *Context, side_i: usize) !void {
        if (side_i >= self.sides.items.len) return;
        for (self.sides.items[side_i].index.items) |ind| {
            self.verts.items[ind] = self.verts.items[ind].add(vec);
        }

        for (self.sides.items) |*side| {
            const batch = editor.meshmap.getPtr(side.tex_id) orelse continue;
            batch.*.is_dirty = true;

            //ensure this is in batch
            try batch.*.contains.put(id, {});
        }
        const bb = (try editor.ecs.getPtr(id, .bounding_box));
        self.recomputeBounds(bb);
        editor.draw_state.meshes_dirty = true;
    }

    pub fn rebuild(self: *@This(), id: EcsT.Id, editor: *Context) !void {
        for (self.sides.items) |*side| {
            const batch = try editor.getOrPutMeshBatch(side.tex_id);
            batch.*.is_dirty = true;
            //ensure this is in batch
            try batch.*.contains.put(id, {});
        }
        const bb = try editor.ecs.getPtr(id, .bounding_box);
        self.recomputeBounds(bb);
        editor.draw_state.meshes_dirty = true;
    }

    pub fn translate(self: *@This(), id: EcsT.Id, vec: Vec3, editor: *Context) !void {
        //move all verts, recompute bounds
        //for each batchid, call rebuild

        for (self.verts.items) |*vert| {
            vert.* = vert.add(vec);
        }
        for (self.sides.items) |*side| {
            side.u.trans = side.u.trans - (vec.dot(side.u.axis)) / side.u.scale;
            side.v.trans = side.v.trans - (vec.dot(side.v.axis)) / side.v.scale;
        }
        try self.rebuild(id, editor);
        editor.draw_state.meshes_dirty = true;
    }

    pub fn removeFromMeshMap(self: *Self, id: EcsT.Id, editor: *Context) !void {
        for (self.sides.items) |side| {
            const batch = editor.meshmap.getPtr(side.tex_id) orelse continue;
            batch.*.is_dirty = true;
            _ = batch.*.contains.remove(id);
        }
        editor.draw_state.meshes_dirty = true;
    }

    pub fn drawEdgeOutline(self: *Self, draw: *DrawCtx, edge_color: u32, point_color: u32, vec: Vec3) void {
        const v = self.verts.items;
        for (self.sides.items) |side| {
            if (side.index.items.len < 3) continue;
            const ind = side.index.items;

            var last = v[ind[ind.len - 1]].add(vec);
            for (0..ind.len) |ti| {
                const p = v[ind[ti]].add(vec);
                if (edge_color > 0)
                    draw.line3D(last, p, edge_color);
                if (point_color > 0)
                    draw.point3D(p, point_color);
                last = p;
            }
        }
    }

    //messy but if side_i is not null, offset only applies to that face
    pub fn drawImmediate(self: *Self, draw: *DrawCtx, editor: *Context, offset: Vec3, side_i: ?usize) !void {
        if (side_i orelse 0 >= self.sides.items.len) return;
        for (self.sides.items) |side| {
            const batch = &(draw.getBatch(.{ .batch_kind = .billboard, .params = .{
                .shader = DrawCtx.billboard_shader,
                .texture = (try editor.getTexture(side.tex_id)).id,
                .camera = ._3d,
            } }) catch return).billboard;
            //try batch.vertices.ensureUnusedCapacity(side.verts.items.len);
            //try batch.indicies.ensureUnusedCapacity(side.index.items.len);
            const uvs = try editor.csgctx.calcUVCoordsIndexed(
                self.verts.items,
                side.index.items,
                side,
                @intCast(side.tw),
                @intCast(side.th),
            );
            const ioffset = batch.vertices.items.len;
            for (side.index.items, 0..) |vi, i| {
                const v = self.verts.items[vi];

                var off = offset;
                if (side_i) |s| {
                    if (std.mem.indexOfScalar(u32, self.sides.items[s].index.items, vi) == null)
                        off = Vec3.zero();
                }
                try batch.vertices.append(.{
                    .pos = .{
                        .x = v.x() + off.x(),
                        .y = v.y() + off.y(),
                        .z = v.z() + off.z(),
                    },
                    .uv = .{
                        .x = uvs[i].x(),
                        .y = uvs[i].y(),
                    },
                    .color = 0xffffffff,
                });
            }
            const indexs = try editor.csgctx.triangulateIndex(@intCast(side.index.items.len), @intCast(ioffset));
            try batch.indicies.appendSlice(indexs);
        }
    }
};

pub const Entity = struct {
    origin: Vec3 = Vec3.zero(),
    angle: Vec3 = Vec3.zero(),
    class: []const u8 = "",
    model: ?[]const u8 = null,
    model_id: ?vpk.VpkResId = null,
    sprite: ?vpk.VpkResId = null,

    pub fn dupe(self: *const @This()) @This() {
        return self.*;
    }

    pub fn drawEnt(ent: *@This(), editor: *Context, view_3d: Mat4, draw: *DrawCtx, draw_nd: *DrawCtx, param: struct {
        frame_color: u32 = 0x00ff00ff,
        draw_model_bb: bool = false,
    }) !void {
        const ENT_RENDER_DIST = 64 * 10;
        const dist = ent.origin.distance(editor.draw_state.cam3d.pos);
        if (editor.draw_state.tog.models and dist < editor.draw_state.tog.model_render_dist) {
            if (ent.model_id) |m| {
                if (editor.models.getPtr(m)) |o_mod| {
                    if (o_mod.mesh) |mod| {
                        const mat1 = Mat4.fromTranslate(ent.origin);
                        const mat3 = mat1.mul(util3d.extrinsicEulerAnglesToMat4(ent.angle));
                        mod.drawSimple(view_3d, mat3, editor.draw_state.basic_shader);
                        if (param.draw_model_bb) {
                            const cc = util3d.cubeFromBounds(mod.hull_min, mod.hull_max);
                            //TODO rotate it
                            draw.cubeFrame(ent.origin.add(cc[0]), cc[1], param.frame_color);
                        }
                    }
                } else {
                    try editor.loadModelFromId(m);
                }
            }
        }
        if (dist > ENT_RENDER_DIST)
            return;
        //TODO set the model size of entities hitbox thingy
        if (editor.draw_state.tog.sprite) {
            if (ent.sprite) |spr| {
                draw_nd.cubeFrame(ent.origin.sub(Vec3.new(8, 8, 8)), Vec3.new(16, 16, 16), param.frame_color);
                const isp = try editor.getTexture(spr);
                draw_nd.billboard(ent.origin, .{ .x = 16, .y = 16 }, isp.rect(), isp, editor.draw_state.cam3d);
            }
        }
    }
};

pub const KeyValues = struct {
    const Self = @This();
    const MapT = std.StringHashMap([]const u8);
    map: MapT,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .map = MapT.init(alloc),
        };
    }

    pub fn initFromJson(v: std.json.Value, editor: *Context) !@This() {
        if (v != .object) return error.broken;
        var ret = init(editor.alloc);

        var it = v.object.iterator();
        while (it.next()) |item| {
            if (item.value_ptr.* != .string) return error.invalidKv;
            try ret.map.put(try editor.storeString(item.key_ptr.*), try editor.storeString(item.value_ptr.string));
        }

        return ret;
    }

    pub fn serial(self: @This(), _: *Context, jw: anytype) !void {
        try jw.beginObject();
        {
            var it = self.map.iterator();
            while (it.next()) |item| {
                try jw.objectField(item.value_ptr.*);
                try jw.write(item.key_ptr.*);
            }
        }
        try jw.endObject();
    }

    pub fn deinit(self: *Self) void {
        self.map.deinit();
    }
};

const Comp = graph.Ecs.Component;
pub const EcsT = graph.Ecs.Registry(&.{
    Comp("bounding_box", AABB),
    Comp("solid", Solid),
    Comp("entity", Entity),
    Comp("displacement", Displacement),
    Comp("key_values", KeyValues),
    //Comp("model"),
});

const Model = struct {
    mesh: ?*vvd.MultiMesh = null,

    pub fn initEmpty(_: std.mem.Allocator) @This() {
        return .{ .mesh = null };
    }

    //Alloc  allocated meshptr
    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        if (self.mesh) |mm| {
            mm.deinit();
            alloc.destroy(mm);
        }
    }
};

const log = std.log.scoped(.rathammer);
pub const Context = struct {
    const Self = @This();
    const ButtonState = graph.SDL.ButtonState;

    autosaver: Autosaver,
    rayctx: raycast.Ctx,
    csgctx: csg.Context,
    vpkctx: vpk.Context,
    meshmap: MeshMap,
    lower_buf: std.ArrayList(u8),
    scratch_buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    name_arena: std.heap.ArenaAllocator,
    string_storage: StringStorage,
    undoctx: undo.UndoContext,

    fgd_ctx: fgd.EntCtx,
    icon_map: std.StringHashMap(graph.Texture),

    /// These maps map vpkids to their respective resource,
    /// when fetching a resource with getTexture, etc. Something is always returned. If an entry does not exist,
    /// a job is submitted to the load thread pool and a placeholder is inserted into the map and returned
    textures: std.AutoHashMap(vpk.VpkResId, graph.Texture),
    models: std.AutoHashMap(vpk.VpkResId, Model),

    skybox: Skybox,
    notifier: NotifyCtx,

    asset_browser: assetbrowse.AssetBrowserGui,

    ecs: EcsT,

    texture_load_ctx: texture_load_thread.Context,
    tool_res_map: std.AutoHashMap(vpk.VpkResId, void),

    tools: tool_def.ToolRegistry,

    draw_state: struct {
        meshes_dirty: bool = false,
        tog: struct {
            wireframe: bool = false,
            tools: bool = true,
            sprite: bool = true,
            models: bool = true,

            model_render_dist: f32 = 512 * 2,
        } = .{},

        basic_shader: graph.glID,
        cam3d: graph.Camera3D = .{ .up = .z, .move_speed = 10, .max_move_speed = 100, .fwd_back_kind = .planar },
        cam_far_plane: f32 = 512 * 64,

        /// we keep our own so that we can do some draw calls with depth some without.
        ctx: graph.ImmediateDrawingContext,

        /// This state determines if sdl.grabMouse is true. each view that wants to grab mouse should call setGrab
        grab: struct {
            is: bool = false,
            was: bool = false,
            claimed: bool = false,

            pub fn setGrab(self: *@This(), area_has_mouse: bool, ungrab_key_down: bool, win: *graph.SDL.Window, center: graph.Vec2f) void {
                if (self.is or area_has_mouse) {
                    self.is = !ungrab_key_down;
                    self.claimed = true;
                }
                if (self.was and !self.is) {
                    graph.c.SDL_WarpMouseInWindow(win.win, center.x, center.y);
                }
            }

            pub fn endFrame(self: *@This()) void {
                self.was = self.is;
                if (!self.claimed)
                    self.is = false;
                self.claimed = false;
            }
        } = .{},
    },

    file_selection: struct {
        mutex: std.Thread.Mutex = .{},
        has_file: enum { waiting, failed, has } = .waiting,
        file_buf: std.ArrayList(u8),
        await_file: bool = false,

        fn reset(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.has_file = .waiting;
            self.await_file = false;
        }
    },

    selection: Selection,

    edit_state: struct {
        tool_index: usize = 0,
        last_frame_tool_index: usize = 0,

        //id: ?EcsT.Id = null,
        lmouse: ButtonState = .low,
        rmouse: ButtonState = .low,

        grid_snap: f32 = 16,

        mpos: graph.Vec2f = undefined,
    } = .{},

    misc_gui_state: struct {
        scroll_a: graph.Vec2f = .{ .x = 0, .y = 0 },
    } = .{},

    config: Conf.Config,
    game_conf: Conf.GameEntry,
    dirs: struct {
        const Dir = std.fs.Dir;
        cwd: Dir,
        base: Dir,
        game: Dir,
        fgd: Dir,
        pref: Dir,
        autosave: Dir,
    },

    asset: graph.AssetBake.AssetMap,
    asset_atlas: graph.Texture,
    frame_arena: std.heap.ArenaAllocator,
    // basename of map, without extension or path
    loaded_map_name: ?[]const u8 = null,
    //This is always relative to cwd
    loaded_map_path: ?[]const u8 = null,

    fn setMapName(self: *Self, filename: []const u8) !void {
        const eql = std.mem.eql;
        const allowed_exts = [_][]const u8{
            ".json",
            ".vmf",
        };
        var dot_index: ?usize = null;
        var slash_index: ?usize = null;
        if (std.mem.lastIndexOfScalar(u8, filename, '.')) |index| {
            var found = false;
            for (allowed_exts) |ex| {
                if (eql(u8, filename[index..], ex)) {
                    found = true;
                }
            }
            if (!found) {
                log.warn("Unknown map extension: {s}", .{filename});
            }
            dot_index = index;
            //pruned = filename[0..index];
        } else {
            log.warn("Map has no extension {s}", .{filename});
        }
        if (std.mem.lastIndexOfAny(u8, filename, "\\/")) |sep| {
            slash_index = sep;
        }
        const lname = filename[if (slash_index) |si| si + 1 else 0..if (dot_index) |d| d else filename.len];
        self.loaded_map_name = try self.storeString(lname);
        self.loaded_map_path = try self.storeString(filename[0..if (slash_index) |s| s + 1 else 0]);
        //pruned = pruned[sep + 1 ..];

        //self.loaded_map_name = try self.storeString(pruned);
    }

    pub fn init(alloc: std.mem.Allocator, num_threads: ?u32, config: Conf.Config) !Self {
        return .{
            //These are initilized in editor.postInit
            .dirs = undefined,
            .game_conf = undefined,
            .asset = undefined,
            .asset_atlas = undefined,

            .file_selection = .{
                .file_buf = std.ArrayList(u8).init(alloc),
            },
            .notifier = NotifyCtx.init(alloc, 4000),
            .autosaver = try Autosaver.init(config.autosave.interval_min * std.time.ms_per_min, config.autosave.max, config.autosave.enable, alloc),
            .rayctx = raycast.Ctx.init(alloc),
            .selection = Selection.init(alloc),
            .frame_arena = std.heap.ArenaAllocator.init(alloc),
            .config = config,
            .alloc = alloc,
            .fgd_ctx = fgd.EntCtx.init(alloc),
            .undoctx = undo.UndoContext.init(alloc),
            .string_storage = StringStorage.init(alloc),
            .asset_browser = assetbrowse.AssetBrowserGui.init(alloc),
            .name_arena = std.heap.ArenaAllocator.init(alloc),
            .tools = tool_def.ToolRegistry.init(alloc),
            .csgctx = try csg.Context.init(alloc),
            .vpkctx = try vpk.Context.init(alloc),
            .meshmap = MeshMap.init(alloc),
            .ecs = try EcsT.init(alloc),
            .lower_buf = std.ArrayList(u8).init(alloc),
            .scratch_buf = std.ArrayList(u8).init(alloc),
            .models = std.AutoHashMap(vpk.VpkResId, Model).init(alloc),
            .texture_load_ctx = try texture_load_thread.Context.init(alloc, num_threads),
            .textures = std.AutoHashMap(vpk.VpkResId, graph.Texture).init(alloc),
            .skybox = try Skybox.init(alloc),
            .icon_map = std.StringHashMap(graph.Texture).init(alloc),
            .tool_res_map = std.AutoHashMap(vpk.VpkResId, void).init(alloc),

            .draw_state = .{
                .ctx = graph.ImmediateDrawingContext.init(alloc),
                .basic_shader = try graph.Shader.loadFromFilesystem(alloc, std.fs.cwd(), &.{
                    .{ .path = "ratgraph/asset/shader/gbuffer.vert", .t = .vert },
                    .{ .path = "src/basic.frag", .t = .frag },
                }),
            },
        };
    }

    pub fn postInit(self: *Self, args: anytype) !void {
        if (self.config.default_game.len == 0) {
            std.debug.print("config.vdf must specify a default_game!\n", .{});
            return error.incompleteConfig;
        }
        const game_name = args.game orelse self.config.default_game;
        const game_conf = self.config.games.map.get(game_name) orelse {
            std.debug.print("{s} is not defined in the \"games\" section\n", .{game_name});
            return error.gameConfigNotFound;
        };
        self.game_conf = game_conf;

        const cwd = if (args.custom_cwd) |cc| util.openDirFatal(std.fs.cwd(), cc, .{}, "") else std.fs.cwd();
        const custom_cwd_msg = "Set a custom cwd with --custom_cwd flag";
        const base_dir = util.openDirFatal(cwd, args.basedir orelse game_conf.base_dir, .{}, custom_cwd_msg);
        const game_dir = util.openDirFatal(cwd, args.gamedir orelse game_conf.game_dir, .{}, custom_cwd_msg);
        const fgd_dir = util.openDirFatal(cwd, args.fgddir orelse game_conf.fgd_dir, .{}, "");

        const ORG = "rathammer";
        const APP = "";
        const path = graph.c.SDL_GetPrefPath(ORG, APP);
        const pref = try std.fs.cwd().makeOpenPath(std.mem.span(path), .{});
        const autosave = try pref.makeOpenPath("autosave", .{});

        try graph.AssetBake.assetBake(self.alloc, std.fs.cwd(), "ratasset", pref, "packed", .{});

        self.asset = try graph.AssetBake.AssetMap.initFromManifest(self.alloc, pref, "packed");
        self.asset_atlas = try graph.AssetBake.AssetMap.initTextureFromManifest(self.alloc, pref, "packed");

        self.dirs = .{ .cwd = cwd, .base = base_dir, .game = game_dir, .fgd = fgd_dir, .pref = pref, .autosave = autosave };
        try gameinfo.loadGameinfo(self.alloc, base_dir, game_dir, &self.vpkctx);
        try self.asset_browser.populate(&self.vpkctx, game_conf.asset_browser_exclude.prefix, game_conf.asset_browser_exclude.entry.items);
        try fgd.loadFgd(&self.fgd_ctx, fgd_dir, args.fgd orelse game_conf.fgd);

        try self.tools.register("translate", tool_def.Translate);
        try self.tools.register("translate_face", tool_def.TranslateFace);
        try self.tools.register("place_model", tool_def.PlaceModel);
        try self.tools.register("cube_draw", tool_def.CubeDraw);
        try self.tools.register("fast_face", tool_def.FastFaceManip);
        try self.tools.register("texture", tool_def.TextureTool);
    }

    pub fn deinit(self: *Self) void {
        self.asset.deinit();

        self.tools.deinit();
        self.tool_res_map.deinit();
        self.file_selection.file_buf.deinit();
        self.undoctx.deinit();
        self.ecs.deinit();
        self.fgd_ctx.deinit();
        self.notifier.deinit();
        self.icon_map.deinit();
        self.lower_buf.deinit();
        self.selection.deinit();
        self.string_storage.deinit();
        self.rayctx.deinit();
        self.scratch_buf.deinit();
        self.asset_browser.deinit();
        self.csgctx.deinit();
        self.vpkctx.deinit();
        self.skybox.deinit();
        self.frame_arena.deinit();
        var mit = self.models.valueIterator();
        while (mit.next()) |m| {
            m.deinit(self.alloc);
        }
        self.models.deinit();
        self.textures.deinit();

        var it = self.meshmap.iterator();
        while (it.next()) |item| {
            item.value_ptr.*.deinit();
            self.alloc.destroy(item.value_ptr.*);
        }
        self.meshmap.deinit();
        self.name_arena.deinit();
        self.draw_state.ctx.deinit();
        self.texture_load_ctx.deinit();
    }

    pub fn rebuildMeshesIfDirty(self: *Self) !void {
        var it = self.meshmap.iterator();
        while (it.next()) |mesh| {
            try mesh.value_ptr.*.rebuildIfDirty(self);
        }
    }

    pub fn writeToJsonFile(self: *Self, path: std.fs.Dir, filename: []const u8) !void {
        const outfile = try path.createFile(filename, .{});
        defer outfile.close();
        try self.writeToJson(outfile);
    }

    pub fn writeToJson(self: *Self, outfile: std.fs.File) !void {
        const to_omit = [_]usize{@intFromEnum(EcsT.Components.bounding_box)};
        const wr = outfile.writer();
        var bwr = std.io.bufferedWriter(wr);
        const bb = bwr.writer();
        var jwr = std.json.writeStream(bb, .{});
        try jwr.beginObject();
        {
            try jwr.objectField("editor");
            try jwr.write(.{
                .cam = JsonCamera.fromCam(self.draw_state.cam3d),
            });
            try jwr.objectField("sky_name");
            try jwr.write(self.skybox.sky_name);
            try jwr.objectField("objects");
            try jwr.beginArray();
            {
                for (self.ecs.entities.items, 0..) |ent, id| {
                    if (ent.isSet(EcsT.Types.tombstone_bit))
                        continue;
                    try jwr.beginObject();
                    {
                        try jwr.objectField("id");
                        try jwr.write(id);
                        inline for (EcsT.Fields, 0..) |field, f_i| {
                            if (std.mem.indexOfScalar(usize, &to_omit, f_i) == null) {
                                if (ent.isSet(f_i)) {
                                    try jwr.objectField(field.name);
                                    const ptr = try self.ecs.getPtr(@intCast(id), @enumFromInt(f_i));
                                    try self.writeComponentToJson(&jwr, ptr.*);
                                }
                            }
                        }
                    }
                    try jwr.endObject();
                }
            }
            try jwr.endArray();
        }
        //Men I trust, men that rust
        try jwr.endObject();
        try bwr.flush();
    }

    fn readComponentFromJson(self: *Self, v: std.json.Value, T: type) !T {
        const info = @typeInfo(T);
        switch (T) {
            []const u8 => {
                if (v != .string) return error.value;
                return try self.string_storage.store(v.string);
            },
            Vec3 => {
                if (v != .string) return error.value;
                var it = std.mem.splitScalar(u8, v.string, ' ');
                const x = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
                const y = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
                const z = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
                return Vec3.new(x, y, z);
            },
            Side.UVaxis => {
                if (v != .string) return error.value;
                var it = std.mem.splitScalar(u8, v.string, ' ');
                const x = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
                const y = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
                const z = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
                const tr = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
                const sc = try std.fmt.parseFloat(f32, it.next() orelse return error.expectedFloat);
                return .{
                    .axis = Vec3.new(x, y, z),
                    .trans = tr,
                    .scale = sc,
                };
            },
            vpk.VpkResId => {
                if (v != .string) return error.value;
                const id = try self.vpkctx.getResourceIdString(v.string);
                return id orelse return error.broken;
            },
            else => {},
        }
        switch (info) {
            .Bool, .Float, .Int => return try std.json.innerParseFromValue(T, self.alloc, v, .{}),
            .Struct => |s| {
                if (std.meta.hasFn(T, "initFromJson")) {
                    return try T.initFromJson(v, self);
                }
                if (vdf.getArrayListChild(T)) |child| {
                    var ret = std.ArrayList(child).init(self.alloc);
                    if (v != .array) return error.value;
                    for (v.array.items) |item|
                        try ret.append(try self.readComponentFromJson(item, child));

                    return ret;
                }
                if (v != .object) return error.value;
                var ret: T = .{};
                inline for (s.fields) |field| {
                    if (v.object.get(field.name)) |val| {
                        @field(ret, field.name) = try self.readComponentFromJson(val, field.type);
                    }
                }
                return ret;
            },
            .Optional => |o| {
                if (v == .null)
                    return null;
                return try self.readComponentFromJson(v, o.child);
            },
            else => {},
        }
        @compileError("not sup " ++ @typeName(T));
    }

    fn writeComponentToJson(self: *Self, jw: anytype, comp: anytype) !void {
        const T = @TypeOf(comp);
        const info = @typeInfo(T);
        switch (T) {
            []const u8 => return jw.write(comp),
            vpk.VpkResId => {
                if (self.vpkctx.namesFromId(comp)) |name| {
                    return try jw.print("\"{s}/{s}.{s}\"", .{ name.path, name.name, name.ext });
                }
                return try jw.write(null);
            },
            Vec3 => return jw.print("\"{e} {e} {e}\"", .{ comp.x(), comp.y(), comp.z() }),
            Side.UVaxis => return jw.print("\"{} {} {} {} {}\"", .{ comp.axis.x(), comp.axis.y(), comp.axis.z(), comp.trans, comp.scale }),
            else => {},
        }
        switch (info) {
            .Int, .Float, .Bool => try jw.write(comp),
            .Optional => {
                if (comp) |p|
                    return try self.writeComponentToJson(jw, p);
                return try jw.write(null);
            },
            .Struct => |s| {
                if (std.meta.hasFn(T, "serial")) {
                    return try comp.serial(self, jw);
                }
                if (vdf.getArrayListChild(@TypeOf(comp))) |_| {
                    try jw.beginArray();
                    for (comp.items) |item| {
                        try self.writeComponentToJson(jw, item);
                    }
                    try jw.endArray();
                    return;
                }
                try jw.beginObject();
                inline for (s.fields) |field| {
                    try jw.objectField(field.name);
                    try self.writeComponentToJson(jw, @field(comp, field.name));
                }
                try jw.endObject();
            },
            else => @compileError("no work for : " ++ @typeName(T)),
        }
    }

    pub fn rebuildAllMeshes(self: *Self) !void {
        mesh_build_time.start();
        { //First clear
            var mesh_it = self.meshmap.valueIterator();
            while (mesh_it.next()) |batch| {
                batch.*.mesh.vertices.clearRetainingCapacity();
                batch.*.mesh.indicies.clearRetainingCapacity();
            }
        }
        { //Iterate all solids and add
            var it = self.ecs.iterator(.solid);
            while (it.next()) |solid| {
                const bb = (try self.ecs.getOptPtr(it.i, .bounding_box)) orelse continue;
                solid.recomputeBounds(bb);
                try solid.rebuild(it.i, self);
            }
        }
        {
            var it = self.ecs.iterator(.displacement);
            while (it.next()) |disp| {
                const batch = self.meshmap.getPtr(disp.tex_id) orelse continue;
                try disp.rebuild(batch.*, self);
            }
        }
        { //Set all the gl data
            var it = self.meshmap.valueIterator();
            while (it.next()) |item| {
                item.*.mesh.setData();
            }
        }
        mesh_build_time.end();
        mesh_build_time.log("Mesh build time");
    }

    pub fn getOrPutMeshBatch(self: *Self, res_id: vpk.VpkResId) !*MeshBatch {
        const res = try self.meshmap.getOrPut(res_id);
        if (!res.found_existing) {
            const tex = try self.getTexture(res_id);
            res.value_ptr.* = try self.alloc.create(MeshBatch);
            res.value_ptr.*.* = .{
                .notify_vt = .{ .notify_fn = &MeshBatch.notify },
                .tex = tex,
                .tex_res_id = res_id,
                .mesh = undefined,
                .contains = std.AutoHashMap(EcsT.Id, void).init(self.alloc),
            };
            res.value_ptr.*.mesh = meshutil.Mesh.init(self.alloc, res.value_ptr.*.tex.id);

            try self.texture_load_ctx.addNotify(res_id, &res.value_ptr.*.notify_vt);
        }
        return res.value_ptr.*;
    }

    ///Given a csg defined solid, convert to mesh and store.
    pub fn putSolidFromVmf(self: *Self, solid: vmf.Solid, parent_id: ?EcsT.Id) !void {
        const new = try self.ecs.createEntity();
        var newsolid = try self.csgctx.genMesh2(
            solid.side,
            self.alloc,
            &self.string_storage,
            self,
            //@intCast(self.set.sparse.items.len),
        );
        newsolid.parent_entity = parent_id;
        for (solid.side, 0..) |*side, s_i| {
            const tex = try self.loadTextureFromVpk(side.material);
            const res = try self.getOrPutMeshBatch(tex.res_id);
            try res.contains.put(new, {});

            if (side.dispinfo.power != -1) {
                for (newsolid.sides.items) |*sp|
                    sp.omit_from_batch = true;
                const disp_id = try self.ecs.createEntity();
                var disp_gen = Displacement.init(self.alloc, tex.res_id, new, s_i, &side.dispinfo);
                const ss = newsolid.sides.items[s_i].index.items;
                const corners = [4]Vec3{
                    newsolid.verts.items[ss[0]],
                    newsolid.verts.items[ss[1]],
                    newsolid.verts.items[ss[2]],
                    newsolid.verts.items[ss[3]],
                };
                try self.csgctx.genMeshDisplacement(
                    &corners,
                    //newsolid.sides.items[s_i].verts.items,
                    &side.dispinfo,
                    &disp_gen,
                );
                try res.contains.put(disp_id, {});
                if (false) { //dump to obj
                    std.debug.print("o disp\n", .{});
                    for (disp_gen.verts.items) |vert| {
                        std.debug.print("v {d} {d} {d}\n", .{ vert.x(), vert.y(), vert.z() });
                    }
                    for (0..@divExact(disp_gen.index.items.len, 3)) |i| {
                        std.debug.print("f {d} {d} {d}\n", .{
                            disp_gen.index.items[(i * 3) + 0] + 1,
                            disp_gen.index.items[(i * 3) + 1] + 1,
                            disp_gen.index.items[(i * 3) + 2] + 1,
                        });
                    }
                }

                try self.ecs.attach(disp_id, .displacement, disp_gen);
            }
        }
        try self.ecs.attach(new, .solid, newsolid);
        try self.ecs.attach(new, .bounding_box, .{});
        //try self.set.insert(newsolid.id, newsolid);
    }

    pub fn screenRay(self: *Self, screen_area: graph.Rect, view_3d: Mat4) []const raycast.RcastItem {
        const rc = util3d.screenSpaceRay(
            screen_area.dim(),
            if (self.draw_state.grab.was) screen_area.center() else self.edit_state.mpos,
            view_3d,
        );
        return self.rayctx.findNearestSolid(&self.ecs, rc[0], rc[1], &self.csgctx, false) catch &.{};
    }

    pub fn getCurrentTool(self: *Self) ?*tool_def.i3DTool {
        if (self.edit_state.tool_index >= self.tools.tools.items.len)
            return null;
        return self.tools.tools.items[self.edit_state.tool_index];
    }

    pub fn loadJson(self: *Self, path: std.fs.Dir, filename: []const u8, loadctx: *LoadCtx) !void {
        var timer = try std.time.Timer.start();
        defer log.info("Loaded json in {d}ms", .{timer.read() / std.time.ns_per_ms});
        const infile = try path.openFile(filename, .{});
        defer infile.close();

        const slice = try infile.reader().readAllAlloc(self.alloc, std.math.maxInt(usize));
        defer self.alloc.free(slice);
        var aa = std.heap.ArenaAllocator.init(self.alloc);
        defer aa.deinit();
        var parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, slice, .{});
        defer parsed.deinit();
        try self.setMapName(filename);
        loadctx.cb("json parsed");
        if (parsed.value != .object)
            return error.invalidMap;

        { //Sky stuff
            if (parsed.value.object.get("sky_name")) |sky_name| {
                if (sky_name == .string) {
                    try self.skybox.loadSky(try self.storeString(sky_name.string), &self.vpkctx);
                } else {
                    return error.invalidSky;
                }
            }
        }
        {
            if (parsed.value.object.get("editor")) |editor| {
                const ed = try std.json.parseFromValueLeaky(JsonEditor, aa.allocator(), editor, .{});
                ed.cam.setCam(&self.draw_state.cam3d);
            }
        }

        const obj_o = parsed.value.object.get("objects") orelse return error.invalidMap;
        if (obj_o != .array) return error.invalidMap;

        loadctx.expected_cb = obj_o.array.items.len + 10;
        for (obj_o.array.items, 0..) |val, i| {
            if (val != .object) return error.invalidMap;
            const id = (val.object.get("id") orelse return error.invalidMap).integer;
            var it = val.object.iterator();
            //TODO all entities have bounding boxes, add those
            //TODO finally get that model loading thing to set bb's
            var origin = Vec3.zero();
            outer: while (it.next()) |data| {
                if (std.mem.eql(u8, "id", data.key_ptr.*)) continue;
                inline for (EcsT.Fields, 0..) |field, f_i| {
                    if (std.mem.eql(u8, field.name, data.key_ptr.*)) {
                        const comp = try self.readComponentFromJson(data.value_ptr.*, field.ftype);
                        try self.ecs.attachComponentAndCreate(@intCast(id), @enumFromInt(f_i), comp);

                        switch (field.ftype) {
                            Entity => {
                                origin = comp.origin;
                            },
                            else => {},
                        }

                        continue :outer;
                    }
                }

                return error.invalidKey;
            }
            var bb = AABB{ .a = Vec3.new(0, 0, 0), .b = Vec3.new(16, 16, 16), .origin_offset = Vec3.new(8, 8, 8) };
            bb.setFromOrigin(origin);
            try self.ecs.attachComponentAndCreate(@intCast(id), .bounding_box, bb);
            loadctx.printCb("Ent parsed {d} / {d}", .{ i, obj_o.array.items.len });
        }
        loadctx.cb("Building meshes}");
        try self.rebuildAllMeshes();
    }

    pub fn loadVmf(self: *Self, path: std.fs.Dir, filename: []const u8, loadctx: *LoadCtx) !void {
        var timer = try std.time.Timer.start();
        const infile = util.openFileFatal(path, filename, .{}, "");
        defer infile.close();
        defer log.info("Loaded vmf in {d}ms", .{timer.read() / std.time.ns_per_ms});

        const slice = try infile.reader().readAllAlloc(self.alloc, std.math.maxInt(usize));
        defer self.alloc.free(slice);
        var aa = std.heap.ArenaAllocator.init(self.alloc);
        var obj = try vdf.parse(self.alloc, slice);
        defer obj.deinit();
        loadctx.cb("vmf parsed");
        try self.setMapName(filename);
        const vmf_ = try vdf.fromValue(vmf.Vmf, &.{ .obj = &obj.value }, aa.allocator(), null);
        try self.skybox.loadSky(try self.storeString(vmf_.world.skyname), &self.vpkctx);
        {
            loadctx.expected_cb = vmf_.world.solid.len + vmf_.entity.len + 10;
            var gen_timer = try std.time.Timer.start();
            for (vmf_.world.solid, 0..) |solid, si| {
                try self.putSolidFromVmf(solid, null);
                loadctx.printCb("csg generated {d} / {d}", .{ si, vmf_.world.solid.len });
            }
            for (vmf_.entity, 0..) |ent, ei| {
                loadctx.printCb("ent generated {d} / {d}", .{ ei, vmf_.entity.len });
                const new = try self.ecs.createEntity();
                for (ent.solid) |solid|
                    try self.putSolidFromVmf(solid, new);
                {
                    var bb = AABB{ .a = Vec3.new(0, 0, 0), .b = Vec3.new(16, 16, 16), .origin_offset = Vec3.new(8, 8, 8) };
                    if (ent.model.len > 0) {
                        if (self.loadModel(ent.model)) |m| {
                            _ = m;
                            //bb.origin_offset = m.hull_min.scale(-1);
                            //bb.a = m.hull_min;
                            //bb.b = m.hull_max;
                        } else |err| {
                            log.err("Load model failed with {}", .{err});
                        }
                        //TODO update the bb when the models has loaded
                        //we need to keep a list of vtables
                    }
                    var sprite_tex: ?vpk.VpkResId = null;
                    { //Fgd stuff
                        if (self.fgd_ctx.base.get(ent.classname)) |base| {
                            var sl = base.iconsprite;
                            if (sl.len > 0) {
                                if (std.mem.endsWith(u8, base.iconsprite, ".vmt"))
                                    sl = base.iconsprite[0 .. base.iconsprite.len - 4];
                                const sprite_tex_ = try self.loadTextureFromVpk(sl);
                                if (sprite_tex_.res_id != 0)
                                    sprite_tex = sprite_tex_.res_id;
                            }
                        }
                    }
                    bb.setFromOrigin(ent.origin.v);
                    const model_id = self.modelIdFromName(ent.model) catch null;
                    try self.ecs.attach(new, .entity, .{
                        .origin = ent.origin.v,
                        .angle = ent.angles.v,
                        .class = try self.storeString(ent.classname),
                        .model = if (ent.model.len > 0) try self.storeString(ent.model) else null,
                        .model_id = model_id,
                        .sprite = sprite_tex,
                    });
                    try self.ecs.attach(new, .bounding_box, bb);
                }

                if (ent.rest_kvs.count() > 0) {
                    var kvs = KeyValues.init(self.alloc);
                    var it = ent.rest_kvs.iterator();
                    while (it.next()) |item|
                        try kvs.map.put(try self.storeString(item.key_ptr.*), try self.storeString(item.value_ptr.*));

                    try self.ecs.attach(new, .key_values, kvs);
                }

                //try procSolid(&editor.csgctx, alloc, solid, &editor.meshmap, &editor.vpkctx);
            }
            try self.rebuildAllMeshes();
            const nm = self.meshmap.count();
            const whole_time = gen_timer.read();

            log.info("csg took {d} {d:.2} us", .{ nm, csg.gen_time / std.time.ns_per_us / nm });
            log.info("Generated {d} meshes in {d:.2} ms", .{ nm, whole_time / std.time.ns_per_ms });
        }
        aa.deinit();
        loadctx.cb("csg generated");
    }

    pub fn drawToolbar(self: *Self, area: graph.Rect, draw: *DrawCtx) void {
        const start = area.pos();
        const w = 100;
        const tool_index = self.edit_state.tool_index;
        for (self.tools.tools.items, 0..) |tool, i| {
            const fi: f32 = @floatFromInt(i);
            const rec = graph.Rec(start.x + fi * w, start.y, 100, 100);
            tool.tool_icon_fn(tool, draw, self, rec);
            if (tool_index == i) {
                draw.rectBorder(rec, 3, 0x00ff00ff);
            }
        }
    }

    fn modelIdFromName(self: *Self, mdl_name: []const u8) !?vpk.VpkResId {
        const mdln = blk: {
            if (std.mem.endsWith(u8, mdl_name, ".mdl"))
                break :blk mdl_name[0 .. mdl_name.len - 4];
            break :blk mdl_name;
        };

        return try self.vpkctx.getResourceIdFmt("mdl", "{s}", .{mdln});
    }

    pub fn loadModel(self: *Self, model_name: []const u8) !vpk.VpkResId {
        const mod = try self.storeString(model_name);
        const res_id = try self.modelIdFromName(mod) orelse return error.noMdl;
        if (self.models.get(res_id)) |_| return res_id; //Don't load model twice!
        try self.models.put(res_id, Model.initEmpty(self.alloc));
        try self.texture_load_ctx.loadModel(res_id, mod, &self.vpkctx);
        return res_id;
    }

    pub fn loadModelFromId(self: *Self, res_id: vpk.VpkResId) !void {
        if (self.models.get(res_id)) |_| return; //Don't load model twice!
        if (self.vpkctx.namesFromId(res_id)) |names| {
            self.scratch_buf.clearRetainingCapacity();
            try self.scratch_buf.writer().print("{s}/{s}.{s}", .{ names.path, names.name, names.ext });
            const mod = try self.storeString(self.scratch_buf.items);
            try self.models.put(res_id, Model.initEmpty(self.alloc));

            try self.texture_load_ctx.loadModel(res_id, mod, &self.vpkctx);
        }
    }

    pub fn storeString(self: *Self, string: []const u8) ![]const u8 {
        return try self.string_storage.store(string);
    }

    pub fn getTexture(self: *Self, res_id: vpk.VpkResId) !graph.Texture {
        if (self.textures.get(res_id)) |tex| return tex;

        try self.loadTexture(res_id);

        return missingTexture();
    }

    pub fn loadTexture(self: *Self, res_id: vpk.VpkResId) !void {
        if (self.textures.get(res_id)) |_| return;

        { //track tools
            if (self.vpkctx.namesFromId(res_id)) |name| {
                if (std.mem.startsWith(u8, name.path, "materials/tools")) {
                    try self.tool_res_map.put(res_id, {});
                }
            }
        }

        try self.textures.put(res_id, missingTexture());
        try self.texture_load_ctx.loadTexture(res_id, &self.vpkctx);
    }

    pub fn loadTextureFromVpk(self: *Self, material: []const u8) !struct { tex: graph.Texture, res_id: vpk.VpkResId } {
        const res_id = try self.vpkctx.getResourceIdFmt("vmt", "materials/{s}", .{material}) orelse return .{ .tex = missingTexture(), .res_id = 0 };
        if (self.textures.get(res_id)) |tex| return .{ .tex = tex, .res_id = res_id };

        try self.loadTexture(res_id);

        return .{ .tex = missingTexture(), .res_id = res_id };
    }

    pub fn camRay(self: *Self, area: graph.Rect, view: Mat4) [2]Vec3 {
        return util3d.screenSpaceRay(
            area.dim(),
            if (self.draw_state.grab.was) area.center() else self.edit_state.mpos,
            view,
        );
    }

    fn printScratch(self: *Self, comptime str: []const u8, args: anytype) ![]const u8 {
        self.scratch_buf.clearRetainingCapacity();
        try self.scratch_buf.writer().print(str, args);
        return self.scratch_buf.items;
    }

    fn saveAndNotify(self: *Self, basename: []const u8, path: []const u8) !void {
        var timer = try std.time.Timer.start();
        try self.notifier.submitNotify("saving: {s}{s}", .{ path, basename }, 0xfca73fff);
        const name = try self.printScratch("{s}{s}.json", .{ path, basename });
        //TODO make copy of existing map incase something goes wrong
        const out_file = try std.fs.cwd().createFile(name, .{});
        defer out_file.close();
        if (self.writeToJson(out_file)) {
            try self.notifier.submitNotify(" saved: {s}{s} in {d:.1}ms", .{ path, basename, timer.read() / std.time.ns_per_ms }, 0xff00ff);
        } else |err| {
            log.err("writeToJson failed ! {}", .{err});
            try self.notifier.submitNotify("save failed!: {}", .{err}, 0xff0000ff);
        }
    }

    pub fn update(self: *Self, win: *graph.SDL.Window) !void {
        //TODO in the future, set app state to 'autosaving' and send saving to worker thread
        if (self.autosaver.shouldSave()) {
            const basename = self.loaded_map_name orelse "unnamed_map";
            log.info("Autosaving {s}", .{basename});
            self.autosaver.resetTimer();
            if (self.autosaver.getSaveFileAndPrune(self.dirs.autosave, basename, ".json")) |out_file| {
                defer out_file.close();
                self.writeToJson(out_file) catch |err| {
                    log.err("writeToJson failed ! {}", .{err});
                    try self.notifier.submitNotify("Autosave failed!: {}", .{err}, 0xff0000ff);
                };
            } else |err| {
                log.err("Autosave failed with error {}", .{err});
                try self.notifier.submitNotify("Autosave failed!: {}", .{err}, 0xff0000ff);
            }
            try self.notifier.submitNotify("Autosaved: {s}", .{basename}, 0x00ff00ff);
        }
        if (win.isBindState(self.config.keys.save.b, .rising)) {
            if (self.loaded_map_name) |basename| {
                try self.saveAndNotify(basename, self.loaded_map_path orelse "");
            } else {
                if (!self.file_selection.await_file) {
                    self.file_selection.reset();
                    self.file_selection.await_file = true;
                    graph.c.SDL_ShowSaveFileDialog(&saveFileCallback, self, null, null, 0, null);
                }
            }
        }
        if (win.isBindState(self.config.keys.save_new.b, .rising)) {
            if (!self.file_selection.await_file) {
                self.file_selection.reset();
                self.file_selection.await_file = true;
                graph.c.SDL_ShowSaveFileDialog(&saveFileCallback, self, null, null, 0, null);
            }
        }
        if (self.file_selection.await_file) {
            if (self.file_selection.mutex.tryLock()) {
                defer self.file_selection.mutex.unlock();
                switch (self.file_selection.has_file) {
                    .waiting => {},
                    .failed => self.file_selection.await_file = false,
                    .has => {
                        try self.setMapName(self.file_selection.file_buf.items);
                        self.file_selection.await_file = false;
                        if (self.loaded_map_name) |basename| {
                            try self.saveAndNotify(basename, self.loaded_map_path orelse "");
                        }
                    },
                }
            }
        }

        _ = self.frame_arena.reset(.retain_capacity);
        self.edit_state.last_frame_tool_index = self.edit_state.tool_index;
        const MAX_UPDATE_TIME = std.time.ns_per_ms * 16;
        var timer = try std.time.Timer.start();
        //defer std.debug.print("UPDATE {d} ms\n", .{timer.read() / std.time.ns_per_ms});
        var tcount: usize = 0;
        {
            self.texture_load_ctx.completed_mutex.lock();
            defer self.texture_load_ctx.completed_mutex.unlock();
            tcount = self.texture_load_ctx.completed.items.len;
            var num_rm_tex: usize = 0;
            for (self.texture_load_ctx.completed.items) |*completed| {
                if (completed.data.deinitToTexture(self.texture_load_ctx.alloc)) |texture| {
                    try self.textures.put(completed.vpk_res_id, texture);
                    self.texture_load_ctx.notifyTexture(completed.vpk_res_id, self);
                } else |err| {
                    log.err("texture init failed with : {}", .{err});
                }

                num_rm_tex += 1;
                const elapsed = timer.read();
                if (elapsed > MAX_UPDATE_TIME)
                    break;
            }
            for (0..num_rm_tex) |_|
                _ = self.texture_load_ctx.completed.orderedRemove(0);

            var completed_ids = std.ArrayList(vpk.VpkResId).init(self.frame_arena.allocator());
            var num_removed: usize = 0;
            for (self.texture_load_ctx.completed_models.items) |*completed| {
                var model = completed.mesh;
                model.initGl();
                try self.models.put(completed.res_id, .{ .mesh = model });
                for (completed.texture_ids.items) |tid| {
                    try self.texture_load_ctx.addNotify(tid, &completed.mesh.notify_vt);
                }
                for (model.meshes.items) |*mesh| {
                    const t = try self.getTexture(mesh.tex_res_id);
                    mesh.texture_id = t.id;
                }
                try completed_ids.append(completed.res_id);
                completed.texture_ids.deinit();
                num_removed += 1;

                const elapsed = timer.read();
                if (elapsed > MAX_UPDATE_TIME)
                    break;
            }
            for (0..num_removed) |_|
                _ = self.texture_load_ctx.completed_models.orderedRemove(0);

            var m_it = self.ecs.iterator(.entity);
            while (m_it.next()) |ent| {
                if (ent.model_id) |mid| {
                    if (std.mem.indexOfScalar(vpk.VpkResId, completed_ids.items, mid) != null) {
                        const mod = self.models.getPtr(mid) orelse continue;
                        const mesh = mod.mesh orelse continue;
                        const bb = try self.ecs.getPtr(m_it.i, .bounding_box);
                        bb.origin_offset = mesh.hull_min.scale(-1);
                        bb.a = mesh.hull_min;
                        bb.b = mesh.hull_max;
                        bb.setFromOrigin(ent.origin);
                    }
                }
            }
        }
        if (tcount > 0) {
            self.draw_state.meshes_dirty = true;
        }

        if (self.draw_state.meshes_dirty) {
            self.draw_state.meshes_dirty = false;
            try self.rebuildMeshesIfDirty();
        }
    }
};

pub const LoadCtx = struct {
    const builtin = @import("builtin");
    buffer: [256]u8 = undefined,
    timer: std.time.Timer,
    draw: *graph.ImmediateDrawingContext,
    win: *graph.SDL.Window,
    os9gui: *graph.Os9Gui,
    font: *graph.Font,
    splash: graph.Texture,
    draw_splash: bool = true,
    gtimer: std.time.Timer,
    time: u64 = 0,

    expected_cb: usize = 1, // these are used to update progress bar
    cb_count: usize = 0,

    pub fn printCb(self: *@This(), comptime fmt: []const u8, args: anytype) void {
        self.cb_count += 1;
        //No need for high fps when loading, this is 15fps
        if (self.timer.read() / std.time.ns_per_ms < 66) {
            return;
        }
        self.cb_count -= 1;
        var fbs = std.io.FixedBufferStream([]u8){ .buffer = &self.buffer, .pos = 0 };
        fbs.writer().print(fmt, args) catch return;
        self.cb(fbs.getWritten());
    }

    pub fn cb(self: *@This(), message: []const u8) void {
        self.cb_count += 1;
        if (self.timer.read() / std.time.ns_per_ms < 8) {
            return;
        }
        self.timer.reset();
        self.win.pumpEvents(.poll);
        self.draw.begin(0x678caaff, self.win.screen_dimensions.toF()) catch return;
        self.os9gui.beginFrame(.{}, self.win) catch return;
        //self.draw.text(.{ .x = 0, .y = 0 }, message, &self.font.font, 100, 0xffffffff);
        const perc: f32 = @as(f32, @floatFromInt(self.cb_count)) / @as(f32, @floatFromInt(self.expected_cb));
        self.drawSplash(perc, message);
        self.os9gui.endFrame(self.draw) catch return;
        self.draw.end(null) catch return;
        self.win.swap(); //So the window doesn't look too broken while loading
    }

    pub fn drawSplash(self: *@This(), perc: f32, message: []const u8) void {
        const cx = self.draw.screen_dimensions.x / 2;
        const cy = self.draw.screen_dimensions.y / 2;
        const w: f32 = @floatFromInt(self.splash.w);
        const h: f32 = @floatFromInt(self.splash.h);
        const sr = graph.Rec(cx - w / 2, cy - h / 2, w, h);
        const tbox = graph.Rec(sr.x + 10, sr.y + 156, 420, 22);
        const pbar = graph.Rec(sr.x + 8, sr.y + 172, 430, 6);
        _ = self.os9gui.beginTlWindow(sr) catch return;
        defer self.os9gui.endTlWindow();
        self.os9gui.gui.drawRectTextured(sr, 0xffffffff, self.splash.rect(), self.splash);
        self.os9gui.gui.drawTextFmt(
            "{s}",
            .{message},
            tbox,
            20,
            //tbox.h,
            0xff,
            .{},
            self.os9gui.font,
        );
        const p = @min(1, perc);
        self.os9gui.gui.drawRectFilled(pbar.split(.vertical, pbar.w * p)[0], 0xf7a41dff);
        //self.draw.rectTex(sr, self.splash.rect(), self.splash);
        //self.draw.text(
        //    tbox.pos(),
        //    message,
        //    &self.font.font,
        //    tbox.h,
        //    0xff,
        //);
    }

    pub fn loadedSplash(self: *@This(), end: bool) !void {
        if (self.draw_splash) {
            var fbs = std.io.FixedBufferStream([]u8){ .buffer = &self.buffer, .pos = 0 };
            try fbs.writer().print("v0.0.1 Loaded in {d:.2} ms. {s}.{s}.{s}", .{
                self.time / std.time.ns_per_ms,
                @tagName(builtin.mode),
                @tagName(builtin.target.os.tag),
                @tagName(builtin.target.cpu.arch),
            });
            graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
            self.draw.rect(graph.Rec(0, 0, self.draw.screen_dimensions.x, self.draw.screen_dimensions.y), 0x88);
            self.drawSplash(1.0, fbs.getWritten());
            if (end)
                self.draw_splash = false;
        }
    }
};

pub fn missingTexture() graph.Texture {
    const static = struct {
        const m = [3]u8{ 0xfc, 0x05, 0xbe };
        const b = [3]u8{ 0x0, 0x0, 0x0 };
        const data = m ++ b ++ b ++ m;
        //const data = [_]u8{ 0xfc, 0x05, 0xbe, b,b,b, };
        var texture: ?graph.Texture = null;
    };

    if (static.texture == null) {
        static.texture = graph.Texture.initFromBuffer(
            &static.data,
            2,
            2,
            .{
                .pixel_format = graph.c.GL_RGB,
                .pixel_store_alignment = 1,
                .mag_filter = graph.c.GL_NEAREST,
            },
        );
        static.texture.?.w = 400; //Zoom the texture out
        static.texture.?.h = 400;
    }
    return static.texture.?;
}
