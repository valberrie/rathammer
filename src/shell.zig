const std = @import("std");

const Console = @import("windows/console.zig");
const Editor = @import("editor.zig").Context;

const Commands = enum {
    count_ents,
    help,
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
        self.execErr(command, output) catch return;
    }

    pub fn execErr(self: *@This(), command: []const u8, output: *std.ArrayList(u8)) !void {
        const wr = output.writer();
        if (std.meta.stringToEnum(Commands, command)) |com| {
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
            }
        } else {
            try wr.print("Unknown command: '{s}' Type help for list of commands", .{command});
        }
    }
};
