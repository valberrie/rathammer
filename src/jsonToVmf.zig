const std = @import("std");
const graph = @import("graph");
const ecs = @import("ecs.zig");

const StringStorage = @import("string.zig").StringStorage;
const json_map = @import("json_map.zig");

const LoadCtx = struct {
    const Self = @This();

    pub fn printCb(self: *Self, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        _ = fmt;
        _ = args;
    }

    pub fn cb(_: *Self, _: []const u8) void {}

    pub fn addExpected(_: *Self, _: usize) void {}
};

/// We do not free any memory
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    var arg_it = try std.process.argsWithAllocator(alloc);
    defer arg_it.deinit();

    const Arg = graph.ArgGen.Arg;
    const args = try graph.ArgGen.parseArgs(&.{
        Arg("json", .string, "json map to load"),
    }, &arg_it);

    var loadctx = LoadCtx{};

    if (args.json) |mapname| {
        const infile = try std.fs.cwd().openFile(mapname, .{});
        defer infile.close();
        const slice = try infile.reader().readAllAlloc(alloc, std.math.maxInt(usize));

        var strings = StringStorage.init(alloc);
        var ecs_p = try ecs.EcsT.init(alloc);

        var vpkmapper = json_map.VpkMapper.init(alloc);

        const jsonctx = json_map.InitFromJsonCtx{ .alloc = alloc, .str_store = &strings };
        const parsed = try json_map.loadJson(jsonctx, slice, &loadctx, &ecs_p, &vpkmapper);
        _ = parsed;
    } else {
        std.debug.print("Please specify json file with --json\n", .{});
    }
}
