const std = @import("std");
const thread_pool = @import("thread_pool.zig");
const Context = @import("editor.zig").Context;
const graph = @import("graph");
/// This will destroy() itself onComplete()
pub const SdlFileData = struct {
    pub const Action = enum {
        save_map,
    };
    action: Action,

    job: thread_pool.iJob,
    has_file: enum { waiting, failed, has } = .waiting,

    pool_ptr: *thread_pool.Context,

    name_buffer: std.ArrayList(u8),

    pub fn spawn(alloc: std.mem.Allocator, pool: *thread_pool.Context, kind: Action) !void {
        const self = try alloc.create(@This());
        self.* = .{
            .job = .{ .onComplete = &onComplete, .user_id = 0 },
            .name_buffer = std.ArrayList(u8).init(alloc),
            .pool_ptr = pool,
            .action = kind,
        };

        try pool.spawnJob(workFunc, .{self});
    }

    pub fn destroy(self: *@This()) void {
        const alloc = self.name_buffer.allocator;
        self.name_buffer.deinit();
        alloc.destroy(self);
    }

    pub fn onComplete(vt: *thread_pool.iJob, edit: *Context) void {
        const self: *@This() = @alignCast(@fieldParentPtr("job", vt));
        defer self.destroy();
        if (self.has_file != .has) return;
        switch (self.action) {
            .save_map => {
                edit.setMapName(self.name_buffer.items) catch return;
                if (edit.loaded_map_name) |basename| {
                    edit.saveAndNotify(basename, edit.loaded_map_path orelse "") catch return;
                }
            },
        }
    }

    pub fn workFunc(self: *@This()) void {
        graph.c.SDL_ShowSaveFileDialog(&saveFileCallback2, self, null, null, 0, null);
    }

    export fn saveFileCallback2(opaque_self: ?*anyopaque, filelist: [*c]const [*c]const u8, index: c_int) void {
        if (opaque_self) |ud| {
            const self: *SdlFileData = @alignCast(@ptrCast(ud));
            defer self.pool_ptr.insertCompletedJob(&self.job) catch {};

            if (filelist == 0 or filelist[0] == 0) {
                self.has_file = .failed;
                return;
            }

            const first = std.mem.span(filelist[0]);
            if (first.len == 0) {
                self.has_file = .failed;
                return;
            }

            self.name_buffer.clearRetainingCapacity();
            self.name_buffer.appendSlice(first) catch return;
            self.has_file = .has;
        }
        _ = index;
    }
};
