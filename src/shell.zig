const std = @import("std");

const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const Console = @import("windows/console.zig");
const Editor = @import("editor.zig").Context;
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
