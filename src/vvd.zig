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
};

test "cr" {
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
    }

    for (0..@divFloor(h1.numLODVertexes[0], 4)) |i| {
        const of = i * 4 + 1;
        try w.print("f {d} {d} {d} {d}\n", .{ of, of + 1, of + 2, of + 3 });
    }
}
