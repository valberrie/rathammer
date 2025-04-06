const std = @import("std");
const ImageFormat = enum(i32) {
    IMAGE_FORMAT_NONE = -1,
    IMAGE_FORMAT_RGBA8888 = 0,
    IMAGE_FORMAT_ABGR8888,
    IMAGE_FORMAT_RGB888,
    IMAGE_FORMAT_BGR888,
    IMAGE_FORMAT_RGB565,
    IMAGE_FORMAT_I8,
    IMAGE_FORMAT_IA88,
    IMAGE_FORMAT_P8,
    IMAGE_FORMAT_A8,
    IMAGE_FORMAT_RGB888_BLUESCREEN,
    IMAGE_FORMAT_BGR888_BLUESCREEN,
    IMAGE_FORMAT_ARGB8888,
    IMAGE_FORMAT_BGRA8888,
    IMAGE_FORMAT_DXT1,
    IMAGE_FORMAT_DXT3,
    IMAGE_FORMAT_DXT5,
    IMAGE_FORMAT_BGRX8888,
    IMAGE_FORMAT_BGR565,
    IMAGE_FORMAT_BGRX5551,
    IMAGE_FORMAT_BGRA4444,
    IMAGE_FORMAT_DXT1_ONEBITALPHA,
    IMAGE_FORMAT_BGRA5551,
    IMAGE_FORMAT_UV88,
    IMAGE_FORMAT_UVWQ8888,
    IMAGE_FORMAT_RGBA16161616F,
    IMAGE_FORMAT_RGBA16161616,
    IMAGE_FORMAT_UVLX8888,
};

const VtfHeader01 = struct {
    width: u16,
    height: u16,
    flags: u32,
    frames: u16,
    first_frame: u16,
    padding: [4]u8,
    reflectivity: [3]f32,
    padding1: [4]u8,
    bumpmap_scale: f32,
    highres_fmt: ImageFormat,
    mipmap_count: u8,
    lowres_fmt: ImageFormat,
    lowres_w: u8,
    lowres_h: u8,
};

pub fn parseStruct(comptime T: type, endian: std.builtin.Endian, r: anytype) !T {
    const info = @typeInfo(T);
    switch (info) {
        .Enum => |e| {
            const int = try parseStruct(e.tag_type, endian, r);
            return @enumFromInt(int);
        },
        .Struct => |s| {
            var ret: T = undefined;
            inline for (s.fields) |f| {
                @field(ret, f.name) = try parseStruct(f.type, endian, r);
            }
            return ret;
        },
        .Float => {
            switch (T) {
                f32 => {
                    const int = try r.readInt(u32, endian);
                    return @bitCast(int);
                },
                else => @compileError("bad float"),
            }
        },
        .Int => {
            return try r.readInt(T, endian);
        },
        .Array => |a| {
            var ret: T = undefined;
            for (0..a.len) |i| {
                ret[i] = try parseStruct(a.child, endian, r);
            }
            return ret;
        },
        else => @compileError("not supported"),
    }
}

test "basic" {
    const open = try std.fs.cwd().openFile("crass.vtf", .{});
    var r = open.reader();
    const VtfSig = 0x00465456;
    const sig = try r.readInt(u32, .little);
    if (sig != VtfSig) return error.notVtf;

    const version_maj = try r.readInt(u32, .little);
    const version_min = try r.readInt(u32, .little);
    if (version_maj != 7) return error.unsupportedVersion;
    const header_size = try r.readInt(u32, .little);
    _ = header_size;

    const h1 = try parseStruct(VtfHeader01, .little, r);
    std.debug.print("{}\n", .{h1});

    switch (version_min) {
        1 => {},
        else => return error.unsupportedVersion,
    }
}
