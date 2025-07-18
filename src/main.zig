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
const panereg = @import("pane.zig");

const Conf = @import("config.zig");

//Deprecate this please
//wrapper to make the old gui stuff work with pane reg
//singleton on kind
pub const OldGuiPane = struct {
    const Self = @This();
    const guis = graph.RGui;
    const Gui = guis.Gui;

    const Kind = enum {
        texture,
        model,
        model_view,
    };

    vt: panereg.iPane,

    editor: *Editor,
    os9gui: *Os9Gui,
    kind: Kind,

    pub fn create(alloc: std.mem.Allocator, ed: *Editor, kind: Kind, os9gui: *Os9Gui) !*panereg.iPane {
        var ret = try alloc.create(@This());
        ret.* = .{
            .vt = .{
                .deinit_fn = &deinit,
                .draw_fn = &draw_fn,
            },
            .kind = kind,
            .os9gui = os9gui,
            .editor = ed,
        };
        return &ret.vt;
    }

    pub fn draw_fn(vt: *panereg.iPane, pane_area: graph.Rect, editor: *Editor, vd: panereg.ViewDrawState, pane_id: panereg.PaneId) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        switch (self.kind) {
            .model => {
                editor.asset_browser.drawEditWindow(pane_area, self.os9gui, editor, .model) catch return;
            },
            .texture => {
                editor.asset_browser.drawEditWindow(pane_area, self.os9gui, editor, .texture) catch return;
            },
            .model_view => {
                _ = editor.draw_state.grab_pane.trySetGrab(pane_id, editor.win.mouse.left == .high);
                editor.asset_browser.drawModelPreview(
                    editor.win,
                    pane_area,
                    vd.camstate,
                    editor,
                    vd.draw,
                ) catch return;
            },
        }
    }

    pub fn deinit(vt: *panereg.iPane, alloc: std.mem.Allocator) void {
        const self: *@This() = @alignCast(@fieldParentPtr("vt", vt));
        alloc.destroy(self);
    }
};

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
    try draw.begin(0x3d8891ff, win.screen_dimensions.toF());
    try editor.update(win);

    {
        const max_w = gui.style.config.default_item_h * 30;
        const area = graph.Rec(0, 0, draw.screen_dimensions.x, draw.screen_dimensions.y);
        const w = @min(max_w, area.w);
        const side_l = (area.w - w);
        const winrect = area.replace(side_l, null, w, null);
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
        .frame_sync = .adaptive_vsync,
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

    const main_3d_id = try editor.panes.add(try editor_view.Main3DView.create(editor.panes.alloc, &os9gui));
    const main_2d_id = try editor.panes.add(try Ctx2dView.create(editor.panes.alloc));
    const inspector_pane = try editor.panes.add(try panereg.GuiPane.create(editor.panes.alloc, &gui, &inspector_win.vt));
    const texture_pane = try editor.panes.add(try OldGuiPane.create(editor.panes.alloc, editor, .texture, &os9gui));
    const model_pane = try editor.panes.add(try OldGuiPane.create(editor.panes.alloc, editor, .model, &os9gui));
    const model_preview_pane = try editor.panes.add(try OldGuiPane.create(editor.panes.alloc, editor, .model_view, &os9gui));

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
    var panes: [256]panereg.PaneId = undefined;
    var SI: usize = 0;
    var PI: usize = 0;
    const Tab = editor_view.Tab;
    const tabs = [_]Tab{
        .{
            .split = Tab.newSplit(&splits, &SI, &.{ .{ .left, 0.7 }, .{ .top, 1 } }),
            .panes = Tab.newPane(&panes, &PI, &.{ main_3d_id, inspector_pane }),
        },
        .{
            .split = Tab.newSplit(&splits, &SI, &.{.{ .left, 1 }}),
            .panes = Tab.newPane(&panes, &PI, &.{texture_pane}),
        },
        .{
            .split = Tab.newSplit(&splits, &SI, &.{ .{ .left, 0.6 }, .{ .left, 1 } }),
            .panes = Tab.newPane(&panes, &PI, &.{ model_pane, model_preview_pane }),
        },
        .{
            .split = Tab.newSplit(&splits, &SI, &.{ .{ .left, 0.5 }, .{ .left, 1 } }),
            .panes = Tab.newPane(&panes, &PI, &.{ main_3d_id, main_2d_id }),
        },
    };

    var last_frame_group_owner: ?edit.EcsT.Id = null;

    var frame_timer = try std.time.Timer.start();
    var frame_time: u64 = 0;
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
        frame_time = frame_timer.read();
        frame_timer.reset();
        const perc_of_60fps: f32 = @as(f32, @floatFromInt(frame_time)) / std.time.ns_per_ms / 16;
        //if (win.mouse.pos.x >= draw.screen_dimensions.x - 40)
        //    graph.c.SDL_WarpMouseInWindow(win.win, 10, win.mouse.pos.y);

        editor.edit_state.mpos = win.mouse.pos;

        const is_full: Gui.InputState = .{ .mouse = win.mouse, .key_state = &win.key_state, .keys = win.keys.slice(), .mod_state = win.mod };
        const is = is_full;
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
            .speed_perc = @as(f32, if (win.bindHigh(config.keys.cam_slow.b)) 0.1 else 1) * perc_of_60fps,
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
        for (tab.panes, 0..) |pane, p_i| {
            const pane_area = areas[p_i];
            if (editor.panes.get(pane)) |pane_vt| {
                const owns = editor.draw_state.grab_pane.tryOwn(pane_area, &win, pane);
                editor.draw_state.grab_pane.current_stack_pane = pane;
                if (owns) {
                    editor.edit_state.lmouse = win.mouse.left;
                    editor.edit_state.rmouse = win.mouse.right;
                } else {
                    editor.edit_state.lmouse = .low;
                    editor.edit_state.rmouse = .low;
                }
                if (pane_vt.draw_fn) |drawf| {
                    drawf(pane_vt, pane_area, editor, .{ .draw = &draw, .win = &win, .camstate = cam_state }, pane);
                }
            }
        }
        if (console_active) {
            try gui.update(&.{&console_win.vt});
            try gui.window_collector.append(&console_win.vt);
        }

        editor.draw_state.grab_pane.endFrame();

        try os9gui.drawGui(&draw);
        const wins = gui.window_collector.items;
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
