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
const thread_pool = @import("thread_pool.zig");
const assetbrowse = @import("asset_browser.zig");
const Conf = @import("config.zig");
const undo = @import("undo.zig");
const tool_def = @import("tools.zig");
const util = @import("util.zig");
const Autosaver = @import("autosave.zig").Autosaver;
const NotifyCtx = @import("notify.zig").NotifyCtx;
const Selection = @import("selection.zig");
const VisGroups = @import("visgroup.zig");
const ecs = @import("ecs.zig");
const json_map = @import("json_map.zig");
const DISABLE_SPLASH = false;
const GroupId = ecs.Groups.GroupId;
const eviews = @import("editor_views.zig");

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
    map_json_version: []const u8,
    cam: JsonCamera,
};

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

pub threadlocal var mesh_build_time = profile.BasicProfiler.init();
pub const EcsT = ecs.EcsT;
const Side = ecs.Side;
const MeshBatch = ecs.MeshBatch;
const Displacement = ecs.Displacement;
const Entity = ecs.Entity;
const AABB = ecs.AABB;
const KeyValues = ecs.KeyValues;
pub const log = std.log.scoped(.rathammer);
pub const Context = struct {
    const Self = @This();
    const ButtonState = graph.SDL.ButtonState;

    /// Only real state is a timer, has helper functions for naming and pruning autosaves.
    autosaver: Autosaver,

    /// These two have no real state, just exist to prevent excessive memory allocation.
    rayctx: raycast.Ctx,
    csgctx: csg.Context,

    /// Manages mounting of vpks and assigning a unique id to all resource string paths.
    vpkctx: vpk.Context,

    scratch_buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    /// Stores all the mesh data for solids.
    meshmap: ecs.MeshMap,

    /// Store static strings for the lifetime of application
    string_storage: StringStorage,

    /// Stores undo state, most changes to world state (ecs) should be done through a undo vtable
    undoctx: undo.UndoContext,

    /// This sucks, clean it up
    fgd_ctx: fgd.EntCtx,

    /// These maps map vpkids to their respective resource,
    /// when fetching a resource with getTexture, etc. Something is always returned. If an entry does not exist,
    /// a job is submitted to the load thread pool and a placeholder is inserted into the map and returned
    textures: std.AutoHashMap(vpk.VpkResId, graph.Texture),
    models: std.AutoHashMap(vpk.VpkResId, Model),

    skybox: Skybox,

    /// Draw colored text messages to the screen for a short time
    notifier: NotifyCtx,

    /// Gui widget
    asset_browser: assetbrowse.AssetBrowserGui,

    /// Stores all the world state, solids, entities, disp, etc.
    ecs: EcsT,
    groups: ecs.Groups,

    async_asset_load: thread_pool.Context,
    /// Used to track tool txtures, so we can easily disable drawing, remove once visgroups are good.
    tool_res_map: std.AutoHashMap(vpk.VpkResId, void),
    visgroups: VisGroups,

    tools: tool_def.ToolRegistry,
    panes: eviews.PaneReg,

    draw_state: struct {
        tab_index: usize = 0,
        meshes_dirty: bool = false,

        //TODO remove this once we have a decent split system
        //Used by inspector when clicking select on a texture or model kv
        texture_browser_tab_index: usize = 1,
        model_browser_tab_index: usize = 2,

        /// This should be replaced with visgroups, for the most part.
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

    /// When we open a file dialog, this is the structure that gets passed as user context
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
        default_group_entity: enum { none, func_detail } = .func_detail,
        tool_index: usize = 0,
        /// used to determine if the tool has changed
        last_frame_tool_index: usize = 0,

        lmouse: ButtonState = .low,
        rmouse: ButtonState = .low,
        mpos: graph.Vec2f = undefined,

        grid_snap: f32 = 16,
    } = .{},

    //TODO this is inspector state
    misc_gui_state: struct {
        scroll_a: graph.Vec2f = .{ .x = 0, .y = 0 },
        inspector_index: usize = 0,
        selected_index: usize = 0,
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

    /// These are currently only used for baking all tool icons into an atlas.
    asset: graph.AssetBake.AssetMap,
    asset_atlas: graph.Texture,

    /// This arena is reset every frame
    frame_arena: std.heap.ArenaAllocator,
    /// basename of map, without extension or path
    loaded_map_name: ?[]const u8 = null,
    /// This is always relative to cwd
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

    pub fn init(alloc: std.mem.Allocator, num_threads: ?u32, config: Conf.Config, args: anytype) !*Self {
        var ret = try alloc.create(Context);
        ret.* = .{
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
            .groups = ecs.Groups.init(alloc),
            .config = config,
            .alloc = alloc,
            .fgd_ctx = fgd.EntCtx.init(alloc),
            .undoctx = undo.UndoContext.init(alloc),
            .string_storage = StringStorage.init(alloc),
            .asset_browser = assetbrowse.AssetBrowserGui.init(alloc),
            .tools = tool_def.ToolRegistry.init(alloc),
            .panes = eviews.PaneReg.init(alloc),
            .csgctx = try csg.Context.init(alloc),
            .vpkctx = try vpk.Context.init(alloc),
            .visgroups = VisGroups.init(alloc),
            .meshmap = ecs.MeshMap.init(alloc),
            .ecs = try EcsT.init(alloc),
            .scratch_buf = std.ArrayList(u8).init(alloc),
            .models = std.AutoHashMap(vpk.VpkResId, Model).init(alloc),
            .async_asset_load = try thread_pool.Context.init(alloc, num_threads),
            .textures = std.AutoHashMap(vpk.VpkResId, graph.Texture).init(alloc),
            .skybox = try Skybox.init(alloc),
            .tool_res_map = std.AutoHashMap(vpk.VpkResId, void).init(alloc),

            .draw_state = .{
                .ctx = graph.ImmediateDrawingContext.init(alloc),
                .basic_shader = try graph.Shader.loadFromFilesystem(alloc, std.fs.cwd(), &.{
                    .{ .path = "ratgraph/asset/shader/gbuffer.vert", .t = .vert },
                    .{ .path = "src/basic.frag", .t = .frag },
                }),
            },
        };
        //If an error occurs during initilization it is fatal so there is no reason to clean up resources.
        //Thus we call, defer editor.deinit(); after all is initialized..
        try ret.postInit(args);
        return ret;
    }

    /// Called by init
    fn postInit(self: *Self, args: anytype) !void {
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

        self.visgroups.deinit();
        self.tools.deinit();
        self.panes.deinit();
        self.tool_res_map.deinit();
        self.file_selection.file_buf.deinit();
        self.undoctx.deinit();
        self.ecs.deinit();
        self.fgd_ctx.deinit();
        self.notifier.deinit();
        self.selection.deinit();
        self.string_storage.deinit();
        self.rayctx.deinit();
        self.scratch_buf.deinit();
        self.asset_browser.deinit();
        self.csgctx.deinit();
        self.vpkctx.deinit();
        self.skybox.deinit();
        self.frame_arena.deinit();
        self.groups.deinit();
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
        self.draw_state.ctx.deinit();
        self.async_asset_load.deinit();

        //destroy does not take a pointer to alloc, so this is safe.
        self.alloc.destroy(self);
    }

    /// This is a wrapper around ecs.getOptPtr which only returns component if the visgroup component is attached.
    pub fn getComponent(self: *Self, index: EcsT.Id, comptime comp: EcsT.Components) ?*EcsT.Fields[@intFromEnum(comp)].ftype {
        const ent = self.ecs.getEntity(index) catch return null;
        if (!ent.isSet(@intFromEnum(comp))) return null;
        if (ent.isSet(@intFromEnum(EcsT.Components.invisible)))
            return null;
        return self.ecs.getPtr(index, comp) catch null;
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
        const wr = outfile.writer();
        var bwr = std.io.bufferedWriter(wr);
        const bb = bwr.writer();
        var jwr = std.json.writeStream(bb, .{ .whitespace = .indent_1 });
        try jwr.beginObject();
        {
            try jwr.objectField("editor");
            try jwr.write(.{
                .cam = JsonCamera.fromCam(self.draw_state.cam3d),
                .map_json_version = "0.0.1",
            });
            try jwr.objectField("sky_name");
            try jwr.write(self.skybox.sky_name);
            try jwr.objectField("objects");
            try jwr.beginArray();
            {
                for (self.ecs.entities.items, 0..) |ent, id| {
                    if (ent.isSet(EcsT.Types.tombstone_bit))
                        continue;
                    if (ent.isSet(@intFromEnum(EcsT.Components.deleted)))
                        continue;
                    try jwr.beginObject();
                    {
                        try jwr.objectField("id");
                        try jwr.write(id);

                        if (self.groups.getGroup(@intCast(id))) |group| {
                            try jwr.objectField("owned_group");
                            try jwr.write(group);
                        }

                        inline for (EcsT.Fields, 0..) |field, f_i| {
                            if (!@hasDecl(field.ftype, "ECS_NO_SERIAL")) {
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

    pub fn writeComponentToJson(self: *Self, jw: anytype, comp: anytype) !void {
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
                    if (field.name[0] == '_') { //Skip fields

                    } else {
                        try jw.objectField(field.name);
                        try self.writeComponentToJson(jw, @field(comp, field.name));
                    }
                }
                try jw.endObject();
            },
            else => @compileError("no work for : " ++ @typeName(T)),
        }
    }

    //TODO poke around codebase, make sure this rebuilds ALL the dependant state
    pub fn rebuildAllDependentState(self: *Self) !void {
        mesh_build_time.start();
        {
            var it = self.ecs.iterator(.entity);
            while (it.next()) |ent| {
                if (try self.ecs.getOptPtr(it.i, .key_values)) |kvs| {
                    if (kvs.getString("model")) |model| {
                        ent._model_id = self.modelIdFromName(model) catch null;
                    }
                }
                try ent.setClass(self, ent.class);
                // Clear before we iterate solids as they will insert themselves into here
                //ent.solids.clearRetainingCapacity();
            }
        }
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
                //if (solid._parent_entity) |pid| {
                //    try self.attachSolid(it.i, pid);
                //}
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

            try self.async_asset_load.addNotify(res_id, &res.value_ptr.*.notify_vt);
        }
        return res.value_ptr.*;
    }

    pub fn attachSolid(self: *Self, solid_id: EcsT.Id, parent_id: EcsT.Id) !void {
        if (try self.ecs.getOptPtr(parent_id, .entity)) |ent| {
            var found = false;
            for (ent.solids.items) |item| {
                if (item == solid_id) {
                    found = true;
                    break;
                }
            }
            if (!found)
                try ent.solids.append(solid_id);
        }
    }

    ///Given a csg defined solid, convert to mesh and store.
    pub fn putSolidFromVmf(self: *Self, solid: vmf.Solid, group_id: ?GroupId) !void {
        const new = try self.ecs.createEntity();
        try self.ecs.attach(new, .editor_info, .{ .vis_mask = try self.visgroups.getMaskFromEditorInfo(&solid.editor) });
        const newsolid = try self.csgctx.genMesh2(
            solid.side,
            self.alloc,
            &self.string_storage,
            self,
            //@intCast(self.set.sparse.items.len),
        );
        if (group_id) |gid| {
            try self.ecs.attach(new, .group, .{ .id = gid });
        }
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

        const jsonctx = json_map.InitFromJsonCtx{
            .alloc = self.alloc,
            .str_store = &self.string_storage,
        };
        var parsed = try json_map.loadJson(jsonctx, slice, loadctx, &self.ecs, &self.vpkctx, &self.groups);
        defer parsed.deinit();

        try self.setMapName(filename);

        try self.skybox.loadSky(try self.storeString(parsed.value.sky_name), &self.vpkctx);
        parsed.value.editor.cam.setCam(&self.draw_state.cam3d);

        loadctx.cb("Building meshes}");
        try self.rebuildAllDependentState();
    }

    //TODO write a vmf -> json utility like jsonToVmf.zig
    //Then, only have a single function to load serialized data into engine "loadJson"
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
        try self.visgroups.buildMappingFromVmf(vmf_.visgroups, null);
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
                const group_id = if (ent.solid.len > 0) try self.groups.newGroup(new) else 0;
                try self.ecs.attach(new, .editor_info, .{ .vis_mask = try self.visgroups.getMaskFromEditorInfo(&ent.editor) });
                for (ent.solid) |solid|
                    try self.putSolidFromVmf(solid, group_id);
                {
                    var bb = AABB{ .a = Vec3.new(0, 0, 0), .b = Vec3.new(16, 16, 16), .origin_offset = Vec3.new(8, 8, 8) };
                    var model_id: ?vpk.VpkResId = null;
                    if (ent.rest_kvs.count() > 0) {
                        var kvs = KeyValues.init(self.alloc);
                        var it = ent.rest_kvs.iterator();
                        while (it.next()) |item| {
                            var new_list = std.ArrayList(u8).init(self.alloc);
                            try new_list.appendSlice(item.value_ptr.*);
                            try kvs.map.put(try self.storeString(item.key_ptr.*), .{ .string = new_list });
                        }

                        if (kvs.getString("model")) |model| {
                            if (model.len > 0) {
                                model_id = self.modelIdFromName(model) catch null;
                                if (self.loadModel(model)) |m| {
                                    _ = m;
                                } else |err| {
                                    log.err("Load model failed with {}", .{err});
                                }
                            }
                        }

                        try self.ecs.attach(new, .key_values, kvs);
                    }
                    bb.setFromOrigin(ent.origin.v);
                    try self.ecs.attach(new, .entity, .{
                        .origin = ent.origin.v,
                        .angle = ent.angles.v,
                        .class = try self.storeString(ent.classname),
                        ._model_id = model_id,
                        ._sprite = null,
                    });
                    try self.ecs.attach(new, .bounding_box, bb);

                    {
                        var new_ent = try self.ecs.getPtr(new, .entity);
                        try new_ent.setClass(self, ent.classname);
                    }
                }

                //try procSolid(&editor.csgctx, alloc, solid, &editor.meshmap, &editor.vpkctx);
            }
            try self.rebuildAllDependentState();
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
        for (self.tools.vtables.items, 0..) |tool, i| {
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
        try self.async_asset_load.loadModel(res_id, mod, &self.vpkctx);
        return res_id;
    }

    pub fn loadModelFromId(self: *Self, res_id: vpk.VpkResId) !void {
        if (self.models.get(res_id)) |_| return; //Don't load model twice!
        if (self.vpkctx.namesFromId(res_id)) |names| {
            const mod = try self.storeString(try self.printScratch("{s}/{s}.{s}", .{ names.path, names.name, names.ext }));
            try self.models.put(res_id, Model.initEmpty(self.alloc));

            try self.async_asset_load.loadModel(res_id, mod, &self.vpkctx);
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
        try self.async_asset_load.loadTexture(res_id, &self.vpkctx);
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
        try self.notify("saving: {s}{s}", .{ path, basename }, 0xfca73fff);
        const name = try self.printScratch("{s}{s}.json", .{ path, basename });
        //TODO make copy of existing map incase something goes wrong
        const out_file = try std.fs.cwd().createFile(name, .{});
        defer out_file.close();
        if (self.writeToJson(out_file)) {
            try self.notify(" saved: {s}{s} in {d:.1}ms", .{ path, basename, timer.read() / std.time.ns_per_ms }, 0xff00ff);
        } else |err| {
            log.err("writeToJson failed ! {}", .{err});
            try self.notify("save failed!: {}", .{err}, 0xff0000ff);
        }
    }

    pub fn notify(self: *Self, comptime fmt: []const u8, args: anytype, color: u32) !void {
        log.info(fmt, args);
        try self.notifier.submitNotify(fmt, args, color);
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
                    try self.notify("Autosave failed!: {}", .{err}, 0xff0000ff);
                };
            } else |err| {
                log.err("Autosave failed with error {}", .{err});
                try self.notify("Autosave failed!: {}", .{err}, 0xff0000ff);
            }
            try self.notify("Autosaved: {s}", .{basename}, 0x00ff00ff);
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
        if (win.isBindState(self.config.keys.build_map.b, .rising)) {
            blk: {
                const lp = self.loaded_map_path orelse break :blk;
                const lm = self.loaded_map_name orelse break :blk;
                try self.saveAndNotify(lm, lp);
                var res = try std.process.Child.run(.{ .allocator = self.alloc, .argv = &.{
                    "zig-out/bin/jsonmaptovmf",
                    "--json",
                    try self.printScratch("{s}{s}.json", .{ lp, lm }),
                } });
                std.debug.print("{s}\n", .{res.stdout});
                std.debug.print("{s}\n", .{res.stderr});
                self.alloc.free(res.stdout);
                self.alloc.free(res.stderr);

                try self.notify("Exported map to vmf", .{}, 0x00ff00ff);
                res = try std.process.Child.run(.{ .allocator = self.alloc, .argv = &.{
                    "zig-out/bin/mapbuilder",
                    "--vmf",
                    "dump.vmf",
                } });
                std.debug.print("{s}\n", .{res.stdout});
                std.debug.print("{s}\n", .{res.stderr});
                self.alloc.free(res.stdout);
                self.alloc.free(res.stderr);
                try self.notify("built map", .{}, 0x00ff00ff);
            }
        }

        _ = self.frame_arena.reset(.retain_capacity);
        self.edit_state.last_frame_tool_index = self.edit_state.tool_index;
        const MAX_UPDATE_TIME = std.time.ns_per_ms * 16;
        var timer = try std.time.Timer.start();
        //defer std.debug.print("UPDATE {d} ms\n", .{timer.read() / std.time.ns_per_ms});
        var tcount: usize = 0;
        {
            self.async_asset_load.completed_mutex.lock();
            defer self.async_asset_load.completed_mutex.unlock();
            tcount = self.async_asset_load.completed.items.len;
            var num_rm_tex: usize = 0;
            for (self.async_asset_load.completed.items) |*completed| {
                if (completed.data.deinitToTexture(self.async_asset_load.alloc)) |texture| {
                    try self.textures.put(completed.vpk_res_id, texture);
                    self.async_asset_load.notifyTexture(completed.vpk_res_id, self);
                } else |err| {
                    log.err("texture init failed with : {}", .{err});
                }

                num_rm_tex += 1;
                const elapsed = timer.read();
                if (elapsed > MAX_UPDATE_TIME)
                    break;
            }
            for (0..num_rm_tex) |_|
                _ = self.async_asset_load.completed.orderedRemove(0);

            var completed_ids = std.ArrayList(vpk.VpkResId).init(self.frame_arena.allocator());
            var num_removed: usize = 0;
            for (self.async_asset_load.completed_models.items) |*completed| {
                var model = completed.mesh;
                model.initGl();
                try self.models.put(completed.res_id, .{ .mesh = model });
                for (completed.texture_ids.items) |tid| {
                    try self.async_asset_load.addNotify(tid, &completed.mesh.notify_vt);
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
                _ = self.async_asset_load.completed_models.orderedRemove(0);

            var m_it = self.ecs.iterator(.entity);
            while (m_it.next()) |ent| {
                if (ent._model_id) |mid| {
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

    //No need for high fps when loading. Only repaint this often.
    refresh_period_ms: usize = 66,

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
        if (self.timer.read() / std.time.ns_per_ms < self.refresh_period_ms) {
            return;
        }
        self.cb_count -= 1;
        var fbs = std.io.FixedBufferStream([]u8){ .buffer = &self.buffer, .pos = 0 };
        fbs.writer().print(fmt, args) catch return;
        self.cb(fbs.getWritten());
    }

    pub fn addExpected(self: *@This(), addition: usize) void {
        self.expected_cb += addition;
    }

    pub fn cb(self: *@This(), message: []const u8) void {
        self.cb_count += 1;
        if (self.timer.read() / std.time.ns_per_ms < self.refresh_period_ms) {
            return;
        }
        self.timer.reset();
        self.win.pumpEvents(.poll);
        self.draw.begin(0x678caaff, self.win.screen_dimensions.toF()) catch return;
        self.os9gui.resetFrame(.{}, self.win) catch return;
        //self.draw.text(.{ .x = 0, .y = 0 }, message, &self.font.font, 100, 0xffffffff);
        const perc: f32 = @as(f32, @floatFromInt(self.cb_count)) / @as(f32, @floatFromInt(self.expected_cb));
        self.drawSplash(perc, message);
        self.os9gui.drawGui(self.draw) catch return;
        self.draw.end(null) catch return;
        self.win.swap(); //So the window doesn't look too broken while loading
    }

    pub fn drawSplash(self: *@This(), perc: f32, message: []const u8) void {
        if (DISABLE_SPLASH)
            return;
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
            0xff,
            .{},
            self.os9gui.font,
        );
        const p = @min(1, perc);
        self.os9gui.gui.drawRectFilled(pbar.split(.vertical, pbar.w * p)[0], 0xf7a41dff);
    }

    pub fn loadedSplash(self: *@This(), end: bool) !void {
        if (DISABLE_SPLASH)
            return;
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

/// Returns the infamous pink and black checker texture.
pub fn missingTexture() graph.Texture {
    const static = struct {
        const m = [3]u8{ 0xfc, 0x05, 0xbe };
        const b = [3]u8{ 0x0, 0x0, 0x0 };
        const data = m ++ b ++ b ++ m;
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
