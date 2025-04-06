const std = @import("std");

pub const Side = struct {
    //verts:
};

pub const Solid = struct {
    sides: std.ArrayList(Side),
};
