const std = @import("std");
const edit = @import("editor.zig");
const Id = edit.EcsT.Id;
//TODO
//allow tools to force single

const Self = @This();
const Mode = enum {
    one,
    many,
};

single_id: ?Id = null,
multi: std.ArrayList(Id),
mode: Mode = .one,
ignore_groups: bool = true,

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

pub fn setToSingle(self: *Self, id: Id) void {
    self.mode = .one;
    self.single_id = id;
}

pub fn multiContains(self: *Self, id: Id) bool {
    for (self.multi.items) |item| {
        if (item == id)
            return true;
    }
    return false;
}

pub fn tryRemoveMulti(self: *Self, id: Id) void {
    if (std.mem.indexOfScalar(Id, self.multi.items, id)) |index|
        _ = self.multi.orderedRemove(index);
}

pub fn tryAddMulti(self: *Self, id: Id) !void {
    if (std.mem.indexOfScalar(Id, self.multi.items, id)) |_| {
        return;
    }
    try self.multi.append(id);
}

threadlocal var single_slice: [1]Id = undefined;
pub fn getSlice(self: *Self) []const Id {
    switch (self.mode) {
        .one => {
            if (self.single_id) |id| {
                single_slice[0] = id;
                return &single_slice;
            }
        },
        .many => return self.multi.items,
    }
    return &.{};
}

pub fn clear(self: *Self) void {
    switch (self.mode) {
        .one => self.single_id = null,
        .many => self.multi.clearRetainingCapacity(),
    }
}

pub fn deinit(self: *Self) void {
    self.multi.deinit();
}

pub fn put(self: *Self, id: Id, editor: *edit.Context) !void {
    if (!self.ignore_groups) {
        if (try editor.ecs.getOpt(id, .group)) |group| {
            self.mode = .many;
            const remove = self.multiContains(id);
            var it = editor.ecs.iterator(.group);
            while (it.next()) |ent| {
                if (ent.id == group.id and ent.id != 0) {
                    if (remove) {
                        self.tryRemoveMulti(it.i);
                    } else {
                        try self.tryAddMulti(it.i);
                    }
                }
            }
            return;
        }
    }
    {
        switch (self.mode) {
            .one => {
                self.single_id = id;
            },
            .many => {
                if (std.mem.indexOfScalar(Id, self.multi.items, id)) |index| {
                    _ = self.multi.orderedRemove(index);
                } else {
                    try self.multi.append(id);
                }
            },
        }
    }
}
