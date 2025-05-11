const std = @import("std");

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
