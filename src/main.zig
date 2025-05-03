const std = @import("std");
const graph = @import("graph");
const Rec = graph.Rec;
const Vec2f = graph.Vec2f;
const V3f = graph.za.Vec3;
const meshutil = graph.meshutil;
const vdf = @import("vdf.zig");
const vmf = @import("vmf.zig");
const vpk = @import("vpk.zig");
const fgd = @import("fgd.zig");
const edit = @import("editor.zig");
const Editor = @import("editor.zig").Context;
const Vec3 = V3f;
const util3d = @import("util_3d.zig");
const Os9Gui = graph.gui_app.Os9Gui;
const guiutil = graph.gui_app;
const Gui = graph.Gui;
const Split = @import("splitter.zig");

const Conf = @import("config.zig");

pub fn wrappedMain(alloc: std.mem.Allocator, args: anytype) !void {
    var loaded_config = try Conf.loadConfig(alloc, std.fs.cwd(), "config.vdf");
    defer loaded_config.deinit();
    const config = loaded_config.config;
    var win = try graph.SDL.Window.createWindow("Rat Hammer - ラット　ハンマー", .{
        .window_size = .{ .x = config.window.width_px, .y = config.window.height_px },
    });
    defer win.destroyWindow();

    if (!graph.SDL.Window.glHasExtension("GL_EXT_texture_compression_s3tc")) return error.glMissingExt;

    //materials/concrete/concretewall008a
    //const o = try vpkctx.getFileTemp("vtf", "materials/concrete", "concretewall008a");
    //var my_tex = try vtf.loadTexture(o.?, alloc);
    var editor = try Editor.init(alloc, if (args.nthread) |nt| @intFromFloat(nt) else null, config);
    defer editor.deinit();

    var draw = graph.ImmediateDrawingContext.init(alloc);
    defer draw.deinit();
    var font = try graph.Font.init(alloc, std.fs.cwd(), "ratgraph/asset/fonts/roboto.ttf", 40, .{});
    defer font.deinit();
    const splash = try graph.Texture.initFromImgFile(alloc, std.fs.cwd(), "small.png", .{});
    var os9gui = try Os9Gui.init(alloc, try std.fs.cwd().openDir("ratgraph", .{}), args.gui_scale orelse 2);
    defer os9gui.deinit();
    var loadctx = edit.LoadCtx{
        .draw = &draw,
        .font = &font,
        .win = &win,
        .splash = splash,
        .os9gui = &os9gui,
        .timer = try std.time.Timer.start(),
        .gtimer = try std.time.Timer.start(),
        .expected_cb = 100,
    };

    loadctx.cb("Loading");

    try editor.postInit(args);

    loadctx.cb("Vpk's mounted");

    vpk.timer.log("Vpk dir");

    var model_cam = graph.Camera3D{ .pos = Vec3.new(-100, 0, 0), .front = Vec3.new(1, 0, 0), .up = .z };
    model_cam.yaw = 0;
    var name_buf = std.ArrayList(u8).init(alloc);
    defer name_buf.deinit();

    editor.draw_state.cam3d.fov = config.window.cam_fov;

    try editor.loadVmf(std.fs.cwd(), args.vmf orelse "sdk_materials.vmf", &loadctx);

    loadctx.time = loadctx.gtimer.read();

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

    const Pane = enum {
        main_3d_view,
        asset_browser,
        inspector,
        model_preview,
        model_browser,
        file_browser,
        about,
    };
    var areas_buf: [10]graph.Rect = undefined;
    var fb = try guiutil.FileBrowser.init(alloc, std.fs.cwd());
    defer fb.deinit();

    var splits: [256]Split.Op = undefined;
    var panes: [256]Pane = undefined;
    var SI: usize = 0;
    var PI: usize = 0;
    const Tab = struct {
        split: []Split.Op,
        panes: []Pane,

        fn newSplit(s: []Split.Op, i: *usize, sp: []const Split.Op) []Split.Op {
            @memcpy(s[i.* .. i.* + sp.len], sp);
            defer i.* += sp.len;
            return s[i.* .. i.* + sp.len];
        }

        fn newPane(p: []Pane, pi: *usize, ps: []const Pane) []Pane {
            @memcpy(p[pi.* .. pi.* + ps.len], ps);
            defer pi.* += ps.len;
            return p[pi.* .. pi.* + ps.len];
        }
    };
    const tabs = [_]Tab{
        .{
            .split = Tab.newSplit(&splits, &SI, &.{ .{ .left, 0.7 }, .{ .top, 1 } }),
            .panes = Tab.newPane(&panes, &PI, &.{ .main_3d_view, .inspector }),
        },
        .{
            .split = Tab.newSplit(&splits, &SI, &.{.{ .left, 1 }}),
            .panes = Tab.newPane(&panes, &PI, &.{.asset_browser}),
        },
        .{
            .split = Tab.newSplit(&splits, &SI, &.{ .{ .left, 0.6 }, .{ .left, 1 } }),
            .panes = Tab.newPane(&panes, &PI, &.{ .model_browser, .model_preview }),
        },
        .{
            .split = Tab.newSplit(&splits, &SI, &.{ .{ .left, 0.5 }, .{ .left, 1 } }),
            .panes = Tab.newPane(&panes, &PI, &.{ .about, .about }),
        },
    };
    var tab_index: usize = 0;
    var show_tab_editor = false;

    win.grabMouse(true);
    while (!win.should_exit) {
        if (win.bindHigh(config.keys.quit.b))
            win.should_exit = true;
        try draw.begin(0x75573cff, win.screen_dimensions.toF());
        win.grabMouse(grab_mouse);
        //TODO add a cool down for wait events?
        win.pumpEvents(.poll);
        //if (win.mouse.pos.x >= draw.screen_dimensions.x - 40)
        //    graph.c.SDL_WarpMouseInWindow(win.win, 10, win.mouse.pos.y);
        defer last_frame_grabbed = grab_mouse;

        if (win.keyRising(._9))
            show_tab_editor = !show_tab_editor;

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

        const is: Gui.InputState = .{ .mouse = win.mouse, .key_state = &win.key_state, .keys = win.keys.slice(), .mod_state = win.mod };
        try os9gui.beginFrame(is, &win);

        if (win.keyRising(.TAB))
            editor.draw_state.draw_tools = !editor.draw_state.draw_tools;
        const cam_state = graph.ptypes.Camera3D.MoveState{
            .down = win.bindHigh(config.keys.cam_down.b),
            .up = win.bindHigh(config.keys.cam_up.b),
            .left = win.bindHigh(config.keys.cam_strafe_l.b),
            .right = win.bindHigh(config.keys.cam_strafe_r.b),
            .fwd = win.bindHigh(config.keys.cam_forward.b),
            .bwd = win.bindHigh(config.keys.cam_back.b),
            .mouse_delta = if (last_frame_grabbed) win.mouse.delta else .{ .x = 0, .y = 0 },
            .scroll_delta = win.mouse.wheel_delta.y,
        };

        graph.c.glEnable(graph.c.GL_BLEND);
        try editor.update();
        const winrect = graph.Rec(0, 0, draw.screen_dimensions.x, draw.screen_dimensions.y);
        for (config.keys.workspace.items, 0..) |b, i| {
            if (win.isBindState(b.b, .rising))
                tab_index = i;
        }
        tab_index = @min(tab_index, tabs.len - 1);

        const tab = tabs[tab_index];
        const areas = Split.fillBuf(tab.split, &areas_buf, winrect);
        {
            const state_btns = [_]graph.SDL.keycodes.Scancode{ ._1, ._2, ._3, ._4, ._5, ._6, ._7 };
            const num_field = @typeInfo(@TypeOf(editor.edit_state.state)).Enum.fields.len;
            for (state_btns, 0..) |sbtn, i| {
                if (i >= num_field)
                    break;
                if (win.keyRising(sbtn)) {
                    editor.edit_state.state = @enumFromInt(i);
                }
            }
        }

        var mouse_is_claimed = false;
        for (tab.panes, 0..) |pane, p_i| {
            const pane_area = areas[p_i];
            const has_mouse = pane_area.containsPoint(win.mouse.pos);
            switch (pane) {
                .main_3d_view => {
                    editor.draw_state.cam3d.updateDebugMove(if (grab_mouse) cam_state else .{});
                    if (grab_mouse or has_mouse) {
                        grab_mouse = !(win.keyHigh(.LSHIFT));
                        mouse_is_claimed = true;
                    }
                    if (last_frame_grabbed and !grab_mouse) { //Mouse just ungrabbed
                        const center = pane_area.center();
                        graph.c.SDL_WarpMouseInWindow(win.win, center.x, center.y);
                    }
                    try editor.draw3Dview(pane_area, &draw);
                },
                .about => {
                    if (try os9gui.beginTlWindow(pane_area)) {
                        defer os9gui.endTlWindow();
                        _ = try os9gui.beginV();
                        defer os9gui.endL();
                        os9gui.label("Hello this is the rat hammer 鼠", .{});
                        try os9gui.enumCombo(
                            "Select pane {s}",
                            .{@tagName(pane)},
                            &tabs[tab_index].panes[p_i],
                        );
                    }
                },
                .model_browser => try editor.asset_browser.drawEditWindow(pane_area, &os9gui, &editor, &config, .model),
                .asset_browser => {
                    try editor.asset_browser.drawEditWindow(pane_area, &os9gui, &editor, &config, .texture);
                },
                .inspector => try editor.drawInspector(pane_area, &os9gui),
                .model_preview => {
                    const selected_index = editor.asset_browser.selected_index_model;
                    if (selected_index < editor.asset_browser.model_list_sub.items.len) {
                        const sp = pane_area;
                        if (has_mouse or grab_mouse) {
                            grab_mouse = win.mouse.left == .high;
                            mouse_is_claimed = true;
                        }
                        model_cam.updateDebugMove(if (win.mouse.left == .high) cam_state else .{});
                        const screen_area = pane_area;
                        const x: i32 = @intFromFloat(screen_area.x);
                        const y: i32 = @intFromFloat(screen_area.y);
                        const w: i32 = @intFromFloat(screen_area.w);
                        const h: i32 = @intFromFloat(screen_area.h);

                        graph.c.glViewport(x, y, w, h);
                        graph.c.glScissor(x, y, w, h);
                        graph.c.glEnable(graph.c.GL_SCISSOR_TEST);
                        defer graph.c.glDisable(graph.c.GL_SCISSOR_TEST);
                        //todo
                        //defer loading of all textures

                        const modid = editor.asset_browser.model_list_sub.items[selected_index];
                        name_buf.clearRetainingCapacity();
                        //try name_buf.writer().print("models/{s}/{s}.mdl", .{ modname[0], modname[1] });
                        //draw.cube(Vec3.new(0, 0, 0), Vec3.new(10, 10, 10), 0xffffffff);
                        if (editor.models.get(modid)) |mod| {
                            if (mod) |mm| {
                                const view = model_cam.getMatrix(sp.h / sp.w, 1, 64 * 512);
                                const mat = graph.za.Mat4.identity();
                                mm.drawSimple(view, mat, editor.draw_state.basic_shader);
                            }
                        } else {
                            if (editor.vpkctx.entries.get(modid)) |tt| {
                                try name_buf.writer().print("{s}/{s}.mdl", .{ tt.path, tt.name });
                                _ = try editor.loadModel(name_buf.items);
                            }
                        }
                        try draw.flush(null, model_cam);
                    }
                },
                .file_browser => {
                    if (try os9gui.beginTlWindow(pane_area)) {
                        defer os9gui.endTlWindow();
                        try fb.update(&os9gui);
                    }
                },
            }
        }
        if (!mouse_is_claimed)
            grab_mouse = false;

        if (win.isBindState(config.keys.select.b, .rising)) {
            editor.edit_state.state = .select;
            const pot = try editor.rayctx.findNearestSolid(&editor.ecs, editor.draw_state.cam3d.pos, editor.draw_state.cam3d.front, &editor.csgctx, false);
            if (pot.len > 0) {
                editor.edit_state.id = pot[0].id;
            }
            //var rcast_timer = try std.time.Timer.start();
            //defer std.debug.print("Rcast took {d} us\n", .{rcast_timer.read() / std.time.ns_per_us});
        }

        //try draw.flush(null, editor.draw_state.cam3d);

        if (show_tab_editor) {
            const thing = winrect.inset(winrect.h / 5);
            if (try os9gui.beginTlWindow(thing)) {
                defer os9gui.endTlWindow();
                _ = try os9gui.beginV();
                defer os9gui.endL();
                for (tabs) |tabl| {
                    for (tabl.split) |*s| {
                        os9gui.slider(&s[1], 0, 1);
                    }
                    os9gui.hr();
                }
            }
        }
        try loadctx.loadedSplash(win.keys.len > 0);
        try os9gui.endFrame(&draw);
        try draw.end(editor.draw_state.cam3d);
        win.swap();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 0 }){};
    const alloc = gpa.allocator();
    var arg_it = try std.process.argsWithAllocator(alloc);
    defer arg_it.deinit();

    const Arg = graph.ArgGen.Arg;
    const args = try graph.ArgGen.parseArgs(&.{
        Arg("vmf", .string, "vmf to load"),
        Arg("basedir", .string, "base directory of the game, \"Half-Life 2\""),
        Arg("gamedir", .string, "directory of gameinfo.txt, \"Half-Life 2/hl2\""),
        Arg("fgddir", .string, "directory of fgd file"),
        Arg("fgd", .string, "name of fgd file"),
        Arg("nthread", .number, "How many threads."),
        Arg("gui_scale", .number, "Scale the gui"),
        Arg("game", .string, "Name of a game defined in config.vdf"),
        Arg("custom_cwd", .string, "override the directory used for game"),
    }, &arg_it);
    try wrappedMain(alloc, args);
    _ = gpa.detectLeaks(); // Not deferred, so on error there isn't spam
}
