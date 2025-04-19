const std = @import("std");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const SparseSet = graph.SparseSet;
const meshutil = graph.meshutil;
const vmf = @import("vmf.zig");
const vdf = @import("vdf.zig");
const vpk = @import("vpk.zig");
const csg = @import("csg.zig");
const vtf = @import("vtf.zig");
const fgd = @import("fgd.zig");
const profile = @import("profile.zig");
const Gui = graph.Gui;
const StringStorage = @import("string.zig").StringStorage;

pub threadlocal var mesh_build_time = profile.BasicProfiler.init();
pub const MeshBatch = struct {
    tex: graph.Texture,
    mesh: meshutil.Mesh,
    // Each batch needs to keep track of:
    // needs_rebuild
    // contained_solids:ent_id
};
pub const MeshMap = std.StringHashMap(MeshBatch);
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
    material: []const u8, //owned by somebody else
    pub fn deinit(self: @This()) void {
        self.verts.deinit();
        self.index.deinit();
    }
};

pub const AABB = struct {
    a: Vec3 = Vec3.zero(),
    b: Vec3 = Vec3.zero(),
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
};

pub const Entity = struct {
    origin: Vec3,
    class: []const u8,
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

    ecs: EcsT,

    draw_state: struct {
        draw_tools: bool = true,
        basic_shader: graph.glID,
        cam3d: graph.Camera3D = .{ .up = .z, .move_speed = 50, .max_move_speed = 100 },
    },

    edit_state: struct {
        id: ?EcsT.Id = null,
    } = .{},

    misc_gui_state: struct {
        scroll_a: graph.Vec2f = .{ .x = 0, .y = 0 },
    } = .{},

    pub fn init(alloc: std.mem.Allocator) !Self {
        return .{
            .alloc = alloc,
            .fgd_ctx = fgd.EntCtx.init(alloc),
            .string_storage = StringStorage.init(alloc),
            .name_arena = std.heap.ArenaAllocator.init(alloc),
            .csgctx = try csg.Context.init(alloc),
            .vpkctx = try vpk.Context.init(alloc),
            .meshmap = MeshMap.init(alloc),
            .ecs = try EcsT.init(alloc),
            .lower_buf = std.ArrayList(u8).init(alloc),
            .scratch_buf = std.ArrayList(u8).init(alloc),

            .icon_map = std.StringHashMap(graph.Texture).init(alloc),

            .draw_state = .{
                .basic_shader = try graph.Shader.loadFromFilesystem(alloc, std.fs.cwd(), &.{
                    .{ .path = "ratgraph/asset/shader/gbuffer.vert", .t = .vert },
                    .{ .path = "src/basic.frag", .t = .frag },
                }),
            },
        };
    }

    pub fn deinit(self: *Self) void {
        self.ecs.deinit();
        self.fgd_ctx.deinit();
        self.icon_map.deinit();
        self.lower_buf.deinit();
        self.string_storage.deinit();
        self.scratch_buf.deinit();
        self.csgctx.deinit();
        self.vpkctx.deinit();
        var it = self.meshmap.iterator();
        while (it.next()) |item| {
            item.value_ptr.mesh.deinit();
        }
        self.meshmap.deinit();
        self.name_arena.deinit();
    }

    pub fn rebuildAllMeshes(self: *Self) !void {
        mesh_build_time.start();
        { //First clear
            var mesh_it = self.meshmap.valueIterator();
            while (mesh_it.next()) |batch| {
                batch.mesh.vertices.clearRetainingCapacity();
                batch.mesh.indicies.clearRetainingCapacity();
            }
        }
        { //Iterate all solids and add
            var it = self.ecs.iterator(.solid);
            while (it.next()) |solid| {
                const bb = (try self.ecs.getOptPtr(it.i, .bounding_box)) orelse continue;
                solid.recomputeBounds(bb);
                for (solid.sides.items) |side| {
                    const batch = self.meshmap.getPtr(side.material) orelse continue;
                    const mesh = &batch.mesh;
                    try mesh.vertices.ensureUnusedCapacity(side.verts.items.len);
                    try mesh.indicies.ensureUnusedCapacity(side.index.items.len);
                    const uvs = try self.csgctx.calcUVCoords(
                        side.verts.items,
                        side,
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
            }
        }
        { //Set all the gl data
            var it = self.meshmap.valueIterator();
            while (it.next()) |item| {
                item.mesh.setData();
            }
        }
        mesh_build_time.end();
        mesh_build_time.log("Mesh build time");
    }

    ///Given a csg defined solid, convert to mesh and store.
    pub fn putSolidFromVmf(self: *Self, solid: vmf.Solid) !void {
        const StrCtx = std.hash_map.StringContext;
        for (solid.side) |*side| {
            const res = try self.meshmap.getOrPutAdapted(side.material, StrCtx{});
            if (!res.found_existing) {
                res.key_ptr.* = try self.storeString(side.material);
                res.value_ptr.* = .{
                    .tex = try self.loadTextureFromVpk(side.material),
                    .mesh = undefined,
                };
                res.value_ptr.mesh = meshutil.Mesh.init(self.alloc, res.value_ptr.tex.id);
            }
        }
        const newsolid = try self.csgctx.genMesh(
            solid.side,
            self.alloc,
            &self.string_storage,
            //@intCast(self.set.sparse.items.len),
        );
        const new = try self.ecs.createEntity();
        try self.ecs.attach(new, .solid, newsolid);
        try self.ecs.attach(new, .bounding_box, .{});
        //try self.set.insert(newsolid.id, newsolid);
    }

    pub fn loadVmf(self: *Self, path: std.fs.Dir, filename: []const u8, loadctx: *LoadCtx) !void {
        const infile = try path.openFile(filename, .{});
        defer infile.close();

        const slice = try infile.reader().readAllAlloc(self.alloc, std.math.maxInt(usize));
        defer self.alloc.free(slice);
        var aa = std.heap.ArenaAllocator.init(self.alloc);
        var obj = try vdf.parse(self.alloc, slice);
        defer obj.deinit();
        loadctx.cb("vmf parsed");
        const vmf_ = try vdf.fromValue(vmf.Vmf, &.{ .obj = &obj.value }, aa.allocator());
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
                    try self.ecs.attach(new, .entity, .{
                        .origin = ent.origin.v,
                        .class = try self.storeString(ent.classname),
                    });
                    try self.ecs.attach(new, .bounding_box, .{
                        .a = ent.origin.v.sub(Vec3.new(8, 8, 8)),
                        .b = ent.origin.v.add(Vec3.new(8, 8, 8)),
                    });
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

    pub fn storeString(self: *Self, string: []const u8) ![]const u8 {
        return try self.string_storage.store(string);
    }

    pub fn loadTextureFromVpk(self: *Self, material: []const u8) !graph.Texture {
        const err = in: {
            //const slash = std.mem.lastIndexOfScalar(u8, sl, '/') orelse break :in error.noSlash;
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
                                        break :in vtf.loadTexture(
                                            (self.vpkctx.getFileTempFmt(
                                                "vtf",
                                                "materials/{s}",
                                                .{base.literal},
                                            ) catch |err| break :in err) orelse {
                                                break :in error.notfound;
                                            },
                                            self.alloc,
                                        ) catch |err| break :in err;
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
            }

            break :in vtf.loadTexture(
                (self.vpkctx.getFileTempFmt("vtf", "materials/{s}", .{material}) catch |err| break :in err) orelse break :in error.notfoundGeneric,
                //(self.vpkctx.getFileTemp("vtf", sl[0..slash], sl[slash + 1 ..]) catch |err| break :in err) orelse break :in error.notfound,
                self.alloc,
            ) catch |err| break :in err;
        };
        return err catch |e| {
            log.warn("{} for {s}", .{ e, material });
            return missingTexture();
        };
        //defer bmp.deinit();
        //break :blk graph.Texture.initFromBitmap(bmp, .{});
    }

    pub fn draw3Dview(self: *Self, screen_area: graph.Rect, draw: *graph.ImmediateDrawingContext) !void {
        const ENT_RENDER_DIST = 64 * 10;
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

        const view_3d = self.draw_state.cam3d.getMatrix(screen_area.w / screen_area.h, 1, 64 * 512);

        var it = self.meshmap.iterator();
        while (it.next()) |mesh| {
            if (!self.draw_state.draw_tools and std.mem.startsWith(u8, mesh.key_ptr.*, "TOOLS"))
                continue;
            mesh.value_ptr.mesh.drawSimple(view_3d, mat, self.draw_state.basic_shader);
        }

        graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
        //Crosshair
        const cw = 4;
        const crossp = screen_area.center().sub(.{ .x = cw, .y = cw });
        draw.rect(graph.Rec(
            crossp.x,
            crossp.y,
            cw * 2,
            cw * 2,
        ), 0xffffffff);
        var ent_it = self.ecs.iterator(.entity);
        while (ent_it.next()) |ent| {
            const dist = ent.origin.distance(self.draw_state.cam3d.pos);
            if (dist > ENT_RENDER_DIST)
                continue;
            if (self.fgd_ctx.base.get(ent.class)) |base| {
                if (self.icon_map.get(base.iconsprite)) |isp| {
                    draw.cubeFrame(ent.origin.sub(Vec3.new(8, 8, 8)), Vec3.new(16, 16, 16), 0x00ff00ff);
                    draw.billboard(ent.origin, .{ .x = 16, .y = 16 }, isp.rect(), isp, self.draw_state.cam3d);
                }
            }
        }
        if (self.edit_state.id) |id| {
            if (try self.ecs.getOpt(id, .solid)) |solid| {
                //const bb = &solid.bounding_box;
                //draw.cube(bb.a, bb.b.sub(bb.a), 0xffffffff);
                for (solid.sides.items) |side| {
                    const v = side.verts.items;
                    //for (0..@divFloor(side.verts.items.len, 2)) |ti| {
                    //    draw.line3D(v[ti], v[ti + 1], 0xff00ff);
                    //}
                    if (side.verts.items.len > 0) {
                        var last = side.verts.items[side.verts.items.len - 1];
                        for (0..side.verts.items.len) |ti| {
                            draw.line3D(last, v[ti], 0xff00ff);
                            draw.point3D(v[ti], 0xff0000ff);
                            last = v[ti];
                        }
                    }
                }
            }
            if (try self.ecs.getOpt(id, .bounding_box)) |bb| {
                draw.cube(bb.a, bb.b.sub(bb.a), 0xffffff77);
            }
            //id = (id + 1) % @as(u32, @intCast(editor.set.dense.items.len));
        }
        try draw.flush(null, self.draw_state.cam3d);
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
    buffer: [256]u8 = undefined,
    timer: std.time.Timer,
    draw: *graph.ImmediateDrawingContext,
    win: *graph.SDL.Window,
    font: *graph.Font,

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
        if (self.timer.read() / std.time.ns_per_ms < 8) {
            return;
        }
        self.timer.reset();
        self.win.pumpEvents(.poll);
        self.draw.begin(0x222222ff, self.win.screen_dimensions.toF()) catch return;
        self.draw.text(.{ .x = 0, .y = 0 }, message, &self.font.font, 100, 0xffffffff);
        self.draw.end(null) catch return;
        self.win.swap(); //So the window doesn't look too broken while loading
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
