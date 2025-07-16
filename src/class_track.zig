const std = @import("std");
const ecs = @import("ecs.zig");
const Id = ecs.EcsT.Id;

//Map ent class's to entity id's
pub const Tracker = struct {
    const Self = @This();
    const List = std.ArrayListUnmanaged(Id);
    const MapT = std.StringHashMap(List);

    alloc: std.mem.Allocator,
    map: MapT,

    // All keys into map are not managed, must live forever
    pub fn init(alloc: std.mem.Allocator) Tracker {
        return .{
            .alloc = alloc,
            .map = MapT.init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.map.iterator();

        while (it.next()) |item| {
            item.value_ptr.deinit(self.alloc);
        }
        self.map.deinit();
    }

    pub fn put(self: *Self, class: []const u8, id: Id) !void {
        var res = try self.map.getOrPut(class);
        if (!res.found_existing) {
            res.value_ptr.* = .{};
        }
        for (res.value_ptr.items) |item| {
            if (item == id)
                return;
        }
        try res.value_ptr.append(self.alloc, id);
    }

    pub fn remove(self: *Self, class: []const u8, id: Id) void {
        if (self.map.getPtr(class)) |list| {
            for (list.items, 0..) |item, i| {
                if (item == id) {
                    _ = list.swapRemove(i);
                    return;
                }
            }
        }
    }

    pub fn change(self: *Self, new: []const u8, old: []const u8, id: Id) !void {
        self.remove(old, id);
        try self.put(new, id);
    }

    /// Becomes invalid if any are added or removed
    pub fn get(self: *Self, class: []const u8) []const Id {
        if (self.map.get(class)) |list|
            return list.items;

        return &.{};
    }

    // get the last one, so user can determine order
    // With multiple light_environment, user sets class of the one they want in the box
    pub fn getLast(self: *Self, class: []const u8) ?Id {
        if (self.map.get(class)) |list| {
            if (list.items.len > 0)
                return list.items[list.items.len - 1];
        }
        return null;
    }

    pub fn getFirstDeprecate(self: *Self, class: []const u8) ?Id {
        if (self.map.get(class)) |list| {
            if (list.items.len > 0)
                return list.items[0];
        }
        return null;
    }
};
