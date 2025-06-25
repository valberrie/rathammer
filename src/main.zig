const std = @import("std");
const builtin = @import("builtin");
const IS_DEBUG = builtin.mode == .Debug;

const graph = @import("graph");
const Rec = graph.Rec;
const Vec2f = graph.Vec2f;
const V3f = graph.za.Vec3;
const vpk = @import("vpk.zig");
const edit = @import("editor.zig");
const Editor = @import("editor.zig").Context;
const Vec3 = V3f;
const Os9Gui = graph.gui_app.Os9Gui;
const Gui = graph.Gui;
const Split = @import("splitter.zig");
const editor_view = @import("editor_views.zig");
const G = graph.RGui;
const PauseWindow = @import("windows/pause.zig").PauseWindow;
const InspectorWindow = @import("windows/inspector.zig").InspectorWindow;

const Conf = @import("config.zig");

pub fn dpiDetect(win: *graph.SDL.Window) !f32 {
    const sc = graph.c.SDL_GetWindowDisplayScale(win.win);
    if (sc == 0)
        return error.sdl;
    return sc;
}

pub fn wrappedMain(alloc: std.mem.Allocator, args: anytype) !void {
    const load_timer = try std.time.Timer.start();
    var loaded_config = try Conf.loadConfig(alloc, std.fs.cwd(), "config.vdf");
    defer loaded_config.deinit();
    const config = loaded_config.config;
    //var win = try graph.SDL.Window.createWindow("Rat Hammer - ラットハンマー", .{
    var win = try graph.SDL.Window.createWindow("Rat Hammer", .{
        .window_size = .{ .x = config.window.width_px, .y = config.window.height_px },
    });
    defer win.destroyWindow();

    const sc = try dpiDetect(&win);
    const default_item_height = 25;
    const default_text_height = 20;
    const scaled_item_height = @trunc(default_item_height * sc);
    const scaled_text_height = @trunc(default_text_height * sc);
    edit.log.info("Detected a display scale of {d}", .{sc});

    if (!graph.SDL.Window.glHasExtension("GL_EXT_texture_compression_s3tc")) return error.glMissingExt;

    var editor = try Editor.init(alloc, if (args.nthread) |nt| @intFromFloat(nt) else null, config, args);
    defer editor.deinit();
    var draw = graph.ImmediateDrawingContext.init(alloc);
    defer draw.deinit();
    var font = try graph.Font.init(alloc, std.fs.cwd(), "ratgraph/asset/fonts/roboto.ttf", scaled_text_height, .{});
    defer font.deinit();

    const splash = graph.Texture.initFromImgFile(alloc, std.fs.cwd(), "small.png", .{}) catch edit.missingTexture();
    var os9gui = try Os9Gui.init(alloc, try std.fs.cwd().openDir("ratgraph", .{}), args.gui_scale orelse 2, .{
        .cache_dir = editor.dirs.pref,
        .font_size_px = args.gui_font_size orelse scaled_text_height,
        .item_height = args.gui_item_height orelse scaled_item_height,
    });
    defer os9gui.deinit();

    var gui = try G.Gui.init(alloc, &win, try std.fs.cwd().openDir("ratgraph", .{}), os9gui.font);
    defer gui.deinit();
    gui.style.config.default_item_h = scaled_item_height;
    gui.style.config.text_h = scaled_text_height;
    const gui_dstate = G.DrawState{ .ctx = &draw, .font = os9gui.font, .style = &gui.style, .gui = &gui };
    const inspector_win = InspectorWindow.create(&gui, editor);
    const pause_win = PauseWindow.create(&gui, editor);
    try gui.addWindow(&pause_win.vt, Rec(0, 300, 1000, 1000));
    try gui.addWindow(&inspector_win.vt, Rec(0, 300, 1000, 1000));

    try editor.panes.registerCustom("main_3d_view", editor_view.Main3DView, try editor_view.Main3DView.create(editor.panes.alloc, &os9gui));

    var loadctx = edit.LoadCtx{
        .draw = &draw,
        .font = &font,
        .win = &win,
        .splash = splash,
        .os9gui = &os9gui,
        .timer = try std.time.Timer.start(),
        .gtimer = load_timer,
        .expected_cb = 100,
    };

    loadctx.cb("Loading");

    var my_var: i32 = 0;
    my_var = my_var + 1;

    loadctx.cb("Vpk's mounted");

    vpk.timer.log("Vpk dir");

    var model_cam = graph.Camera3D{ .pos = Vec3.new(-100, 0, 0), .front = Vec3.new(1, 0, 0), .up = .z };
    model_cam.yaw = 0;
    var name_buf = std.ArrayList(u8).init(alloc);
    defer name_buf.deinit();

    editor.draw_state.cam3d.fov = config.window.cam_fov;
    var windows_list: [16]*G.iWindow = undefined;
    var win_count: usize = 0;

    if (args.vmf) |mapname| {
        if (std.mem.endsWith(u8, mapname, ".json")) {
            try editor.loadJson(std.fs.cwd(), mapname, &loadctx);
            //try editor.writeToJsonFile(std.fs.cwd(), "serial2.json");
        } else {
            try editor.loadVmf(std.fs.cwd(), mapname, &loadctx);
            //try editor.writeToJsonFile(std.fs.cwd(), "serial.json");
        }
    } else {
        //Put a default sky
        try editor.skybox.loadSky(try editor.storeString("sky_day01_01"), &editor.vpkctx);
    }

    //TODO with assets loaded dynamically, names might not be correct when saving before all loaded

    loadctx.time = loadctx.gtimer.read();

    graph.c.glEnable(graph.c.GL_CULL_FACE);
    graph.c.glCullFace(graph.c.GL_BACK);

    var areas_buf: [10]graph.Rect = undefined;

    //TODO rewrite the tab system to allow for full control over splitting
    var splits: [256]Split.Op = undefined;
    var panes: [256]editor_view.Pane = undefined;
    var SI: usize = 0;
    var PI: usize = 0;
    const Tab = editor_view.Tab;
    const tabs = [_]Tab{
        .{
            .split = Tab.newSplit(&splits, &SI, &.{ .{ .left, 0.7 }, .{ .top, 1 } }),
            .panes = Tab.newPane(&panes, &PI, &.{ .main_3d_view, .new_inspector }),
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
            .split = Tab.newSplit(&splits, &SI, &.{.{ .left, 1 }}),
            .panes = Tab.newPane(&panes, &PI, &.{.main_3d_view}),
        },
    };

    var last_frame_group_owner: ?edit.EcsT.Id = null;

    win.grabMouse(true);
    main_loop: while (!win.should_exit) {
        if (win.isBindState(config.keys.quit.b, .rising) or pause_win.should_exit)
            break :main_loop;
        if (win.isBindState(config.keys.pause.b, .rising))
            editor.paused = !editor.paused;

        if (editor.paused) {
            win.pumpEvents(.wait);
            win.grabMouse(false);
            try draw.begin(0x62d8e5ff, win.screen_dimensions.toF());

            {
                const winrect = graph.Rec(0, 0, draw.screen_dimensions.x, draw.screen_dimensions.y);
                const wins = &.{&pause_win.vt};
                try gui.pre_update(wins);
                try gui.updateWindowSize(&pause_win.vt, winrect);
                try gui.update(wins);
                try gui.draw(gui_dstate, false, wins);
                gui.drawFbos(&draw, wins);
            }

            try draw.end(editor.draw_state.cam3d);
            win.swap();
            continue;
        }
        try draw.begin(0x3d8891ff, win.screen_dimensions.toF());

        graph.c.glPolygonMode(
            graph.c.GL_FRONT_AND_BACK,
            if (editor.draw_state.tog.wireframe) graph.c.GL_LINE else graph.c.GL_FILL,
        );
        win.grabMouse(editor.draw_state.grab.is);
        win.pumpEvents(.poll);
        //if (win.mouse.pos.x >= draw.screen_dimensions.x - 40)
        //    graph.c.SDL_WarpMouseInWindow(win.win, 10, win.mouse.pos.y);

        if (win.keyRising(._9))
            editor.draw_state.tog.wireframe = !editor.draw_state.tog.wireframe;

        editor.edit_state.lmouse = win.mouse.left;
        editor.edit_state.rmouse = win.mouse.right;
        editor.edit_state.mpos = win.mouse.pos;
        if (os9gui.gui.window_index_grabbed_mouse != null) {
            //HACKY
            editor.edit_state.lmouse = .low;
            editor.edit_state.rmouse = .low;
        }

        const is_full: Gui.InputState = .{ .mouse = win.mouse, .key_state = &win.key_state, .keys = win.keys.slice(), .mod_state = win.mod };
        const is = if (editor.draw_state.grab.is) Gui.InputState{} else is_full;
        try os9gui.resetFrame(is, &win);

        const cam_state = graph.ptypes.Camera3D.MoveState{
            .down = win.bindHigh(config.keys.cam_down.b),
            .up = win.bindHigh(config.keys.cam_up.b),
            .left = win.bindHigh(config.keys.cam_strafe_l.b),
            .right = win.bindHigh(config.keys.cam_strafe_r.b),
            .fwd = win.bindHigh(config.keys.cam_forward.b),
            .bwd = win.bindHigh(config.keys.cam_back.b),
            .mouse_delta = if (editor.draw_state.grab.was) win.mouse.delta else .{ .x = 0, .y = 0 },
            .scroll_delta = win.mouse.wheel_delta.y,
            .speed_perc = if (win.bindHigh(config.keys.cam_slow.b)) 0.1 else 1,
        };

        graph.c.glEnable(graph.c.GL_BLEND);
        try editor.update(&win);
        for (config.keys.workspace.items, 0..) |b, i| {
            if (win.isBindState(b.b, .rising))
                editor.draw_state.tab_index = i;
        }

        const winrect = graph.Rec(0, 0, draw.screen_dimensions.x, draw.screen_dimensions.y);
        if (win.isBindState(config.keys.grid_inc.b, .rising))
            editor.edit_state.grid_snap *= 2;
        if (win.isBindState(config.keys.grid_dec.b, .rising))
            editor.edit_state.grid_snap /= 2;
        editor.edit_state.grid_snap = std.math.clamp(editor.edit_state.grid_snap, 1, 4096);
        editor.draw_state.tab_index = @min(editor.draw_state.tab_index, tabs.len - 1);

        const tab = tabs[editor.draw_state.tab_index];
        const areas = Split.fillBuf(tab.split, &areas_buf, winrect);
        {
            const state_btns = [_]graph.SDL.keycodes.Scancode{ ._1, ._2, ._3, ._4, ._5, ._6, ._7 };
            const num_field = editor.tools.vtables.items.len;
            //const num_field = @typeInfo(@TypeOf(editor.edit_state.state)).Enum.fields.len;
            for (state_btns, 0..) |sbtn, i| {
                if (i >= num_field)
                    break;
                if (win.keyRising(sbtn)) {
                    editor.edit_state.tool_index = i;
                    //editor.edit_state.state = @enumFromInt(i);
                }
            }
        }
        { //Hacks to update gui
            const new_id = editor.selection.getGroupOwnerExclusive(&editor.groups);
            if (new_id != last_frame_group_owner) {
                inspector_win.vt.needs_rebuild = true;
            }
            last_frame_group_owner = new_id;
        }

        try gui.pre_update(gui.windows.items);
        win_count = 0;
        for (tab.panes, 0..) |pane, p_i| {
            const pane_area = areas[p_i];
            const has_mouse = pane_area.containsPoint(win.mouse.pos);
            switch (pane) {
                .new_inspector => {
                    windows_list[win_count] = &inspector_win.vt;
                    try gui.updateWindowSize(&inspector_win.vt, pane_area);
                    win_count += 1;
                },
                else => try editor_view.drawPane(editor, pane, has_mouse, cam_state, &win, pane_area, &draw, &os9gui),
            }
        }
        {
            const wins = windows_list[0..win_count];
            //try gui.updateWindowSize(&pause_win.vt, winrect);
            //var time = try std.time.Timer.start();
            try gui.update(wins);
            try gui.draw(gui_dstate, false, wins);
            gui.drawFbos(&draw, wins);
            //std.debug.print("draw gui in: {d:.2} us\n", .{time.read() / std.time.ns_per_us});
        }
        editor.draw_state.grab.endFrame();

        try loadctx.loadedSplash(win.keys.len > 0);
        {
            //var time = try std.time.Timer.start();
            try os9gui.drawGui(&draw);
            //std.debug.print("draw gui in: {d:.2} us\n", .{time.read() / std.time.ns_per_us});
        }

        draw.setViewport(null);
        try draw.end(editor.draw_state.cam3d);
        win.swap();
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = if (IS_DEBUG) 0 else 0,
    }){};
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
        Arg("gui_font_size", .number, "pixel size of font"),
        Arg("gui_item_height", .number, "item height in pixels / gui_scale"),
        Arg("game", .string, "Name of a game defined in config.vdf"),
        Arg("custom_cwd", .string, "override the directory used for game"),
    }, &arg_it);
    try wrappedMain(alloc, args);

    // if the application is quit while items are being loaded in the thread pool, we get spammed with memory leaks.
    // There is no benefit to ensuring those items are free'd on exit.
    if (IS_DEBUG)
        _ = gpa.detectLeaks(); // Not deferred, so on error there isn't spam
}
