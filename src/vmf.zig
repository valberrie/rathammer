//// Define's a zig struct equivalent of a vmf file
const std = @import("std");
const vdf = @import("vdf.zig");

pub const Vmf = struct {
    world: World,
    entity: []const Entity,
};

pub const VersionInfo = struct {
    editorversion: u32,
    editorbuild: u32,
    mapversion: u32,
    formatversion: u32,
    prefab: u32,
};

pub const World = struct {
    id: u32,
    mapversion: u32,
    solid: []const Solid,
};

pub const Solid = struct {
    id: u32,
    side: []const Side,
};
pub const Entity = struct {
    id: u32,
    classname: []const u8,
    model: []const u8,
    solid: []const Solid,
};
pub const Side = struct {
    id: u32,
    plane: struct {
        pub fn parseVdf(val: *const vdf.KV.Value, _: std.mem.Allocator) !@This() {
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
        tri: [3]vdf.Vec3,
    },
    material: []const u8,
};
