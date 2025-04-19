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
const edit = @import("editor.zig");
const Editor = @import("editor.zig").Context;
const Vec3 = V3f;
const util3d = @import("util_3d.zig");
const Os9Gui = graph.gui_app.Os9Gui;
const guiutil = graph.gui_app;
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

    try fgd.loadFgd(&editor.fgd_ctx, try std.fs.cwd().openDir("Half-Life 2/bin", .{}), "halflife2.fgd");
    {
        //Create an atlas for the icons
        var it = editor.fgd_ctx.base.valueIterator();
        while (it.next()) |class| {
            if (class.iconsprite.len == 0) continue;
            const res = try editor.icon_map.getOrPut(class.iconsprite);
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

    var obj = try vdf.parse(alloc, slice);
    defer obj.deinit();
    loadctx.cb("vmf parsed");

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
            {
                const new = try editor.ecs.createEntity();
                try editor.ecs.attach(new, .entity, .{
                    .origin = ent.origin.v,
                    .class = ent.classname,
                });
                try editor.ecs.attach(new, .bounding_box, .{
                    .a = ent.origin.v.sub(Vec3.new(8, 8, 8)),
                    .b = ent.origin.v.add(Vec3.new(8, 8, 8)),
                });
            }

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

    win.grabMouse(true);
    while (!win.should_exit) {
        try draw.begin(0x75573cff, win.screen_dimensions.toF());
        win.grabMouse(grab_mouse);
        win.pumpEvents(.poll);
        //if (win.mouse.pos.x >= draw.screen_dimensions.x - 40)
        //    graph.c.SDL_WarpMouseInWindow(win.win, 10, win.mouse.pos.y);
        defer last_frame_grabbed = grab_mouse;
        grab_mouse = (!win.keyHigh(.LSHIFT));
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
