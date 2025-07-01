const std = @import("std");
const graph = @import("graph");
const ecs = @import("ecs.zig");
const vdf_serial = @import("vdf_serial.zig");
const vmf = @import("vmf.zig");
const GroupId = ecs.Groups.GroupId;

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

pub fn jsontovmf(alloc: std.mem.Allocator, ecs_p: *ecs.EcsT, skyname: []const u8, vpkmapper: anytype, groups: *ecs.Groups) !void {
    const outfile = try std.fs.cwd().createFile("dump.vmf", .{});
    defer outfile.close();
    const wr = outfile.writer();
    var bwr = std.io.bufferedWriter(wr);
    defer bwr.flush() catch {};
    const bb = bwr.writer();
    var vr = vdf_serial.WriteVdf(@TypeOf(bb)).init(alloc, bb);

    {
        try vr.writeComment("This vmf was created by RatHammer.\n", .{});
        try vr.writeComment("It may not be compatible with official Valve tools.\n", .{});
        try vr.writeComment("See: https://github.com/nmalthouse/rathammer\n", .{});
        try vr.writeComment("rathammer_version  0.0.1\n", .{});
        try vr.writeKv("versioninfo", vmf.VersionInfo{
            .editorversion = 400,
            .editorbuild = 2987,
            .mapversion = 1,
            .formatversion = 100,
            .prefab = 0,
        });
        try vr.writeKey("world");
        try vr.beginObject();
        try vr.writeInnerStruct(.{
            .id = 0,
            .mapversion = 1,
            .classname = @as([]const u8, "worldspawn"),
            .skyname = skyname,
            .sound = 0,
            .MaxRange = 20000,
            .startdark = 0,
            .gametitle = 0,
            .newunit = 0,
            .defaultteam = 0,
            .fogenable = 1,
            .fogblend = 0,
            .fogcolor = @as([]const u8, "220 221 196"),
            .fogcolor2 = @as([]const u8, "255 255 255"),
            .fogdir = @as([]const u8, "1 0 0"),
            .fogstart = 2048,
            .fogend = 7900,
            .light = 0,
        });
        var side_id_start: usize = 0;

        var group_ent_map = std.AutoHashMap(GroupId, std.ArrayList(ecs.EcsT.Id)).init(alloc);

        var solids = ecs_p.iterator(.solid);
        while (solids.next()) |solid| {
            if (try ecs_p.getOpt(solids.i, .group)) |g| {
                if (g.id != 0) {
                    const res = try group_ent_map.getOrPut(g.id);
                    if (!res.found_existing) {
                        res.value_ptr.* = std.ArrayList(ecs.EcsT.Id).init(alloc);
                    }
                    try res.value_ptr.append(solids.i);
                    continue;
                }
            }

            //if (solid._parent_entity != null) continue;

            try writeSolid(&vr, solids.i, solid, &side_id_start, vpkmapper);
        }
        try vr.endObject(); //world

        var ents = ecs_p.iterator(.entity);
        while (ents.next()) |ent| {
            try vr.writeKey("entity");
            try vr.beginObject();
            {
                try vr.writeKv("id", ents.i);
                try vr.writeKey("origin");
                try vr.printValue("\"{d} {d} {d}\"\n", .{ ent.origin.x(), ent.origin.y(), ent.origin.z() });
                try vr.writeKey("angles");
                try vr.printValue("\"{d} {d} {d}\"\n", .{ ent.angle.x(), ent.angle.y(), ent.angle.z() });

                try vr.writeKv("classname", ent.class);
                var model_written = false;

                if (try ecs_p.getOptPtr(ents.i, .key_values)) |kvs| {
                    var it = kvs.map.iterator();
                    while (it.next()) |kv| {
                        if (std.mem.eql(u8, "model", kv.key_ptr.*))
                            model_written = true;
                        switch (kv.value_ptr.*) {
                            .string => |str| try vr.writeKv(kv.key_ptr.*, str.items),
                            .floats => |c| {
                                try vr.writeKey(kv.key_ptr.*);
                                try vr.beginValue();
                                for (c.d[0..c.count]) |cc|
                                    try vr.printInnerValue("{d} ", .{cc});
                                try vr.endValue();
                            },
                        }
                    }
                }

                if (try ecs_p.getOptPtr(ents.i, .connections)) |cons| {
                    try vr.writeKey("connections");
                    try vr.beginObject();
                    {
                        //Format for vmf is
                        //listen_event   "target,input,value,delay,fire_count"
                        const fmt = "\"{s},{s},{s},{d},{d}\"\n";
                        for (cons.list.items) |con| {
                            // empty kvs cause a segfault in vbsp lol
                            if (con.listen_event.len == 0) continue;
                            try vr.writeKey(con.listen_event);
                            try vr.printValue(fmt, .{
                                con.target.items,
                                con.input,
                                con.value.items,
                                con.delay,
                                con.fire_count,
                            });
                        }
                    }
                    try vr.endObject();
                }

                if (ent._model_id) |mid|
                    try vr.writeKv("model", vpkmapper.getResource(mid) orelse "");
            }

            if (groups.getGroup(ents.i)) |group| {
                if (group_ent_map.get(group)) |list| {
                    for (list.items) |solid_i| {
                        const solid = try ecs_p.getOptPtr(solid_i, .solid) orelse continue;
                        try writeSolid(&vr, solid_i, solid, &side_id_start, vpkmapper);
                    }
                }
            }
            try vr.endObject();
        }
    }
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

        const infile = std.fs.cwd().openFile(mapname, .{}) catch |err| {
            std.debug.print("Unable to open file: {s}, {!}\n", .{ mapname, err });
            std.process.exit(1);
        };
        defer infile.close();
        const slice = try infile.reader().readAllAlloc(alloc, std.math.maxInt(usize));

        var strings = StringStorage.init(alloc);
        var ecs_p = try ecs.EcsT.init(alloc);

        var vpkmapper = json_map.VpkMapper.init(alloc);
        var groups = ecs.Groups.init(alloc);

        const jsonctx = json_map.InitFromJsonCtx{ .alloc = alloc, .str_store = &strings };
        const parsed = try json_map.loadJson(jsonctx, slice, &loadctx, &ecs_p, &vpkmapper, &groups);

        {
            try vr.writeComment("This vmf was created by RatHammer.\n", .{});
            try vr.writeComment("It may not be compatible with official Valve tools.\n", .{});
            try vr.writeComment("See: https://github.com/nmalthouse/rathammer\n", .{});
            try vr.writeComment("rathammer_version  0.0.1\n", .{});
            try vr.writeKv("versioninfo", vmf.VersionInfo{
                .editorversion = 400,
                .editorbuild = 2987,
                .mapversion = 1,
                .formatversion = 100,
                .prefab = 0,
            });
            try vr.writeKey("world");
            try vr.beginObject();
            try vr.writeInnerStruct(.{
                .id = 0,
                .mapversion = 1,
                .classname = @as([]const u8, "worldspawn"),
                .skyname = parsed.value.sky_name,
                .sound = 0,
                .MaxRange = 20000,
                .startdark = 0,
                .gametitle = 0,
                .newunit = 0,
                .defaultteam = 0,
                .fogenable = 1,
                .fogblend = 0,
                .fogcolor = @as([]const u8, "220 221 196"),
                .fogcolor2 = @as([]const u8, "255 255 255"),
                .fogdir = @as([]const u8, "1 0 0"),
                .fogstart = 2048,
                .fogend = 7900,
                .light = 0,
            });
            var side_id_start: usize = 0;

            var group_ent_map = std.AutoHashMap(GroupId, std.ArrayList(ecs.EcsT.Id)).init(alloc);

            var solids = ecs_p.iterator(.solid);
            while (solids.next()) |solid| {
                if (try ecs_p.getOpt(solids.i, .group)) |g| {
                    if (g.id != 0) {
                        const res = try group_ent_map.getOrPut(g.id);
                        if (!res.found_existing) {
                            res.value_ptr.* = std.ArrayList(ecs.EcsT.Id).init(alloc);
                        }
                        try res.value_ptr.append(solids.i);
                        continue;
                    }
                }

                //if (solid._parent_entity != null) continue;

                try writeSolid(&vr, solids.i, solid, &side_id_start, &vpkmapper);
            }
            try vr.endObject(); //world

            var ents = ecs_p.iterator(.entity);
            while (ents.next()) |ent| {
                try vr.writeKey("entity");
                try vr.beginObject();
                {
                    try vr.writeKv("id", ents.i);
                    try vr.writeKey("origin");
                    try vr.printValue("\"{d} {d} {d}\"\n", .{ ent.origin.x(), ent.origin.y(), ent.origin.z() });
                    try vr.writeKey("angles");
                    try vr.printValue("\"{d} {d} {d}\"\n", .{ ent.angle.x(), ent.angle.y(), ent.angle.z() });

                    try vr.writeKv("classname", ent.class);
                    var model_written = false;

                    if (try ecs_p.getOptPtr(ents.i, .key_values)) |kvs| {
                        var it = kvs.map.iterator();
                        while (it.next()) |kv| {
                            if (std.mem.eql(u8, "model", kv.key_ptr.*))
                                model_written = true;
                            switch (kv.value_ptr.*) {
                                .string => |str| try vr.writeKv(kv.key_ptr.*, str.items),
                                .floats => |c| {
                                    try vr.writeKey(kv.key_ptr.*);
                                    try vr.beginValue();
                                    for (c.d[0..c.count]) |cc|
                                        try vr.printInnerValue("{d} ", .{cc});
                                    try vr.endValue();
                                },
                            }
                        }
                    }

                    if (try ecs_p.getOptPtr(ents.i, .connections)) |cons| {
                        try vr.writeKey("connections");
                        try vr.beginObject();
                        {
                            //Format for vmf is
                            //listen_event   "target,input,value,delay,fire_count"
                            const fmt = "\"{s},{s},{s},{d},{d}\"\n";
                            for (cons.list.items) |con| {
                                try vr.writeKey(con.listen_event);
                                try vr.printValue(fmt, .{
                                    con.target.items,
                                    con.input,
                                    con.value.items,
                                    con.delay,
                                    con.fire_count,
                                });
                            }
                        }
                        try vr.endObject();
                    }

                    if (ent._model_id) |mid|
                        try vr.writeKv("model", vpkmapper.getResource(mid) orelse "");
                }

                if (groups.getGroup(ents.i)) |group| {
                    if (group_ent_map.get(group)) |list| {
                        for (list.items) |solid_i| {
                            const solid = try ecs_p.getOptPtr(solid_i, .solid) orelse continue;
                            try writeSolid(&vr, solid_i, solid, &side_id_start, &vpkmapper);
                        }
                    }
                }
                try vr.endObject();
            }
        }
    } else {
        std.debug.print("Please specify json file with --json\n", .{});
    }
}

fn ensurePlanar(index: []const u32) ?[3]u32 {
    if (index.len < 3) return null;
    var last = index[index.len - 1];
    var good: [3]u32 = undefined;
    var count: usize = 0;
    for (index) |ind| {
        if (ind == last)
            continue;
        good[count] = ind;
        count += 1;
        last = ind;
        if (count >= 3) {
            return good;
        }
    }
    return null;
}

fn writeSolid(vr: anytype, ent_id: ecs.EcsT.Id, solid: *ecs.Solid, side_id_start: *usize, vpkmapper: anytype) !void {
    try vr.writeKey("solid");
    try vr.beginObject();
    {
        try vr.writeKv("id", ent_id);
        for (solid.sides.items) |side| {
            if (side.index.items.len < 3) continue;
            try vr.writeKey("side");
            try vr.beginObject();
            {
                const id = side_id_start.*;
                side_id_start.* += 1;
                try vr.writeKv("id", id);
                if (ensurePlanar(side.index.items)) |inds| {
                    const v1 = solid.verts.items[inds[0]];
                    const v2 = solid.verts.items[inds[1]];
                    const v3 = solid.verts.items[inds[2]];

                    try vr.writeKey("plane");
                    try vr.printValue("\"({d} {d} {d}) ({d} {d} {d}) ({d} {d} {d})\"\n", .{
                        v1.x(), v1.y(), v1.z(),
                        v2.x(), v2.y(), v2.z(),
                        v3.x(), v3.y(), v3.z(),
                    });
                }
                try vr.writeKv("material", sanatizeMaterialName(vpkmapper.getResource(side.tex_id) orelse ""));
                try vr.writeKey("uaxis");
                const uvfmt = "\"[{d} {d} {d} {d}] {d}\"\n";
                try vr.printValue(uvfmt, .{ side.u.axis.x(), side.u.axis.y(), side.u.axis.z(), side.u.trans, side.u.scale });
                try vr.writeKey("vaxis");
                try vr.printValue(uvfmt, .{ side.v.axis.x(), side.v.axis.y(), side.v.axis.z(), side.v.trans, side.v.scale });
                try vr.writeKv("rotation", @as(i32, 0));
                try vr.writeKv("lightmapscale", side.lightmapscale);
                try vr.writeKv("smoothing_groups", side.smoothing_groups);
            }
            try vr.endObject();
        }
    }
    try vr.endObject();
}
