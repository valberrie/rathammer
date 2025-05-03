const std = @import("std");
const vdf = @import("vdf.zig");
const graph = @import("graph");
const StringStorage = @import("string.zig").StringStorage;

// TODO all values should have a default value
/// The user's 'config.vdf' maps directly into this structure
pub const Config = struct {
    keys: struct {
        cam_forward: Keybind,
        cam_back: Keybind,
        cam_strafe_l: Keybind,
        cam_strafe_r: Keybind,
        cam_down: Keybind,
        cam_up: Keybind,
        quit: Keybind,
        focus_search: Keybind,
        workspace: std.ArrayList(Keybind),
        select: Keybind,
    },
    window: struct {
        height_px: i32 = 600,
        width_px: i32 = 800,
        cam_fov: f32 = 90,
    },
    default_game: []const u8 = "",
    games: struct {
        map: std.StringHashMap(GameEntry),
        pub fn parseVdf(v: *const vdf.KV.Value, alloc: std.mem.Allocator, strings_o: ?*StringStorage) !@This() {
            const strings = strings_o orelse return error.needStrings;
            var ret = @This(){
                .map = std.StringHashMap(GameEntry).init(alloc),
            };
            if (v.* == .literal)
                return error.notgood;
            for (v.obj.list.items) |entry| {
                try ret.map.put(
                    try strings.store(entry.key),
                    try vdf.fromValue(GameEntry, &entry.val, alloc, strings),
                );
            }
            return ret;
        }
    },
};
pub const GameEntry = struct {
    base_dir: []const u8,
    game_dir: []const u8,
    fgd_dir: []const u8,
    fgd: []const u8,

    asset_browser_exclude: struct {
        prefix: []const u8,
        entry: std.ArrayList([]const u8),
    },
};

pub const ConfigCtx = struct {
    config: Config,
    strings: StringStorage,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *@This()) void {
        var it = self.config.games.map.valueIterator();
        while (it.next()) |item|
            item.asset_browser_exclude.entry.deinit();
        self.config.games.map.deinit();
        self.config.keys.workspace.deinit();
        self.strings.deinit();
    }
};

pub const Keybind = struct {
    b: graph.SDL.NewBind,
    pub fn parseVdf(v: *const vdf.KV.Value, _: std.mem.Allocator, _: anytype) !@This() {
        const stw = std.mem.startsWith;
        if (v.* != .literal)
            return error.notgood;

        var buf: [128]u8 = undefined;
        var it = std.mem.tokenizeScalar(u8, v.literal, '+');
        var ret = graph.SDL.NewBind{
            .key = undefined,
            .mod = 0,
        };
        var has_key: bool = false;
        while (it.next()) |key_name| {
            const is_scancode = stw(u8, key_name, "scancode:");
            var start_i = if (is_scancode) "scancode:".len else 0;
            if (stw(u8, key_name, "keycode:"))
                start_i = "keycode:".len;

            const slice1 = key_name[start_i..];
            if (slice1.len > buf.len)
                return error.keyNameTooLong;
            @memcpy(buf[0..slice1.len], slice1);
            std.mem.replaceScalar(u8, buf[0..slice1.len], '_', ' ');
            //std.debug.print("{s}\n", .{slice1});
            const scancode = graph.SDL.getScancodeFromName(buf[0..slice1.len]);
            if (scancode == 0) {
                std.debug.print("Not a key {s}\n", .{key_name});
                return error.notAKey;
            }

            const Kmod = graph.SDL.keycodes.Keymod;
            const keymod = Kmod.fromScancode(@enumFromInt(scancode));
            ret.key = if (is_scancode) .{ .scancode = @enumFromInt(scancode) } else .{ .keycode = graph.SDL.getKeyFromScancode(@enumFromInt(scancode)) };
            if (keymod != @intFromEnum(Kmod.NONE)) {
                ret.mod |= keymod;
            }
            has_key = true;

            //const keyc = graph.SDL.getKeyFromScancode(@enumFromInt(scancode));
            //std.debug.print("{s}\n", .{graph.c.SDL_GetKeyName(@intFromEnum(keyc))});
        }
        if (!has_key)
            return error.noKeySpecified;
        return .{ .b = ret };
    }
};

pub fn loadConfig(alloc: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) !ConfigCtx { //Load config
    const in = try dir.openFile(path, .{});
    const slice = try in.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(slice);

    var val = try vdf.parse(alloc, slice);
    defer val.deinit();

    var ctx = ConfigCtx{
        .alloc = alloc,
        .strings = StringStorage.init(alloc),
        .config = undefined,
    };
    //CONF MUST BE copyable IE no alloc
    const conf = try vdf.fromValue(
        Config,
        &.{ .obj = &val.value },
        alloc,
        &ctx.strings,
    );
    ctx.config = conf;
    return ctx;
}
