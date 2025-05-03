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

const util3d = @import("util_3d.zig");

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
            if (try editor.ecs.getOptPtr(id.key_ptr.*, .solid)) |solid| {
                for (solid.sides.items) |*side| {
                    if (side.tex_id == self.tex_res_id) {
                        try side.rebuild(self, editor);
                    }
                }
            }
        }
        self.mesh.setData();
    }
};
pub const MeshMap = std.StringHashMap(*MeshBatch);
pub const Side = struct {
    pub const UVaxis = struct {
        axis: Vec3,
        trans: f32,
        scale: f32,
    };
    verts: std.ArrayList(Vec3), // all verts must lie in the same plane
    index: std.ArrayList(u32),
    u: UVaxis,
    v: UVaxis,
    tex_id: vpk.VpkResId = 0, //Used for drawing immediate
    tw: i32 = 0,
    th: i32 = 0,
    material: []const u8, //owned by somebody else
    pub fn deinit(self: @This()) void {
        self.verts.deinit();
        self.index.deinit();
    }

    pub fn rebuild(side: *@This(), batch: *MeshBatch, editor: *Context) !void {
        side.tex_id = batch.tex_res_id;
        side.tw = batch.tex.w;
        side.th = batch.tex.h;
        const mesh = &batch.mesh;
        try mesh.vertices.ensureUnusedCapacity(side.verts.items.len);
        try mesh.indicies.ensureUnusedCapacity(side.index.items.len);
        const uvs = try editor.csgctx.calcUVCoords(
            side.verts.items,
            side.*,
            @intCast(batch.tex.w),
            @intCast(batch.tex.h),
        );
        const offset = mesh.vertices.items.len;
        for (side.verts.items, 0..) |v, i| {
            try mesh.vertices.append(.{
                .x = v.x(),
                .y = v.y(),
                .z = v.z(),
                .u = uvs[i].x,
                .v = uvs[i].y,
                .nx = 0,
                .ny = 0,
                .nz = 0,
                .color = 0xffffffff,
            });
        }
        for (side.index.items) |ind| {
            try mesh.indicies.append(ind + @as(u32, @intCast(offset)));
        }
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
};

pub const Solid = struct {
    const Self = @This();
    sides: std.ArrayList(Side),

    /// Bounding box is used during broad phase ray tracing
    /// they are recomputed along with vertex arrays
    pub fn init(alloc: std.mem.Allocator) Solid {
        return .{
            .sides = std.ArrayList(Side).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.sides.items) |side|
            side.deinit();
        self.sides.deinit();
    }

    pub fn recomputeBounds(self: *Self, aabb: *AABB) void {
        var min = Vec3.set(std.math.floatMax(f32));
        var max = Vec3.set(-std.math.floatMax(f32));
        for (self.sides.items) |side| {
            for (side.verts.items) |s| {
                min = min.min(s);
                max = max.max(s);
            }
        }
        aabb.a = min;
        aabb.b = max;
    }

    pub fn translate(self: *@This(), id: EcsT.Id, vec: Vec3, editor: *Context) !void {
        //move all verts, recompute bounds
        //for each batchid, call rebuild

        for (self.sides.items) |*side| {
            for (side.verts.items) |*vert| {
                vert.* = vert.add(vec);
            }
            side.u.trans = side.u.trans - (vec.dot(side.u.axis)) / side.u.scale;
            side.v.trans = side.v.trans - (vec.dot(side.v.axis)) / side.v.scale;

            const batch = editor.meshmap.getPtr(side.material) orelse continue;
            batch.*.is_dirty = true;

            //ensure this is in batch
            try batch.*.contains.put(id, {});
        }
        const bb = try editor.ecs.getPtr(id, .bounding_box);
        self.recomputeBounds(bb);

        //TODO move this somewhere else and do it proper
        var it = editor.meshmap.iterator();
        while (it.next()) |mesh| {
            try mesh.value_ptr.*.rebuildIfDirty(editor);
        }
    }

    pub fn removeFromMeshMap(self: *Self, id: EcsT.Id, editor: *Context) !void {
        for (self.sides.items) |side| {
            const batch = editor.meshmap.getPtr(side.material) orelse continue;
            batch.*.is_dirty = true;
            _ = batch.*.contains.remove(id);
        }
        var it = editor.meshmap.iterator();
        while (it.next()) |mesh| {
            try mesh.value_ptr.*.rebuildIfDirty(editor);
        }
    }

    pub fn drawImmediate(self: *Self, draw: *DrawCtx, editor: *Context, offset: Vec3) !void {
        for (self.sides.items) |side| {
            const batch = &(draw.getBatch(.{ .batch_kind = .billboard, .params = .{
                .shader = DrawCtx.billboard_shader,
                .texture = editor.getTexture(side.tex_id).id,
                .camera = ._3d,
            } }) catch unreachable).billboard;
            try batch.vertices.ensureUnusedCapacity(side.verts.items.len);
            try batch.indicies.ensureUnusedCapacity(side.index.items.len);
            const uvs = try editor.csgctx.calcUVCoords(
                side.verts.items,
                side,
                @intCast(side.tw),
                @intCast(side.th),
            );
            const ioffset = batch.vertices.items.len;
            for (side.verts.items, 0..) |v, i| {
                try batch.vertices.append(.{
                    .pos = .{
                        .x = v.x() + offset.x(),
                        .y = v.y() + offset.y(),
                        .z = v.z() + offset.z(),
                    },
                    .uv = .{
                        .x = uvs[i].x,
                        .y = uvs[i].y,
                    },
                    .color = 0xffffffff,
                });
            }
            for (side.index.items) |ind| {
                try batch.indicies.append(ind + @as(u32, @intCast(ioffset)));
            }
        }
    }
};

pub const Entity = struct {
    origin: Vec3,
    angle: Vec3,
    class: []const u8,
    model: ?[]const u8 = null,
    model_id: ?vpk.VpkResId = null,
    sprite: ?vpk.VpkResId = null,

    pub fn drawEnt(ent: *@This(), editor: *Context, view_3d: Mat4, draw: *DrawCtx, draw_nd: *DrawCtx) void {
        const ENT_RENDER_DIST = 64 * 10;
        if (ent.model_id) |m| {
            if (editor.models.getPtr(m)) |o_mod| {
                if (o_mod.*) |mod| {
                    const M4 = graph.za.Mat4;
                    //x: fwd
                    //y:left
                    //z: up

                    const x1 = M4.fromRotation(ent.angle.z(), Vec3.new(1, 0, 0));
                    const y1 = M4.fromRotation(ent.angle.y(), Vec3.new(0, 0, 1));
                    const z = M4.fromRotation(ent.angle.x(), Vec3.new(0, 1, 0));
                    const mat1 = graph.za.Mat4.fromTranslate(ent.origin);
                    //zyx
                    const mat3 = mat1.mul(z.mul(y1.mul(x1)));
                    //const mat3 = mat1.mul(y1.mul(x1.mul(z)));
                    mod.drawSimple(view_3d, mat3, editor.draw_state.basic_shader);
                }
            }
        }
        _ = draw;
        const dist = ent.origin.distance(editor.draw_state.cam3d.pos);
        if (dist > ENT_RENDER_DIST)
            return;
        //TODO set the model size of entities hitbox thingy
        if (ent.sprite) |spr| {
            draw_nd.cubeFrame(ent.origin.sub(Vec3.new(8, 8, 8)), Vec3.new(16, 16, 16), 0x00ff00ff);
            const isp = editor.getTexture(spr);
            draw_nd.billboard(ent.origin, .{ .x = 16, .y = 16 }, isp.rect(), isp, editor.draw_state.cam3d);
        }
        //if (editor.fgd_ctx.base.get(ent.class)) |base| {
        //    if (editor.icon_map.get(base.iconsprite)) |isp| {
        //        draw_nd.cubeFrame(ent.origin.sub(Vec3.new(8, 8, 8)), Vec3.new(16, 16, 16), 0x00ff00ff);
        //        draw_nd.billboard(ent.origin, .{ .x = 16, .y = 16 }, isp.rect(), isp, editor.draw_state.cam3d);
        //    }
        //}
    }
};

const Comp = graph.Ecs.Component;
pub const EcsT = graph.Ecs.Registry(&.{
    Comp("bounding_box", AABB),
    Comp("solid", Solid),
    Comp("entity", Entity),
});

const log = std.log.scoped(.rathammer);
pub const Context = struct {
    const Self = @This();
    const ButtonState = graph.SDL.ButtonState;

    rayctx: raycast.Ctx,
    csgctx: csg.Context,
    vpkctx: vpk.Context,
    meshmap: MeshMap,
    lower_buf: std.ArrayList(u8),
    scratch_buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    name_arena: std.heap.ArenaAllocator,
    string_storage: StringStorage,

    fgd_ctx: fgd.EntCtx,
    icon_map: std.StringHashMap(graph.Texture),

    textures: std.AutoHashMap(vpk.VpkResId, graph.Texture),
    models: std.AutoHashMap(vpk.VpkResId, ?*vvd.MultiMesh),
    skybox: Skybox,

    asset_browser: assetbrowse.AssetBrowserGui,

    ecs: EcsT,

    temp_line_array: std.ArrayList([2]Vec3),

    texture_load_ctx: texture_load_thread.Context,

    draw_state: struct {
        draw_tools: bool = true,
        basic_shader: graph.glID,
        cam3d: graph.Camera3D = .{ .up = .z, .move_speed = 50, .max_move_speed = 100 },
        cam_far_plane: f32 = 512 * 64,

        /// we keep our own so that we can do some draw calls with depth some without.
        ctx: graph.ImmediateDrawingContext,
    },

    edit_state: struct {
        show_gui: bool = false,
        gui_tab: enum {
            model,
            texture,
            fgd,
        } = .model,
        state: enum {
            select,
            face_manip,
            model_place,
        } = .select,

        id: ?EcsT.Id = null,
        lmouse: ButtonState = .low,
        rmouse: ButtonState = .low,

        gizmo: Gizmo = .{},

        btn_x_trans: ButtonState = .low,
        btn_y_trans: ButtonState = .low,
        btn_z_trans: ButtonState = .low,
        trans_begin: graph.Vec2f = undefined,
        trans_end: graph.Vec2f = undefined,
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
    },

    pub fn init(alloc: std.mem.Allocator, num_threads: ?u32, config: Conf.Config) !Self {
        return .{
            //These are initilized in editor.postInit
            .dirs = undefined,
            .game_conf = undefined,

            .rayctx = raycast.Ctx.init(alloc),
            .config = config,
            .alloc = alloc,
            .fgd_ctx = fgd.EntCtx.init(alloc),
            .string_storage = StringStorage.init(alloc),
            .asset_browser = assetbrowse.AssetBrowserGui.init(alloc),
            .name_arena = std.heap.ArenaAllocator.init(alloc),
            .csgctx = try csg.Context.init(alloc),
            .vpkctx = try vpk.Context.init(alloc),
            .meshmap = MeshMap.init(alloc),
            .ecs = try EcsT.init(alloc),
            .lower_buf = std.ArrayList(u8).init(alloc),
            .scratch_buf = std.ArrayList(u8).init(alloc),
            .models = std.AutoHashMap(vpk.VpkResId, ?*vvd.MultiMesh).init(alloc),
            .texture_load_ctx = try texture_load_thread.Context.init(alloc, num_threads),
            .textures = std.AutoHashMap(vpk.VpkResId, graph.Texture).init(alloc),
            .skybox = try Skybox.init(alloc),
            .temp_line_array = std.ArrayList([2]Vec3).init(alloc),
            .icon_map = std.StringHashMap(graph.Texture).init(alloc),

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

        const cwd = if (args.custom_cwd) |cc| try std.fs.cwd().openDir(cc, .{}) else std.fs.cwd();
        const base_dir = try cwd.openDir(args.basedir orelse game_conf.base_dir, .{});
        const game_dir = try cwd.openDir(args.gamedir orelse game_conf.game_dir, .{});
        const fgd_dir = try cwd.openDir(args.fgddir orelse game_conf.fgd_dir, .{});
        self.dirs = .{ .cwd = cwd, .base = base_dir, .game = game_dir, .fgd = fgd_dir };
        try gameinfo.loadGameinfo(self.alloc, base_dir, game_dir, &self.vpkctx);
        try self.asset_browser.populate(&self.vpkctx, game_conf.asset_browser_exclude.prefix, game_conf.asset_browser_exclude.entry.items);
        try fgd.loadFgd(&self.fgd_ctx, fgd_dir, args.fgd orelse game_conf.fgd);
    }

    pub fn deinit(self: *Self) void {
        self.ecs.deinit();
        self.fgd_ctx.deinit();
        self.icon_map.deinit();
        self.lower_buf.deinit();
        self.string_storage.deinit();
        self.rayctx.deinit();
        self.scratch_buf.deinit();
        self.asset_browser.deinit();
        self.csgctx.deinit();
        self.vpkctx.deinit();
        self.skybox.deinit();
        var mit = self.models.valueIterator();
        while (mit.next()) |m| {
            if (m.*) |mm| {
                mm.deinit();
                self.alloc.destroy(mm);
            }
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
                for (solid.sides.items) |*side| {
                    const batch = self.meshmap.getPtr(side.material) orelse continue;
                    try side.rebuild(batch.*, self);
                }
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

    ///Given a csg defined solid, convert to mesh and store.
    pub fn putSolidFromVmf(self: *Self, solid: vmf.Solid) !void {
        const StrCtx = std.hash_map.StringContext;
        const new = try self.ecs.createEntity();
        for (solid.side) |*side| {
            const res = try self.meshmap.getOrPutAdapted(side.material, StrCtx{});
            if (!res.found_existing) {
                res.key_ptr.* = try self.storeString(side.material);
                const tex = try self.loadTextureFromVpk(side.material);
                res.value_ptr.* = try self.alloc.create(MeshBatch);
                res.value_ptr.*.* = .{
                    .notify_vt = .{ .notify_fn = &MeshBatch.notify },
                    .tex = tex.tex,
                    .tex_res_id = tex.res_id,
                    .mesh = undefined,
                    .contains = std.AutoHashMap(EcsT.Id, void).init(self.alloc),
                };
                res.value_ptr.*.mesh = meshutil.Mesh.init(self.alloc, res.value_ptr.*.tex.id);

                try self.texture_load_ctx.addNotify(tex.res_id, &res.value_ptr.*.notify_vt);
            }
            try res.value_ptr.*.contains.put(new, {});
        }
        const newsolid = try self.csgctx.genMesh(
            solid.side,
            self.alloc,
            &self.string_storage,
            //@intCast(self.set.sparse.items.len),
        );
        try self.ecs.attach(new, .solid, newsolid);
        try self.ecs.attach(new, .bounding_box, .{});
        //try self.set.insert(newsolid.id, newsolid);
    }

    pub fn loadVmf(self: *Self, path: std.fs.Dir, filename: []const u8, loadctx: *LoadCtx) !void {
        var timer = try std.time.Timer.start();
        defer log.info("Loaded vmf in {d}ms", .{timer.read() / std.time.ns_per_ms});
        const infile = try path.openFile(filename, .{});
        defer infile.close();

        const slice = try infile.reader().readAllAlloc(self.alloc, std.math.maxInt(usize));
        defer self.alloc.free(slice);
        var aa = std.heap.ArenaAllocator.init(self.alloc);
        var obj = try vdf.parse(self.alloc, slice);
        defer obj.deinit();
        loadctx.cb("vmf parsed");
        const vmf_ = try vdf.fromValue(vmf.Vmf, &.{ .obj = &obj.value }, aa.allocator(), null);
        try self.skybox.loadSky(vmf_.world.skyname, &self.vpkctx);
        {
            var gen_timer = try std.time.Timer.start();
            for (vmf_.world.solid, 0..) |solid, si| {
                try self.putSolidFromVmf(solid);
                loadctx.printCb("csg generated {d} / {d}", .{ si, vmf_.world.solid.len });
            }
            for (vmf_.entity, 0..) |ent, ei| {
                loadctx.printCb("ent generated {d} / {d}", .{ ei, vmf_.entity.len });
                for (ent.solid) |solid|
                    try self.putSolidFromVmf(solid);
                {
                    const new = try self.ecs.createEntity();
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
                    }
                    var sprite_tex: ?vpk.VpkResId = null;
                    { //Fgd stuff
                        if (self.fgd_ctx.base.get(ent.classname)) |base| {
                            var sl = base.iconsprite;
                            if (std.mem.endsWith(u8, base.iconsprite, ".vmt"))
                                sl = base.iconsprite[0 .. base.iconsprite.len - 4];
                            const sprite_tex_ = try self.loadTextureFromVpk(sl);
                            if (sprite_tex_.res_id != 0)
                                sprite_tex = sprite_tex_.res_id;
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
        try self.models.put(res_id, null);
        try self.texture_load_ctx.loadModel(res_id, mod, &self.vpkctx);
        return res_id;
    }

    pub fn loadModelOld(self: *Self, model_name: []const u8) !*vvd.MultiMesh {
        const res_id = try self.modelIdFromName(model_name) orelse return error.noMdl;
        if (self.models.getPtr(res_id)) |ptr| return ptr;

        const mod = try self.storeString(model_name);

        const mesh = try vvd.loadModelCrappy(self.alloc, mod, self);
        try self.models.put(res_id, mesh);
        if (self.models.getPtr(res_id)) |ptr| return ptr;
        unreachable;
    }

    pub fn storeString(self: *Self, string: []const u8) ![]const u8 {
        return try self.string_storage.store(string);
    }

    pub fn getTexture(self: *Self, res_id: vpk.VpkResId) graph.Texture {
        if (self.textures.get(res_id)) |tex| return tex;

        return missingTexture();
    }

    pub fn loadTextureFromVpkFail(self: *Self, material: []const u8) !graph.Texture {
        if (try self.vpkctx.getFileTempFmt("vmt", "materials/{s}", .{material})) |tt| {
            var obj = try vdf.parse(self.alloc, tt);
            defer obj.deinit();
            //All vmt are a single root object with a shader name as key
            if (obj.value.list.items.len > 0) {
                const fallback_keys = [_][]const u8{
                    "$basetexture", "%tooltexture",
                };
                const ob = obj.value.list.items[0].val;
                switch (ob) {
                    .obj => |o| {
                        for (fallback_keys) |fbkey| {
                            if (o.getFirst(fbkey)) |base| {
                                if (base == .literal) {
                                    return try vtf.loadTexture(
                                        (try self.vpkctx.getFileTempFmt(
                                            "vtf",
                                            "materials/{s}",
                                            .{base.literal},
                                        )) orelse {
                                            return error.notfound;
                                        },
                                        self.alloc,
                                    );
                                }
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        return try vtf.loadTexture(
            (try self.vpkctx.getFileTempFmt("vtf", "materials/{s}", .{material})) orelse return error.notfoundGeneric,
            //(self.vpkctx.getFileTemp("vtf", sl[0..slash], sl[slash + 1 ..]) catch |err| break :in err) orelse break :in error.notfound,
            self.alloc,
        );
        //defer bmp.deinit();
        //break :blk graph.Texture.initFromBitmap(bmp, .{});
    }

    pub fn loadTexture(self: *Self, res_id: vpk.VpkResId) !void {
        if (self.textures.get(res_id)) |_| return;
        try self.textures.put(res_id, missingTexture());
        try self.texture_load_ctx.loadTexture(res_id, &self.vpkctx);
    }

    pub fn loadTextureFromVpk(self: *Self, material: []const u8) !struct { tex: graph.Texture, res_id: vpk.VpkResId } {
        const res_id = try self.vpkctx.getResourceIdFmt("vmt", "materials/{s}", .{material}) orelse return .{ .tex = missingTexture(), .res_id = 0 };
        if (self.textures.get(res_id)) |tex| return .{ .tex = tex, .res_id = res_id };

        try self.textures.put(res_id, missingTexture());
        try self.texture_load_ctx.loadTexture(res_id, &self.vpkctx);

        return .{ .tex = missingTexture(), .res_id = res_id };
    }

    fn camRay(self: *Self) [2]Vec3 {
        return [_]Vec3{ self.draw_state.cam3d.pos, self.draw_state.cam3d.front };
    }

    pub fn update(self: *Self) !void {
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

            var num_removed: usize = 0;
            for (self.texture_load_ctx.completed_models.items) |*completed| {
                var model = completed.mesh;
                model.initGl();
                try self.models.put(completed.res_id, model);
                for (completed.texture_ids.items) |tid| {
                    try self.texture_load_ctx.addNotify(tid, &completed.mesh.notify_vt);
                }
                for (model.meshes.items) |*mesh| {
                    const t = self.getTexture(mesh.tex_res_id);
                    mesh.texture_id = t.id;
                }
                completed.texture_ids.deinit();
                num_removed += 1;

                const elapsed = timer.read();
                if (elapsed > MAX_UPDATE_TIME)
                    break;
            }
            for (0..num_removed) |_|
                _ = self.texture_load_ctx.completed_models.orderedRemove(0);
        }
        if (tcount > 0) {
            var it = self.meshmap.iterator();
            while (it.next()) |mesh| {
                try mesh.value_ptr.*.rebuildIfDirty(self);
            }
        }
    }

    pub fn draw3Dview(self: *Self, screen_area: graph.Rect, draw: *graph.ImmediateDrawingContext) !void {
        try self.draw_state.ctx.beginNoClear(screen_area.dim());
        // draw_nd "draw no depth" is for any immediate drawing after the depth buffer has been cleared.
        // "draw" still has depth buffer
        const draw_nd = &self.draw_state.ctx;
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
        const mat = graph.za.Mat4.identity();

        const view_3d = self.draw_state.cam3d.getMatrix(screen_area.w / screen_area.h, 1, self.draw_state.cam_far_plane);

        var it = self.meshmap.iterator();
        while (it.next()) |mesh| {
            if (!self.draw_state.draw_tools and std.mem.startsWith(u8, mesh.key_ptr.*, "TOOLS"))
                continue;
            mesh.value_ptr.*.mesh.drawSimple(view_3d, mat, self.draw_state.basic_shader);
        }

        {
            var ent_it = self.ecs.iterator(.entity);
            while (ent_it.next()) |ent| {
                ent.drawEnt(self, view_3d, draw, draw_nd);
            }
        }
        { //sky stuff
            const trans = graph.za.Mat4.fromTranslate(self.draw_state.cam3d.pos);
            const c = graph.c;
            c.glDepthMask(c.GL_FALSE);
            c.glDepthFunc(c.GL_LEQUAL);
            defer c.glDepthFunc(c.GL_LESS);
            defer c.glDepthMask(c.GL_TRUE);

            for (self.skybox.meshes.items, 0..) |*sk, i| {
                sk.draw(.{ .texture = self.skybox.textures.items[i].id, .shader = self.skybox.shader }, view_3d, trans);
            }
        }
        try draw.flush(null, self.draw_state.cam3d);

        if (self.edit_state.btn_x_trans == .rising or self.edit_state.btn_y_trans == .rising)
            self.edit_state.state = .face_manip;

        if (self.edit_state.id) |id| {
            switch (self.edit_state.state) {
                .face_manip => {
                    if (try self.ecs.getOptPtr(id, .solid)) |solid| {
                        var near_i: usize = 100000;
                        var far_i: usize = 100000;
                        var near: f32 = std.math.floatMax(f32);
                        var far: f32 = std.math.floatMin(f32);
                        if (try self.ecs.getOpt(id, .bounding_box)) |bb| {
                            _ = bb;
                            const sel_near = self.edit_state.btn_x_trans;
                            var s_index: usize = 1000000;
                            if (sel_near == .high) {
                                const r = self.camRay();
                                //Find the face it intersects with
                                if (try raycast.doesRayIntersectSolid(
                                    r[0],
                                    r[1],
                                    solid,
                                    &self.csgctx,
                                )) |face_inter| {
                                    const d = face_inter.point.distance(self.draw_state.cam3d.pos);
                                    if (d < near) {
                                        near_i = face_inter.side_index;
                                        near = d;
                                    } else if (d > far) {
                                        far_i = face_inter.side_index;
                                        far = d;
                                    }
                                    //_ = face_inter;
                                    s_index = face_inter.side_index;
                                }
                            }
                            if (near_i >= solid.sides.items.len or far_i >= solid.sides.items.len) {
                                //This isn't an error condition, we can intersect only one if we are inside of the solid.
                                //std.debug.print("BROKEN IS \n", .{});
                            }
                            for (solid.sides.items, 0..) |side, s_i| {
                                const v = side.verts.items;
                                var color: u32 = if (near_i == s_i) 0xffffffff else 0xff00ff;
                                color = if (far_i == s_i) 0xffffffff else color;
                                if (side.verts.items.len > 0) {
                                    var last = side.verts.items[side.verts.items.len - 1];
                                    const vs = side.verts.items;
                                    if (s_i == near_i)
                                        draw_nd.triangle3D(vs[0..3], 0xffff);
                                    if (s_i == far_i)
                                        draw_nd.triangle3D(vs[0..3], 0xff00ff);
                                    for (0..side.verts.items.len) |ti| {
                                        draw.line3D(last, v[ti], color);
                                        draw.point3D(v[ti], 0xff0000ff);
                                        last = v[ti];
                                    }
                                }
                            }
                        }
                    }
                },
                .select => {
                    if (try self.ecs.getOptPtr(id, .solid)) |solid| {
                        if (try self.ecs.getOpt(id, .bounding_box)) |bb| {
                            const mid_i = bb.a.add(bb.b).scale(0.5);
                            var mid = mid_i;
                            const giz_active = self.edit_state.gizmo.handle(
                                mid,
                                &mid,
                                self.draw_state.cam3d.pos,
                                self.edit_state.lmouse,
                                draw_nd,
                                screen_area.dim(),
                                view_3d,
                                self.edit_state.trans_begin,
                            );

                            for (solid.sides.items) |side| {
                                const v = side.verts.items;
                                if (side.verts.items.len > 0) {
                                    var last = side.verts.items[side.verts.items.len - 1];
                                    for (0..side.verts.items.len) |ti| {
                                        draw_nd.line3D(last, v[ti], 0xff00ff);
                                        draw_nd.point3D(v[ti], 0xff0000ff);
                                        last = v[ti];
                                    }
                                }
                            }
                            if (giz_active == .rising) {
                                try solid.removeFromMeshMap(id, self);
                            }
                            if (giz_active == .falling) {
                                try solid.translate(id, Vec3.zero(), self); //Dummy to put it bake in the mesh batch
                            }

                            if (giz_active == .high) {
                                var dist = mid.sub(mid_i);
                                dist.data = @floor(dist.data); //Only integer
                                try solid.drawImmediate(
                                    draw,
                                    self,
                                    dist,
                                );
                                if (self.edit_state.rmouse == .rising) {
                                    try solid.translate(id, dist, self);
                                    //Commit the changes
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
                            draw,
                            screen_area.dim(),
                            view_3d,
                            self.edit_state.trans_begin,
                        );
                        if (giz_active == .high) {
                            var orr = orig;
                            orr.data = @floor(orr.data); //Only allow integer coords
                            var copy_ent = ent.*;
                            copy_ent.origin = orr;
                            copy_ent.drawEnt(self, view_3d, draw, draw_nd);

                            //draw.cube(orr, Vec3.new(16, 16, 16), 0xff000022);
                            if (self.edit_state.rmouse == .rising) {
                                //Commit the changes
                                ent.origin = orr;
                                const bb = try self.ecs.getPtr(id, .bounding_box);
                                bb.setFromOrigin(orr);
                            }
                        }
                    }
                },
                .model_place => {
                    // if self.asset_browser.selected_model_vpk_id exists,
                    // do a raycast into the world and draw a model at nearest intersection with solid
                },
            }
        }
        try draw.flush(null, self.draw_state.cam3d);
        graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
        //Crosshair
        const cw = 4;
        const crossp = screen_area.center().sub(.{ .x = cw, .y = cw });
        draw_nd.rect(graph.Rec(
            crossp.x,
            crossp.y,
            cw * 2,
            cw * 2,
        ), 0xffffffff);
        //var ent_it = self.ecs.iterator(.entity);
        //while (ent_it.next()) |ent| {
        //    const dist = ent.origin.distance(self.draw_state.cam3d.pos);
        //    if (dist > ENT_RENDER_DIST)
        //        continue;
        //    if (self.fgd_ctx.base.get(ent.class)) |base| {
        //        if (self.icon_map.get(base.iconsprite)) |isp| {
        //            draw.cubeFrame(ent.origin.sub(Vec3.new(8, 8, 8)), Vec3.new(16, 16, 16), 0x00ff00ff);
        //            draw.billboard(ent.origin, .{ .x = 16, .y = 16 }, isp.rect(), isp, self.draw_state.cam3d);
        //        }
        //    }
        //}
        //if (self.edit_state.lmouse == .rising) {
        //    const rc = util3d.screenSpaceRay(screen_area.dim(), self.edit_state.trans_begin, view_3d);

        //    //std.debug.print("Putting {} {}\n", .{ ray_world, ray_endw });
        //    try self.temp_line_array.append([2]Vec3{ rc[0], rc[0].add(rc[1].scale(1000)) });
        //}
        //for (self.temp_line_array.items) |tl| {
        //    draw.line3D(tl[0], tl[1], 0xff00ffff);
        //}
        try draw_nd.flush(null, self.draw_state.cam3d);
    }

    pub fn drawInspector(self: *Self, screen_area: graph.Rect, os9gui: *graph.Os9Gui) !void {
        if (try os9gui.beginTlWindow(screen_area)) {
            defer os9gui.endTlWindow();
            const gui = &os9gui.gui;
            if (gui.getArea()) |win_area| {
                const area = win_area.inset(6 * os9gui.scale);
                _ = try gui.beginLayout(Gui.SubRectLayout, .{ .rect = area }, .{});
                defer gui.endLayout();

                //_ = try os9gui.beginH(2);
                //defer os9gui.endL();
                if (try os9gui.beginVScroll(&self.misc_gui_state.scroll_a, .{ .sw = area.w, .sh = 1000000 })) |scr| {
                    defer os9gui.endVScroll(scr);
                    os9gui.label("Current Tool: {s}", .{@tagName(self.edit_state.state)});
                    if (self.edit_state.id) |id| {
                        if (try self.ecs.getOptPtr(id, .entity)) |ent| {
                            if (self.fgd_ctx.base.get(ent.class)) |base| {
                                os9gui.label("{s}", .{base.name});
                                scr.layout.pushHeight(400);
                                _ = try os9gui.beginL(Gui.TableLayout{ .columns = 2, .item_height = 30 });
                                for (base.fields.items) |f| {
                                    os9gui.label("{s}", .{f.name});
                                    switch (f.type) {
                                        .choices => |ch| {
                                            if (ch.items.len == 2 and std.mem.eql(u8, ch.items[0][0], "0")) {
                                                var chekd: bool = false;
                                                _ = os9gui.checkbox("", &chekd);

                                                continue;
                                            }
                                            const Ctx = struct {
                                                kvs: []const fgd.EntClass.Field.Type.KV,
                                                index: usize = 0,
                                                pub fn next(ctx: *@This()) ?struct { usize, []const u8 } {
                                                    if (ctx.index >= ctx.kvs.len)
                                                        return null;
                                                    defer ctx.index += 1;
                                                    return .{ ctx.index, ctx.kvs[ctx.index][1] };
                                                }
                                            };
                                            var index: usize = 0;
                                            var ctx = Ctx{
                                                .kvs = ch.items,
                                            };
                                            try os9gui.combo(
                                                "{s}",
                                                .{ch.items[0][1]},
                                                &index,
                                                ch.items.len,
                                                &ctx,
                                                Ctx.next,
                                            );
                                        },
                                        else => os9gui.label("{s}", .{f.default}),
                                    }
                                }
                                os9gui.endL();
                            }
                        }
                        if (try self.ecs.getOptPtr(id, .solid)) |solid| {
                            os9gui.label("Solid with {d} sides", .{solid.sides.items.len});
                            for (solid.sides.items) |side| {
                                os9gui.label("Texture: {s}", .{side.material});
                            }
                        }
                        //scr.layout.padding.top = 0;
                        //scr.layout.padding.bottom = 0;
                        //{
                        //    var eit = self.vpkctx.extensions.iterator();
                        //    var i: usize = 0;
                        //    while (eit.next()) |item| {
                        //        if (os9gui.button(item.key_ptr.*))
                        //            expanded.items[i] = !expanded.items[i];

                        //        if (expanded.items[i]) {
                        //            var pm = item.value_ptr.iterator();
                        //            while (pm.next()) |p| {
                        //                var cc = p.value_ptr.iterator();
                        //                if (!std.mem.startsWith(u8, p.key_ptr.*, textbox.arraylist.items))
                        //                    continue;
                        //                _ = os9gui.label("{s}", .{p.key_ptr.*});
                        //                while (cc.next()) |c| {
                        //                    if (os9gui.buttonEx("        {s}", .{c.key_ptr.*}, .{})) {
                        //                        const sl = try self.vpkctx.getFileTemp(item.key_ptr.*, p.key_ptr.*, c.key_ptr.*);
                        //                        displayed_slice.clearRetainingCapacity();
                        //                        try displayed_slice.appendSlice(sl.?);
                        //                    }
                        //                }
                        //            }
                        //        }
                        //        i += 1;
                        //    }
                        //}

                        //os9gui.slider(&index, 0, 1000);
                        //scr.layout.pushHeight(area.w);
                        //const ar = gui.getArea() orelse return;
                        //gui.drawRectTextured(ar, 0xffffffff, graph.Rec(0, 0, 1, 1), .{ .id = index, .w = 1, .h = 1 });
                    }
                }
                {
                    _ = try os9gui.beginV();
                    defer os9gui.endL();
                    //try os9gui.textbox2(&textbox, .{});

                    //os9gui.gui.drawText(displayed_slice.items, ar.pos(), 40, 0xff, os9gui.font);
                }
            }
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
        //No need for high fps when loading, this is 15fps
        if (self.timer.read() / std.time.ns_per_ms < 66) {
            return;
        }
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
            tbox.h,
            0xff,
            .{},
            self.os9gui.font,
        );
        self.os9gui.gui.drawRectFilled(pbar.split(.vertical, pbar.w * perc)[0], 0xf7a41dff);
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
