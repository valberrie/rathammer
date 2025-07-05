const std = @import("std");
const thread_pool = @import("thread_pool.zig");
const Context = @import("editor.zig").Context;
const graph = @import("graph");
/// This will destroy() itself onComplete()
pub const SdlFileData = struct {
    pub const Action = enum {
        save_map,
        pick_map,
    };
    const map_filters = [_]graph.c.SDL_DialogFileFilter{
        .{ .name = "maps", .pattern = "json;vmf" },
        .{ .name = "vmf maps", .pattern = "vmf" },
        .{ .name = "RatHammer json maps", .pattern = "json" },
        .{ .name = "All files", .pattern = "*" },
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
            .pick_map => {
                edit.loadctx.draw_splash = true; // Renable it
                edit.paused = false;
                edit.loadctx.gtimer.reset();
                edit.loadMap(std.fs.cwd(), self.name_buffer.items, edit.loadctx) catch |err| {
                    std.debug.print("load failed because {!}\n", .{err});
                };
            },
        }
    }

    pub fn workFunc(self: *@This()) void {
        switch (self.action) {
            .save_map => graph.c.SDL_ShowSaveFileDialog(&saveFileCallback2, self, null, null, 0, null),
            .pick_map => graph.c.SDL_ShowOpenFileDialog(&saveFileCallback2, self, null, &map_filters, map_filters.len, null, false),
        }
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

//TODO, make this a singleton, if user tries spawning a second, kill the first and replace
//This will a require mapbuild to have a mutex and callback in its 'runCommand' to kill it
const map_builder = @import("map_builder.zig");
pub const MapCompile = struct {
    job: thread_pool.iJob,
    pool_ptr: *thread_pool.Context,

    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    build_time: std.time.Timer,

    status: enum { failed, built, nothing } = .nothing,

    pub fn spawn(alloc: std.mem.Allocator, pool: *thread_pool.Context, paths: map_builder.Paths) !void {
        const self = try alloc.create(@This());
        self.* = .{
            .job = .{
                .user_id = 0,
                .onComplete = &onComplete,
            },
            .build_time = try std.time.Timer.start(),
            .arena = std.heap.ArenaAllocator.init(alloc),
            .alloc = alloc,
            .pool_ptr = pool,
        };
        const aa = self.arena.allocator();
        try pool.spawnJob(workFunc, .{ self, map_builder.Paths{
            .gamename = try aa.dupe(u8, paths.gamename),
            .gamedir_pre = try aa.dupe(u8, paths.gamedir_pre),
            .tmpdir = try aa.dupe(u8, paths.tmpdir),
            .outputdir = try aa.dupe(u8, paths.outputdir),
            .vmf = try aa.dupe(u8, paths.vmf),
        } });
    }

    pub fn destroy(self: *@This()) void {
        self.arena.deinit();
        const alloc = self.alloc;
        alloc.destroy(self);
    }

    pub fn onComplete(vt: *thread_pool.iJob, edit: *Context) void {
        const self: *@This() = @alignCast(@fieldParentPtr("job", vt));
        defer self.destroy();
        const t = self.build_time.read();
        switch (self.status) {
            .failed => edit.notify("Error building Map", .{}, 0xff0000ff) catch {},
            .built => edit.notify("built map in {d} s", .{t / std.time.ns_per_s}, 0x00ff00ff) catch {},
            .nothing => edit.notify("Something bad happend when building the map", .{}, 0xffff_00_ff) catch {},
        }
    }

    pub fn workFunc(self: *@This(), args: map_builder.Paths) void {
        defer self.pool_ptr.insertCompletedJob(&self.job) catch {};
        if (map_builder.buildmap(self.arena.allocator(), args)) {
            self.status = .built;
        } else |_| {
            self.status = .failed;
        }
    }
};
