const std = @import("std");
const parse = @import("parse_common.zig");
const eql = std.mem.eql;

const HEADER_LUMPS = 64;
const BSP_STRING = "VPSP";

const Header = struct {
    ident: [4]u8,
    version: i32,
    header_lumps: [HEADER_LUMPS]HeaderLump,
};

const HeaderLump = struct {
    file_offset: i32,
    length: i32,
    version: i32,
    ident: [4]u8,
};

const Lump_index = enum(u8) {
    faces = 7,
    lighting = 8,
};

fn getSlice(file_slice: []const u8, start: usize, length: usize) !std.io.FixedBufferStream([]const u8) {
    if (start >= file_slice.len or start + length >= file_slice.len) return error.outOfBounds;

    return std.io.FixedBufferStream([]const u8){ .buffer = file_slice[start .. start + length], .pos = 0 };
}

test {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();
    const path = "/tmp/mapcompile/dump.bsp";
    const in = try std.fs.cwd().openFile(path, .{});

    const slice = try in.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(slice);

    var fbs = std.io.FixedBufferStream([]const u8){ .buffer = slice, .pos = 0 };
    const r_tl = fbs.reader();

    const h = try parse.parseStruct(Header, .little, r_tl);
    if (eql(u8, &h.ident, BSP_STRING)) return error.notAbsp;

    for (h.header_lumps) |lump| {
        std.debug.print("Ident {any}\n", .{lump.ident});
    }
    const out = try std.fs.cwd().createFile("ass.raw", .{});
    defer out.close();
    {
        const SUPPORTED_LIGHT_VERSION = 1;
        const light_index: u8 = @intFromEnum(Lump_index.lighting);
        const lump = h.header_lumps[light_index];
        if (lump.version != SUPPORTED_LIGHT_VERSION) return error.unsupportedLightVersion;
        std.debug.print("SIZE {d}\n", .{lump.length});
        const lfbs = try getSlice(slice, @intCast(lump.file_offset), @intCast(lump.length));

        _ = try out.writer().write(lfbs.buffer);
        //const r = lfbs.reader();
    }
}
