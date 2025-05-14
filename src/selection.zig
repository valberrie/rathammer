const std = @import("std");
const edit = @import("editor.zig");
const Id = edit.EcsT.Id;

const Self = @This();
const Mode = enum {
    one,
    many,
};

single_id: ?Id = null,
multi: std.ArrayList(Id),
mode: Mode = .one,

pub fn init(alloc: std.mem.Allocator) Self {
    return .{
        .multi = std.ArrayList(Id).init(alloc),
    };
}

pub fn toggle(self: *Self) void {
    self.mode = switch (self.mode) {
        .one => .many,
        .many => .one,
    };
}

pub fn getLast(self: *Self) ?Id {
    return switch (self.mode) {
        .one => self.single_id,
        .many => self.multi.getLastOrNull(),
    };
}

pub fn getSlice(self: *Self) []const Id {
    switch (self.mode) {
        .one => {
            if (self.single_id) |id|
                return &.{id};
        },
        .many => return self.multi.items,
    }
    return &.{};
}

pub fn deinit(self: *Self) void {
    self.multi.deinit();
}

pub fn append(self: *Self, id: Id) !void {
    try self.multi.append(id);
}
