const std = @import("std");
const vdf = @import("vdf.zig");
const VpkCtx = @import("vpk.zig").Context;
const Dir = std.fs.Dir;
const log = std.log.scoped(.gameinfo);
fn readFromFile(alloc: std.mem.Allocator, dir: std.fs.Dir, filename: []const u8) ![]const u8 {
    const inf = try dir.openFile(filename, .{});
    defer inf.close();
    const slice = try inf.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    return slice;
}

pub fn loadGameinfo(alloc: std.mem.Allocator, base_dir: Dir, game_dir: Dir, vpkctx: *VpkCtx, loadctx: anytype) !void {
    const sl = readFromFile(alloc, game_dir, "gameinfo.txt") catch |err| {
        var out_path_buf: [512]u8 = undefined;
        const rp = game_dir.realpath(".", &out_path_buf) catch return err;
        log.err("Failed to find \"gameinfo.txt\" in {s}", .{rp});
        return err;
    };
    defer alloc.free(sl);

    var obj = try vdf.parse(alloc, sl);
    defer obj.deinit();

    var aa = std.heap.ArenaAllocator.init(alloc);
    defer aa.deinit();
    const gameinfo = try vdf.fromValue(struct {
        gameinfo: struct {
            game: []const u8 = "",
            title: []const u8 = "",
            type: []const u8 = "",
        } = .{},
    }, &.{ .obj = &obj.value }, aa.allocator(), null);
    log.info("Loading gameinfo {s} {s}", .{ gameinfo.gameinfo.game, gameinfo.gameinfo.title });

    const fs = try obj.value.recursiveGetFirst(&.{ "gameinfo", "filesystem", "searchpaths" });
    if (fs != .obj)
        return error.invalidGameInfo;
    //vdf.printObj(fs.obj.*, 0);
    const startsWith = std.mem.startsWith;
    for (fs.obj.list.items) |entry| {
        var tk = std.mem.tokenizeScalar(u8, entry.key, '+');
        while (tk.next()) |t| {
            if (std.mem.startsWith(u8, t, "game")) {
                if (entry.val != .literal)
                    return error.invalidGameInfo;
                const l = entry.val.literal;
                var path = l;
                const dir = base_dir;
                if (startsWith(u8, l, "|")) {
                    const end = std.mem.indexOfScalar(u8, l[1..], '|') orelse return error.invalidGameInfo;
                    const special = l[1..end];
                    _ = special; //TODO actually use this?
                    //std.debug.print("Special {s}\n", .{special});
                    //          + 2 because end is offset by 1
                    path = l[end + 2 ..];
                    //if(std.mem.eql(u8, special, "all_source_engine_paths"))
                    //dir = game_dir;
                }
                //std.debug.print("Path {s}\n", .{path});
                if (std.mem.endsWith(u8, path, ".vpk")) {
                    loadctx.printCb("mounting: {s}", .{path});
                    if ((std.mem.indexOfPos(u8, path, 0, "sound") == null)) {
                        vpkctx.addDir(dir, path) catch |err| {
                            log.err("Failed to mount vpk {s} with error {}", .{ path, err });
                        };
                    }
                }
            }
        }
    }
    //TODO this is temp
    try vpkctx.addLooseDir(game_dir, ".");
}
