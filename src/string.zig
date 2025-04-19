const std = @import("std");
pub const StringStorage = struct {
    const Self = @This();

    set: std.StringHashMap(void),
    arena: std.heap.ArenaAllocator,
    alloc: ?std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Self {
        return .{
            .arena = std.heap.ArenaAllocator.init(alloc),
            .set = std.StringHashMap(void).init(alloc),
            .alloc = null,
        };
    }

    pub fn store(self: *Self, string: []const u8) ![]const u8 {
        if (self.set.getKey(string)) |str| return str;

        if (self.alloc == null)
            self.alloc = self.arena.allocator();

        const str = try self.alloc.?.dupe(u8, string);
        try self.set.put(str, {});
        return str;
    }

    pub fn deinit(self: *Self) void {
        self.set.deinit();
        self.arena.deinit();
    }
};
