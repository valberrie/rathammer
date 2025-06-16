const std = @import("std");
const edit = @import("editor.zig");
const ecs = @import("ecs.zig");
const GroupId = ecs.Groups.GroupId;
const Id = edit.EcsT.Id;
//TODO
//allow tools to force single

const Self = @This();
const Mode = enum {
    one,
    many,
};

/// When .one, selecting an entity will clear the current selection
/// When .many, the new selection is xored with the current one
/// Note that in state .one, more than one entity may be selected if ignore groups is false
mode: Mode = .one,
/// Toggling this only effects the behavior of fn put()
ignore_groups: bool = true,

multi: std.ArrayList(Id),

groups: std.AutoHashMap(GroupId, void),

pub fn init(alloc: std.mem.Allocator) Self {
    return .{
        .multi = std.ArrayList(Id).init(alloc),
        .groups = std.AutoHashMap(GroupId, void).init(alloc),
    };
}

pub fn toggle(self: *Self) void {
    self.mode = switch (self.mode) {
        .one => .many,
        .many => .one,
    };
}

pub fn getLast(self: *Self) ?Id {
    return self.multi.getLastOrNull();
}

// Only return selected if length of selection is 1
pub fn getExclusive(self: *Self) ?Id {
    if (self.multi.items.len == 1)
        return self.multi.items[0];
    return null;
}

/// Returns either the owner of a selected group if that group is exclusive,
/// or it returns the selection when len == 1
pub fn getGroupOwnerExclusive(self: *Self, groups: *ecs.Groups) ?Id {
    blk: {
        if (self.groups.count() != 1) break :blk;
        var it = self.groups.keyIterator();
        const first = it.next() orelse break :blk;
        if (first.* == 0) break :blk;

        return groups.getOwner(first.*);
    }
    return self.getExclusive();
}

pub fn setToSingle(self: *Self, id: Id) !void {
    self.mode = .one;
    self.clear();
    try self.multi.append(id);
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

pub fn getSlice(self: *Self) []const Id {
    return self.multi.items;
}

pub fn clear(self: *Self) void {
    self.multi.clearRetainingCapacity();
    self.groups.clearAndFree();
}

pub fn deinit(self: *Self) void {
    self.multi.deinit();
    self.groups.deinit();
}

pub fn put(self: *Self, id: Id, editor: *edit.Context) !void {
    var do_normal = true;
    if (!self.ignore_groups) {
        if (try editor.ecs.getOpt(id, .group)) |group| {
            switch (self.mode) {
                .one => self.clear(),
                .many => {},
            }
            const to_remove = self.multiContains(id);
            if (to_remove) _ = self.groups.remove(group.id) else try self.groups.put(group.id, {});
            var it = editor.ecs.iterator(.group);
            while (it.next()) |ent| {
                if (ent.id == group.id and ent.id != 0) {
                    if (to_remove) self.tryRemoveMulti(it.i) else try self.tryAddMulti(it.i);
                }
            }
            do_normal = false;
        }
    }
    if (do_normal) {
        const group = if (try editor.ecs.getOpt(id, .group)) |g| g.id else 0;
        switch (self.mode) {
            .one => {
                try self.multi.resize(1);
                self.multi.items[0] = id;
                self.groups.clearRetainingCapacity();
                try self.groups.put(group, {});
            },
            .many => {
                if (std.mem.indexOfScalar(Id, self.multi.items, id)) |index| {
                    _ = self.multi.orderedRemove(index);
                    _ = self.groups.remove(group);
                } else {
                    try self.multi.append(id);
                    try self.groups.put(group, {});
                }
            },
        }
    }
}
