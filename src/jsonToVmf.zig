const std = @import("std");
const graph = @import("graph");
const ecs = @import("ecs.zig");
const vdf_serial = @import("vdf_serial.zig");
const vmf = @import("vmf.zig");

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

fn sanatizeMaterialName(name: []const u8) []const u8 {
    //materials
    const start = if (std.mem.startsWith(u8, name, "materials/")) "materials/".len else 0;
    const end_offset = if (std.mem.endsWith(u8, name, ".vmt")) ".vmt".len else 0;
    return name[start .. name.len - end_offset];
}

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
        const outfile = try std.fs.cwd().createFile("dump.vmf", .{});
        defer outfile.close();
        const wr = outfile.writer();
        var bwr = std.io.bufferedWriter(wr);
        defer bwr.flush() catch {};
        const bb = bwr.writer();
        var vr = vdf_serial.WriteVdf(@TypeOf(bb)).init(alloc, bb);

        const infile = try std.fs.cwd().openFile(mapname, .{});
        defer infile.close();
        const slice = try infile.reader().readAllAlloc(alloc, std.math.maxInt(usize));

        var strings = StringStorage.init(alloc);
        var ecs_p = try ecs.EcsT.init(alloc);

        var vpkmapper = json_map.VpkMapper.init(alloc);

        const jsonctx = json_map.InitFromJsonCtx{ .alloc = alloc, .str_store = &strings };
        const parsed = try json_map.loadJson(jsonctx, slice, &loadctx, &ecs_p, &vpkmapper);
        _ = parsed;

        {
            try vr.writeKv("versioninfo", vmf.VersionInfo{
                .editorversion = 400,
                .editorbuild = 2987,
                .mapversion = 1,
                .formatversion = 100,
                .prefab = 0,
            });

            var solids = ecs_p.iterator(.solid);
            while (solids.next()) |solid| {
                if (solid.parent_entity != null) continue;

                try vr.writeKey("solid");
                try vr.beginObject();
                {
                    try vr.writeKv("id", solids.i);
                    for (solid.sides.items) |side| {
                        try vr.writeKey("side");
                        try vr.beginObject();
                        {
                            try vr.writeKv("material", sanatizeMaterialName(vpkmapper.getResource(side.tex_id) orelse ""));
                            if (side.index.items.len >= 3) {
                                const v1 = solid.verts.items[side.index.items[0]];
                                const v2 = solid.verts.items[side.index.items[1]];
                                const v3 = solid.verts.items[side.index.items[2]];

                                try vr.writeKey("plane");
                                try vr.printValue("\"({d} {d} {d}) ({d} {d} {d}) ({d} {d} {d})\"\n", .{
                                    v1.x(), v1.y(), v1.z(),
                                    v2.x(), v2.y(), v2.z(),
                                    v3.x(), v3.y(), v3.z(),
                                });
                            }
                        }
                        try vr.endObject();
                    }
                }
                try vr.endObject();
            }
            //try vr.beginObject();
            //{
            //    try vr.writeKv("editorversion", @as(i32, 400));
            //    try vr.writeKv("editorbuild", @as(i32, 2987));
            //    try vr.writeKv("mapversion", @as(i32, 5271));
            //    try vr.writeKv("formatversion", @as(i32, 100));
            //    try vr.writeKv("prefab", @as(i32, 0));
            //}
            //try vr.endObject();
        }
    } else {
        std.debug.print("Please specify json file with --json\n", .{});
    }
}
