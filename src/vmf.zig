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

pub const EditorInfo = struct {
    color: StringVec,
    visgroupid: i32 = -1,
    groupid: i32 = -1,
    visgroupshown: i8 = 1,
    visgroupautoshown: i8 = 1,
    comments: []const u8 = "",
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

    editor: EditorInfo,
};

pub const Solid = struct {
    id: u32,
    side: []const Side,

    editor: EditorInfo,
};

pub const DispInfo = struct {
    power: i32 = -1, //Hack, this is used to see if vdf has initilized dispinfo
    elevation: f32 = undefined,
    subdiv: i32 = undefined,
    startposition: StringVecBracket = undefined,

    normals: DispVectorRow = undefined,
    offsets: DispVectorRow = undefined,
    offset_normals: DispVectorRow = undefined,
    distances: DispRow = undefined,
    alphas: DispRow = undefined,
    triangle_tags: DispRow = undefined,
};

pub const DispRow = struct {
    rows: std.ArrayList(std.ArrayList(f32)),

    pub fn parseVdf(val: *const vdf.KV.Value, alloc: std.mem.Allocator, _: anytype) !@This() {
        if (val.* == .literal)
            return error.notgood;
        var ret = try std.ArrayList(std.ArrayList(f32)).initCapacity(alloc, val.obj.list.items.len);
        try ret.resize(val.obj.list.items.len);
        for (val.obj.list.items) |row| {
            if (row.val != .literal)
                return error.invalidDispNormal;
            const num_norm = val.obj.list.items.len;
            var it = std.mem.splitScalar(u8, row.val.literal, ' ');

            if (!std.mem.startsWith(u8, row.key, "row"))
                return error.invalidNormalKey;
            const row_index = try std.fmt.parseInt(u32, row.key["row".len..], 10);
            var new_row = try std.ArrayList(f32).initCapacity(alloc, num_norm);

            for (0..num_norm) |_| {
                const x = it.next() orelse return error.notEnoughNormals;

                try new_row.append(try std.fmt.parseFloat(f32, x));
            }
            //TODO check all have been visited
            if (row_index >= ret.items.len)
                return error.invalidRowIndex;
            ret.items[row_index] = new_row;
        }
        return .{ .rows = ret };
    }
};

pub const DispVectorRow = struct {
    rows: std.ArrayList(std.ArrayList(graph.za.Vec3)),

    pub fn parseVdf(val: *const vdf.KV.Value, alloc: std.mem.Allocator, _: anytype) !@This() {
        if (val.* == .literal)
            return error.notgood;
        var ret = try std.ArrayList(std.ArrayList(graph.za.Vec3)).initCapacity(alloc, val.obj.list.items.len);
        try ret.resize(val.obj.list.items.len);
        for (val.obj.list.items) |row| {
            if (row.val != .literal)
                return error.invalidDispNormal;
            const num_norm = val.obj.list.items.len;
            var it = std.mem.splitScalar(u8, row.val.literal, ' ');

            if (!std.mem.startsWith(u8, row.key, "row"))
                return error.invalidNormalKey;
            const row_index = try std.fmt.parseInt(u32, row.key["row".len..], 10);
            var new_row = try std.ArrayList(graph.za.Vec3).initCapacity(alloc, num_norm);

            for (0..num_norm) |_| {
                const x = it.next() orelse return error.notEnoughNormals;
                const y = it.next() orelse return error.notEnoughNormals;
                const z = it.next() orelse return error.notEnoughNormals;

                try new_row.append(graph.za.Vec3.new(
                    try std.fmt.parseFloat(f32, x),
                    try std.fmt.parseFloat(f32, y),
                    try std.fmt.parseFloat(f32, z),
                ));
            }
            //TODO check all have been visited
            if (row_index >= ret.items.len)
                return error.invalidRowIndex;
            ret.items[row_index] = new_row;
        }
        return .{ .rows = ret };
    }
};

pub const Entity = struct {
    id: u32,
    classname: []const u8,
    model: []const u8 = "",
    solid: []const Solid,
    origin: StringVec,
    angles: StringVec,
    editor: EditorInfo,
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
    dispinfo: DispInfo = .{},
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

/// Parse a vector "0.0 1.0 2"
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

/// Parse a vector "[0.0 2.0 3.0]"
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
