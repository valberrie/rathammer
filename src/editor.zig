const std = @import("std");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const SparseSet = graph.SparseSet;
const meshutil = graph.meshutil;
const vmf = @import("vmf");
const vpk = @import("vpk.zig");
const csg = @import("csg.zig");
const vtf = @import("vtf.zig");

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
};

pub const Solid = struct {
    const Self = @This();
    sides: std.ArrayList(Side),
    id: u32,

    pub fn init(alloc: std.mem.Allocator, id: u32) Solid {
        return .{
            .id = id,
            .sides = std.ArrayList(Side).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.sides.deinit();
    }
};

pub const Context = struct {
    const Self = @This();
    const SolidSet = SparseSet(Solid, u32);

    set: SolidSet,
    csgctx: csg.Context,
    vpkctx: vpk.Context,
    meshmap: csg.MeshMap,
    lower_buf: std.ArrayList(u8),
    scratch_buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !Self {
        return .{
            .alloc = alloc,
            .set = try SolidSet.init(alloc),
            .csgctx = try csg.Context.init(alloc),
            .vpkctx = vpk.Context.init(alloc),
            .meshmap = csg.MeshMap.init(alloc),
            .lower_buf = std.ArrayList(u8).init(alloc),
            .scratch_buf = std.ArrayList(u8).init(alloc),
        };
    }

    ///Given a csg defined solid, convert to mesh and store.
    pub fn putSolidFromVmf(self: *Self, solid: vmf.Solid) !void {
        for (solid.side) |side| {
            const res = try self.meshmap.getOrPut(side.material);
            if (!res.found_existing) {
                //var t = try std.time.Timer.start();
                try self.lower_buf.ensureTotalCapacity(side.material.len);
                const lower = std.ascii.lowerString(&self.lower_buf.items, side.material);
                res.value_ptr.* = .{
                    .tex = blk: {
                        self.scratch_buf.clearRetainingCapacity();
                        try self.scratch_buf.writer().print("materials/{s}", .{lower});
                        const sl = self.scratch_buf.items();
                        const err = in: {
                            const slash = std.mem.lastIndexOfScalar(u8, sl, '/') orelse break :in error.noSlash;
                            //dev dev_prisontvoverlay002
                            break :in vtf.loadTexture(
                                (self.vpkctx.getFileTemp("vtf", sl[0..slash], sl[slash + 1 ..]) catch |err| break :in err) orelse break :in error.notfound,
                                self.alloc,
                            ) catch |err| break :in err;
                        };
                        break :blk err catch |e| {
                            std.debug.print("{} for {s}\n", .{ e, sl });
                            break :blk missingTexture();
                            //graph.Texture.initEmpty();
                        };
                        //defer bmp.deinit();
                        //break :blk graph.Texture.initFromBitmap(bmp, .{});
                    },
                    .mesh = undefined,
                };
                res.value_ptr.mesh = meshutil.Mesh.init(self.alloc, res.value_ptr.tex.id);
            }
        }
        const newsolid = self.csgctx.genMeshS(solid.side, self.alloc, self.set.sparse.items.len);
        try self.set.insert(newsolid.id, newsolid);
    }

    pub fn deinit(self: *Self) void {
        {
            var it = self.set.denseIterator();
            while (it.next()) |item|
                item.deinit();
        }
        self.set.deinit();
        self.csgctx.deinit();
        self.vpkctx.deinit();
        var it = self.meshmap.iterator();
        while (it.next()) |item| {
            item.value_ptr.mesh.deinit();
        }
        self.meshmap.deinit();
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
