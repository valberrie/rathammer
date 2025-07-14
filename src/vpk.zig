const std = @import("std");
const profile = @import("profile.zig");
const VPK_FILE_SIG: u32 = 0x55aa1234;
const StringStorage = @import("string.zig").StringStorage;

pub threadlocal var timer = profile.BasicProfiler.init();
threadlocal var error_msg_buffer: [1024]u8 = undefined;

const config = @import("config");
const vpk_dump_file_t = if (config.dump_vpk) std.fs.File else void;

//TODO support mounting of loose files aswell.
//Modify the way getResourceId works so it never returns null
//if res_id is not found in self.entries, we instead search through self.loose_dirs
//for each loose_dir:
//  fs.tryOpen(path)
//
//Rather than do a search, at mounting, walk the directories and add all files, if this takes a long time,
//create a cache file consisting of:
//  mtimes of all directories, recursive
//  vpk index data
//
//Add a flag to force rebuild

pub const VpkResId = u64;

pub const IdOrName = union(enum) {
    id: VpkResId,
    name: []const u8,
};

pub const IdAndName = struct {
    id: VpkResId,
    name: []const u8,
};
///16 bits: extension_index
///16 bits: path_index
///32 bits: entry_index
pub fn encodeResourceId(extension_index: u64, path_index: u64, entry_index: u64) VpkResId {
    std.debug.assert(extension_index < 0xffff);
    std.debug.assert(path_index < 0xffff);
    std.debug.assert(entry_index < 0xff_ff_ff_ff);
    //Assert all are below accepted values
    return extension_index << 48 | path_index << 32 | entry_index;
}

pub fn decodeResourceId(id: VpkResId) struct {
    ext: u64,
    path: u64,
    name: u64,
} {
    return .{
        .ext = id >> 48,
        .path = id << 16 >> (32 + 16),
        .name = id << 32 >> 32,
    };
}

/// Given one or more vpk dir files, allows you to request file contents
pub const Context = struct {
    const log = std.log.scoped(.vpk);
    const Self = @This();
    const StrCtx = std.hash_map.StringContext;
    pub const Names = struct {
        ext: []const u8,
        path: []const u8,
        name: []const u8,
    };

    /// Map a resource string to numeric id
    const IdMap = struct {
        /// All strings are stored by parent vpk.Context.arena
        map: std.StringHashMap(u32),
        lut: std.ArrayList([]const u8), //Strings owned by arena
        counter: u32 = 0,
        mutex: std.Thread.Mutex = .{},

        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{
                .map = std.StringHashMap(u32).init(alloc),
                .lut = std.ArrayList([]const u8).init(alloc),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.mutex.lock();
            self.map.deinit();
            self.lut.deinit();
        }

        pub fn getName(self: *@This(), id: u32) ?[]const u8 {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (id == 0) return null;
            if (id - 1 >= self.lut.items.len) return null;
            return self.lut.items[id - 1];
        }

        pub fn getPut(self: *@This(), res_name: []const u8) !u32 {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.map.get(res_name)) |entry| return entry;

            self.counter += 1;
            const new_id = self.counter;
            try self.lut.append(res_name);
            try self.map.put(res_name, new_id);
            return new_id;
        }

        pub fn get(self: *@This(), res_name: []const u8) ?u32 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.map.get(res_name);
        }
    };
    const IdEntryMap = std.AutoHashMap(VpkResId, Entry);

    const ExtensionMap = std.StringHashMap(PathMap);
    const PathMap = std.StringHashMap(EntryMap);
    const EntryMap = std.StringHashMap(Entry);

    const Dir = struct {
        prefix: []const u8,

        fds: std.AutoHashMap(u16, std.fs.File),
        root: std.fs.Dir,

        pub fn init(alloc: std.mem.Allocator, prefix: []const u8, root: std.fs.Dir) @This() {
            return .{
                .fds = std.AutoHashMap(u16, std.fs.File).init(alloc),
                .prefix = prefix,
                .root = root,
            };
        }

        pub fn deinit(self: *@This()) void {
            var it = self.fds.valueIterator();
            while (it.next()) |f|
                f.close();
            self.fds.deinit();
        }
    };

    const Entry = struct {
        dir_index: u16,
        archive_index: u16,
        offset: u32,
        length: u32,
        res_id: VpkResId,

        path: []const u8,
        name: []const u8,
    };

    /// These map the strings found in vpk to a numeric id.
    /// Ids are not unique between maps. using encodeResourceId they uniquely identify any resource.
    /// Id's are not shelf stable
    extension_map: IdMap,
    path_map: IdMap,
    res_map: IdMap,

    /// This maps a encodeResourceId id to a vpk entry
    entries: IdEntryMap,

    loose_dirs: std.ArrayList(std.fs.Dir),
    dirs: std.ArrayList(Dir),
    /// Stores all long lived strings used by vpkctx. Mostly keys into IdMap
    string_storage: StringStorage,

    alloc: std.mem.Allocator,

    /// Scratch buffers
    strbuf: std.ArrayList(u8),
    name_buf: std.ArrayList(u8),
    split_buf: std.ArrayList(u8),
    filebuf: std.ArrayList(u8),

    /// File object to optionally dump contents of all mounted vpk's
    vpk_dump_file: vpk_dump_file_t,

    mutex: std.Thread.Mutex = .{},

    pub fn init(alloc: std.mem.Allocator) !Self {
        return .{
            .extension_map = IdMap.init(alloc),
            .path_map = IdMap.init(alloc),
            .res_map = IdMap.init(alloc),
            .entries = IdEntryMap.init(alloc),
            .loose_dirs = std.ArrayList(std.fs.Dir).init(alloc),
            .name_buf = std.ArrayList(u8).init(alloc),

            .strbuf = std.ArrayList(u8).init(alloc),
            .split_buf = std.ArrayList(u8).init(alloc),
            .dirs = std.ArrayList(Dir).init(alloc),
            .filebuf = std.ArrayList(u8).init(alloc),
            .string_storage = StringStorage.init(alloc),
            .alloc = alloc,
            .vpk_dump_file = if (config.dump_vpk) try std.fs.cwd().createFile("vpkdump.txt", .{}) else {},
        };
    }

    pub fn deinit(self: *Self) void {
        if (config.dump_vpk)
            self.vpk_dump_file.close();
        self.string_storage.deinit();
        for (self.dirs.items) |*dir| {
            dir.deinit();
        }
        self.dirs.deinit();
        self.strbuf.deinit();
        self.filebuf.deinit();
        self.split_buf.deinit();
        for (self.loose_dirs.items) |*dir|
            dir.close();
        self.loose_dirs.deinit();

        self.name_buf.deinit();
        self.extension_map.deinit();
        self.path_map.deinit();
        self.res_map.deinit();
        self.entries.deinit();
    }

    /// All identifiers within the vpk are lowercased and \ -> /
    pub fn sanatizeVpkString(str: []u8) void {
        for (str) |*ch| {
            ch.* = switch (ch.*) {
                '\\' => '/',
                'A'...'Z' => ch.* | 0b00100000, //Lowercase
                else => ch.*,
            };
        }
    }

    //Not thread safe
    fn namesFromId_(self: *Self, id: VpkResId) ?Names {
        const ids = decodeResourceId(id);
        return .{
            .name = self.res_map.getName(@intCast(ids.name)) orelse return null,
            .ext = self.extension_map.getName(@intCast(ids.ext)) orelse return null,
            .path = self.path_map.getName(@intCast(ids.path)) orelse return null,
        };
    }

    /// Thread safe
    pub fn namesFromId(self: *Self, id: VpkResId) ?Names {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.namesFromId_(id);
    }

    pub fn getResource(self: *Self, id: VpkResId) ?[]const u8 {
        if (self.namesFromId(id)) |names| {
            self.name_buf.clearRetainingCapacity();
            self.name_buf.writer().print("{s}/{s}.{s}", .{
                names.path,
                names.name,
                names.ext,
            }) catch return null;
            return self.name_buf.items;
        }
        return null;
    }

    /// clobbers and returns memory from namebuf
    pub fn resolveId(self: *Self, id: IdOrName) !?IdAndName {
        self.name_buf.clearRetainingCapacity();
        switch (id) {
            .id => |idd| {
                const names = self.namesFromId(idd) orelse return null;
                try self.name_buf.writer().print("{s}/{s}.{s}", .{ names.path, names.name, names.ext });
                return .{
                    .id = idd,
                    .name = self.name_buf.items,
                };
            },
            .name => |name| {
                const idd = try self.getResourceIdString(name) orelse return null;

                try self.name_buf.appendSlice(name);
                return .{
                    .id = idd,
                    .name = self.name_buf.items,
                };
            },
        }
    }

    fn writeDump(self: *Self, comptime fmt: []const u8, args: anytype) void {
        if (config.dump_vpk) {
            self.vpk_dump_file.writer().print(fmt, args) catch return;
        }
    }

    pub fn addLooseDir(self: *Self, root: std.fs.Dir, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.loose_dirs.append(try root.openDir(path, .{}));
    }

    /// the vpk_set: hl2_pak.vpk -> hl2_pak_dir.vpk . This matches the way gameinfo.txt does it
    /// The passed in root dir must remain alive.
    pub fn addDir(self: *Self, root: std.fs.Dir, vpk_set: []const u8, loadctx: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!std.mem.endsWith(u8, vpk_set, ".vpk")) {
            log.err("Invalid vpk set: {s}", .{vpk_set});
            log.err("Vpk sets should be in the format: 'hl2_pak.vpk' which maps to the files: hl2_pak_xxx.vpk", .{});
            log.err("See hl2/gameinfo.txt for examples", .{});
            return error.invalidVpkSet;
        }
        timer.start();
        defer timer.end();
        const prefix = vpk_set[0 .. vpk_set.len - ".vpk".len];
        var new_dir = Dir.init(self.alloc, try self.string_storage.store(prefix), root);
        const dir_index = self.dirs.items.len;

        var strbuf = std.ArrayList(u8).init(self.alloc);
        defer strbuf.deinit();
        try strbuf.writer().print("{s}_dir.vpk", .{prefix});
        self.writeDump("VPK NAME: {s}\n", .{prefix});

        const file_name = try self.string_storage.store(strbuf.items);
        const infile = root.openFile(strbuf.items, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                log.err("Couldn't find vpk: {s} with given set: {s}", .{ strbuf.items, vpk_set });
                const path = root.realpath(".", &error_msg_buffer) catch "realpathFailed";
                log.err("Search directory path is: {s}/{s}", .{ path, strbuf.items });
                return error.FileNotFound;
            },
            else => return err,
        };
        // 0x7fff is the marker for files stored inside the dir.vpk
        try new_dir.fds.put(0x7fff, infile);
        try self.dirs.append(new_dir);

        // We read into fbs because File.Reader is slow!
        self.filebuf.clearRetainingCapacity();
        try infile.reader().readAllArrayList(&self.filebuf, std.math.maxInt(usize));
        var fbs = std.io.FixedBufferStream([]const u8){ .buffer = self.filebuf.items, .pos = 0 };

        const r = fbs.reader();
        const sig = try r.readInt(u32, .little);
        if (sig != VPK_FILE_SIG)
            return error.invalidVpk;
        const version = try r.readInt(u32, .little);
        const header_size: u32 = switch (version) {
            1 => 12,
            2 => 28,
            else => return error.unsupportedVpkVersion,
        };
        switch (version) {
            //1 => {},
            2 => {
                const tree_size = try r.readInt(u32, .little);
                const filedata_section_size = try r.readInt(u32, .little);
                const archive_md5_sec_size = try r.readInt(u32, .little);
                const other_md5_sec_size = try r.readInt(u32, .little);
                const sig_sec_size = try r.readInt(u32, .little);
                _ = sig_sec_size;
                _ = archive_md5_sec_size;
                _ = filedata_section_size;

                if (other_md5_sec_size != 48) return error.invalidMd5Size;

                //std.debug.print("{d} {d} {d} {d}\n", .{ tree_size, filedata_section_size, archive_md5_sec_size, sig_sec_size });

                loadctx.addExpected(10);
                while (true) {
                    loadctx.printCb("Dir mounted {d:.2}%", .{@as(f32, @floatFromInt(fbs.pos)) / @as(f32, @floatFromInt(self.filebuf.items.len + 1)) * 100});
                    const ext = try readString(r, &strbuf);
                    if (ext.len == 0)
                        break;
                    sanatizeVpkString(ext);
                    self.writeDump("{s}\n", .{ext});
                    const ext_stored = try self.string_storage.store(ext);
                    const ext_id = try self.extension_map.getPut(ext_stored);
                    while (true) {
                        const path = try readString(r, &strbuf);
                        self.writeDump("    {s}\n", .{path});
                        if (path.len == 0)
                            break;
                        sanatizeVpkString(path);
                        const path_stored = try self.string_storage.store(path);
                        const path_id = try self.path_map.getPut(path_stored);

                        while (true) {
                            const fname = try readString(r, &strbuf);
                            self.writeDump("        {s}\n", .{fname});
                            if (fname.len == 0)
                                break;

                            _ = try r.readInt(u32, .little); //CRC
                            _ = try r.readInt(u16, .little); //preload bytes
                            const arch_index = try r.readInt(u16, .little); //archive index
                            var offset = try r.readInt(u32, .little);
                            const entry_len = try r.readInt(u32, .little);

                            const term = try r.readInt(u16, .little);
                            if (term != 0xffff) return error.badBytes;
                            //std.debug.print("\t\t{s}: {d}bytes, i:{d}\n", .{ fname, entry_len, arch_index });
                            if (arch_index == 0x7fff) {
                                //TODO put a dir with arch_index 0x7ff do it .
                                offset += tree_size + header_size;
                            }

                            sanatizeVpkString(fname);
                            const fname_stored = try self.string_storage.store(fname);
                            const fname_id = try self.res_map.getPut(fname_stored);
                            const res_id = encodeResourceId(ext_id, path_id, fname_id);
                            const entry = try self.entries.getOrPut(res_id);
                            if (!entry.found_existing) {
                                entry.value_ptr.* = Entry{
                                    .dir_index = @intCast(dir_index),
                                    .archive_index = arch_index,
                                    .offset = offset,
                                    .length = entry_len,
                                    .res_id = res_id,
                                    .path = path_stored,
                                    .name = fname_stored,
                                };
                            } else {
                                //log.err("Duplicate resource is named: {s}", .{fname});
                                //    //return error.duplicateResource;
                            }
                        }
                    }
                }
            },
            else => {
                log.err("Unsupported vpk version {d}, file: {s}", .{ version, file_name });
                return error.unsupportedVpkVersion;
            },
        }
    }

    /// Only call this from the main thread.
    pub fn getFileTempFmt(self: *Self, extension: []const u8, comptime fmt: []const u8, args: anytype) !?[]const u8 {
        //Also , race condition
        return self.getFileTempFmtBuf(extension, fmt, args, &self.filebuf);
    }

    pub fn getFileTempFmtBuf(self: *Self, extension: []const u8, comptime fmt: []const u8, args: anytype, buf: *std.ArrayList(u8)) !?[]const u8 {
        const res_id = try self.getResourceIdFmt(extension, fmt, args) orelse return null;
        buf.clearRetainingCapacity();
        return try self.getFileFromRes(res_id, buf);
    }

    /// Returns a buffer owned by Self which will be clobberd on next getFileTemp call
    /// Only call this from the main thread
    pub fn getFileTemp(self: *Self, extension: []const u8, path: []const u8, name: []const u8) !?[]const u8 {
        const res_id = try self.getResourceId(extension, path, name) orelse return null;
        self.filebuf.clearRetainingCapacity();
        //the pointer is passed before mutex is locked, if another thread is resizing filebuf the ptr is invalid
        //In practice this shouldn't be a problem because only the main thread should ever call getFileTemp.
        return self.getFileFromRes(res_id, &self.filebuf);
    }

    // Thread safe
    pub fn getResourceId(self: *Self, extension: []const u8, path: []const u8, fname: []const u8) ?VpkResId {
        const ex = self.string_storage.store(extension) catch return null;
        const p = self.string_storage.store(path) catch return null;
        const fnam = self.string_storage.store(fname) catch return null;
        return encodeResourceId(
            self.extension_map.getPut(ex) catch return null,
            self.path_map.getPut(p) catch return null,
            self.res_map.getPut(fnam) catch return null,
        );
    }

    /// Thread safe
    pub fn getResourceIdFmt(self: *Self, ext: []const u8, comptime fmt: []const u8, args: anytype) !?VpkResId {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.split_buf.clearRetainingCapacity();
        try self.split_buf.writer().print(fmt, args);
        sanatizeVpkString(self.split_buf.items);
        //_ = std.ascii.lowerString(self.split_buf.items, self.split_buf.items);
        const sl = self.split_buf.items;
        const slash = std.mem.lastIndexOfScalar(u8, sl, '/') orelse return error.noSlash;

        return self.getResourceId(ext, sl[0..slash], sl[slash + 1 ..]);
    }

    pub fn getResourceIdString(self: *Self, name: []const u8) !?VpkResId {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.split_buf.clearRetainingCapacity();
        _ = try self.split_buf.writer().write(name);
        sanatizeVpkString(self.split_buf.items);
        //_ = std.ascii.lowerString(self.split_buf.items, self.split_buf.items);
        const sl = self.split_buf.items;
        const slash = std.mem.lastIndexOfScalar(u8, sl, '/') orelse return error.noSlash;
        const dot = std.mem.lastIndexOfScalar(u8, sl, '.') orelse return error.noExt;

        const path = sl[0..slash];
        const ext = sl[dot + 1 ..]; //Eat the dot
        const name_ = sl[slash + 1 .. dot];

        return self.getResourceId(ext, path, name_);
    }

    /// Thread safe
    pub fn getFileFromRes(self: *Self, res_id: VpkResId, buf: *std.ArrayList(u8)) !?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.entries.get(res_id) orelse {
            const names = self.namesFromId_(res_id) orelse return null;
            self.strbuf.clearRetainingCapacity();
            try self.strbuf.writer().print("{s}/{s}.{s}", .{ names.path, names.name, names.ext });
            //std.debug.print("Searching loose dir for {s} \n", .{self.strbuf.items});
            for (self.loose_dirs.items) |ldir| {
                const infile = ldir.openFile(self.strbuf.items, .{}) catch continue;
                defer infile.close();
                buf.clearRetainingCapacity();
                try infile.reader().readAllArrayList(buf, std.math.maxInt(usize));
                return buf.items;
            }
            return null;
        };
        const dir = self.getDir(entry.dir_index) orelse return null;
        const res = try dir.fds.getOrPut(entry.archive_index);
        if (!res.found_existing) {
            errdefer _ = dir.fds.remove(entry.archive_index); //Prevent closing an unopened file messing with stack trace
            self.strbuf.clearRetainingCapacity();
            try self.strbuf.writer().print("{s}_{d:0>3}.vpk", .{ dir.prefix, entry.archive_index });

            res.value_ptr.* = dir.root.openFile(self.strbuf.items, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    log.err("Couldn't open vpk file: {s}", .{self.strbuf.items});
                    return err;
                },
                else => return err,
            };
        }

        try buf.resize(entry.length);
        try res.value_ptr.seekTo(entry.offset);
        try res.value_ptr.reader().readNoEof(buf.items);
        return buf.items;
    }

    /// The pointer to Dir may be invalidated if addDir is called
    pub fn getDir(self: *Self, dir_index: u16) ?*Dir {
        if (dir_index < self.dirs.items.len) {
            return &self.dirs.items[dir_index];
        }
        return null;
    }
};

///Read next string in vpk dir file
///Clears str
fn readString(r: anytype, str: *std.ArrayList(u8)) ![]u8 {
    str.clearRetainingCapacity();
    while (true) {
        const char = try r.readByte();
        if (char == 0)
            return str.items;
        try str.append(char);
    }
}
