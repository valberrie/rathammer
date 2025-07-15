const std = @import("std");
const builtin = @import("builtin");
const IS_DEBUG = builtin.mode == .Debug;
const util = @import("util.zig");

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
const ConsoleWindow = @import("windows/console.zig").Console;
const InspectorWindow = @import("windows/inspector.zig").InspectorWindow;
const Ctx2dView = @import("view_2d.zig").Ctx2dView;

const Conf = @import("config.zig");

pub fn dpiDetect(win: *graph.SDL.Window) !f32 {
    const sc = graph.c.SDL_GetWindowDisplayScale(win.win);
    if (sc == 0)
        return error.sdl;
    return sc;
}

var font_ptr: *graph.OnlineFont = undefined;
fn flush_cb() void {
    font_ptr.syncBitmapToGL();
}

pub fn pauseLoop(win: *graph.SDL.Window, draw: *graph.ImmediateDrawingContext, pause_win: *PauseWindow, gui: *G.Gui, gui_dstate: G.DrawState, loadctx: *edit.LoadCtx, editor: *Editor) !enum { cont, exit, unpause } {
    if (!editor.paused)
        return .unpause;
    if (win.isBindState(editor.config.keys.quit.b, .rising) or pause_win.should_exit)
        return .exit;
    win.pumpEvents(.wait);
    win.grabMouse(false);
    try draw.begin(0x62d8e5ff, win.screen_dimensions.toF());
    try editor.update(win);

    {
        const winrect = graph.Rec(0, 0, draw.screen_dimensions.x, draw.screen_dimensions.y);
        const wins = &.{&pause_win.vt};
        try gui.pre_update(wins);
        try gui.updateWindowSize(&pause_win.vt, winrect);
        try gui.update(wins);
        try gui.draw(gui_dstate, false, wins);
        gui.drawFbos(draw, wins);
    }
    try draw.flush(null, null);
    try loadctx.loadedSplash(win.keys.len > 0);

    try draw.end(editor.draw_state.cam3d);
    win.swap();
    return .cont;
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

    const Preset = struct {
        dpi: f32 = 1,
        fh: f32 = 25,
        ih: f32 = 14,
        scale: f32 = 2,

        pub fn distance(_: void, item: @This(), key: @This()) f32 {
            return @abs(item.dpi - key.dpi);
        }
    };

    const DPI_presets = [_]Preset{
        .{ .dpi = 1, .fh = 14, .ih = 25, .scale = 1 },
        .{ .dpi = 1.7, .fh = 24, .ih = 42 },
    };
    const sc = args.display_scale orelse try dpiDetect(&win);
    edit.log.info("Detected a display scale of {d}", .{sc});
    const dpi_preset = blk: {
        const default_scaled = Preset{ .fh = 20 * sc, .ih = 25 * sc, .scale = 2 };
        const max_dpi_diff = 0.3;
        const index = util.nearest(Preset, &DPI_presets, {}, Preset.distance, .{ .dpi = sc }) orelse break :blk default_scaled;
        const p = DPI_presets[index];
        if (@abs(p.dpi - sc) > max_dpi_diff)
            break :blk default_scaled;
        edit.log.info("Matching dpi preset number: {d}, display scale: {d}, font_height {d}, item_height {d},", .{ index, p.dpi, p.fh, p.ih });
        break :blk p;
    };

    const scaled_item_height = args.gui_item_height orelse @trunc(dpi_preset.ih);
    const scaled_text_height = args.gui_font_size orelse @trunc(dpi_preset.fh);
    const gui_scale = args.gui_scale orelse dpi_preset.scale;
    edit.log.info("gui Size: {d} text ", .{scaled_text_height});

    if (!graph.SDL.Window.glHasExtension("GL_EXT_texture_compression_s3tc")) return error.glMissingExt;
    var draw = graph.ImmediateDrawingContext.init(alloc);
    defer draw.deinit();
    var font = try graph.Font.init(alloc, std.fs.cwd(), args.fontfile orelse "ratgraph/asset/fonts/roboto.ttf", scaled_text_height, .{
        .codepoints_to_load = &(graph.Font.CharMaps.Default),
    });
    defer font.deinit();
    const splash = graph.Texture.initFromImgFile(alloc, std.fs.cwd(), "small.png", .{}) catch edit.missingTexture();

    var loadctx = edit.LoadCtx{
        .draw = &draw,
        .font = &font,
        .win = &win,
        .splash = splash,
        .timer = try std.time.Timer.start(),
        .gtimer = load_timer,
        .expected_cb = 100,
    };
    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();

    var editor = try Editor.init(alloc, if (args.nthread) |nt| @intFromFloat(nt) else null, config, args, &win, &loadctx, &env);
    defer editor.deinit();

    var os9gui = try Os9Gui.init(alloc, try std.fs.cwd().openDir("ratgraph", .{}), gui_scale, .{
        .cache_dir = editor.dirs.pref,
        .font_size_px = scaled_text_height,
        .item_height = scaled_item_height,
    });
    defer os9gui.deinit();
    draw.preflush_cb = &flush_cb;
    font_ptr = os9gui.ofont;

    loadctx.cb("Loading gui");
    var gui = try G.Gui.init(alloc, &win, editor.dirs.pref, try std.fs.cwd().openDir("ratgraph", .{}), &font.font);
    defer gui.deinit();
    gui.style.config.default_item_h = scaled_item_height;
    gui.style.config.text_h = scaled_text_height;
    gui.scale = gui_scale;
    const gui_dstate = G.DrawState{
        .ctx = &draw,
        .font = &font.font,
        .style = &gui.style,
        .gui = &gui,
        .scale = gui_scale,
    };
    const inspector_win = InspectorWindow.create(&gui, editor);
    const pause_win = try PauseWindow.create(&gui, editor);
    try gui.addWindow(&pause_win.vt, Rec(0, 300, 1000, 1000));
    try gui.addWindow(&inspector_win.vt, Rec(0, 300, 1000, 1000));

    var console_active = false;
    const console_win = try ConsoleWindow.create(&gui, editor, &editor.shell.cb_vt);
    try gui.addWindow(&console_win.vt, Rec(0, 0, 800, 600));

    try editor.panes.registerCustom("main_3d_view", editor_view.Main3DView, try editor_view.Main3DView.create(editor.panes.alloc, &os9gui));
    try editor.panes.registerCustom("main_2d_view", Ctx2dView, try Ctx2dView.create(editor.panes.alloc));

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
        try editor.loadMap(std.fs.cwd(), mapname, &loadctx);
    } else {
        while (!win.should_exit) {
            switch (try pauseLoop(&win, &draw, pause_win, &gui, gui_dstate, &loadctx, editor)) {
                .exit => break,
                .unpause => break,
                .cont => continue,
            }
        }
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
            .split = Tab.newSplit(&splits, &SI, &.{ .{ .left, 0.6 }, .{ .top, 1 } }),
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
            .split = Tab.newSplit(&splits, &SI, &.{ .{ .left, 0.5 }, .{ .left, 1 } }),
            .panes = Tab.newPane(&panes, &PI, &.{ .main_3d_view, .main_2d_view }),
        },
        .{
            .split = Tab.newSplit(&splits, &SI, &.{ .{ .left, 0.6 }, .{ .top, 1 } }),
            .panes = Tab.newPane(&panes, &PI, &.{ .console, .new_inspector }),
        },
    };

    var last_frame_group_owner: ?edit.EcsT.Id = null;

    win.grabMouse(true);
    main_loop: while (!win.should_exit) {
        if (win.isBindState(config.keys.quit.b, .rising) or pause_win.should_exit)
            break :main_loop;
        if (win.isBindState(config.keys.pause.b, .rising)) {
            editor.paused = !editor.paused;
        }
        if (console_active)
            editor.draw_state.grab_pane.override();

        if (editor.paused) {
            switch (try pauseLoop(&win, &draw, pause_win, &gui, gui_dstate, &loadctx, editor)) {
                .cont => continue :main_loop,
                .exit => break :main_loop,
                .unpause => editor.paused = false,
            }
        }
        try draw.begin(0x3d8891ff, win.screen_dimensions.toF());

        //win.grabMouse(editor.draw_state.grab.is);
        win.grabMouse(editor.draw_state.grab_pane.was_grabbed);
        win.pumpEvents(.poll);
        //if (win.mouse.pos.x >= draw.screen_dimensions.x - 40)
        //    graph.c.SDL_WarpMouseInWindow(win.win, 10, win.mouse.pos.y);

        const owner_3d = editor.draw_state.grab_pane.owner == .main_3d_view;
        editor.edit_state.mpos = win.mouse.pos;
        if (owner_3d) {
            editor.edit_state.lmouse = win.mouse.left;
            editor.edit_state.rmouse = win.mouse.right;
        } else {
            editor.edit_state.lmouse = .low;
            editor.edit_state.rmouse = .low;
        }

        const is_full: Gui.InputState = .{ .mouse = win.mouse, .key_state = &win.key_state, .keys = win.keys.slice(), .mod_state = win.mod };
        const is = if (owner_3d) Gui.InputState{} else is_full;
        try os9gui.resetFrame(is, &win);

        const cam_state = graph.ptypes.Camera3D.MoveState{
            .down = win.bindHigh(config.keys.cam_down.b),
            .up = win.bindHigh(config.keys.cam_up.b),
            .left = win.bindHigh(config.keys.cam_strafe_l.b),
            .right = win.bindHigh(config.keys.cam_strafe_r.b),
            .fwd = win.bindHigh(config.keys.cam_forward.b),
            .bwd = win.bindHigh(config.keys.cam_back.b),
            .mouse_delta = if (editor.draw_state.grab_pane.was_grabbed) win.mouse.delta else .{ .x = 0, .y = 0 },
            .scroll_delta = win.mouse.wheel_delta.y,
            .speed_perc = if (win.bindHigh(config.keys.cam_slow.b)) 0.1 else 1,
        };

        const winrect = graph.Rec(0, 0, draw.screen_dimensions.x, draw.screen_dimensions.y);
        graph.c.glEnable(graph.c.GL_BLEND);
        try editor.update(&win);
        editor.handleMisc3DKeys(&tabs);

        { //Hacks to update gui
            const new_id = editor.selection.getGroupOwnerExclusive(&editor.groups);
            const tool_changed = editor.edit_state.last_frame_tool_index != editor.edit_state.tool_index;
            if (new_id != last_frame_group_owner or tool_changed) {
                inspector_win.vt.needs_rebuild = true;
            }
            last_frame_group_owner = new_id;
        }
        const tab = tabs[editor.draw_state.tab_index];
        const areas = Split.fillBuf(tab.split, &areas_buf, winrect);

        try gui.pre_update(gui.windows.items);
        if (win.isBindState(config.keys.toggle_console.b, .rising)) {
            console_active = !console_active;
            if (console_active) {
                console_win.area.dirty(&gui);
            }
        }
        win_count = 0;
        for (tab.panes, 0..) |pane, p_i| {
            const pane_area = areas[p_i];
            switch (pane) {
                .new_inspector, .console => {
                    {
                        const win_vt = switch (pane) {
                            .new_inspector => &inspector_win.vt,
                            .console => &console_win.vt,
                            else => unreachable,
                        };
                        const owns = editor.draw_state.grab_pane.tryOwn(pane_area, &win, pane);
                        windows_list[win_count] = win_vt;
                        try gui.updateWindowSize(win_vt, pane_area);
                        //The reason sometimes the console fails is because it does not own it when it gets switch ed to
                        if (owns)
                            try gui.update(&.{win_vt});
                        win_count += 1;
                    }
                },
                else => try editor_view.drawPane(editor, pane, cam_state, &win, pane_area, &draw, &os9gui),
            }
        }
        if (console_active) {
            try gui.update(&.{&console_win.vt});
            windows_list[win_count] = &console_win.vt;
            win_count += 1;
        }

        editor.draw_state.grab_pane.endFrame();

        try os9gui.drawGui(&draw);
        const wins = windows_list[0..win_count];
        try gui.draw(gui_dstate, false, wins);
        gui.drawFbos(&draw, wins);

        draw.setViewport(null);
        try loadctx.loadedSplash(win.keys.len > 0);
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
        Arg("fontfile", .string, "load custom font"),
        Arg("display_scale", .number, "override detected display scale, should be ~ 0.2-3"),
    }, &arg_it);
    try wrappedMain(alloc, args);

    // if the application is quit while items are being loaded in the thread pool, we get spammed with memory leaks.
    // There is no benefit to ensuring those items are free'd on exit.
    if (IS_DEBUG)
        _ = gpa.detectLeaks(); // Not deferred, so on error there isn't spam
}
