const std = @import("std");

const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const Console = @import("windows/console.zig");
const edit = @import("editor.zig");
const Editor = edit.Context;
const pointfile = @import("pointfile.zig");
//TODO
//add commands for
//rebuild all meshes
//write a save
//kill the vbsp

const Commands = enum {
    count_ents,
    help,
    select_id,
    fov,
    dump_selected,
    snap_selected,
    tp,
    pointfile,
    unload_pointfile,
    unload_portalfile,
    portalfile,
    stats,
    wireframe,
};

pub const CommandCtx = struct {
    cb_vt: Console.ConsoleCb,

    ed: *Editor,

    pub fn create(alloc: std.mem.Allocator, editor: *Editor) !*@This() {
        const self = try alloc.create(@This());

        self.* = .{
            .cb_vt = .{ .exec = &exec_command_cb },
            .ed = editor,
        };

        return self;
    }

    pub fn destroy(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }

    pub fn exec_command_cb(vt: *Console.ConsoleCb, command: []const u8, output: *std.ArrayList(u8)) void {
        const self: *@This() = @alignCast(@fieldParentPtr("cb_vt", vt));
        self.execErr(command, output) catch |err| {
            output.writer().print("Fatal: command exec failed with {!}", .{err}) catch return;
        };
    }

    pub fn execErr(self: *@This(), command: []const u8, output: *std.ArrayList(u8)) !void {
        const wr = output.writer();
        var args = std.mem.tokenizeScalar(u8, command, ' ');
        const com_name = args.next() orelse return;
        if (std.meta.stringToEnum(Commands, com_name)) |com| {
            switch (com) {
                .count_ents => {
                    try wr.print("Number of entites: {d}", .{self.ed.ecs.getEntLength()});
                },
                .help => {
                    try wr.print("commands: \n", .{});
                    const field = @typeInfo(Commands).@"enum".fields;
                    inline for (field) |f| {
                        try wr.print("{s}\n", .{f.name});
                    }
                },
                .fov => {
                    const fov: f32 = std.fmt.parseFloat(f32, args.next() orelse "90") catch 90;
                    self.ed.draw_state.cam3d.fov = fov;
                    try wr.print("Set fov to {d}", .{fov});
                },
                .select_id => {
                    while (args.next()) |item| {
                        if (std.fmt.parseInt(u32, item, 10)) |id| {
                            if (!self.ed.ecs.isEntity(id)) {
                                try wr.print("\tNot an entity: {d}\n", .{id});
                            } else {
                                self.ed.selection.put(id, self.ed) catch |err| {
                                    try wr.print("Selection failed {!}\n", .{err});
                                };
                            }
                        } else |_| {
                            try wr.print("\tinvalid number: {s}\n", .{item});
                        }
                    }
                },
                .wireframe => {
                    self.ed.draw_state.tog.wireframe = !self.ed.draw_state.tog.wireframe;
                },
                .stats => {
                    try wr.print("Num meshmaps/texture: {d}\n", .{self.ed.meshmap.count()});
                    try wr.print("Num models: {d}\n", .{self.ed.models.count()});
                    try wr.print("comp solid: {d} \n", .{self.ed.ecs.data.solid.dense.items.len});
                    try wr.print("comp ent  : {d} \n", .{self.ed.ecs.data.entity.dense.items.len});
                    try wr.print("comp kvs  : {d} \n", .{self.ed.ecs.data.key_values.dense.items.len});
                    try wr.print("comp AABB : {d} \n", .{self.ed.ecs.data.bounding_box.dense.items.len});
                    try wr.print("comp deleted : {d} \n", .{self.ed.ecs.data.deleted.dense.items.len});
                },
                .dump_selected => {
                    const selected_slice = self.ed.selection.getSlice();
                    for (selected_slice) |id| {
                        try wr.print("id: {d} \n", .{id});
                        if (try self.ed.ecs.getOptPtr(id, .solid)) |solid| {
                            try wr.print("Solid\n", .{});
                            for (solid.verts.items, 0..) |vert, i| {
                                try wr.print("  v {d} [{d:.1} {d:.1} {d:.1}]\n", .{ i, vert.x(), vert.y(), vert.z() });
                            }
                            for (solid.sides.items, 0..) |side, i| {
                                try wr.print("  side {d}", .{i});
                                for (side.index.items) |ind|
                                    try wr.print(" {d}", .{ind});
                                try wr.print("\n", .{});
                                const norm = side.normal(solid);
                                try wr.print("  Normal: [{d} {d} {d}]\n", .{ norm.x(), norm.y(), norm.z() });
                            }
                        }
                    }
                },
                .snap_selected => {
                    const selected_slice = self.ed.selection.getSlice();
                    for (selected_slice) |id| {
                        if (try self.ed.ecs.getOptPtr(id, .solid)) |solid|
                            try solid.roundAllVerts(id, self.ed);
                    }
                },
                .tp => {
                    if (parseVec(&args)) |vec| {
                        try wr.print("Teleporting to {d} {d} {d}\n", .{ vec.x(), vec.y(), vec.z() });
                        self.ed.draw_state.cam3d.pos = vec;
                    } else {
                        try wr.print("Invalid teleport command: '{s}'\n", .{command});
                    }
                },
                .portalfile => {
                    const pf = &self.ed.draw_state.portalfile;
                    if (pf.*) |pf1|
                        pf1.verts.deinit();
                    pf.* = null;

                    const path = if (args.next()) |p| p else try self.ed.printScratch("{s}/{s}", .{ edit.TMP_DIR, "dump.prt" });

                    pf.* = try pointfile.loadPortalfile(self.ed.alloc, std.fs.cwd(), path);
                },
                .pointfile => {
                    if (self.ed.draw_state.pointfile) |pf|
                        pf.verts.deinit();
                    self.ed.draw_state.pointfile = null;

                    const path = if (args.next()) |p| p else try self.ed.printScratch("{s}/{s}", .{ edit.TMP_DIR, "dump.lin" });

                    self.ed.draw_state.pointfile = try pointfile.loadPointfile(self.ed.alloc, std.fs.cwd(), path);
                },
                .unload_pointfile => {
                    if (self.ed.draw_state.pointfile) |pf|
                        pf.verts.deinit();
                    self.ed.draw_state.pointfile = null;
                },
                .unload_portalfile => {
                    if (self.ed.draw_state.portalfile) |pf|
                        pf.verts.deinit();
                    self.ed.draw_state.portalfile = null;
                },
            }
        } else {
            try wr.print("Unknown command: '{s}' Type help for list of commands", .{command});
        }
    }
};

fn parseVec(it: anytype) ?Vec3 {
    return Vec3.new(
        std.fmt.parseFloat(f32, it.next() orelse return null) catch return null,
        std.fmt.parseFloat(f32, it.next() orelse return null) catch return null,
        std.fmt.parseFloat(f32, it.next() orelse return null) catch return null,
    );
}
