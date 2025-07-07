const std = @import("std");
pub const clip_solid = @import("clip_solid.zig");
pub const prim_gen = @import("primitive_gen.zig");

test {
    std.testing.refAllDecls(@This());
}
