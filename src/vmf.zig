//// Define's a zig struct equivalent of a vmf file
const std = @import("std");
const vdf = @import("vdf.zig");
const graph = @import("graph");

pub const Vmf = struct {
    world: World,
    entity: []const Entity,
    viewsettings: ViewSettings,
};

pub const VersionInfo = struct {
    editorversion: u32,
    editorbuild: u32,
    mapversion: u32,
    formatversion: u32,
    prefab: u32,
};

//TODO are these fully recursive
pub const VisGroups = struct {
    //visgroup
};

pub const ViewSettings = struct {
    bSnapToGrid: i32,
    bShowGrid: i32,
    nGridSpacing: i32,
    bShow3DGrid: i32,
};

pub const World = struct {
    id: u32,
    mapversion: u32,
    skyname: []const u8,
    solid: []const Solid,
    classname: []const u8,
    sounds: []const u8,
    MaxRange: []const u8,
    startdark: []const u8,
    gametitle: []const u8,
    newunit: []const u8,
    defaultteam: []const u8,
    fogenable: []const u8,
    fogblend: []const u8,
    fogcolor: []const u8,
    fogcolor2: []const u8,
    fogdir: []const u8,
    fogstart: []const u8,
    fogend: []const u8,
    light: []const u8,
    ResponseContext: []const u8,
    maxpropscreenwidth: []const u8,
};

pub const Solid = struct {
    id: u32,
    side: []const Side,
};

pub const DispInfo = struct {
    power: i32 = 4,
    elevation: f32,
    subdiv: i32,
    startposition: StringVecBracket,
};

pub const Entity = struct {
    id: u32,
    classname: []const u8,
    model: []const u8 = "",
    solid: []const Solid,
    origin: StringVec,
    angles: StringVec,
};
pub const Side = struct {
    pub const UvCoord = struct {
        axis: graph.za.Vec3,
        translation: f64,
        scale: f64,

        pub fn parseVdf(val: *const vdf.KV.Value, _: anytype, _: anytype) !@This() {
            if (val.* != .literal)
                return error.notgood;

            const str = val.literal;
            var i: usize = 0;
            const ax = try parseVec(str, &i, 4, '[', ']', f32);
            const scale = try std.fmt.parseFloat(f64, std.mem.trimLeft(u8, str[i..], " "));

            return .{
                .axis = graph.za.Vec3.new(ax[0], ax[1], ax[2]),
                .translation = ax[3],
                .scale = scale,
            };
        }
    };
    id: u32,
    plane: struct {
        pub fn parseVdf(val: *const vdf.KV.Value, _: anytype, _: anytype) !@This() {
            if (val.* != .literal)
                return error.notgood;

            const str = val.literal;
            var self: @This() = undefined;
            var i: usize = 0;
            for (0..3) |j| {
                const r1 = try parseVec(str, &i, 3, '(', ')', f64);
                self.tri[j] = vdf.Vec3.new(r1[0], r1[1], r1[2]);
            }

            return self;
        }
        tri: [3]vdf.Vec3,
    },

    uaxis: UvCoord,
    vaxis: UvCoord,
    material: []const u8,
    lightmapscale: i32,
    rotation: f32,
    smoothing_groups: i32,
    dispinfo: DispInfo,
};

fn parseVec(
    str: []const u8,
    i: *usize,
    comptime count: usize,
    comptime start: u8,
    comptime end: u8,
    comptime ft: type,
) ![count]ft {
    var ret: [count]ft = undefined;
    var in_num: bool = false;
    var vert_index: i64 = -1;
    var comp_index: usize = 0;

    while (i.* < str.len) : (i.* += 1) {
        if (str[i.*] != ' ')
            break;
    }
    var num_start_index: usize = i.*;
    const slice = str[i.*..];
    for (slice) |char| {
        switch (char) {
            else => {
                if (!in_num)
                    num_start_index = i.*;
                in_num = true;
            },
            start => {
                vert_index += 1;
            },
            ' ', end => {
                const s = str[num_start_index..i.*];
                if (in_num) {
                    const f = std.fmt.parseFloat(ft, s) catch {
                        std.debug.print("IT BROKE {s}: {s}\n", .{ s, slice });
                        return error.fucked;
                    };
                    if (vert_index < 0)
                        return error.invalid;
                    ret[comp_index] = f;
                    comp_index += 1;
                }
                in_num = false;
                if (char == end) {
                    if (comp_index != count)
                        return error.notEnoughComponent;
                    i.* += 1;
                    return ret;
                }
            },
        }
        i.* += 1;
    }
    return ret;
}

const StringVec = struct {
    v: graph.za.Vec3,

    pub fn parseVdf(val: *const vdf.KV.Value, _: anytype, _: anytype) !@This() {
        if (val.* != .literal)
            return error.notgood;
        var it = std.mem.splitScalar(u8, val.literal, ' ');
        var ret: @This() = undefined;
        ret.v.data[0] = try std.fmt.parseFloat(f32, it.next() orelse return error.wrongOrigin);
        ret.v.data[1] = try std.fmt.parseFloat(f32, it.next() orelse return error.wrongOrigin);
        ret.v.data[2] = try std.fmt.parseFloat(f32, it.next() orelse return error.wrongOrigin);
        return ret;
    }
};

const StringVecBracket = struct {
    v: graph.za.Vec3,

    pub fn parseVdf(val: *const vdf.KV.Value, _: anytype, _: anytype) !@This() {
        if (val.* != .literal)
            return error.notgood;
        var i: usize = 0;
        const a = try parseVec(val.literal, &i, 3, '[', ']', f32);
        return .{ .v = graph.za.Vec3.new(a[0], a[1], a[2]) };
    }
};

test "parse vec" {
    const str = "(0 12 12.3   ) (0 12E3 88)  ";
    var i: usize = 0;

    const a = try parseVec(str, &i, 3, '(', ')', f32);
    const b = try parseVec(str, &i, 3, '(', ')', f32);
    try std.testing.expectEqual(a[0], 0);
    try std.testing.expectEqual(b[0], 0);
    try std.testing.expectEqual(b[2], 88);
}

test "parse big" {
    const str = "[0 0 0 0] 0.02";
    var i: usize = 0;
    const a = try parseVec(str, &i, 4, '[', ']', f32);
    std.debug.print("{any}\n", .{a});
    std.debug.print("{s}\n", .{str[i..]});
    const scale = try std.fmt.parseFloat(f64, std.mem.trimLeft(u8, str[i..], " "));
    std.debug.print("{d}\n", .{scale});
}
