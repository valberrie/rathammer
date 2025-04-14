const std = @import("std");
const com = @import("parse_common.zig");
const parseStruct = com.parseStruct;

const MdlVector = struct { x: f32, y: f32, z: f32 };

const MDL_MAGIC_STRING = "IDST";
const Studiohdr_01 = struct {
    id: [4]u8,
    //id: u32,
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

test "mdl" {
    const log = std.log.scoped(.mdl);
    //const alloc = std.testing.alloc;
    const in = try std.fs.cwd().openFile("mdl/out.mdl", .{});
    // const slice = try in.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    // defer alloc.free(slice);
    const r = in.reader();
    const o1 = try parseStruct(Studiohdr_01, .little, r);
    if (!std.mem.eql(u8, &o1.id, MDL_MAGIC_STRING))
        return error.notMdl;
    if (o1.version != 44)
        log.warn("Unsupported mdl version {d} , attempting to parse", .{o1.version});

    const h2 = try parseStruct(Studiohdr_02, .little, r);
    std.debug.print("Name: {s} {d}\n", .{ h2.name, h2.data_length });
    std.debug.print("{}\n", .{h2});
    const h3 = try parseStruct(Studiohdr_03, .little, r);
    std.debug.print("{}\n", .{h3});
}
