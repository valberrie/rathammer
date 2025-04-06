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

pub fn missingTexture() graph.Texture {
    const static = struct {
        const m = [3]u8{ 0xfc, 0x05, 0xbe };
        const b = [3]u8{ 0x0, 0x0, 0x0 };
        const data = m ++ b ++ b ++ m;
        //const data = [_]u8{ 0xfc, 0x05, 0xbe, b,b,b, };
        var texture: ?graph.Texture = null;
    };

    if (static.texture == null) {
        static.texture = graph.Texture.initFromBuffer(
            &static.data,
            2,
            2,
            .{
                .pixel_format = graph.c.GL_RGB,
                .pixel_store_alignment = 3,
                .mag_filter = graph.c.GL_NEAREST,
            },
        );
        static.texture.?.w = 100; //Zoom the texture out
        static.texture.?.h = 100;
    }
    return static.texture.?;
}

var texture_time: u64 = 0;
fn procSolid(
    csgctx: *csg.Context,
    alloc: std.mem.Allocator,
    solid: vmf.Solid,
    matmap: *csg.MeshMap,
    vpkctx: *vpk.Context,
) !void {
    var lower_buf: [256]u8 = undefined;
    var buf: [256]u8 = undefined;
    var fbs = std.io.FixedBufferStream([]u8){ .buffer = &buf, .pos = 0 };
    for (solid.side) |side| {
        const res = try matmap.getOrPut(side.material);
        if (!res.found_existing) {
            var t = try std.time.Timer.start();
            defer texture_time += t.read();
            const lower = std.ascii.lowerString(&lower_buf, side.material);
            res.value_ptr.* = .{
                .tex = blk: {
                    fbs.reset();
                    try fbs.writer().print("materials/{s}", .{lower});
                    const sl = fbs.getWritten();
                    const err = in: {
                        const slash = std.mem.lastIndexOfScalar(u8, sl, '/') orelse break :in error.noSlash;
                        //dev dev_prisontvoverlay002
                        break :in vtf.loadTexture(
                            (vpkctx.getFileTemp("vtf", sl[0..slash], sl[slash + 1 ..]) catch |err| break :in err) orelse break :in error.notfound,
                            alloc,
                        ) catch |err| break :in err;
                    };
                    break :blk err catch |e| {
                        std.debug.print("{} for {s}\n", .{ e, sl });
                        break :blk missingTexture();
                        //graph.Texture.initEmpty();
                    };
                    //defer bmp.deinit();
                    //break :blk graph.Texture.initFromBitmap(bmp, .{});
                },
                .mesh = undefined,
            };
            res.value_ptr.mesh = meshutil.Mesh.init(alloc, res.value_ptr.tex.id);
        }
    }
    try csgctx.genMesh(solid.side, matmap);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();

    var arg_it = try std.process.argsWithAllocator(alloc);
    defer arg_it.deinit();

    var vpkctx = vpk.Context.init(alloc);
    defer vpkctx.deinit();

    try vpkctx.addDir(try std.fs.cwd().openDir("hl2", .{}), "hl2_textures.vpk");
    try vpkctx.addDir(try std.fs.cwd().openDir("hl2", .{}), "hl2_misc.vpk");
    //materials/nature/red_grass
    std.debug.print("{s}\n", .{(try vpkctx.getFileTemp("vmt", "materials/concrete", "concretewall071a")) orelse ""});
    if (true)
        return;

    vpk.timer.log("Vpk dir");

    const Arg = graph.ArgGen.Arg;
    const args = try graph.ArgGen.parseArgs(&.{
        Arg("vmf", .string, "vmf to load"),
        Arg("scale", .number, "scale the model"),
    }, &arg_it);
    var draw_tools = true;

    //const infile = try std.fs.cwd().openFile("sdk_materials.vmf", .{});
    const infile = try std.fs.cwd().openFile(args.vmf orelse "sdk_materials.vmf", .{});
    defer infile.close();

    const slice = try infile.reader().readAllAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(slice);

    var obj = try vdf.parse(alloc, slice);
    defer obj.deinit();
    var win = try graph.SDL.Window.createWindow("Rat Hammer - 鼠", .{
        .window_size = .{ .x = 800, .y = 600 },
    });
    defer win.destroyWindow();

    if (!graph.SDL.Window.glHasExtension("GL_EXT_texture_compression_s3tc")) return error.glMissingExt;
    _ = graph.c.GL_COMPRESSED_RGBA_S3TC_DXT5_EXT;

    //materials/concrete/concretewall008a
    const o = try vpkctx.getFileTemp("vtf", "materials/concrete", "concretewall008a");
    var my_tex = try vtf.loadTexture(o.?, alloc);

    var matmap = csg.MeshMap.init(alloc);
    defer {
        var it = matmap.iterator();
        while (it.next()) |item| {
            item.value_ptr.mesh.deinit();
        }
        matmap.deinit();
    }
    var csgctx = try csg.Context.init(alloc);
    defer csgctx.deinit();

    var draw = graph.ImmediateDrawingContext.init(alloc);
    defer draw.deinit();
    var font = try graph.Font.init(alloc, std.fs.cwd(), "ratgraph/asset/fonts/roboto.ttf", 40, .{});
    defer font.deinit();
    {
        win.pumpEvents(.poll);
        try draw.begin(0x222222ff, win.screen_dimensions.toF());
        draw.text(.{ .x = 0, .y = 0 }, "Loading", &font.font, 20, 0xffffffff);
        try draw.end(null);
        win.swap(); //So the window doesn't look too broken while loading
    }
    const basic_shader = try graph.Shader.loadFromFilesystem(alloc, std.fs.cwd(), &.{
        .{ .path = "ratgraph/asset/shader/gbuffer.vert", .t = .vert },
        .{ .path = "src/basic.frag", .t = .frag },
    });

    var aa = std.heap.ArenaAllocator.init(alloc);
    defer aa.deinit();
    const vmf_ = try vdf.fromValue(vmf.Vmf, &.{ .obj = &obj.value }, aa.allocator());
    {
        var gen_timer = try std.time.Timer.start();
        for (vmf_.world.solid) |solid| {
            try procSolid(&csgctx, alloc, solid, &matmap, &vpkctx);
            //try meshes.append(try csg.genMesh(solid.side, alloc));
        }
        for (vmf_.entity) |ent| {
            for (ent.solid) |solid|
                try procSolid(&csgctx, alloc, solid, &matmap, &vpkctx);
        }
        var t2 = try std.time.Timer.start();
        var it = matmap.valueIterator();
        const nm = matmap.count();
        while (it.next()) |item| {
            item.mesh.setData();
        }
        const set_time = t2.read();
        const whole_time = gen_timer.read();

        std.debug.print("csg took {d} {d:.2} us, {d:.2}\n", .{ nm, csg.gen_time / std.time.ns_per_us / nm, set_time / std.time.ns_per_ms });
        std.debug.print("Generated {d} meshes in {d:.2} ms\n", .{ nm, whole_time / std.time.ns_per_ms });
        std.debug.print("texture load took: {d:.2} ms", .{texture_time / std.time.ns_per_ms});
    }

    var cam = graph.Camera3D{};
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

        draw.rect(Rec(0, 0, 100, 100), 0xff00ff5f);
        draw.rectTex(Rec(0, 0, 1000, 1000), my_tex.rect(), my_tex);
        draw.cube(V3f.new(0, 0, 0), V3f.new(1, 1, 1), 0xffffffff);
        //graph.c.glPolygonMode(graph.c.GL_FRONT_AND_BACK, graph.c.GL_LINE);
        const view_3d = cam.getMatrix(draw.screen_dimensions.x / draw.screen_dimensions.y, 0.1, 100000);
        var it = matmap.iterator();
        const mat = graph.za.Mat4.identity().rotate(-90, graph.za.Vec3.new(1, 0, 0));
        while (it.next()) |mesh| {
            if (!draw_tools and std.mem.startsWith(u8, mesh.key_ptr.*, "TOOLS"))
                continue;
            mesh.value_ptr.mesh.drawSimple(view_3d, mat, basic_shader);
        }

        try draw.end(cam);
        win.swap();
    }
}
