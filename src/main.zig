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
const Editor = @import("editor.zig").Context;
const util3d = @import("util_3d.zig");

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
    loadctx.cb("Loading");

    //const root = try std.fs.cwd().openDir("tf", .{});
    const hl_root = try std.fs.cwd().openDir("hl2", .{});
    //const ep_root = try std.fs.cwd().openDir("ep2", .{});
    //try vpkctx.addDir(root, "tf2_textures.vpk");
    //try vpkctx.addDir(root, "tf2_misc.vpk");

    try editor.vpkctx.addDir(hl_root, "hl2_misc.vpk");
    try editor.vpkctx.addDir(hl_root, "hl2_textures.vpk");
    //try editor.vpkctx.addDir(ep_root, "ep2_pak.vpk");
    //materials/nature/red_grass
    //std.debug.print("{s}\n", .{(try editor.vpkctx.getFileTemp("vmt", "materials/concrete", "concretewall071a")) orelse ""});
    loadctx.cb("Vpk's mounted");

    vpk.timer.log("Vpk dir");
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

        pub fn lessThan(_: void, a: @This(), b: @This()) bool {
            return a.dist < b.dist;
        }
    };
    var raycast_pot = std.ArrayList(RcastItem).init(alloc);
    defer raycast_pot.deinit();

    var raycast_pot_fine = std.ArrayList(RcastItem).init(alloc);
    defer raycast_pot_fine.deinit();

    var cam = graph.Camera3D{};
    cam.up = .z;
    cam.move_speed = 50;
    cam.max_move_speed = 100;
    graph.c.glEnable(graph.c.GL_CULL_FACE);
    graph.c.glCullFace(graph.c.GL_BACK);

    win.grabMouse(true);
    while (!win.should_exit) {
        try draw.begin(0x75573cff, win.screen_dimensions.toF());
        win.pumpEvents(.poll);
        if (win.keyRising(.TAB))
            draw_tools = !draw_tools;
        cam.updateDebugMove(.{
            .down = win.keyHigh(.LSHIFT),
            .up = win.keyHigh(.SPACE),
            .left = win.keyHigh(.A),
            .right = win.keyHigh(.D),
            .fwd = win.keyHigh(.W),
            .bwd = win.keyHigh(.S),
            .mouse_delta = win.mouse.delta,
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
        draw.cube(V3f.new(0, 0, 0), V3f.new(1, 1, 1), 0xffffffff);
        //graph.c.glPolygonMode(graph.c.GL_FRONT_AND_BACK, graph.c.GL_LINE);
        const view_3d = cam.getMatrix(draw.screen_dimensions.x / draw.screen_dimensions.y, 0.1, 100000);
        var it = editor.meshmap.iterator();
        const mat = graph.za.Mat4.identity();
        //.rotate(-90, graph.za.Vec3.new(1, 0, 0));
        graph.c.glEnable(graph.c.GL_BLEND);
        while (it.next()) |mesh| {
            if (!draw_tools and std.mem.startsWith(u8, mesh.key_ptr.*, "TOOLS"))
                continue;
            mesh.value_ptr.mesh.drawSimple(view_3d, mat, basic_shader);
        }
        if (win.mouse.left == .rising) {
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
                        if (util3d.doesRayIntersectConvexPlanarPolygon(
                            cam.pos,
                            cam.front,
                            plane,
                            side.verts.items,
                        )) |point| {
                            const len = point.distance(cam.pos);
                            try raycast_pot_fine.append(.{ .id = bp_rc.id, .dist = len });
                        }
                    }
                }

                std.sort.insertion(RcastItem, raycast_pot_fine.items, {}, RcastItem.lessThan);
                if (raycast_pot_fine.items.len > 0) {
                    std.debug.print("Count {d} {d}\n", .{ raycast_pot.items.len, raycast_pot_fine.items.len });
                    for (raycast_pot_fine.items) |itt|
                        std.debug.print("ID: {d} {d}\n", .{ itt.id, itt.dist });
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
        const cw = 4;
        graph.c.glClear(graph.c.GL_DEPTH_BUFFER_BIT);
        draw.rect(graph.Rec(draw.screen_dimensions.x / 2 - cw, draw.screen_dimensions.y / 2 - cw, cw * 2, cw * 2), 0xffffffff);
        {
            if (editor.set.getOpt(id)) |solid| {
                //const bb = &solid.bounding_box;
                //draw.cube(bb.a, bb.b.sub(bb.a), 0xffffffff);
                for (solid.sides.items) |side| {
                    const v = side.verts.items;
                    for (0..@divFloor(side.verts.items.len, 2)) |ti| {
                        draw.line3D(v[ti], v[ti + 1], 0xff00ff);
                    }
                    for (side.verts.items) |v1|
                        draw.point3D(v1, 0xff0000ff);
                }
            }
            //id = (id + 1) % @as(u32, @intCast(editor.set.dense.items.len));
        }
        try draw.end(cam);
        win.swap();
    }
}
