const std = @import("std");
const com = @import("parse_common.zig");
const parseStruct = com.parseStruct;
const mdl = @import("mdl.zig");
const graph = @import("graph");
const vpk = @import("vpk.zig");
const edit = @import("editor.zig");

const VVD_MAGIC_STRING = "IDSV";
const MAX_LODS = 8;
const VertexHeader_1 = struct {
    id: [4]u8, // MODEL_VERTEX_FILE_ID
    version: u32, // MODEL_VERTEX_FILE_VERSION
    checksum: u32, // same as studiohdr_t, ensures sync      ( Note: maybe long instead of int in versions other than 4. )
    numLODs: u32, // num of valid lods
    numLODVertexes: [MAX_LODS]u32, // num verts for desired root lod
    numFixups: u32, // num of vertexFileFixup_t
    fixupTableStart: u32, // offset from base to fixup table
    vertexDataStart: u32, // offset from base to vertex block
    tangentDataStart: u32, // offset from base to tangent block
};

const FIXUP_SIZE = 4 * 4;
const FixupEntry = struct {
    lod: i32,
    source_vertex_id: u32,
    num_vertex: u32,
};

const V3 = struct { x: f32, y: f32, z: f32 };
const V2 = struct { x: f32, y: f32 };

const BoneWeightLen = 16;
const Vertex = struct {
    boneweight: [BoneWeightLen]u8,
    pos: V3,
    norm: V3,
    uv: V2,
};

const Vtx = struct {
    // this structure is in <mod folder>/src/public/optimize.h
    const VtxHeader = struct {
        // file version as defined by OPTIMIZED_MODEL_FILE_VERSION (currently 7)
        version: u32,

        // hardware params that affect how the model is to be optimized.
        vertCacheSize: u32,
        maxBonesPerStrip: u16,
        maxBonesPerTri: u16,
        maxBonesPerVert: u32,

        // must match checkSum in the .mdl
        checkSum: u32,

        numLODs: u32, // Also specified in ModelHeader_t's and should match

        // Offset to materialReplacementList Array. one of these for each LOD, 8 in total
        materialReplacementListOffset: u32,

        //Defines the size and location of the body part array
        numBodyParts: u32,
        bodyPartOffset: u32,
    };

    pub const BodyPart_h1 = struct {
        num_model: u32,
        model_offset: u32,
    };

    pub const Model_h1 = struct {
        num_lods: u32,
        lod_offset: u32,
    };

    pub const ModelLod_h1 = struct {
        num_mesh: u32,
        mesh_offset: u32,
        switch_point: f32,
    };

    pub const Mesh_h1 = struct {
        num_strip_group: u32,
        sg_offset: u32,
        flags: u8,
    };

    pub const StripGroup = struct {
        num_verts: u32,
        vert_offset: u32,
        num_index: u32,
        index_offset: u32,

        num_strips: u32,
        strip_offset: u32,
        flags: u8,
        //num_topo: u32,
        //topo_offset: u32,
    };

    pub const StripHeader = struct {
        pub const Flags = enum(u8) {
            trilist = 0x1,
            tristrip = 0x2,
        };

        num_index: u32,
        index_offset: u32,
        num_verts: u32,
        vert_offset: u32,
        bones: u16,
        flags: u8,
        num_bone_state: u32,
        bone_state_offset: u32,
    };

    pub const Vertex = struct {
        bone_weight_index: [3]u8,
        num_bones: u8,
        orig_mesh_vert_id: u16,

        bone_id: [3]u8,
    };

    pub const MaterialReplacmentHdr = struct {
        num: u32,
        offset: u32,
    };

    pub const MaterialReplacment = struct {
        matid: u16,
        name_offset: u32,
    };
};

fn dummyPrint(_: []const u8, _: anytype) void {}

//it sucks but it works
//there is very little version checking.
//offsets are not bounds checked so this can crash at anytime
pub fn loadModelCrappy(alloc: std.mem.Allocator, mdl_name: []const u8, editor: *edit.Context) !MultiMesh {
    const mdln = blk: {
        if (std.mem.endsWith(u8, mdl_name, ".mdl"))
            break :blk mdl_name[0 .. mdl_name.len - 4];
        break :blk mdl_name;
    };

    const print = dummyPrint;
    //const print = std.debug.print;
    const info = try mdl.doItCrappy(alloc, try editor.vpkctx.getFileTempFmt("mdl", "{s}", .{mdln}) orelse return error.nomdl, print);
    defer {
        for (info.texture_paths.items) |item|
            alloc.free(item);
        for (info.texture_names.items) |item|
            alloc.free(item);
        info.texture_paths.deinit();
        info.texture_names.deinit();
        info.vert_offsets.deinit();
    }
    var scratch = std.ArrayList(u8).init(alloc);
    defer scratch.deinit();
    var texts = std.ArrayList(c_uint).init(alloc);
    defer texts.deinit();
    outer: for (info.texture_names.items) |tname| {
        inner: for (info.texture_paths.items) |tpath| {
            scratch.clearRetainingCapacity();
            try scratch.writer().print("{s}{s}", .{ tpath, tname });
            const tex = editor.loadTextureFromVpkFail(scratch.items) catch continue :inner;
            try texts.append(tex.id);
            continue :outer;
        }
        try texts.append(0); //Put missing
    }
    var mmesh = MultiMesh.init(alloc);
    //var mesh = graph.meshutil.Mesh.init(alloc, 0);
    //const outf = try std.fs.cwd().createFile("out.obj", .{});
    const w = std.io.null_writer;
    //const w = outf.writer();
    {
        const slice_vvd = try editor.vpkctx.getFileTempFmt("vvd", "{s}", .{mdln}) orelse return error.notFound;
        var fbs_vvd = std.io.FixedBufferStream([]const u8){ .buffer = slice_vvd, .pos = 0 };
        const r = fbs_vvd.reader();
        const h1 = try parseStruct(VertexHeader_1, .little, r);
        if (!std.mem.eql(u8, VVD_MAGIC_STRING, &h1.id))
            return error.invalidVVD;
        print("{}\n", .{h1});

        fbs_vvd.pos = h1.fixupTableStart;
        var fixups = std.ArrayList(FixupEntry).init(alloc);
        defer fixups.deinit();
        for (0..h1.numFixups) |_| {
            const fu = try parseStruct(FixupEntry, .little, r);
            print("{}\n", .{fu});
            try fixups.append(fu);
        }

        var verts = std.ArrayList(Vertex).init(alloc);
        defer verts.deinit();
        fbs_vvd.pos = h1.vertexDataStart;
        for (0..h1.numLODVertexes[0]) |_| {
            const vert = try parseStruct(Vertex, .little, r);
            try verts.append(vert);
        }
        var total: usize = 0;
        if (fixups.items.len > 0) {
            for (fixups.items) |fu| {
                for (verts.items[fu.source_vertex_id .. fu.source_vertex_id + fu.num_vertex]) |v| {
                    try mmesh.vertices.append(.{
                        .x = v.pos.x,
                        .y = v.pos.y,
                        .z = v.pos.z,
                        .u = v.uv.x,
                        .v = v.uv.y,
                        .nx = 0,
                        .ny = 0,
                        .nz = 0,
                        .color = 0xff_ff_ff_ff,
                    });
                    try w.print("v {d} {d} {d}\n", .{ v.pos.x, v.pos.y, v.pos.z });
                }
                total += fu.num_vertex;
            }
            print("TOTAL VERCTS FIXED {d}\n", .{total});
        } else {
            for (verts.items) |v| {
                try w.print("v {d} {d} {d}\n", .{ v.pos.x, v.pos.y, v.pos.z });
                try mmesh.vertices.append(.{
                    .x = v.pos.x,
                    .y = v.pos.y,
                    .z = v.pos.z,
                    .u = v.uv.x,
                    .v = v.uv.y,
                    .nx = 0,
                    .ny = 0,
                    .nz = 0,
                    .color = 0xff_ff_ff_ff,
                });
            }
        }
    }
    {
        //Load vtx
        const slice = try editor.vpkctx.getFileTempFmt("vtx", "{s}.dx90", .{mdln}) orelse return error.broken;
        var fbs = std.io.FixedBufferStream([]const u8){ .buffer = slice, .pos = 0 };
        const r1 = fbs.reader();
        const header_pos = fbs.pos;
        const hv1 = try parseStruct(Vtx.VtxHeader, .little, r1);
        if (hv1.version >= 49)
            print("NEW VERSION {d}\n", .{hv1.version});
        print("{}\n", .{hv1});
        fbs.pos = header_pos + hv1.bodyPartOffset;
        //if (hv1.bodyPartOffset != 36) return error.crappyVtxParser;

        var max: u32 = 0;
        const bpstart = fbs.pos;
        for (0..hv1.numBodyParts) |bpi| {
            if (bpi > 0)
                break; //it breaks lol
            const BP_SIZE = 8;
            var st = bpstart + bpi * BP_SIZE;
            const bp = try parseStruct(Vtx.BodyPart_h1, .little, r1);
            print("{}\n", .{bp});
            fbs.pos = st + bp.model_offset;
            st = fbs.pos;
            {
                const mh = try parseStruct(Vtx.Model_h1, .little, r1);
                //We only read the first lod for now
                fbs.pos = st + mh.lod_offset;
                print("{}\n", .{mh});

                st = fbs.pos;
                var mesh_offset: u16 = 0;
                {
                    const mlod = try parseStruct(Vtx.ModelLod_h1, .little, r1);
                    print("{}\n", .{mlod});
                    fbs.pos = st + mlod.mesh_offset;
                    const mesh_start = fbs.pos;
                    for (0..mlod.num_mesh) |mi| {
                        const MESH_SIZE = 9;
                        st = mesh_start + mi * MESH_SIZE;
                        fbs.pos = st;
                        const mhh = try parseStruct(Vtx.Mesh_h1, .little, r1);

                        print("{}\n", .{mhh});

                        var strip_vert_count: u16 = 0;

                        const mesh_h_start = st + mhh.sg_offset;
                        for (0..mhh.num_strip_group) |si| {
                            const STRIP_GROUP_SIZE = 25;
                            st = mesh_h_start + si * STRIP_GROUP_SIZE;
                            fbs.pos = st;
                            const SG = try parseStruct(Vtx.StripGroup, .little, r1);
                            print("{}\n", .{SG});

                            const sg_start = st;

                            var vert_table = std.ArrayList(u16).init(alloc);
                            defer vert_table.deinit();
                            fbs.pos = sg_start + SG.vert_offset;
                            for (0..SG.num_verts) |_| {
                                const v = try parseStruct(Vtx.Vertex, .little, r1);
                                try vert_table.append(mesh_offset + v.orig_mesh_vert_id);
                            }
                            var indices = std.ArrayList(u16).init(alloc);
                            try indices.ensureTotalCapacity(SG.num_index);
                            defer indices.deinit();
                            fbs.pos = sg_start + SG.index_offset;
                            for (0..SG.num_index) |_| {
                                try indices.append(try r1.readInt(u16, .little));
                            }

                            fbs.pos = sg_start + SG.strip_offset;
                            st = fbs.pos;
                            const vtt = vert_table.items;
                            const newm = try mmesh.newMesh(texts.items[mi]);
                            for (0..SG.num_strips) |sii| {
                                try w.print("o mod_{d}_{d}_{d}\n", .{ mi, si, sii });
                                const hh = try parseStruct(Vtx.StripHeader, .little, r1);
                                print("{}\n", .{hh});
                                const sl = indices.items[hh.index_offset .. hh.num_index + hh.index_offset];
                                const vttt = vtt;
                                //const vttt = vtt[hh.vert_offset .. hh.vert_offset + hh.num_verts];
                                strip_vert_count += @intCast(hh.num_verts);
                                const fl: Vtx.StripHeader.Flags = @enumFromInt(
                                    hh.flags,
                                );
                                switch (fl) {
                                    .trilist => {
                                        for (0..@divFloor(sl.len, 3)) |i| {
                                            const j = i * 3;
                                            try newm.indicies.appendSlice(&.{
                                                vttt[sl[j + 2]],
                                                vttt[sl[j + 1]],
                                                vttt[sl[j]],
                                            });
                                            max = @max(max, vttt[sl[j]] + 1);
                                            max = @max(max, vttt[sl[j + 1]] + 1);
                                            max = @max(max, vttt[sl[j + 2]] + 1);
                                            try w.print("f {d} {d} {d}\n", .{
                                                vttt[sl[j]] + 1,
                                                vttt[sl[j + 1]] + 1,
                                                vttt[sl[j + 2]] + 1,
                                            });
                                        }
                                    },
                                    else => return error.broken,
                                }
                                //fbs.pos = start + hh.index_offset;
                            }
                        }
                        mesh_offset += info.vert_offsets.items[mi];
                    }

                    //try r1.skipBytes(mhh.sg_offset - 9, .{}); //36 = mlod.offset - Sizeof(ModelLod_h1

                    if (false) {
                        fbs.pos = header_pos + hv1.materialReplacementListOffset;
                        const mathdr = try parseStruct(Vtx.MaterialReplacmentHdr, .little, r1);
                        print("{}\n", .{mathdr});
                        for (0..mathdr.num) |_| {
                            const start = fbs.pos;
                            const rep = try parseStruct(Vtx.MaterialReplacment, .little, r1);
                            print("{}\n", .{rep});
                            const str: [*c]const u8 = &slice[start + rep.name_offset];
                            print("{s}\n", .{str});
                        }
                    }
                }
                //break; //Read the first only
            }
        }
    }
    mmesh.setData();
    return mmesh;
}

//One vertex buffer, many index buffers
pub const MultiMesh = struct {
    const c = graph.c;
    const GL = graph.GL;
    const Self = @This();
    const MeshVert = graph.meshutil.MeshVert;
    pub const Mesh = struct {
        indicies: std.ArrayList(u16),
        ebo: c_uint,
        vao: c_uint,
        texture_id: c_uint,

        pub fn init(alloc: std.mem.Allocator, tex: c_uint) @This() {
            var ebo: c_uint = 0;
            var vao: c_uint = 0;
            c.glGenBuffers(1, &ebo);
            c.glGenVertexArrays(1, &vao);
            return .{
                .ebo = ebo,
                .vao = vao,
                .indicies = std.ArrayList(u16).init(alloc),
                .texture_id = tex,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.indicies.deinit();
        }
    };

    vbo: c_uint,
    vertices: std.ArrayList(MeshVert),
    meshes: std.ArrayList(Mesh),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) @This() {
        var ret = Self{
            .vertices = std.ArrayList(MeshVert).init(alloc),
            .meshes = std.ArrayList(Mesh).init(alloc),
            .alloc = alloc,
            .vbo = 0,
        };

        c.glGenBuffers(1, &ret.vbo);

        //GL.bufferData(c.GL_ELEMENT_ARRAY_BUFFER, ret.ebo, u32, ret.indicies.items);
        return ret;
    }

    pub fn newMesh(self: *Self, tex: c_uint) !*Mesh {
        try self.meshes.append(Mesh.init(self.alloc, tex));
        const ret = &self.meshes.items[self.meshes.items.len - 1];

        GL.floatVertexAttrib(ret.vao, self.vbo, 0, 3, MeshVert, "x"); //XYZ
        GL.floatVertexAttrib(ret.vao, self.vbo, 1, 2, MeshVert, "u"); //RGBA
        GL.floatVertexAttrib(ret.vao, self.vbo, 2, 3, MeshVert, "nx"); //RGBA
        GL.intVertexAttrib(ret.vao, self.vbo, 3, 1, MeshVert, "color", c.GL_UNSIGNED_INT);
        GL.floatVertexAttrib(ret.vao, self.vbo, 4, 3, MeshVert, "tx");

        //c.glBindVertexArray(ret.vao);
        //GL.bufferData(c.GL_ARRAY_BUFFER, ret.vbo, MeshVert, ret.vertices.items);
        return &self.meshes.items[self.meshes.items.len - 1];
    }

    pub fn setData(self: *Self) void {
        for (self.meshes.items) |mesh| {
            c.glBindVertexArray(mesh.vao);
            GL.bufferData(c.GL_ARRAY_BUFFER, self.vbo, MeshVert, self.vertices.items);
            GL.bufferData(c.GL_ELEMENT_ARRAY_BUFFER, mesh.ebo, u16, mesh.indicies.items);
        }
    }

    pub fn deinit(self: *Self) void {
        self.vertices.deinit();
        for (self.meshes.items) |*mesh| {
            mesh.deinit();
        }
        self.meshes.deinit();
    }

    pub fn drawSimple(self: *Self, view: graph.za.Mat4, model: graph.za.Mat4, shader: c_uint) void {
        c.glUseProgram(shader);
        GL.passUniform(shader, "view", view);
        GL.passUniform(shader, "model", model);
        const diffuse_loc = c.glGetUniformLocation(shader, "diffuse_texture");
        for (self.meshes.items) |mesh| {
            c.glBindVertexArray(mesh.vao);
            c.glUniform1i(diffuse_loc, 0);
            c.glBindTextureUnit(0, mesh.texture_id);

            c.glDrawElements(c.GL_TRIANGLES, @as(c_int, @intCast(mesh.indicies.items.len)), c.GL_UNSIGNED_SHORT, null);
        }
    }
};
