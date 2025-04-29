const std = @import("std");
const Mutex = std.Thread.Mutex;
const vtf = @import("vtf.zig");
const vpk = @import("vpk.zig");
const vdf = @import("vdf.zig");

//TODO allow custom number of worker threads

pub const ThreadState = struct {
    vtf_file_buffer: std.ArrayList(u8),

    pub fn init(alloc: std.mem.Allocator) @This() {
        return .{ .vtf_file_buffer = std.ArrayList(u8).init(alloc) };
    }

    pub fn deinit(self: *@This()) void {
        self.vtf_file_buffer.deinit();
    }
};

pub const CompletedVtfItem = struct { data: vtf.VtfBuf, vpk_res_id: vpk.VpkResId };
const log = std.log.scoped(.vtf);

const ThreadId = std.Thread.Id;
pub const Context = struct {
    alloc: std.mem.Allocator,

    map: std.AutoHashMap(std.Thread.Id, *ThreadState),
    map_mutex: Mutex = .{},

    completed: std.ArrayList(CompletedVtfItem),
    completed_mutex: Mutex = .{},

    pool: *std.Thread.Pool,

    pub fn init(alloc: std.mem.Allocator) !@This() {
        const pool = try alloc.create(std.Thread.Pool);
        try pool.init(.{ .allocator = alloc, .n_jobs = 3 });
        return .{
            .map = std.AutoHashMap(std.Thread.Id, *ThreadState).init(alloc),
            .alloc = alloc,
            .completed = std.ArrayList(CompletedVtfItem).init(alloc),
            .pool = pool,
        };
    }

    pub fn getState(self: *@This()) !*ThreadState {
        self.map_mutex.lock();
        defer self.map_mutex.unlock();
        const thread_id = std.Thread.getCurrentId();
        if (self.map.get(thread_id)) |th| return th;

        const new = try self.alloc.create(ThreadState);
        new.* = ThreadState.init(self.alloc);
        try self.map.put(thread_id, new);
        return new;
    }

    pub fn insertCompleted(self: *@This(), item: CompletedVtfItem) !void {
        self.completed_mutex.lock();
        defer self.completed_mutex.unlock();
        try self.completed.append(item);
    }

    pub fn deinit(self: *@This()) void {
        self.pool.deinit();
        self.map_mutex.lock();
        self.completed_mutex.lock();
        var it = self.map.iterator();
        while (it.next()) |item| {
            item.value_ptr.*.deinit();
            self.alloc.destroy(item.value_ptr.*);
        }
        for (self.completed.items) |*item|
            self.alloc.free(item.data.buffer);
        self.completed.deinit();
        self.map.deinit();

        self.alloc.destroy(self.pool);
    }

    pub fn loadTexture(self: *@This(), material: []const u8, res_id: vpk.VpkResId, vpkctx: *vpk.Context) !void {
        try self.pool.spawn(workFunc, .{ self, material, res_id, vpkctx });
    }

    pub fn workFunc(self: *@This(), material: []const u8, vpk_res_id: vpk.VpkResId, vpkctx: *vpk.Context) void {
        workFuncErr(self, material, vpk_res_id, vpkctx) catch return;
    }

    pub fn workFuncErr(self: *@This(), material: []const u8, vpk_res_id: vpk.VpkResId, vpkctx: *vpk.Context) !void {
        const thread_state = try self.getState();
        const err = in: {
            //const slash = std.mem.lastIndexOfScalar(u8, sl, '/') orelse break :in error.noSlash;
            if (try vpkctx.getFileFromRes(vpk_res_id, &thread_state.vtf_file_buffer)) |tt| {
                var obj = try vdf.parse(self.alloc, tt);
                defer obj.deinit();
                //All vmt are a single root object with a shader name as key
                if (obj.value.list.items.len > 0) {
                    const fallback_keys = [_][]const u8{
                        "$basetexture", "%tooltexture",
                    };
                    const ob = obj.value.list.items[0].val;
                    switch (ob) {
                        .obj => |o| {
                            for (fallback_keys) |fbkey| {
                                if (o.getFirst(fbkey)) |base| {
                                    if (base == .literal) {
                                        break :in vtf.loadBuffer(
                                            (vpkctx.getFileTempFmtBuf(
                                                "vtf",
                                                "materials/{s}",
                                                .{base.literal},
                                                &thread_state.vtf_file_buffer,
                                            ) catch |err| break :in err) orelse {
                                                break :in error.notfound;
                                            },
                                            self.alloc,
                                        ) catch |err| break :in err;
                                    }
                                }
                            }
                        },
                        else => {},
                    }
                }
            }
            break :in error.missingTexture;
        };
        const unwrapped = err catch |e| {
            log.warn("{} for {s}", .{ e, material });
            return; //TODO notify
        };
        try self.insertCompleted(.{
            .data = unwrapped,
            .vpk_res_id = vpk_res_id,
        });
    }
};

//threadpool object
