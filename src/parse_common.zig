const std = @import("std");
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
