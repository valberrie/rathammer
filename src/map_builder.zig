const std = @import("std");
const graph = @import("graph");

pub fn splitPath(path: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |index| {
        return .{ path[0..index], path[index + 1 ..] };
    }

    return .{ ".", path };
}

pub fn printString(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    var vec = std.ArrayList(u8).init(alloc);

    try vec.writer().print(fmt, args);
    return vec.items;
}

pub fn stripExtension(str: []const u8) []const u8 {
    return str[0 .. std.mem.lastIndexOfScalar(u8, str, '.') orelse str.len];
}

const builtin = @import("builtin");
const DO_WINE = builtin.target.os.tag != .windows;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();

    var arg_it = try std.process.argsWithAllocator(alloc);
    defer arg_it.deinit();
    const Arg = graph.ArgGen.Arg;

    const args = try graph.ArgGen.parseArgs(&.{
        Arg("vmf", .string, "vmf to load"),
    }, &arg_it);

    const game_name = "hl2_complete";
    const gamedir = "/mnt/flash/SteamLibrary/steamapps/common/Half-Life 2";
    const working_dir = "/tmp/mapcompile";
    const outputdir = gamedir ++ "/hl2/maps";

    const mapname = args.vmf orelse {
        std.debug.print("Please specify vmf name with --vmf\n", .{});
        return;
    };

    const stripped = splitPath(mapname);
    const map_no_extension = stripExtension(stripped[1]);
    const working = try std.fs.cwd().makeOpenPath(working_dir, .{});

    try std.fs.cwd().copyFile(mapname, working, stripped[1], .{});

    const output_dir = try std.fs.cwd().openDir(outputdir, .{});

    const game_path = gamedir ++ "/" ++ game_name;
    try runCommand(alloc, &.{ "wine", gamedir ++ "/bin/vbsp.exe", "-game", game_path, "-novconfig", map_no_extension }, working_dir);
    try runCommand(alloc, &.{ "wine", gamedir ++ "/bin/vvis.exe", "-game", game_path, "-novconfig", "-fast", map_no_extension }, working_dir);
    try runCommand(alloc, &.{ "wine", gamedir ++ "/bin/vrad.exe", "-game", game_path, "-novconfig", "-fast", map_no_extension }, working_dir);

    const bsp_name = try printString(alloc, "{s}.bsp", .{map_no_extension});
    try working.copyFile(bsp_name, output_dir, bsp_name, .{});
}

fn runCommand(alloc: std.mem.Allocator, argv: []const []const u8, working_dir: []const u8) !void {
    std.debug.print("Running command in: {s} ", .{working_dir});
    for (argv) |arg|
        std.debug.print("{s} ", .{arg});
    std.debug.print("\n", .{});
    const res = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .cwd = working_dir,
    });
    std.debug.print("{s}\n", .{res.stdout});
    switch (res.term) {
        .Exited => |e| {
            if (e == 0)
                return;
        },
        else => {},
    }
    std.debug.print("{s}\n", .{res.stderr});
    return error.broken;
}
