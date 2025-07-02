const std = @import("std");
//Contains random things

threadlocal var real_path_buffer: [1024]u8 = undefined;
pub fn openFileFatal(
    dir: std.fs.Dir,
    sub_path: []const u8,
    flags: std.fs.File.OpenFlags,
    message: []const u8,
) std.fs.File {
    return dir.openFile(sub_path, flags) catch |err| {
        const rp = dir.realpath(".", &real_path_buffer) catch "error.realpathFailed";

        std.debug.print("Failed to open file {s} in directory: {s}  with error: {}\n", .{ sub_path, rp, err });
        std.debug.print("{s}\n", .{message});
        std.process.exit(1);
    };
}

pub fn openDirFatal(
    dir: std.fs.Dir,
    sub_path: []const u8,
    flags: std.fs.Dir.OpenDirOptions,
    message: []const u8,
) std.fs.Dir {
    return dir.openDir(sub_path, flags) catch |err| {
        const rp = dir.realpath(".", &real_path_buffer) catch "error.realpathFailed";

        std.debug.print("Failed to open directory {s} in {s} with error: {}\n", .{ sub_path, rp, err });
        std.debug.print("{s}\n", .{message});
        std.process.exit(1);
    };
}

//Perform a linear search for closest match, returning index
pub fn nearest(comptime T: type, items: []const T, context: anytype, comptime distanceFn: fn (@TypeOf(context), item: T, key: T) f32, key: T) ?usize {
    var nearest_i: ?usize = null;
    var dist: f32 = std.math.floatMax(f32);
    for (items, 0..) |item, i| {
        const d = distanceFn(context, item, key);
        if (d < dist) {
            nearest_i = i;
            dist = d;
        }
    }
    return nearest_i;
}
