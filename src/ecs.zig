const std = @import("std");
const graph = @import("graph");
const profile = @import("profile.zig");
const Vec3 = graph.za.Vec3;
const Mat4 = graph.za.Mat4;
const vpk = @import("vpk.zig");
const vmf = @import("vmf.zig");
const util3d = @import("util_3d.zig");
const meshutil = graph.meshutil;
const thread_pool = @import("thread_pool.zig");
const Editor = @import("editor.zig").Context;
const DrawCtx = graph.ImmediateDrawingContext;
const VisGroups = @import("visgroup.zig");

const Comp = graph.Ecs.Component;
pub const EcsT = graph.Ecs.Registry(&.{
    Comp("bounding_box", AABB),
    Comp("solid", Solid),
    Comp("entity", Entity),
    Comp("displacement", Displacement),
    Comp("key_values", KeyValues),
    Comp("invisible", struct {
        pub const ECS_NO_SERIAL = void;
        pub fn dupe(_: *@This()) !@This() {
            return .{};
        }
    }),
    Comp("editor_info", EditorInfo),
    Comp("deleted", struct {
        pub const ECS_NO_SERIAL = void;
        pub fn dupe(_: *@This()) !@This() {
            return .{};
        }
    }),
});

pub const MeshMap = std.AutoHashMap(vpk.VpkResId, *MeshBatch);
pub threadlocal var mesh_build_time = profile.BasicProfiler.init();
/// Solid mesh storage:
/// Solids are stored as entities in the ecs.
/// The actual mesh data is stored in `Meshmap'.
/// There is one MeshBatch per material. So if there are n materials in use by a map we have n draw calls regardless of the number of solids.
/// This means that modifying a solids verticies or uvs requires the rebuilding of any mesh batches the solid's materials use.
///
/// Every MeshBatch has a hashset 'contains' which stores the ecs ids of all solids it contains
pub const MeshBatch = struct {
    const Self = @This();
    tex: graph.Texture,
    tex_res_id: vpk.VpkResId,
    mesh: meshutil.Mesh,
    contains: std.AutoHashMap(EcsT.Id, void),
    is_dirty: bool = false,

    notify_vt: thread_pool.DeferredNotifyVtable,
    // Each batch needs to keep track of:
    // needs_rebuild
    // contained_solids:ent_id

    pub fn deinit(self: *@This()) void {
        self.mesh.deinit();
        //self.tex.deinit();
        self.contains.deinit();
    }

    pub fn rebuildIfDirty(self: *Self, editor: *Editor) !void {
        if (self.is_dirty) {
            self.is_dirty = false;
            return self.rebuild(editor);
        }
    }

    pub fn notify(vt: *thread_pool.DeferredNotifyVtable, id: vpk.VpkResId, editor: *Editor) void {
        const self: *@This() = @alignCast(@fieldParentPtr("notify_vt", vt));
        if (id == self.tex_res_id) {
            self.tex = (editor.textures.get(id) orelse return);
            self.mesh.diffuse_texture = self.tex.id;
            self.is_dirty = true;
        }
    }

    pub fn rebuild(self: *Self, editor: *Editor) !void {
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
pub const AABB = struct {
    pub const ECS_NO_SERIAL = void;
    a: Vec3 = Vec3.zero(),
    b: Vec3 = Vec3.zero(),

    origin_offset: Vec3 = Vec3.zero(),

    pub fn dupe(self: *@This()) !AABB {
        return self.*;
    }

    pub fn setFromOrigin(self: *@This(), new_origin: Vec3) void {
        const delta = new_origin.sub(self.a.add(self.origin_offset));
        self.a = self.a.add(delta);
        self.b = self.b.add(delta);
    }

    pub fn initFromJson(_: std.json.Value, _: anytype) !@This() {
        return error.notAllowed;
    }
};

pub const Entity = struct {
    origin: Vec3 = Vec3.zero(),
    angle: Vec3 = Vec3.zero(),
    class: []const u8 = "",
    model: ?[]const u8 = null,
    model_id: ?vpk.VpkResId = null,
    sprite: ?vpk.VpkResId = null,

    pub fn dupe(self: *const @This()) !@This() {
        return self.*;
    }

    pub fn drawEnt(ent: *@This(), editor: *Editor, view_3d: Mat4, draw: *DrawCtx, draw_nd: *DrawCtx, param: struct {
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
            draw.cubeFrame(ent.origin.sub(Vec3.new(8, 8, 8)), Vec3.new(16, 16, 16), param.frame_color);
            if (ent.sprite) |spr| {
                const isp = try editor.getTexture(spr);
                draw_nd.billboard(ent.origin, .{ .x = 16, .y = 16 }, isp.rect(), isp, editor.draw_state.cam3d);
            }
        }
    }
};

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

    pub fn normal(self: *@This(), solid: *Solid) Vec3 {
        const ind = self.index.items;
        if (ind.len < 3) return Vec3.zero();
        const v = solid.verts.items;
        return util3d.trianglePlane(.{ v[ind[0]], v[ind[1]], v[ind[2]] });
    }

    pub fn rebuild(side: *@This(), solid: *Solid, batch: *MeshBatch, editor: *Editor) !void {
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

    pub fn serial(self: @This(), editor: *Editor, jw: anytype) !void {
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

    pub fn translateSide(self: *@This(), id: EcsT.Id, vec: Vec3, editor: *Editor, side_i: usize) !void {
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

    pub fn rebuild(self: *@This(), id: EcsT.Id, editor: *Editor) !void {
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

    pub fn translate(self: *@This(), id: EcsT.Id, vec: Vec3, editor: *Editor) !void {
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

    pub fn removeFromMeshMap(self: *Self, id: EcsT.Id, editor: *Editor) !void {
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
    pub fn drawImmediate(self: *Self, draw: *DrawCtx, editor: *Editor, offset: Vec3, side_i: ?usize) !void {
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

pub const Displacement = struct {
    const Self = @This();
    verts: std.ArrayList(Vec3) = undefined,
    index: std.ArrayList(u32) = undefined,
    tex_id: vpk.VpkResId = 0,
    parent_id: EcsT.Id = 0,
    parent_side_i: usize = 0,
    power: u32 = 0,

    //TODO duping things with parents how
    pub fn dupe(self: *Self) !Self {
        var ret = self.*;
        ret.verts = try self.verts.clone();
        ret.index = try self.index.clone();

        return ret;
    }

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

    pub fn rebuild(self: *Self, batch: *MeshBatch, editor: *Editor) !void {
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

pub const EditorInfo = struct {
    //pub const ECS_NO_SERIAL = void;
    vis_mask: VisGroups.BitSetT = VisGroups.BitSetT.initEmpty(),

    pub fn dupe(a: *@This()) !@This() {
        return a.*;
    }

    pub fn initFromJson(_: std.json.Value, _: anytype) !@This() {
        return .{ .vis_mask = VisGroups.BitSetT.initEmpty() };
    }
    pub fn serial(self: @This(), _: *Editor, jw: anytype) !void {
        const mask_count = self.vis_mask.masks.len;
        if (mask_count != 2)
            @compileError("fix this lol");
        try jw.print("\"{x}_{x}\"", .{ self.vis_mask.masks[0], self.vis_mask.masks[1] });
    }
};

//TODO Storing the damn strings
//having hundreds of arraylists is probably slow.,
//most kvs are small < 16bytes
//on x64 an array list is 40bytes
//for now just use array list
pub const KeyValues = struct {
    const Value = union(enum) {
        const MAX_FLOAT = 8;
        string: std.ArrayList(u8),
        floats: struct { count: u8, d: [MAX_FLOAT]f32 },
        //float4: [4]f32,

        pub fn toFloats(self: *@This(), comptime count: u8) !void {
            if (count >= MAX_FLOAT)
                @compileError("not enough floats");
            switch (self.*) {
                .floats => {
                    self.floats.count = count;
                    //TODO zero out new floats
                    return;
                },
                .string => {
                    var it = std.mem.splitScalar(u8, self.string.items, ' ');
                    var ret: [MAX_FLOAT]f32 = undefined;
                    for (0..count) |i| {
                        ret[i] = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
                    }
                    self.string.deinit();
                    self.* = .{ .floats = .{ .count = count, .d = ret } };
                },
            }
        }

        pub fn clone(self: *@This()) !@This() {
            switch (self.*) {
                .string => return .{ .string = try self.string.clone() },
                else => return self.*,
            }
        }

        pub fn deinit(self: *@This()) void {
            switch (self.*) {
                .string => |str| str.deinit(),
                else => {},
            }
        }
    };
    const Self = @This();
    const MapT = std.StringHashMap(Value);
    map: MapT,

    pub fn dupe(self: *Self) !Self {
        var ret = Self{
            .map = try self.map.clone(),
        };
        var it = ret.map.valueIterator();
        while (it.next()) |item| {
            item.* = try item.clone();
        }
        return ret;
    }

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .map = MapT.init(alloc),
        };
    }

    pub fn initFromJson(v: std.json.Value, ctx: anytype) !@This() {
        if (v != .object) return error.broken;
        var ret = init(ctx.alloc);

        var it = v.object.iterator();
        while (it.next()) |item| {
            if (item.value_ptr.* != .string) return error.invalidKv;
            var new_list = std.ArrayList(u8).init(ctx.alloc);
            try new_list.appendSlice(item.value_ptr.string);
            try ret.map.put(try ctx.str_store.store(item.key_ptr.*), .{ .string = new_list });
        }

        return ret;
    }

    pub fn serial(self: @This(), edit: *Editor, jw: anytype) !void {
        try jw.beginObject();
        {
            var it = self.map.iterator();
            while (it.next()) |item| {
                try jw.objectField(item.key_ptr.*);
                switch (item.value_ptr.*) {
                    .string => |str| try jw.write(str.items),
                    .floats => |c| {
                        edit.scratch_buf.clearRetainingCapacity();
                        for (c.d[0..c.count]) |cc|
                            try edit.scratch_buf.writer().print("{d} ", .{cc});

                        try jw.write(edit.scratch_buf.items);
                        //try jw.print("\"{d} {d} {d}\"", .{ c[0], c[1], c[2] }),
                    },
                    //else => try jw.write(""), //TODO store type data
                }
            }
        }
        try jw.endObject();
    }

    pub fn deinit(self: *Self) void {
        var it = self.map.valueIterator();
        while (it.next()) |item|
            item.deinit();
        self.map.deinit();
    }
};
