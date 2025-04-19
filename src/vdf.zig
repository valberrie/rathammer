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

    fn isWhitespace(char: u8) bool {
        return char == ' ' or char == '\t';
    }

    fn isNewline(char: u8) bool {
        return char == '\n' or char == '\r';
    }

    pub fn next(self: *Self) !?Token {
        const eql = std.mem.eql;
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
                //escape the next char
                //This is commented out as some vmt's use backslashes as path seperators
                //'\\' => {
                //    switch (self.state) {
                //        .quoted_ident => {},
                //        else => return error.fucked,
                //    }
                //    //Ugly way to do it
                //    if (self.pos + 1 < self.slice.len) {
                //        try self.token_buf.append(self.slice[self.pos]);
                //        self.pos += 1;
                //    }
                //},
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
                    if (self.state == .ident or self.state == .none) {
                        if (self.pos < self.slice.len and eql(u8, self.slice[self.pos - 1 .. self.pos + 1], "//")) {
                            //Seek forward, leaving pos at next newline,
                            while (self.pos < self.slice.len and !isNewline(self.slice[self.pos])) : (self.pos += 1) {}
                            if (self.state == .ident) {
                                self.state = .none;
                                return .{ .ident = self.token_buf.items };
                            }
                        } else {
                            self.state = .ident;
                            try self.token_buf.append(byte);
                        }
                    } else {
                        try self.token_buf.append(byte);
                    }
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

    var key: []u8 = "";

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
                    _ = std.ascii.lowerString(key, key);
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

fn printObj(obj: Object, ident: usize) void {
    const ident_buf = [_]u8{' '} ** 100;
    const buf = ident_buf[0 .. ident * 4];

    std.debug.print("{s}{{\n", .{buf});
    defer std.debug.print("{s}}}\n", .{buf});
    for (obj.list.items) |item| {
        std.debug.print("{s}{s}: ", .{ buf, item.key });
        switch (item.val) {
            .literal => |k| std.debug.print("{s}\n", .{k}),
            .obj => |o| printObj(o.*, ident + 1),
        }
    }
}

test {
    const alloc = std.testing.allocator;
    const in = try std.fs.cwd().openFile("tf/gameinfo.txt", .{});
    const slice = try in.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(slice);

    var val = try parse(alloc, slice);
    defer val.deinit();
    printObj(val.value, 0);
}

//fn outObjSolid(solid: []const Solid, alloc: std.mem.Allocator, w: anytype, ind_offset: *usize) !void {
//    for (solid) |sol| {
//        const mesh = try genMesh(sol.side, alloc);
//        try w.print("o obj_{d}\n", .{sol.id});
//        for (mesh.verts.items) |vert| {
//            try w.print("v {d} {d} {d}\n", .{ vert.data[0], vert.data[1], vert.data[2] });
//        }
//        const len = @divExact(mesh.index.items.len, 3);
//        const ind = mesh.index.items;
//        for (0..len) |i| {
//            const b = i * 3;
//            try w.print("f {d} {d} {d}\n", .{ ind[b] + ind_offset.*, ind[b + 1] + ind_offset.*, ind[b + 2] + ind_offset.* });
//        }
//        ind_offset.* += mesh.verts.items.len;
//        //std.debug.print("{s}\n", .{sid.material});
//    }
//}
