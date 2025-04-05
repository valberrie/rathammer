const std = @import("std");
const graph = @import("graph");
pub const Vec3 = graph.za.Vec3_f64;
pub const KV = struct {
    pub const Value = union(enum) { literal: []const u8, obj: *Object };
    key: []const u8,
    val: Value,
};
pub const Object = struct {
    const Self = @This();
    list: std.ArrayList(KV),

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{ .list = std.ArrayList(KV).init(alloc) };
    }

    pub fn deinit(self: Self) void {
        self.list.deinit();
    }

    pub fn append(self: *Self, kv: KV) !void {
        try self.list.append(kv);
    }

    pub fn getFirst(self: *Self, key: []const u8) ?KV.Value {
        for (self.list.items) |item| {
            if (std.mem.eql(u8, key, item.key))
                return item.val;
        }
        return null;
    }
};

pub fn fromValue(comptime T: type, value: *const KV.Value, alloc: std.mem.Allocator) !T {
    const info = @typeInfo(T);
    switch (info) {
        .Struct => |s| {
            if (std.meta.hasFn(T, "parseVdf")) {
                return try T.parseVdf(value, alloc);
            }
            var ret: T = undefined;
            if (value.* != .obj) {
                return error.broken;
            }
            inline for (s.fields) |f| {
                const child_info = @typeInfo(f.type);
                const do_many = child_info == .Pointer and child_info.Pointer.size == .Slice and child_info.Pointer.child != u8;
                const ar_c = if (do_many) child_info.Pointer.child else void;
                var vec = std.ArrayList(ar_c).init(alloc);
                for (value.obj.list.items) |*item| {
                    if (std.mem.eql(u8, item.key, f.name)) {
                        if (do_many) {
                            const val = fromValue(ar_c, &item.val, alloc) catch blk: {
                                //std.debug.print("parse FAILED {any}\n", .{item.val});
                                break :blk null;
                            };
                            if (val) |v|
                                try vec.append(v);
                        } else {
                            //A regular struct field
                            @field(ret, f.name) = try fromValue(f.type, &item.val, alloc);
                            break;
                        }
                    }
                }
                if (do_many)
                    @field(ret, f.name) = vec.items;
            }
            return ret;
        },
        .Int => {
            return try std.fmt.parseInt(T, value.literal, 0);
        },
        .Pointer => |p| {
            if (p.size != .Slice or p.child != u8) @compileError("no ptr");
            return value.literal;
        },
        else => @compileError("not supported " ++ @typeName(T) ++ " " ++ @tagName(info)),
    }
    return undefined;
}

pub const VdfTokenIterator = struct {
    const Self = @This();

    pub const Token = union(enum) {
        ident: []const u8,
        object_begin: void,
        object_end: void,
    };

    slice: []const u8,
    pos: usize = 0,
    state: enum { none, ident, quoted_ident } = .none,
    line_counter: usize = 0,
    char_counter: usize = 0,

    token_buf: std.ArrayList(u8),

    pub fn init(slice: []const u8, alloc: std.mem.Allocator) Self {
        return .{
            .slice = slice,
            .token_buf = std.ArrayList(u8).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        self.token_buf.deinit();
    }

    pub fn next(self: *Self) !?Token {
        self.token_buf.clearRetainingCapacity();
        while (self.pos < self.slice.len) {
            const byte = self.slice[self.pos];
            self.pos += 1;

            self.char_counter += 1;
            //while (r.readByte() catch null) |byte| {
            switch (byte) {
                '{', '}' => {
                    if (self.state == .quoted_ident) {
                        try self.token_buf.append(byte);
                    } else {
                        return switch (byte) {
                            '{' => .{ .object_begin = {} },
                            '}' => .{ .object_end = {} },
                            else => unreachable,
                        };
                    }
                }, //recur
                '\"' => { //Begin or end a string
                    switch (self.state) {
                        .ident => return error.fucked,
                        .quoted_ident => {
                            self.state = .none;
                            return .{ .ident = self.token_buf.items };
                        },
                        .none => self.state = .quoted_ident,
                    }
                },
                '\\' => return error.notImplemented, //escape the next char
                '\r', '\n' => {
                    self.line_counter += 1;
                    self.char_counter = 0;
                    switch (self.state) {
                        .quoted_ident => return error.fucked,
                        .ident => {
                            self.state = .none;
                            return .{ .ident = self.token_buf.items };
                        },
                        .none => {},
                    }
                },
                ' ', '\t' => {
                    switch (self.state) {
                        .ident => {
                            self.state = .none;
                            return .{ .ident = self.token_buf.items };
                        },
                        .quoted_ident => {
                            try self.token_buf.append(byte);
                        },
                        .none => {},
                    }
                },
                else => {
                    switch (self.state) {
                        .ident => {},
                        .quoted_ident => {},
                        .none => {
                            self.state = .ident;
                        },
                    }
                    try self.token_buf.append(byte);
                },
            }
        }
        return null;
    }
};

pub fn parse(alloc: std.mem.Allocator, slice: []const u8) !struct {
    value: Object,
    obj_list: std.ArrayList(*Object),
    arena: std.heap.ArenaAllocator,
    pub fn deinit(self: *@This()) void {
        self.arena.deinit();
        for (self.obj_list.items) |item| {
            self.obj_list.allocator.destroy(item);
        }
        self.obj_list.deinit();
        self.value.deinit();
    }
} {
    var arena = std.heap.ArenaAllocator.init(alloc);
    //defer arena.deinit();
    const aa = arena.allocator();

    var key: []const u8 = "";

    var object_stack = std.ArrayList(*Object).init(alloc);
    defer object_stack.deinit();

    var root_object = Object.init(alloc);
    var root = &root_object;

    var it = VdfTokenIterator.init(slice, alloc);
    defer it.deinit();
    var token_state: enum { key, value } = .key;
    var object_list = std.ArrayList(*Object).init(alloc);

    while (try it.next()) |token| {
        switch (token) {
            .object_begin => {
                if (token_state != .value) {
                    std.debug.print("Error at line: {d}:{d}\n", .{ it.line_counter, it.char_counter });
                    return error.invalid;
                }

                const new_root = try alloc.create(Object);
                new_root.* = Object.init(aa);
                try root.append(.{ .key = key, .val = .{ .obj = new_root } });
                try object_stack.append(root);
                try object_list.append(new_root);
                root = new_root;
                token_state = .key;
            },
            .object_end => {
                root = object_stack.pop();
            },
            .ident => switch (token_state) {
                .key => {
                    key = try aa.dupe(u8, token.ident);
                    token_state = .value;
                },
                .value => {
                    try root.append(.{ .key = key, .val = .{ .literal = try aa.dupe(u8, token.ident) } });
                    token_state = .key;
                },
            },
        }
        //Parse versioninfo
        //  expect a string or if a '{ then recur
    }
    return .{ .value = root_object, .arena = arena, .obj_list = object_list };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const infile = try std.fs.cwd().openFile("d1_trainstation_01.vmf", .{});
    defer infile.close();

    const slice = try infile.reader().readAllAlloc(alloc, std.math.maxInt(usize));

    var state: enum { none, ident, quoted_ident } = .none;

    var token_buf = try std.ArrayList(u8).initCapacity(alloc, 512);
    defer token_buf.deinit();

    var token_state: enum { key, value } = .key;
    var key: []const u8 = "";

    var object_stack = std.ArrayList(*Object).init(alloc);
    defer object_stack.deinit();

    var root_object = Object.init(alloc);
    var root = &root_object;

    var line_counter: usize = 0;
    var char_counter: usize = 0;
    for (slice) |byte| {
        char_counter += 1;
        //while (r.readByte() catch null) |byte| {
        const token: union(enum) {
            ident: []const u8,
            object_begin: void,
            object_end: void,
        } = blk: {
            switch (byte) {
                '{', '}' => {
                    if (state == .quoted_ident) {
                        try token_buf.append(byte);
                    } else {
                        break :blk switch (byte) {
                            '{' => .{ .object_begin = {} },
                            '}' => .{ .object_end = {} },
                            else => unreachable,
                        };
                    }
                }, //recur
                '\"' => { //Begin or end a string
                    switch (state) {
                        .ident => return error.fucked,
                        .quoted_ident => {
                            state = .none;
                            const str = try aa.dupe(u8, token_buf.items);
                            token_buf.clearRetainingCapacity();
                            break :blk .{ .ident = str };
                        },
                        .none => state = .quoted_ident,
                    }
                },
                '\\' => return error.notImplemented, //escape the next char
                '\r', '\n' => {
                    line_counter += 1;
                    char_counter = 0;
                    switch (state) {
                        .quoted_ident => return error.fucked,
                        .ident => {
                            state = .none;
                            const str = try aa.dupe(u8, token_buf.items);
                            token_buf.clearRetainingCapacity();
                            break :blk .{ .ident = str };
                        },
                        .none => {},
                    }
                },
                ' ', '\t' => {
                    switch (state) {
                        .ident => {
                            state = .none;
                            const str = try aa.dupe(u8, token_buf.items);
                            token_buf.clearRetainingCapacity();
                            break :blk .{ .ident = str };
                        },
                        .quoted_ident => {
                            try token_buf.append(byte);
                        },
                        .none => {},
                    }
                },
                else => {
                    switch (state) {
                        .ident => {},
                        .quoted_ident => {},
                        .none => {
                            state = .ident;
                        },
                    }
                    try token_buf.append(byte);
                },
            }
            continue;
        };
        switch (token) {
            .object_begin => {
                if (token_state != .value) {
                    std.debug.print("Error at line: {d}:{d}\n", .{ line_counter, char_counter });
                    return error.invalid;
                }

                const new_root = try alloc.create(Object);
                new_root.* = Object.init(aa);
                try root.append(.{ .key = key, .val = .{ .obj = new_root } });
                try object_stack.append(root);
                root = new_root;
                token_state = .key;
            },
            .object_end => {
                root = object_stack.pop();
            },
            .ident => switch (token_state) {
                .key => {
                    key = token.ident;
                    token_state = .value;
                },
                .value => {
                    try root.append(.{ .key = key, .val = .{ .literal = token.ident } });
                    token_state = .key;
                },
            },
        }
        //Parse versioninfo
        //  expect a string or if a '{ then recur
    }
    const ver = try fromValue(struct {
        editorversion: u32,
        editorbuild: u32,
        mapversion: u32,
        formatversion: u32,
        prefab: u32,
    }, &root_object.getFirst("versioninfo").?, alloc);
    std.debug.print("{any}\n", .{ver});
    //const visg = try fromValue(visgroups, &root_object.getFirst("visgroups").?, alloc);
    const visg = try fromValue(World, &root_object.getFirst("world").?, alloc);
    std.debug.print("Solid count: {d}\n", .{visg.solid.len});
    const outfile = try std.fs.cwd().createFile("out.obj", .{});
    const w = outfile.writer();
    var ind_offset: usize = 1;
    try outObjSolid(visg.solid, alloc, w, &ind_offset);
    //for (visg.solid) |sol| {
    //    const mesh = try genMesh(sol.side, alloc);
    //    try w.print("o obj_{d}\n", .{sol.id});
    //    for (mesh.verts.items) |vert| {
    //        try w.print("v {d} {d} {d}\n", .{ vert.data[0], vert.data[1], vert.data[2] });
    //    }
    //    const len = @divExact(mesh.index.items.len, 3);
    //    const ind = mesh.index.items;
    //    for (0..len) |i| {
    //        const b = i * 3;
    //        try w.print("f {d} {d} {d}\n", .{ ind[b] + ind_offset, ind[b + 1] + ind_offset, ind[b + 2] + ind_offset });
    //    }
    //    ind_offset += mesh.verts.items.len;
    //    //std.debug.print("{s}\n", .{sid.material});
    //}

    const ent = try fromValue(Map, &.{ .obj = &root_object }, alloc);
    for (ent.entity) |e| {
        try outObjSolid(e.solid, alloc, w, &ind_offset);
    }
    if (false) {
        root = &root_object;
        const world = root.getFirst("world").?.obj.getFirst("solid").?;
        try printIt(world.obj, 0);
    }
    //try printIt(&root_object, 0);
}

fn outObjSolid(solid: []const Solid, alloc: std.mem.Allocator, w: anytype, ind_offset: *usize) !void {
    for (solid) |sol| {
        const mesh = try genMesh(sol.side, alloc);
        try w.print("o obj_{d}\n", .{sol.id});
        for (mesh.verts.items) |vert| {
            try w.print("v {d} {d} {d}\n", .{ vert.data[0], vert.data[1], vert.data[2] });
        }
        const len = @divExact(mesh.index.items.len, 3);
        const ind = mesh.index.items;
        for (0..len) |i| {
            const b = i * 3;
            try w.print("f {d} {d} {d}\n", .{ ind[b] + ind_offset.*, ind[b + 1] + ind_offset.*, ind[b + 2] + ind_offset.* });
        }
        ind_offset.* += mesh.verts.items.len;
        //std.debug.print("{s}\n", .{sid.material});
    }
}

const visgroups = struct {
    visgroup: []const struct {
        name: []const u8,
        visgroupid: u32,
        color: []const u8,
    },
};
const Side = struct {
    id: u32,
    plane: struct {
        pub fn parseVdf(val: *const KV.Value, _: std.mem.Allocator) !@This() {
            if (val.* != .literal)
                return error.notgood;
            const str = val.literal;
            var in_num: bool = false;
            var vert_index: i64 = -1;
            var comp_index: usize = 0;

            var num_start_index: usize = 0;
            var self: @This() = undefined;
            for (str, 0..) |char, i| {
                switch (char) {
                    '0'...'9', '-', '.', 'e' => {
                        if (!in_num)
                            num_start_index = i;
                        in_num = true;
                    },
                    '(' => {
                        vert_index += 1;
                    },
                    ' ', ')' => {
                        const s = str[num_start_index..i];
                        if (in_num) {
                            const f = std.fmt.parseFloat(f64, s) catch {
                                std.debug.print("IT BROKE {s}: {s}\n", .{ s, str });
                                return error.fucked;
                            };
                            if (vert_index < 0)
                                return error.invalid;
                            self.tri[@intCast(vert_index)].data[comp_index] = f;
                            comp_index += 1;
                        }
                        in_num = false;
                        if (char == ')') {
                            if (comp_index != 3)
                                return error.notEnoughComponent;
                            comp_index = 0;
                        }
                    },
                    else => return error.invalid,
                }
            }
            return self;
        }
        tri: [3]Vec3,
    },
    material: []const u8,
};

const Solid = struct {
    id: u32,
    side: []const Side,
};

const World = struct {
    solid: []const Solid,
};

const Entity = struct {
    solid: []const Solid,
};

const Map = struct {
    entity: []const Entity,
};

pub fn getGlobalUp(norm: Vec3) !Vec3 {
    var axis: ?usize = null;
    var max = -std.math.floatMax(f64);
    const dat: [3]f64 = norm.data;
    for (dat, 0..) |comp, i| {
        const abs = @abs(comp);
        if (abs > max) {
            max = abs;
            axis = i;
        }
    }
    if (axis == null)
        return error.invalidVector;
    if (axis == 1)
        return Vec3.new(1, 0, 0);
    return Vec3.new(0, 1, 0);
}

pub fn baseWinding(plane: Plane, size: f64, alloc: std.mem.Allocator) !std.ArrayList(Vec3) {
    var verts = try std.ArrayList(Vec3).initCapacity(alloc, 4);
    const global_up = try getGlobalUp(plane.norm);
    const right = plane.norm.cross(global_up).norm().scale(size / 2);

    const up = plane.norm.cross(right);
    const offset = plane.norm.scale(plane.dist);
    try verts.append(offset.add(right.scale(-1)).add(up));
    try verts.append(offset.add(right.scale(-1)).add(up.scale(-1)));
    try verts.append(offset.add(right).add(up.scale(-1)));
    try verts.append(offset.add(right).add(up));
    return verts;
}

const Plane = struct {
    norm: Vec3,
    dist: f64,
    pub fn fromTri(tri: [3]Vec3) @This() {
        const v1 = tri[1].sub(tri[0]);
        const v2 = tri[2].sub(tri[0]);
        const norm = v1.cross(v2).norm();
        return .{
            .norm = norm,
            .dist = norm.dot(tri[0]),
        };
    }
};

pub fn clipWinding(winding: std.ArrayList(Vec3), plane: Plane, alloc: std.mem.Allocator) !std.ArrayList(Vec3) {
    const SideClass = enum {
        back,
        front,
        on,
    };

    var sides = try std.ArrayList(SideClass).initCapacity(alloc, winding.items.len + 1);
    defer sides.deinit();
    var dists = try std.ArrayList(f64).initCapacity(alloc, winding.items.len + 1);
    defer dists.deinit();
    for (winding.items) |wind| {
        const dist = plane.norm.dot(wind) - plane.dist;
        try dists.append(dist);
        if (dist > EPSILON) {
            try sides.append(.front);
        } else if (dist < -EPSILON) {
            try sides.append(.back);
        } else {
            try sides.append(.on);
        }
    }
    var front = std.ArrayList(Vec3).init(alloc);
    if (winding.items.len == 0) return front;
    try sides.append(sides.items[0]);
    try dists.append(dists.items[0]);

    for (winding.items, 0..) |p_cur, i| {
        if (sides.items[i] == .on) {
            try front.append(p_cur);
            continue;
        }
        if (sides.items[i] == .front)
            try front.append(p_cur);

        if (sides.items[i + 1] == .on or sides.items[i] == sides.items[i + 1])
            continue;

        const p_next = winding.items[(i + 1) % winding.items.len];
        const t = dists.items[i] / (dists.items[i] - dists.items[i + 1]);

        const v = p_next.sub(p_cur).scale(t);
        try front.append(p_cur.add(v));
    }
    return front;
}

const EPSILON: f64 = 2E-14;

pub fn roundVec(v: Vec3) Vec3 {
    var a = v;
    const R: f64 = 128;
    const rr = @Vector(3, f64){ R, R, R };
    a.data = @round(v.data * rr) / rr;
    return a;
}

//Generate indicies into trianglnes that can be drawin with the uknow, opengl draw indexed
pub fn triangulate(winding: []const Vec3, alloc: std.mem.Allocator, offset: u32) !std.ArrayList(u32) {
    var ret = std.ArrayList(u32).init(alloc);
    if (winding.len < 3) return ret;

    for (1..winding.len - 1) |i| {
        const ii: u32 = @intCast(i);
        try ret.append(0 + offset);
        try ret.append(ii + 1 + offset);
        try ret.append(ii + offset);
    }

    return ret;
}

const Mesh = struct {
    index: std.ArrayList(u32),
    verts: std.ArrayList(Vec3),
};

pub fn genMesh(sides: []const Side, alloc: std.mem.Allocator) !Mesh {
    var ret: Mesh = .{
        .index = std.ArrayList(u32).init(alloc),
        .verts = std.ArrayList(Vec3).init(alloc),
    };
    const MAPSIZE = std.math.maxInt(i32);
    for (sides) |side| {
        if (std.mem.startsWith(u8, side.material, "TOOLS"))
            continue;

        const plane = Plane.fromTri(side.plane.tri);

        var winding = try baseWinding(plane, @floatFromInt(MAPSIZE / 2), alloc);

        for (sides) |subside| {
            const pl2 = Plane.fromTri(subside.plane.tri);
            if (plane.norm.dot(pl2.norm) > 1 - EPSILON)
                continue;

            const new_winding = try clipWinding(winding, pl2, alloc);
            winding.deinit();
            winding = new_winding;
        }

        if (winding.items.len < 3)
            continue;

        for (winding.items) |*item| {
            item.* = roundVec(item.*);
        }

        const indexs = try triangulate(winding.items, alloc, @intCast(ret.verts.items.len));
        try ret.index.appendSlice(indexs.items);
        try ret.verts.appendSlice(winding.items);
        indexs.deinit();
    }

    return ret;
}

pub fn printIt(obj: *Object, indent: usize) !void {
    for (obj.list.items) |item| {
        for (0..indent * 2) |_|
            std.debug.print(" ", .{});
        switch (item.val) {
            .literal => |s| {
                std.debug.print("{s}: {s}\n", .{ item.key, s });
            },
            .obj => |o| {
                std.debug.print("{s}:\n", .{item.key});
                try printIt(o, indent + 1);
            },
        }
    }
}
