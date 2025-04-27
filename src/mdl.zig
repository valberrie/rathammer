const std = @import("std");
const com = @import("parse_common.zig");
const parseStruct = com.parseStruct;
const graph = @import("graph");
const Vec3 = graph.za.Vec3;

const MdlVector = struct {
    x: f32,
    y: f32,
    z: f32,
    pub fn toZa(self: @This()) Vec3 {
        return Vec3.new(self.x, self.y, self.z);
    }
};

const MDL_MAGIC_STRING = "IDST";
const Studiohdr_01 = struct {
    id: [4]u8,
    version: u32,
};

const Studiohdr_02 = struct {
    checksum: u32,
    name: [64]u8,
    data_length: u32, //Size of entire mdl file in bytes, should match slice.len from vpkctx
    eye_pos: MdlVector,
    illumposition: MdlVector,
    hull_min: MdlVector,
    hull_max: MdlVector,
    view_bb_min: MdlVector,
    view_bb_max: MdlVector,

    flags: u32,
};

const Studiohdr_03 = struct {
    bone_count: u32, // Number of data sections (of type mstudiobone_t)
    bone_offset: u32, // Offset of first data section

    // mstudiobonecontroller_t
    bonecontroller_count: u32,
    bonecontroller_offset: u32,

    // mstudiohitboxset_t
    hitbox_count: u32,
    hitbox_offset: u32,

    // mstudioanimdesc_t
    localanim_count: u32,
    localanim_offset: u32,

    // mstudioseqdesc_t
    localseq_count: u32,
    localseq_offset: u32,

    activitylistversion: u32,
    eventsindexed: u32,

    // VMT texture filenames
    // mstudiotexture_t
    texture_count: u32,
    texture_offset: u32,

    // This offset points to a series of ints.
    // Each int value, in turn, is an offset relative to the start of this header/the-file,
    // At which there is a null-terminated string.
    texturedir_count: u32,
    texturedir_offset: u32,

    // Each skin-family assigns a texture-id to a skin location
    skinreference_count: u32,
    skinrfamily_count: u32,
    skinreference_index: u32,

    // mstudiobodyparts_t
    bodypart_count: u32,
    bodypart_offset: u32,

    // Local attachment points
    // mstudioattachment_t
    attachment_count: u32,
    attachment_offset: u32,

    // Node values appear to be single bytes, while their names are null-terminated strings.
    localnode_count: u32,
    localnode_index: u32,
    localnode_name_index: u32,

    // mstudioflexdesc_t
    flexdesc_count: u32,
    flexdesc_index: u32,

    // mstudioflexcontroller_t
    flexcontroller_count: u32,
    flexcontroller_index: u32,

    // mstudioflexrule_t
    flexrules_count: u32,
    flexrules_index: u32,

    // IK probably referse to inverse kinematics
    // mstudioikchain_t
    ikchain_count: u32,
    ikchain_index: u32,

    // Information about any "mouth" on the model for speech animation
    // More than one sounds pretty creepy.
    // mstudiomouth_t
    mouths_count: u32,
    mouths_index: u32,

    // mstudioposeparamdesc_t
    localposeparam_count: u32,
    localposeparam_index: u32,

    // Surface property value (single null-terminated string)
    surfaceprop_index: u32,

    // Unusual: In this one index comes first, then count.
    // Key-value data is a series of strings. If you can't find
    // what you're interested in, check the associated PHY file as well.
    keyvalue_index: u32,
    keyvalue_count: u32,

    // More inverse-kinematics
    // mstudioiklock_t
    iklock_count: u32,
    iklock_index: u32,

    mass: f32, // Mass of object (4-bytes) in kilograms

    contents: u32, // contents flag, as defined in bspflags.h
    // not all content types are valid; see
    // documentation on $contents QC command

    // Other models can be referenced for re-used sequences and animations
    // (See also: The $includemodel QC option.)
    // mstudiomodelgroup_t
    includemodel_count: u32,
    includemodel_index: u32,

    virtualModel: u32, // Placeholder for mutable-void*
    // Note that the SDK only compiles as 32-bit, so an int and a pointer are the same size (4 bytes)

    // mstudioanimblock_t
    animblocks_name_index: u32,
    animblocks_count: u32,
    animblocks_index: u32,

    animblockModel: u32, // Placeholder for mutable-void*

    // Points to a series of bytes?
    bonetablename_index: u32,

    vertex_base: u32, // Placeholder for void*
    offset_base: u32, // Placeholder for void*

    // Used with $constantdirectionallight from the QC
    // Model should have flag #13 set if enabled
    directionaldotproduct: i8,

    rootLod: u8, // Preferred rather than clamped

    // 0 means any allowed, N means Lod 0 -> (N-1)
    numAllowedRootLods: u8,

    unused0: u8, // ??
    unused1: u32, // ??

    // mstudioflexcontrollerui_t
    flexcontrollerui_count: u32,
    flexcontrollerui_index: u32,

    vertAnimFixedPointScale: f32, // ??
    unused2: u32,

    //
    //Offset for additional header information.
    //May be zero if not present, or also 408 if it immediately
    //follows this studiohdr_t
    //
    // studiohdr2_t
    studiohdr2index: u32,

    unused3: u32, // ??

};

pub const StudioTexture = struct {
    name_offset: u32,
    flags: u32,
    used: u32,
    unused: u32,

    material: u32,
    client_mat: u32,
    unused2: [10]u32,
};

pub const BodyPart = struct {
    name_index: u32,
    num_model: u32,
    base: u32,
    model_index: u32,
};

pub const Model = struct {
    name: [64]u8,
    type: u32,
    bounding_rad: f32,
    num_mesh: u32,
    mesh_index: u32,
    num_verts: u32,
    vert_index: u32,
    tangent_index: u32,

    num_attach: u32,
    attach_index: u32,
    num_eyeballs: u32,
    eyeball_index: u32,
    unused: [8]u32,
};

pub const Mesh = struct {
    material: i32,
    model_index: i32,
    num_vert: i32,
    vert_offset: i32,
    num_flex: i32,
    flex_index: i32,

    padding: [1]u32, //??????? Determined experimentally. Does not match what sdk public/studio.h says

    mat_type: i32,
    mat_param: i32,
    mesh_id: i32,
    center: MdlVector,

    num_lod_verts: [8]i32,
    unused: [8]i32,
};

//12 * 4 + 8 * 4

pub const ModelInfo = struct {
    vert_offsets: std.ArrayList(u16),
    texture_paths: std.ArrayList([]const u8),
    texture_names: std.ArrayList([]const u8),
    hull_min: Vec3,
    hull_max: Vec3,
};
pub fn doItCrappy(alloc: std.mem.Allocator, slice: []const u8, print: anytype) !ModelInfo {
    const log = std.log.scoped(.mdl);
    var fbs = std.io.FixedBufferStream([]const u8){ .buffer = slice, .pos = 0 };
    const r = fbs.reader();
    const o1 = try parseStruct(Studiohdr_01, .little, r);
    if (!std.mem.eql(u8, &o1.id, MDL_MAGIC_STRING))
        return error.notMdl;
    if (o1.version != 44)
        log.warn("Unsupported mdl version {d} , attempting to parse", .{o1.version});

    const h2 = try parseStruct(Studiohdr_02, .little, r);
    print("Name: {s} {d}\n", .{ h2.name, h2.data_length });
    print("{}\n", .{h2});
    const h3 = try parseStruct(Studiohdr_03, .little, r);
    print("{}\n", .{h3});

    var info = ModelInfo{
        .vert_offsets = std.ArrayList(u16).init(alloc),
        .texture_paths = std.ArrayList([]const u8).init(alloc),
        .texture_names = std.ArrayList([]const u8).init(alloc),
        .hull_min = h2.hull_min.toZa(),
        .hull_max = h2.hull_max.toZa(),
    };

    fbs.pos = h3.texture_offset;
    for (0..h3.texture_count) |_| {
        const start = fbs.pos;
        const tex = try parseStruct(StudioTexture, .little, r);
        const name: [*c]const u8 = &slice[start + tex.name_offset];
        try info.texture_names.append(try alloc.dupe(u8, std.mem.span(name)));
        print("{s} {}\n", .{ name, tex });
    }

    fbs.pos = h3.texturedir_offset;
    for (0..h3.texturedir_count) |_| {
        const int = try r.readInt(u32, .little);
        const name: [*c]const u8 = &slice[int];
        try info.texture_paths.append(try alloc.dupe(u8, std.mem.span(name)));
        print("NAME {s}\n", .{name});
    }

    fbs.pos = h3.skinreference_index;
    for (0..h3.skinreference_count) |_| {
        print("crass {d}\n", .{try r.readInt(i16, .little)});
    }

    fbs.pos = h3.bodypart_offset;
    for (0..h3.bodypart_count) |_| {
        const o2 = fbs.pos;
        const bp = try parseStruct(BodyPart, .little, r);
        const st = fbs.pos;
        defer fbs.pos = st;
        print("{}\n", .{bp});
        fbs.pos = bp.model_index + o2;
        for (0..bp.num_model) |_| {
            const o3 = fbs.pos;
            const mm = try parseStruct(Model, .little, r);
            print("{}\n", .{mm});
            print("{s}\n", .{@as([*c]const u8, @ptrCast(&mm.name[0]))});
            const stt = fbs.pos;
            defer fbs.pos = stt;
            fbs.pos = mm.mesh_index + o3;
            for (0..mm.num_mesh) |_| {
                const mesh = try parseStruct(Mesh, .little, r);
                print("BIG DOG {d}\n", .{mesh.num_vert});
                try info.vert_offsets.append(@intCast(mesh.num_vert));
                print("{}\n", .{mesh});
            }
        }
    }
    //shortpSkinref( int i ) const { return (short *)(((byte *)this) + skinindex) + i; };
    return info;
}
