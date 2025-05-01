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
const gameinfo = @import("gameinfo.zig");
const vtf = @import("vtf.zig");
const Vec3 = V3f;
const util3d = @import("util_3d.zig");
const Os9Gui = graph.gui_app.Os9Gui;
const guiutil = graph.gui_app;
const Gui = graph.Gui;
const vvd = @import("vvd.zig");

pub fn wrappedMain(alloc: std.mem.Allocator) !void {
    var arg_it = try std.process.argsWithAllocator(alloc);
    defer arg_it.deinit();

    const Arg = graph.ArgGen.Arg;
    const args = try graph.ArgGen.parseArgs(&.{
        Arg("vmf", .string, "vmf to load"),
        Arg("basedir", .string, "base directory of the game, \"Half-Life 2\""),
        Arg("gamedir", .string, "directory of gameinfo.txt, \"Half-Life 2/hl2\""),
        Arg("fgd", .string, "name of fgd file, relative to basedir/bin"),
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
    const game_dir = try std.fs.cwd().openDir(args.gamedir orelse "Half-Life 2/hl2", .{});

    try gameinfo.loadGameinfo(alloc, base_dir, game_dir, &editor.vpkctx);
    loadctx.cb("Vpk's mounted");

    vpk.timer.log("Vpk dir");

    const fgd_dir = try base_dir.openDir("bin", .{});
    try fgd.loadFgd(&editor.fgd_ctx, fgd_dir, args.fgd orelse "halflife2.fgd");
    var model_cam = graph.Camera3D{ .pos = Vec3.new(-100, 0, 0), .front = Vec3.new(1, 0, 0), .up = .z };
    model_cam.yaw = 0;
    var start_index: usize = 0;
    var num_column: usize = 6;
    var selected_index: usize = 0;
    var name_buf = std.ArrayList(u8).init(alloc);
    defer name_buf.deinit();
    var model_array = std.ArrayList(vpk.VpkResId).init(alloc);
    defer model_array.deinit();
    var model_array_sub = std.ArrayList(vpk.VpkResId).init(alloc);
    defer model_array_sub.deinit();

    var tex_array = std.ArrayList(vpk.VpkResId).init(alloc);
    defer tex_array.deinit();

    var tbox = Os9Gui.DynamicTextbox.init(alloc);
    defer tbox.deinit();
    var rebuild_tex_array = true;
    var tex_array_sub = std.ArrayList(vpk.VpkResId).init(alloc);
    defer tex_array_sub.deinit();
    {
        const ep = "materials/";
        const exclude_list = [_][]const u8{
            "models", "gamepadui", "skybox", "vgui", "particle", "console", "sprites", "backpack",
        };
        editor.vpkctx.mutex.lock();
        defer editor.vpkctx.mutex.unlock();
        const vmt = editor.vpkctx.extension_map.get("vmt") orelse return;
        const mdl = editor.vpkctx.extension_map.get("mdl") orelse return;
        var it = editor.vpkctx.entries.iterator();
        var excluded: usize = 0;
        outer: while (it.next()) |item| {
            const id = item.key_ptr.* >> 48;
            if (id == vmt) {
                if (std.mem.startsWith(u8, item.value_ptr.path, ep)) {
                    for (exclude_list) |ex| {
                        if (std.mem.startsWith(u8, item.value_ptr.path[ep.len..], ex)) {
                            excluded += 1;
                            continue :outer;
                        }
                    }
                }
                try tex_array.append(item.key_ptr.*);
            } else if (id == mdl) {
                try model_array.append(item.key_ptr.*);
            }
        }
        std.debug.print("excluded {d}\n", .{excluded});
    }

    //{ //Add all models to array
    //    var it = editor.vpkctx.extensions.get("mdl").?.iterator();
    //    while (it.next()) |path| {
    //        var ent = path.value_ptr.iterator();
    //        while (ent.next()) |entt|
    //            try model_array.append([2][]const u8{ path.key_ptr.*, entt.key_ptr.* });
    //    }
    //}

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
        //TODO add a cool down for wait events?
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

        //grab_mouse = !(win.keyHigh(.LSHIFT) or editor.edit_state.btn_x_trans == .high or editor.edit_state.btn_y_trans == .high or editor.edit_state.btn_z_trans == .high);
        grab_mouse = !(win.keyHigh(.LSHIFT) or editor.edit_state.show_gui);
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
        const split2 = split1[0].split(.vertical, split1[0].w * 0.5);
        const edit_split = if (editor.edit_state.gui_tab == .model) split2[0] else split1[0];
        try editor.update();
        if (win.keyRising(.T))
            editor.edit_state.show_gui = !editor.edit_state.show_gui;
        if (!editor.edit_state.show_gui) {
            try editor.draw3Dview(split1[0], &draw);
        } else if (try os9gui.beginTlWindow(edit_split)) {
            defer os9gui.endTlWindow();
            switch (try os9gui.beginTabs(&editor.edit_state.gui_tab)) {
                .model => {
                    if (rebuild_tex_array) {
                        start_index = 0;
                        rebuild_tex_array = false;
                        model_array_sub.clearRetainingCapacity();
                        const io = std.mem.indexOf;
                        for (model_array.items) |item| {
                            const tt = editor.vpkctx.entries.get(item) orelse continue;
                            if (io(u8, tt.path, tbox.arraylist.items) != null or io(u8, tt.name, tbox.arraylist.items) != null)
                                try model_array_sub.append(item);
                        }
                    }
                    const vl = try os9gui.beginV();
                    vl.padding.top = 0;
                    vl.padding.bottom = 0;
                    defer os9gui.endL();
                    os9gui.sliderEx(&start_index, 0, model_array.items.len, "", .{});
                    {
                        _ = try os9gui.beginH(2);
                        defer os9gui.endL();
                        const len = tbox.arraylist.items.len;
                        try os9gui.textbox2(&tbox, .{});
                        os9gui.label("Results {d}", .{model_array_sub.items.len});
                        if (len != tbox.arraylist.items.len)
                            rebuild_tex_array = true;
                    }
                    for (model_array_sub.items[start_index..], start_index..) |model, i| {
                        const tt = editor.vpkctx.entries.get(model) orelse continue;
                        if (os9gui.buttonEx("{s}/{s}", .{ tt.path, tt.name }, .{ .disabled = selected_index == i })) {
                            selected_index = i;
                        }
                        if (os9gui.gui.layout.last_requested_bounds == null) //Hacky
                            break;
                    }
                },
                .texture => {
                    if (rebuild_tex_array) {
                        start_index = 0;
                        rebuild_tex_array = false;
                        tex_array_sub.clearRetainingCapacity();
                        const io = std.mem.indexOf;
                        for (tex_array.items) |item| {
                            const tt = editor.vpkctx.entries.get(item) orelse continue;
                            if (io(u8, tt.path, tbox.arraylist.items) != null or io(u8, tt.name, tbox.arraylist.items) != null)
                                try tex_array_sub.append(item);
                        }
                    }

                    const vl = try os9gui.beginV();
                    defer os9gui.endL();
                    start_index = @min(start_index, tex_array_sub.items.len);
                    os9gui.sliderEx(&start_index, 0, @divFloor(tex_array_sub.items.len, num_column), "", .{});
                    os9gui.sliderEx(&num_column, 1, 10, "num column", .{});
                    const len = tbox.arraylist.items.len;
                    {
                        _ = try os9gui.beginH(2);
                        defer os9gui.endL();
                        try os9gui.textbox2(&tbox, .{});
                        os9gui.label("Results {d}", .{tex_array_sub.items.len});
                    }
                    if (len != tbox.arraylist.items.len)
                        rebuild_tex_array = true;
                    //const ar = os9gui.gui.getArea() orelse graph.Rec(0, 0, 0, 0);
                    vl.pushRemaining();
                    const scroll_area = os9gui.gui.getArea() orelse return error.broken;
                    os9gui.gui.draw9Slice(scroll_area, os9gui.style.getRect(.basic_inset), os9gui.style.texture, os9gui.scale);
                    const ins = scroll_area.inset(3 * os9gui.scale);
                    start_index = @min(start_index, model_array_sub.items.len);
                    _ = try os9gui.gui.beginLayout(Gui.SubRectLayout, .{ .rect = ins }, .{ .scissor = ins });
                    defer os9gui.gui.endLayout();

                    const nc: f32 = @floatFromInt(num_column);
                    _ = try os9gui.beginL(Gui.TableLayout{
                        .columns = @intCast(num_column),
                        .item_height = ins.w / nc,
                    });
                    defer os9gui.endL();
                    const acc_ind = @min(start_index * num_column, tex_array_sub.items.len);
                    //const missing = edit.missingTexture();
                    for (tex_array_sub.items[acc_ind..], acc_ind..) |model, i| {
                        const tex = editor.getTexture(model);
                        //if (tex.id == missing.id) {
                        try editor.loadTexture(model);
                        //continue;
                        //}
                        const area = os9gui.gui.getArea() orelse break;
                        const text_h = area.h / 8;
                        const click = os9gui.gui.clickWidget(area);
                        if (click == .click)
                            selected_index = i;
                        //os9gui.gui.drawRectFilled(area, 0xffff);
                        os9gui.gui.drawRectTextured(area, 0xffffffff, tex.rect(), tex);
                        const tr = graph.Rec(area.x, area.y + area.h - text_h, area.w, text_h);
                        os9gui.gui.drawRectFilled(tr, 0xff);
                        const tt = editor.vpkctx.entries.get(model) orelse continue;
                        os9gui.gui.drawTextFmt(
                            "{s}/{s}",
                            .{ tt.path, tt.name },
                            tr,
                            text_h,
                            0xffffffff,
                            .{},
                            os9gui.font,
                        );
                        //os9gui.label("{s}/{s}", .{ model[0], model[1] });
                    }
                },
                else => {},
            }
            os9gui.endTabs();
        }
        if (editor.edit_state.show_gui and editor.edit_state.gui_tab == .model) {
            if (selected_index < model_array_sub.items.len) {
                const sp = split2[1];
                const mouse_in = split2[1].containsPoint(win.mouse.pos);
                model_cam.updateDebugMove(.{
                    .down = win.keyHigh(.LCTRL),
                    .up = win.keyHigh(.SPACE),
                    .left = win.keyHigh(.A),
                    .right = win.keyHigh(.D),
                    .fwd = win.keyHigh(.W),
                    .bwd = win.keyHigh(.S),
                    .mouse_delta = if (mouse_in and win.mouse.left == .high) win.mouse.delta else .{ .x = 0, .y = 0 },
                    .scroll_delta = win.mouse.wheel_delta.y,
                });
                const screen_area = split2[1];
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

                const modid = model_array_sub.items[selected_index];
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
                //const name = "models/props_wasteland/exterior_fence002d.mdl";
                //if (editor.models.getPtr(name_buf.items)) |mod| {
                //    const view = model_cam.getMatrix(1, 1, 64 * 512);
                //    const mat = graph.za.Mat4.identity();
                //    mod.drawSimple(view, mat, editor.draw_state.basic_shader);
                //} else {
                //    //std.debug.print("Could not find the model!\n", .{});
                //}
                try draw.flush(null, model_cam);
            }
        }
        try editor.drawInspector(split1[1], &os9gui);
        if (!last_frame_grabbed and split1[1].containsPoint(win.mouse.pos))
            grab_mouse = false;
        if (win.keyRising(.E)) {
            editor.edit_state.state = .select;
            //var rcast_timer = try std.time.Timer.start();
            //defer std.debug.print("Rcast took {d} us\n", .{rcast_timer.read() / std.time.ns_per_us});
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
                            // triangulate using csg
                            // for each tri call mollertrumbor, breaking if enc
                            const ind = try editor.csgctx.triangulateAny(side.verts.items, 0);
                            const ts = side.verts.items;
                            const ro = editor.draw_state.cam3d.pos;
                            const rd = editor.draw_state.cam3d.front;
                            for (0..@divExact(ind.len, 3)) |i_i| {
                                const i = i_i * 3;

                                if (util3d.mollerTrumboreIntersection(
                                    ro,
                                    rd,
                                    ts[ind[i]],
                                    ts[ind[i + 1]],
                                    ts[ind[i + 2]],
                                )) |inter| {
                                    const len = inter.distance(editor.draw_state.cam3d.pos);
                                    try raycast_pot_fine.append(.{ .id = bp_rc.id, .dist = len, .point = inter });
                                    break;
                                }
                            }

                            //const plane = util3d.trianglePlane(side.verts.items[0..3].*);
                            //if (util3d.doesRayIntersectConvexPolygon(
                            //    editor.draw_state.cam3d.pos,
                            //    editor.draw_state.cam3d.front,
                            //    plane,
                            //    side.verts.items,
                            //)) |point| {
                            //    const len = point.distance(editor.draw_state.cam3d.pos);
                            //    try raycast_pot_fine.append(.{ .id = bp_rc.id, .dist = len, .point = point });
                            //}
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 0 }){};
    const alloc = gpa.allocator();
    try wrappedMain(alloc);
    _ = gpa.detectLeaks(); // Not deferred, so on error there isn't spam
}
