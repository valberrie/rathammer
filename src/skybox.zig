const graph = @import("graph");
const vpk = @import("vpk.zig");
const vtf = @import("vtf.zig");
const std = @import("std");
pub const Skybox = struct {
    const Self = @This();
    const SkyBatch = graph.NewBatch(graph.ImmediateDrawingContext.VtxFmt.Textured_3D_NC, .{ .index_buffer = true, .primitive_mode = .triangles });
    meshes: std.ArrayList(SkyBatch),
    textures: std.ArrayList(graph.Texture),
    shader: c_uint,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !Self {
        const sky_shad = try graph.Shader.loadFromFilesystem(alloc, std.fs.cwd(), &.{
            .{ .path = "src/cubemap.vert", .t = .vert },
            .{ .path = "src/cubemap.frag", .t = .frag },
        });
        return Self{
            .alloc = alloc,
            .meshes = std.ArrayList(SkyBatch).init(alloc),
            .textures = std.ArrayList(graph.Texture).init(alloc),
            .shader = sky_shad,
        };
    }

    pub fn loadSky(self: *Self, sky_name: []const u8, vpkctx: *vpk.Context) !void {
        //TODO clear out the old ones;
        const a = 1;
        const t = 1;
        const b = 0.001; //Inset the uv sligtly to prevent seams from showing
        //Maybe use clamptoedge?
        const o = 1 - b;
        //const h = o * 2;
        const uvs = [4]graph.Vec2f{
            .{ .x = b, .y = b },
            .{ .x = o, .y = b },
            .{ .x = o, .y = o },
            .{ .x = b, .y = o },
        };
        const verts = [_]SkyBatch.VtxType{
            .{ .uv = uvs[3], .pos = .{ .y = -a, .z = -a, .x = t } },
            .{ .uv = uvs[2], .pos = .{ .y = a, .z = -a, .x = t } },
            .{ .uv = uvs[1], .pos = .{ .y = a, .z = a, .x = t } },
            .{ .uv = uvs[0], .pos = .{ .y = -a, .z = a, .x = t } },

            .{ .uv = uvs[1], .pos = .{ .y = -a, .z = a, .x = -t } },
            .{ .uv = uvs[0], .pos = .{ .y = a, .z = a, .x = -t } },
            .{ .uv = uvs[3], .pos = .{ .y = a, .z = -a, .x = -t } },
            .{ .uv = uvs[2], .pos = .{ .y = -a, .z = -a, .x = -t } },

            .{ .uv = uvs[1], .pos = .{ .x = -a, .z = a, .y = t } },
            .{ .uv = uvs[0], .pos = .{ .x = a, .z = a, .y = t } },
            .{ .uv = uvs[3], .pos = .{ .x = a, .z = -a, .y = t } },
            .{ .uv = uvs[2], .pos = .{ .x = -a, .z = -a, .y = t } },

            .{ .uv = uvs[3], .pos = .{ .x = -a, .z = -a, .y = -t } },
            .{ .uv = uvs[2], .pos = .{ .x = a, .z = -a, .y = -t } },
            .{ .uv = uvs[1], .pos = .{ .x = a, .z = a, .y = -t } },
            .{ .uv = uvs[0], .pos = .{ .x = -a, .z = a, .y = -t } },

            //top and bottom
            .{ .uv = uvs[3], .pos = .{ .x = -a, .y = -a, .z = t } },
            .{ .uv = uvs[2], .pos = .{ .x = a, .y = -a, .z = t } },
            .{ .uv = uvs[1], .pos = .{ .x = a, .y = a, .z = t } },
            .{ .uv = uvs[0], .pos = .{ .x = -a, .y = a, .z = t } },

            .{ .uv = uvs[0], .pos = .{ .x = -a, .y = a, .z = -t } },
            .{ .uv = uvs[1], .pos = .{ .x = a, .y = a, .z = -t } },
            .{ .uv = uvs[2], .pos = .{ .x = a, .y = -a, .z = -t } },
            .{ .uv = uvs[3], .pos = .{ .x = -a, .y = -a, .z = -t } },
        };
        const ind = [_]u32{
            2, 1, 0, 3, 2, 0,
        };
        const endings = [_][]const u8{ "ft", "bk", "lf", "rt", "up", "dn" };
        for (endings, 0..) |end, i| {
            const vtf_buf = try vpkctx.getFileTempFmt("vtf", "materials/skybox/{s}{s}", .{ sky_name, end }) orelse {
                std.debug.print("Cant find sky {s}{s}\n", .{ sky_name, end });
                continue;
            };
            const tex = vtf.loadTexture(vtf_buf, self.alloc) catch {
                std.debug.print("Had an oopis\n", .{});
                continue;
            };
            var skybatch = SkyBatch.init(self.alloc);
            try skybatch.vertices.appendSlice(verts[i * 4 .. i * 4 + 4]);
            try skybatch.indicies.appendSlice(&ind);
            skybatch.pushVertexData();
            try self.meshes.append(skybatch);
            try self.textures.append(tex);
        }
    }

    pub fn deinit(self: *Self) void {
        for (self.meshes.items) |*i|
            i.deinit();
        for (self.textures.items) |*t|
            t.deinit();
        self.meshes.deinit();
        self.textures.deinit();
    }
};
