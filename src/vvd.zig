const std = @import("std");
const com = @import("parse_common.zig");
const parseStruct = com.parseStruct;

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
    lod: u32,
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
};

test "cr" {
    const alloc = std.testing.allocator;
    const in = try std.fs.cwd().openFile("mdl/out.vvd", .{});
    const r = in.reader();
    const h1 = try parseStruct(VertexHeader_1, .little, r);
    if (!std.mem.eql(u8, VVD_MAGIC_STRING, &h1.id))
        return error.invalidVVD;
    std.debug.print("{}\n", .{h1});

    try r.skipBytes(h1.numFixups * FIXUP_SIZE, .{});
    const outf = try std.fs.cwd().createFile("out.obj", .{});
    try outf.writer().print("o Crass\n", .{});
    const w = outf.writer();
    for (0..h1.numLODVertexes[0]) |_| {
        const vert = try parseStruct(Vertex, .little, r);
        try w.print("v {d} {d} {d}\n", .{ vert.pos.x, vert.pos.y, vert.pos.z });
    }
    {
        //Load vtx
        const inv = try std.fs.cwd().openFile("mdl/out.vtx", .{});
        const slice = try inv.reader().readAllAlloc(alloc, std.math.maxInt(usize));
        defer alloc.free(slice);
        var fbs = std.io.FixedBufferStream([]const u8){ .buffer = slice, .pos = 0 };
        const r1 = fbs.reader();
        const hv1 = try parseStruct(Vtx.VtxHeader, .little, r1);
        if (hv1.version >= 49)
            std.debug.print("NEW VERSION {d}\n", .{hv1.version});
        if (hv1.bodyPartOffset != 36) return error.crappyVtxParser;

        for (0..hv1.numBodyParts) |_| {
            const bp = try parseStruct(Vtx.BodyPart_h1, .little, r1);
            if (bp.model_offset != 8) return error.crappyVtxParser;
            std.debug.print("{}\n", .{bp});

            const mh = try parseStruct(Vtx.Model_h1, .little, r1);
            if (mh.lod_offset != 8) return error.crappyVtxParser;
            std.debug.print("{}\n", .{mh});

            const mlod = try parseStruct(Vtx.ModelLod_h1, .little, r1);
            std.debug.print("{}\n", .{mlod});
            try r1.skipBytes(mlod.mesh_offset - 12, .{}); //36 = mlod.offset - Sizeof(ModelLod_h1
            const mhh = try parseStruct(Vtx.Mesh_h1, .little, r1);
            std.debug.print("{}\n", .{mhh});
            try r1.skipBytes(mhh.sg_offset - 9, .{}); //36 = mlod.offset - Sizeof(ModelLod_h1

            const sg_start = fbs.pos;
            const vs = try parseStruct(Vtx.StripGroup, .little, r1);
            std.debug.print("{}\n", .{vs});

            var indices = std.ArrayList(u16).init(alloc);
            try indices.ensureTotalCapacity(vs.num_index);
            defer indices.deinit();

            //seek to correct place
            if (fbs.pos - sg_start != 25) return error.boro;
            try r1.skipBytes(vs.index_offset - 25, .{});
            for (0..vs.num_index) |_| {
                try indices.append(try r1.readInt(u16, .little) + 1);
            }

            for (0..@divFloor(indices.items.len, 3)) |i| {
                try w.print("f {d} {d} {d}\n", .{
                    indices.items[i],
                    indices.items[i + 1],
                    indices.items[i + 2],
                });
            }

            fbs.pos = sg_start + vs.strip_offset;
            for (0..vs.num_strips) |_| {
                const hh = try parseStruct(Vtx.StripHeader, .little, r1);
                std.debug.print("{}\n", .{hh});
                const sl = indices.items[hh.index_offset .. hh.num_index + hh.index_offset];
                const fl: Vtx.StripHeader.Flags = @enumFromInt(
                    hh.flags,
                );
                switch (fl) {
                    .trilist => {
                        for (0..@divFloor(sl.len, 3)) |i| {
                            const j = i * 3;
                            try w.print("f {d} {d} {d}\n", .{
                                sl[j],
                                sl[j + 1],
                                sl[j + 2],
                            });
                        }
                    },
                    else => return error.broken,
                }
                //fbs.pos = start + hh.index_offset;
                break; //do the first
            }

            break; //Read the first only
        }
    }
}
