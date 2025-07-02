const std = @import("std");
pub const clip_solid = @import("clip_solid.zig");

test {
    std.testing.refAllDecls(@This());
}
