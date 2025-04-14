const std = @import("std");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const SparseSet = graph.SparseSet;
const meshutil = graph.meshutil;
const vmf = @import("vmf.zig");
const vpk = @import("vpk.zig");
const csg = @import("csg.zig");
const vtf = @import("vtf.zig");
const profile = @import("profile.zig");

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
    a: Vec3,
    b: Vec3,
};

pub const Solid = struct {
    const Self = @This();
    sides: std.ArrayList(Side),
    id: u32,

    /// Bounding box is used during broad phase ray tracing
    /// they are recomputed along with vertex arrays
    bounding_box: AABB,

    pub fn init(alloc: std.mem.Allocator, id: u32) Solid {
        return .{
            .id = id,
            .sides = std.ArrayList(Side).init(alloc),
            .bounding_box = .{
                .a = Vec3.zero(),
                .b = Vec3.zero(),
            },
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.sides.items) |side|
            side.deinit();
        self.sides.deinit();
    }

    pub fn recomputeBounds(self: *Self) void {
        //var lx: f32 = std.math.floatMax(f32);
        //var ly: f32 = std.math.floatMax(f32);
        //var lz: f32 = std.math.floatMax(f32);

        //var gx: f32 = -std.math.floatMax(f32);
        //var gy: f32 = -std.math.floatMax(f32);
        //var gz: f32 = -std.math.floatMax(f32);
        var min = Vec3.set(std.math.floatMax(f32));
        var max = Vec3.set(-std.math.floatMax(f32));
        for (self.sides.items) |side| {
            for (side.verts.items) |s| {
                min = min.min(s);
                max = max.max(s);
                //lx = @min(lx, s.x());
                //ly = @min(ly, s.y());
                //lz = @min(lz, s.z());

                //gx = @max(gx, s.x());
                //gy = @max(gy, s.y());
                //gz = @max(gz, s.z());
            }
        }
        self.bounding_box.a = min;
        self.bounding_box.b = max;
        //self.bounding_box.a = graph.za.Vec3.new(lx, ly, lz);
        //self.bounding_box.b = graph.za.Vec3.new(gx, gy, gz);
    }
};

pub const Entity = struct {
    origin: Vec3,
    class: []const u8,
};

pub const Context = struct {
    const Self = @This();
    const SolidSet = SparseSet(Solid, u32);

    ents: std.ArrayList(Entity),
    set: SolidSet,
    csgctx: csg.Context,
    vpkctx: vpk.Context,
    meshmap: MeshMap,
    lower_buf: std.ArrayList(u8),
    scratch_buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    name_arena: std.heap.ArenaAllocator,

    pub fn init(alloc: std.mem.Allocator) !Self {
        return .{
            .alloc = alloc,
            .ents = std.ArrayList(Entity).init(alloc),
            .name_arena = std.heap.ArenaAllocator.init(alloc),
            .set = try SolidSet.init(alloc),
            .csgctx = try csg.Context.init(alloc),
            .vpkctx = vpk.Context.init(alloc),
            .meshmap = MeshMap.init(alloc),
            .lower_buf = std.ArrayList(u8).init(alloc),
            .scratch_buf = std.ArrayList(u8).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        {
            var it = self.set.denseIterator();
            while (it.next()) |item|
                item.deinit();
        }
        self.set.deinit();
        self.lower_buf.deinit();
        self.scratch_buf.deinit();
        self.ents.deinit();
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
            var it = self.set.denseIterator();
            while (it.next()) |solid| {
                solid.recomputeBounds();
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
        for (solid.side) |side| {
            const res = try self.meshmap.getOrPut(side.material);
            if (!res.found_existing) {
                //var t = try std.time.Timer.start();
                //try self.lower_buf.ensureTotalCapacity(side.material.len);
                //try self.lower_buf.resize(side.material.len);
                //const lower = std.ascii.lowerString(self.lower_buf.items, side.material);
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
            @intCast(self.set.sparse.items.len),
        );
        try self.set.insert(newsolid.id, newsolid);
    }

    pub fn loadTextureFromVpk(self: *Self, material: []const u8) !graph.Texture {
        try self.lower_buf.ensureTotalCapacity(material.len);
        try self.lower_buf.resize(material.len);
        const lower = std.ascii.lowerString(self.lower_buf.items, material);
        self.scratch_buf.clearRetainingCapacity();
        try self.scratch_buf.writer().print("materials/{s}", .{lower});
        const sl = self.scratch_buf.items;
        const err = in: {
            const slash = std.mem.lastIndexOfScalar(u8, sl, '/') orelse break :in error.noSlash;
            break :in vtf.loadTexture(
                (self.vpkctx.getFileTemp("vtf", sl[0..slash], sl[slash + 1 ..]) catch |err| break :in err) orelse break :in error.notfound,
                self.alloc,
            ) catch |err| break :in err;
        };
        return err catch |e| {
            std.debug.print("{} for {s}\n", .{ e, sl });
            return missingTexture();
        };
        //defer bmp.deinit();
        //break :blk graph.Texture.initFromBitmap(bmp, .{});
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
