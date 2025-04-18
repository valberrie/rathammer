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
const vtf = @import("vtf.zig");
const fgd = @import("fgd.zig");
const Editor = @import("editor.zig").Context;
const Vec3 = V3f;
const util3d = @import("util_3d.zig");
const Os9Gui = graph.gui_app.Os9Gui;
const Gui = graph.Gui;

const LoadCtx = struct {
    buffer: [256]u8 = undefined,
    timer: std.time.Timer,
    draw: *graph.ImmediateDrawingContext,
    win: *graph.SDL.Window,
    font: *graph.Font,

    fn printCb(self: *@This(), comptime fmt: []const u8, args: anytype) void {
        //No need for high fps when loading, this is 15fps
        if (self.timer.read() / std.time.ns_per_ms < 66) {
            return;
        }
        var fbs = std.io.FixedBufferStream([]u8){ .buffer = &self.buffer, .pos = 0 };
        fbs.writer().print(fmt, args) catch return;
        self.cb(fbs.getWritten());
    }

    fn cb(self: *@This(), message: []const u8) void {
        if (self.timer.read() / std.time.ns_per_ms < 8) {
            return;
        }
        self.timer.reset();
        self.win.pumpEvents(.poll);
        self.draw.begin(0x222222ff, self.win.screen_dimensions.toF()) catch return;
        self.draw.text(.{ .x = 0, .y = 0 }, message, &self.font.font, 100, 0xffffffff);
        self.draw.end(null) catch return;
        self.win.swap(); //So the window doesn't look too broken while loading
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 0 }){};
    defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();

    var arg_it = try std.process.argsWithAllocator(alloc);
    defer arg_it.deinit();

    const Arg = graph.ArgGen.Arg;
    const args = try graph.ArgGen.parseArgs(&.{
        Arg("vmf", .string, "vmf to load"),
        Arg("scale", .number, "scale the model"),
    }, &arg_it);
    var draw_tools = true;

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
    var loadctx = LoadCtx{
        .draw = &draw,
        .font = &font,
        .win = &win,
        .timer = try std.time.Timer.start(),
    };
    var os9gui = try Os9Gui.init(alloc, try std.fs.cwd().openDir("ratgraph", .{}), 2);
    defer os9gui.deinit();
    var crass_scroll: graph.Vec2f = .{ .x = 0, .y = 0 };
    loadctx.cb("Loading");

    //const root = try std.fs.cwd().openDir("tf", .{});
    const hl_root = try std.fs.cwd().openDir("hl2", .{});
    //const ep_root = try std.fs.cwd().openDir("ep2", .{});
    //try vpkctx.addDir(root, "tf2_textures.vpk");
    //try vpkctx.addDir(root, "tf2_misc.vpk");

    try editor.vpkctx.addDir(hl_root, "hl2_misc.vpk");
    try editor.vpkctx.addDir(hl_root, "hl2_textures.vpk");
    try editor.vpkctx.addDir(hl_root, "hl2_pak.vpk");
    //try editor.vpkctx.addDir(ep_root, "ep2_pak.vpk");
    //materials/nature/red_grass
    if (false) {
        //canal_dock02a
        //models/props_junk/garbage_glassbottle001a
        const n = "canal_dock02a";
        const names = [_][]const u8{ n, n, n ++ ".dx90" };
        const path = "models/props_docks";
        const exts = [_][]const u8{ "mdl", "vvd", "vtx" };
        var buf: [256]u8 = undefined;
        var bb = std.io.FixedBufferStream([]u8){ .pos = 0, .buffer = &buf };
        for (exts, 0..) |ext, i| {
            bb.pos = 0;
            const outd = try std.fs.cwd().openDir("mdl", .{});
            const vmt = (try editor.vpkctx.getFileTemp(ext, path, names[i])) orelse {
                std.debug.print("Can't find {s}\n", .{ext});
                continue;
            };
            try bb.writer().print("out.{s}", .{ext});
            const mdl = try outd.createFile(bb.getWritten(), .{});
            try mdl.writer().writeAll(vmt);
        }
        //std.debug.print("{s}\n", .{(try editor.vpkctx.getFileTemp("vmt", "materials/concrete", "concretewall071a")) orelse ""});
        if (true)
            return;
    }
    loadctx.cb("Vpk's mounted");

    vpk.timer.log("Vpk dir");

    var fgd_ctx = fgd.EntCtx.init(alloc);
    defer fgd_ctx.deinit();
    try fgd.loadFgd(&fgd_ctx, try std.fs.cwd().openDir("Half-Life 2/bin", .{}), "halflife2.fgd");
    var icon_map = std.StringHashMap(graph.Texture).init(alloc);
    defer {
        icon_map.deinit();
    }
    {
        //Create an atlas for the icons
        var it = fgd_ctx.base.valueIterator();
        while (it.next()) |class| {
            if (class.iconsprite.len == 0) continue;
            const res = try icon_map.getOrPut(class.iconsprite);
            if (!res.found_existing) {
                const n = class.iconsprite[0 .. class.iconsprite.len - 4];
                std.debug.print("sprite {s}\n", .{n});
                res.value_ptr.* = try editor.loadTextureFromVpk(n);
            }
        }
    }

    //const infile = try std.fs.cwd().openFile("sdk_materials.vmf", .{});
    const infile = try std.fs.cwd().openFile(args.vmf orelse "sdk_materials.vmf", .{});
    defer infile.close();

    const slice = try infile.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(slice);
    var id: u32 = 0;

    var obj = try vdf.parse(alloc, slice);
    defer obj.deinit();
    loadctx.cb("vmf parsed");
    const basic_shader = try graph.Shader.loadFromFilesystem(alloc, std.fs.cwd(), &.{
        .{ .path = "ratgraph/asset/shader/gbuffer.vert", .t = .vert },
        .{ .path = "src/basic.frag", .t = .frag },
    });

    var aa = std.heap.ArenaAllocator.init(alloc);
    defer aa.deinit();
    const vmf_ = try vdf.fromValue(vmf.Vmf, &.{ .obj = &obj.value }, aa.allocator());
    {
        var gen_timer = try std.time.Timer.start();
        for (vmf_.world.solid, 0..) |solid, si| {
            try editor.putSolidFromVmf(solid);
            //try procSolid(&editor.csgctx, alloc, solid, &editor.meshmap, &editor.vpkctx);
            loadctx.printCb("csg generated {d} / {d}", .{ si, vmf_.world.solid.len });
            //try meshes.append(try csg.genMesh(solid.side, alloc));
        }
        for (vmf_.entity, 0..) |ent, ei| {
            loadctx.printCb("ent generated {d} / {d}", .{ ei, vmf_.entity.len });
            for (ent.solid) |solid|
                try editor.putSolidFromVmf(solid);
            try editor.ents.append(.{
                .origin = ent.origin.v.scale(1),
                .class = ent.classname,
            });
            //try procSolid(&editor.csgctx, alloc, solid, &editor.meshmap, &editor.vpkctx);
        }
        try editor.rebuildAllMeshes();
        const nm = editor.meshmap.count();
        const whole_time = gen_timer.read();

        std.debug.print("csg took {d} {d:.2} us\n", .{ nm, csg.gen_time / std.time.ns_per_us / nm });
        std.debug.print("Generated {d} meshes in {d:.2} ms\n", .{ nm, whole_time / std.time.ns_per_ms });
    }
    loadctx.cb("csg generated");

    const RcastItem = struct {
        id: u32,
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

    var frame: usize = 0;
    var cam = graph.Camera3D{};
    cam.up = .z;
    cam.move_speed = 50;
    cam.max_move_speed = 100;
    graph.c.glEnable(graph.c.GL_CULL_FACE);
    graph.c.glCullFace(graph.c.GL_BACK);

    var ort = graph.Rec(0, 0, 200, 200);
    var grab_mouse = true;
    var show_gui: bool = false;
    var textbox = Os9Gui.DynamicTextbox.init(alloc);
    defer textbox.deinit();
    var index: u32 = 0;
    var expanded = std.ArrayList(bool).init(alloc);
    try expanded.appendNTimes(false, editor.vpkctx.extensions.count());
    defer expanded.deinit();
    var displayed_slice = std.ArrayList(u8).init(alloc);
    defer displayed_slice.deinit();

    win.grabMouse(true);
    while (!win.should_exit) {
        try draw.begin(0x75573cff, win.screen_dimensions.toF());
        win.grabMouse(grab_mouse);
        win.pumpEvents(.poll);
        if (win.mouse.pos.x >= draw.screen_dimensions.x - 40)
            graph.c.SDL_WarpMouseInWindow(win.win, 10, win.mouse.pos.y);
        const last_frame_grabbed = grab_mouse;
        grab_mouse = (!win.keyHigh(.LSHIFT) and !show_gui);
        if (last_frame_grabbed and !grab_mouse) { //Mouse just ungrabbed
            //graph.c.SDL_WarpMouseInWindow(win.win, draw.screen_dimensions.x / 2, draw.screen_dimensions.y / 2);
        }
        const is: Gui.InputState = .{ .mouse = win.mouse, .key_state = &win.key_state, .keys = win.keys.slice(), .mod_state = win.mod };
        if (win.keyRising(._1))
            show_gui = !show_gui;

        if (win.keyRising(.TAB))
            draw_tools = !draw_tools;
        cam.updateDebugMove(.{
            .down = win.keyHigh(.LCTRL),
            .up = win.keyHigh(.SPACE),
            .left = win.keyHigh(.A),
            .right = win.keyHigh(.D),
            .fwd = win.keyHigh(.W),
            .bwd = win.keyHigh(.S),
            .mouse_delta = if (grab_mouse) win.mouse.delta else .{ .x = 0, .y = 0 },
            .scroll_delta = win.mouse.wheel_delta.y,
        });
        if (win.keyRising(._8)) {
            const ass = struct {
                export fn fileCb(_: ?*anyopaque, filelist: [*c]const [*c]const u8, filter: c_int) void {
                    _ = filter;
                    var i: usize = 0;
                    while (filelist[i]) |file| : (i += 1) {
                        std.debug.print("file{s}\n", .{file});
                    }
                }
            };
            var a2: i32 = 0;
            graph.c.SDL_ShowOpenFileDialog(&ass.fileCb, @ptrCast(&a2), win.win, null, 0, null, false);
        }

        //draw.rectTex(Rec(0, 0, 1000, 1000), my_tex.rect(), my_tex);
        draw.cube(V3f.new(0, 0, 0), V3f.new(64, 64, 64), 0xffffffff);
        const view_3d = cam.getMatrix(draw.screen_dimensions.x / draw.screen_dimensions.y, 0.1, 100000);
        var it = editor.meshmap.iterator();
        const mat = graph.za.Mat4.identity();
        //graph.c.glEnable(graph.c.GL_SCISSOR_TEST);
        //graph.c.glViewport(0, 0, @divFloor(win.screen_dimensions.x, 2), @divFloor(win.screen_dimensions.y, 2));
        //graph.c.glScissor(0, 0, @divFloor(win.screen_dimensions.x, 2), @divFloor(win.screen_dimensions.y, 2));
        //.rotate(-90, graph.za.Vec3.new(1, 0, 0));
        graph.c.glEnable(graph.c.GL_BLEND);
        while (it.next()) |mesh| {
            if (!draw_tools and std.mem.startsWith(u8, mesh.key_ptr.*, "TOOLS"))
                continue;
            mesh.value_ptr.mesh.drawSimple(view_3d, mat, basic_shader);
        }
        if (win.keyRising(.E)) {
            raycast_pot.clearRetainingCapacity();
            for (editor.set.dense.items, 0..) |solid, i| {
                const bb = &solid.bounding_box;
                //draw.cube(pos, ext, 0xffffffff);
                if (util3d.doesRayIntersectBBZ(cam.pos, cam.front, bb.a, bb.b)) |inter| {
                    const len = inter.distance(cam.pos);
                    try raycast_pot.append(.{ .id = @intCast(i), .dist = len });
                }
            }
            if (true) {
                raycast_pot_fine.clearRetainingCapacity();
                for (raycast_pot.items) |bp_rc| {
                    const solid = editor.set.dense.items[bp_rc.id];
                    for (solid.sides.items) |side| {
                        if (side.verts.items.len < 3) continue;
                        const plane = util3d.trianglePlane(side.verts.items[0..3].*);
                        if (util3d.doesRayIntersectConvexPolygon(
                            cam.pos,
                            cam.front,
                            plane,
                            side.verts.items,
                        )) |point| {
                            const len = point.distance(cam.pos);
                            try raycast_pot_fine.append(.{ .id = bp_rc.id, .dist = len, .point = point });
                        }
                    }
                }

                std.sort.insertion(RcastItem, raycast_pot_fine.items, {}, RcastItem.lessThan);
                if (raycast_pot_fine.items.len > 0) {
                    // std.debug.print("Count {d} {d}\n", .{ raycast_pot.items.len, raycast_pot_fine.items.len });
                    // for (raycast_pot_fine.items) |itt|
                    //     std.debug.print("ID: {d} {d} {}\n", .{ itt.id, itt.dist, itt.point });
                    id = raycast_pot_fine.items[0].id;
                }
            } else {
                std.sort.insertion(RcastItem, raycast_pot.items, {}, RcastItem.lessThan);
                if (raycast_pot.items.len > 0) {
                    id = raycast_pot.items[0].id;
                }
            }
        }

        try draw.flush(null, cam);
        if (false) {
            const w = @divFloor(win.screen_dimensions.x, 2);
            const h = @divFloor(win.screen_dimensions.y, 2);
            graph.c.glViewport(w, 0, w, h);
            graph.c.glScissor(w, 0, w, h);
            if (win.mouse.middle == .high) {
                ort.x += win.mouse.delta.x;
                ort.y += win.mouse.delta.y;
            }
            const ortho = graph.za.Mat4.orthographic(-400 + ort.x, 1000 + ort.x, -1000 + ort.y, 1000 + ort.y, -100, 1000);
            var it2 = editor.meshmap.iterator();
            graph.c.glPolygonMode(graph.c.GL_FRONT_AND_BACK, graph.c.GL_LINE);
            while (it2.next()) |mesh| {
                if (!draw_tools and std.mem.startsWith(u8, mesh.key_ptr.*, "TOOLS"))
                    continue;
                mesh.value_ptr.mesh.drawSimple(ortho, mat, basic_shader);
            }
            graph.c.glPolygonMode(graph.c.GL_FRONT_AND_BACK, graph.c.GL_FILL);
            //try draw.flush(null, null);
        }
        for (editor.ents.items) |ent| {
            draw.cubeFrame(ent.origin.sub(V3f.new(8, 8, 8)), graph.za.Vec3.new(16, 16, 16), 0x00ff00ff);
            if (fgd_ctx.base.get(ent.class)) |base| {
                if (icon_map.get(base.iconsprite)) |isp| {
                    draw.billboard(ent.origin, .{ .x = 16, .y = 16 }, isp.rect(), isp, cam);
                }
            }
        }

        graph.c.glDisable(graph.c.GL_SCISSOR_TEST);
        const cw = 4;
        graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
        draw.rect(graph.Rec(draw.screen_dimensions.x / 2 - cw, draw.screen_dimensions.y / 2 - cw, cw * 2, cw * 2), 0xffffffff);
        {
            if (editor.set.getOpt(id)) |solid| {
                //const bb = &solid.bounding_box;
                //draw.cube(bb.a, bb.b.sub(bb.a), 0xffffffff);
                for (solid.sides.items, 0..) |side, i| {
                    const v = side.verts.items;
                    for (0..@divFloor(side.verts.items.len, 2)) |ti| {
                        draw.line3D(v[ti], v[ti + 1], 0xff00ff);
                    }

                    if (i == 0) {
                        const v1 = v[(frame / 10) % v.len];
                        draw.point3D(v1, 0xff0000ff);
                        frame += 1;
                    }
                }
            }
            //id = (id + 1) % @as(u32, @intCast(editor.set.dense.items.len));
        }
        if (show_gui) {
            try os9gui.beginFrame(is, &win);
            const win_rect = graph.Rec(0, 0, draw.screen_dimensions.x, draw.screen_dimensions.y);
            if (try os9gui.beginTlWindow(win_rect)) {
                defer os9gui.endTlWindow();
                const gui = &os9gui.gui;
                if (gui.getArea()) |win_area| {
                    const area = win_area.inset(6 * os9gui.scale);
                    _ = try gui.beginLayout(Gui.SubRectLayout, .{ .rect = area }, .{});
                    defer gui.endLayout();

                    _ = try os9gui.beginH(2);
                    defer os9gui.endL();
                    if (try os9gui.beginVScroll(&crass_scroll, .{ .sw = area.w, .sh = 1000000 })) |scr| {
                        defer os9gui.endVScroll(scr);
                        scr.layout.padding.top = 0;
                        scr.layout.padding.bottom = 0;
                        index = 0;
                        {
                            var eit = editor.vpkctx.extensions.iterator();
                            var i: usize = 0;
                            while (eit.next()) |item| {
                                if (os9gui.button(item.key_ptr.*))
                                    expanded.items[i] = !expanded.items[i];

                                if (expanded.items[i]) {
                                    var pm = item.value_ptr.iterator();
                                    while (pm.next()) |p| {
                                        var cc = p.value_ptr.iterator();
                                        if (!std.mem.startsWith(u8, p.key_ptr.*, textbox.arraylist.items))
                                            continue;
                                        _ = os9gui.label("{s}", .{p.key_ptr.*});
                                        while (cc.next()) |c| {
                                            if (os9gui.buttonEx("        {s}", .{c.key_ptr.*}, .{})) {
                                                const sl = try editor.vpkctx.getFileTemp(item.key_ptr.*, p.key_ptr.*, c.key_ptr.*);
                                                displayed_slice.clearRetainingCapacity();
                                                try displayed_slice.appendSlice(sl.?);
                                            }
                                        }
                                    }
                                }
                                i += 1;
                            }
                        }

                        //os9gui.slider(&index, 0, 1000);
                        //scr.layout.pushHeight(area.w);
                        //const ar = gui.getArea() orelse return;
                        //gui.drawRectTextured(ar, 0xffffffff, graph.Rec(0, 0, 1, 1), .{ .id = index, .w = 1, .h = 1 });
                    }
                    {
                        _ = try os9gui.beginV();
                        defer os9gui.endL();
                        try os9gui.textbox2(&textbox, .{});

                        const ar = os9gui.gui.getArea().?;
                        os9gui.gui.drawText(displayed_slice.items, ar.pos(), 40, 0xff, os9gui.font);
                    }
                }
            }
            try os9gui.endFrame(&draw);
            graph.c.glDisable(graph.c.GL_STENCIL_TEST);
        }
        try draw.end(cam);
        win.swap();
    }
}
