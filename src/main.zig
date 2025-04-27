const std = @import("std");
const graph = @import("graph");
const Rec = graph.Rec;
const Vec2f = graph.Vec2f;
const V3f = graph.za.Vec3;
const meshutil = graph.meshutil;
const csg = @import("csg.zig");
const vdf = @import("vdf.zig");
const vmf = @import("vmf.zig");
const vpk = @import("vpk.zig");
const fgd = @import("fgd.zig");
const edit = @import("editor.zig");
const Editor = @import("editor.zig").Context;
const vtf = @import("vtf.zig");
const Vec3 = V3f;
const util3d = @import("util_3d.zig");
const Os9Gui = graph.gui_app.Os9Gui;
const guiutil = graph.gui_app;
const Gui = graph.Gui;
const vvd = @import("vvd.zig");

fn readFromFile(alloc: std.mem.Allocator, dir: std.fs.Dir, filename: []const u8) ![]const u8 {
    const inf = try dir.openFile(filename, .{});
    defer inf.close();
    const slice = try inf.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    return slice;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 0 }){};
    const alloc = gpa.allocator();
    try wrappedMain(alloc);
    _ = gpa.detectLeaks(); // Not deferred, so on error there isn't spam
}

pub fn wrappedMain(alloc: std.mem.Allocator) !void {
    var arg_it = try std.process.argsWithAllocator(alloc);
    defer arg_it.deinit();

    const Arg = graph.ArgGen.Arg;
    const args = try graph.ArgGen.parseArgs(&.{
        Arg("vmf", .string, "vmf to load"),
        Arg("basedir", .string, "base directory of the game"),
        Arg("gameinfo", .string, "directory of gameinfo"),
        Arg("scale", .number, "scale the model"),
    }, &arg_it);

    var win = try graph.SDL.Window.createWindow("Rat Hammer - 鼠", .{
        .window_size = .{ .x = 800, .y = 600 },
    });
    defer win.destroyWindow();

    if (!graph.SDL.Window.glHasExtension("GL_EXT_texture_compression_s3tc")) return error.glMissingExt;

    //materials/concrete/concretewall008a
    //const o = try vpkctx.getFileTemp("vtf", "materials/concrete", "concretewall008a");
    //var my_tex = try vtf.loadTexture(o.?, alloc);
    var editor = try Editor.init(alloc);
    defer editor.deinit();

    var draw = graph.ImmediateDrawingContext.init(alloc);
    defer draw.deinit();
    var font = try graph.Font.init(alloc, std.fs.cwd(), "ratgraph/asset/fonts/roboto.ttf", 40, .{});
    defer font.deinit();
    var loadctx = edit.LoadCtx{
        .draw = &draw,
        .font = &font,
        .win = &win,
        .timer = try std.time.Timer.start(),
    };
    var os9gui = try Os9Gui.init(alloc, try std.fs.cwd().openDir("ratgraph", .{}), 2);
    defer os9gui.deinit();
    loadctx.cb("Loading");

    const base_dir = try std.fs.cwd().openDir(args.basedir orelse "Half-Life 2", .{});
    const game_dir = try std.fs.cwd().openDir(args.gameinfo orelse "Half-Life 2/hl2", .{});
    //const hl_root = try std.fs.cwd().openDir("hl2", .{});
    {
        const sl = try readFromFile(alloc, game_dir, "gameinfo.txt");
        defer alloc.free(sl);

        var obj = try vdf.parse(alloc, sl);
        defer obj.deinit();

        var aa = std.heap.ArenaAllocator.init(alloc);
        defer aa.deinit();
        const gameinfo = try vdf.fromValue(struct {
            gameinfo: struct {
                game: []const u8 = "",
                title: []const u8 = "",
                type: []const u8 = "",
            } = .{},
        }, &.{ .obj = &obj.value }, aa.allocator());
        std.debug.print("Loading gameinfo {s} {s}\n", .{ gameinfo.gameinfo.game, gameinfo.gameinfo.title });

        const fs = try obj.value.recursiveGetFirst(&.{ "gameinfo", "filesystem", "searchpaths" });
        if (fs != .obj)
            return error.invalidGameInfo;
        //vdf.printObj(fs.obj.*, 0);
        const startsWith = std.mem.startsWith;
        for (fs.obj.list.items) |entry| {
            var tk = std.mem.tokenizeScalar(u8, entry.key, '+');
            while (tk.next()) |t| {
                if (std.mem.eql(u8, t, "game")) {
                    if (entry.val != .literal)
                        return error.invalidGameInfo;
                    const l = entry.val.literal;
                    var path = l;
                    const dir = base_dir;
                    if (startsWith(u8, l, "|")) {
                        const end = std.mem.indexOfScalar(u8, l[1..], '|') orelse return error.invalidGameInfo;
                        const special = l[1..end];
                        _ = special; //TODO actually use this?
                        //std.debug.print("Special {s}\n", .{special});
                        //          + 2 because end is offset by 1
                        path = l[end + 2 ..];
                        //if(std.mem.eql(u8, special, "all_source_engine_paths"))
                        //dir = game_dir;
                    }
                    //std.debug.print("Path {s}\n", .{path});
                    if (std.mem.endsWith(u8, path, ".vpk")) {
                        if ((std.mem.indexOfPos(u8, path, 0, "sound") == null)) {
                            editor.vpkctx.addDir(dir, path) catch |err| {
                                std.debug.print("Failed to mount vpk {s} with error {}\n", .{ path, err });
                            };
                        }
                    }
                }
            }
        }
    }

    //const ep_root = try std.fs.cwd().openDir("Half-Life 2/ep2", .{});
    //try editor.vpkctx.addDir(ep_root, "ep2_pak.vpk");
    //try vpkctx.addDir(root, "tf2_textures.vpk");
    //try vpkctx.addDir(root, "tf2_misc.vpk");

    //try editor.vpkctx.addDir(hl_root, "hl2_misc.vpk");
    //try editor.vpkctx.addDir(hl_root, "hl2_textures.vpk");
    //try editor.vpkctx.addDir(hl_root, "hl2_pak.vpk");

    //var my_mesh = try vvd.loadModelCrappy(alloc, "models/kleiner", &editor);
    //defer my_mesh.deinit();
    loadctx.cb("Vpk's mounted");

    vpk.timer.log("Vpk dir");

    try fgd.loadFgd(&editor.fgd_ctx, try std.fs.cwd().openDir("Half-Life 2/bin", .{}), "halflife2.fgd");
    {
        //Create an atlas for the icons
        var it = editor.fgd_ctx.base.valueIterator();
        while (it.next()) |class| {
            if (class.iconsprite.len == 0) continue;
            const res = try editor.icon_map.getOrPut(class.iconsprite);
            if (!res.found_existing) {
                var sl = class.iconsprite;
                if (std.mem.endsWith(u8, class.iconsprite, ".vmt"))
                    sl = class.iconsprite[0 .. class.iconsprite.len - 4];
                res.value_ptr.* = try editor.loadTextureFromVpk(sl);
            }
        }
    }

    try editor.loadVmf(std.fs.cwd(), args.vmf orelse "sdk_materials.vmf", &loadctx);

    const RcastItem = struct {
        id: edit.EcsT.Id,
        dist: f32,
        point: graph.za.Vec3 = undefined,

        pub fn lessThan(_: void, a: @This(), b: @This()) bool {
            return a.dist < b.dist;
        }
    };
    var raycast_pot = std.ArrayList(RcastItem).init(alloc);
    defer raycast_pot.deinit();

    var raycast_pot_fine = std.ArrayList(RcastItem).init(alloc);
    defer raycast_pot_fine.deinit();

    graph.c.glEnable(graph.c.GL_CULL_FACE);
    graph.c.glCullFace(graph.c.GL_BACK);

    var last_frame_grabbed: bool = true;
    var grab_mouse = true;

    //var sky = try skybox.Skybox.init(alloc, "skybox/sky_day01_06", &editor.vpkctx);
    //defer sky.deinit();

    win.grabMouse(true);
    while (!win.should_exit) {
        try draw.begin(0x75573cff, win.screen_dimensions.toF());
        win.grabMouse(grab_mouse);
        win.pumpEvents(.poll);
        //if (win.mouse.pos.x >= draw.screen_dimensions.x - 40)
        //    graph.c.SDL_WarpMouseInWindow(win.win, 10, win.mouse.pos.y);
        defer last_frame_grabbed = grab_mouse;

        editor.edit_state.btn_x_trans = win.keystate(._1);
        editor.edit_state.btn_y_trans = win.keystate(._2);
        editor.edit_state.btn_z_trans = win.keystate(._3);
        editor.edit_state.lmouse = win.mouse.left;
        editor.edit_state.rmouse = win.mouse.right;
        if (editor.edit_state.lmouse == .rising) {}
        editor.edit_state.trans_begin = win.mouse.pos;
        { //key stuff
            if (editor.edit_state.btn_x_trans == .rising) {
                editor.edit_state.trans_begin = win.mouse.pos;
            }
            editor.edit_state.trans_end = win.mouse.pos;
        }

        grab_mouse = !(win.keyHigh(.LSHIFT) or editor.edit_state.btn_x_trans == .high or editor.edit_state.btn_y_trans == .high or editor.edit_state.btn_z_trans == .high);
        if (last_frame_grabbed and !grab_mouse) { //Mouse just ungrabbed
            graph.c.SDL_WarpMouseInWindow(win.win, draw.screen_dimensions.x / 2, draw.screen_dimensions.y / 2);
        }
        const is: Gui.InputState = .{ .mouse = win.mouse, .key_state = &win.key_state, .keys = win.keys.slice(), .mod_state = win.mod };
        try os9gui.beginFrame(is, &win);

        if (win.keyRising(.TAB))
            editor.draw_state.draw_tools = !editor.draw_state.draw_tools;
        editor.draw_state.cam3d.updateDebugMove(.{
            .down = win.keyHigh(.LCTRL),
            .up = win.keyHigh(.SPACE),
            .left = win.keyHigh(.A),
            .right = win.keyHigh(.D),
            .fwd = win.keyHigh(.W),
            .bwd = win.keyHigh(.S),
            .mouse_delta = if (last_frame_grabbed) win.mouse.delta else .{ .x = 0, .y = 0 },
            .scroll_delta = win.mouse.wheel_delta.y,
        });

        graph.c.glEnable(graph.c.GL_BLEND);
        const winrect = graph.Rec(0, 0, draw.screen_dimensions.x, draw.screen_dimensions.y);
        const split1 = winrect.split(.vertical, winrect.w * 0.8);
        //const view_3d = editor.draw_state.cam3d.getMatrix(split1[0].w / split1[0].h, 1, editor.draw_state.cam_far_plane);
        //my_mesh.drawSimple(view_3d, graph.za.Mat4.identity(), editor.draw_state.basic_shader);
        try editor.draw3Dview(split1[0], &draw);
        try editor.drawInspector(split1[1], &os9gui);
        if (!last_frame_grabbed and split1[1].containsPoint(win.mouse.pos))
            grab_mouse = false;
        if (win.keyRising(.E)) {
            raycast_pot.clearRetainingCapacity();
            var bbit = editor.ecs.iterator(.bounding_box);
            while (bbit.next()) |bb| {
                //for (editor.set.dense.items, 0..) |solid, i| {
                //draw.cube(pos, ext, 0xffffffff);
                if (util3d.doesRayIntersectBBZ(editor.draw_state.cam3d.pos, editor.draw_state.cam3d.front, bb.a, bb.b)) |inter| {
                    const len = inter.distance(editor.draw_state.cam3d.pos);
                    try raycast_pot.append(.{ .id = bbit.i, .dist = len });
                }
            }
            if (true) {
                raycast_pot_fine.clearRetainingCapacity();
                for (raycast_pot.items) |bp_rc| {
                    if (try editor.ecs.getOptPtr(bp_rc.id, .solid)) |solid| {
                        for (solid.sides.items) |side| {
                            if (side.verts.items.len < 3) continue;
                            const plane = util3d.trianglePlane(side.verts.items[0..3].*);
                            if (util3d.doesRayIntersectConvexPolygon(
                                editor.draw_state.cam3d.pos,
                                editor.draw_state.cam3d.front,
                                plane,
                                side.verts.items,
                            )) |point| {
                                const len = point.distance(editor.draw_state.cam3d.pos);
                                try raycast_pot_fine.append(.{ .id = bp_rc.id, .dist = len, .point = point });
                            }
                        }
                    } else {
                        try raycast_pot_fine.append(bp_rc);
                    }
                }

                std.sort.insertion(RcastItem, raycast_pot_fine.items, {}, RcastItem.lessThan);
                if (raycast_pot_fine.items.len > 0) {
                    // std.debug.print("Count {d} {d}\n", .{ raycast_pot.items.len, raycast_pot_fine.items.len });
                    // for (raycast_pot_fine.items) |itt|
                    //     std.debug.print("ID: {d} {d} {}\n", .{ itt.id, itt.dist, itt.point });
                    editor.edit_state.id = raycast_pot_fine.items[0].id;
                }
            } else {
                std.sort.insertion(RcastItem, raycast_pot.items, {}, RcastItem.lessThan);
                if (raycast_pot.items.len > 0) {
                    editor.edit_state.id = raycast_pot.items[0].id;
                }
            }
        }

        //try draw.flush(null, editor.draw_state.cam3d);

        try os9gui.endFrame(&draw);
        try draw.end(editor.draw_state.cam3d);
        win.swap();
    }
}
