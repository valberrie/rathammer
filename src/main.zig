const std = @import("std");
const graph = @import("graph");
const Rec = graph.Rec;
const Vec2f = graph.Vec2f;
const V3f = graph.za.Vec3;
const meshutil = graph.meshutil;
const csg = @import("csg.zig");
const vdf = @import("vdf.zig");
const vmf = @import("vmf.zig");

fn procSolid(csgctx: *csg.Context, alloc: std.mem.Allocator, solid: vmf.Solid, matmap: *csg.MeshMap, dir: std.fs.Dir) !void {
    var buf: [256]u8 = undefined;
    var fbs = std.io.FixedBufferStream([]u8){ .buffer = &buf, .pos = 0 };
    for (solid.side) |side| {
        const res = try matmap.getOrPut(side.material);
        if (!res.found_existing) {
            _ = std.ascii.lowerString(&buf, side.material);
            fbs.pos = side.material.len;
            try fbs.writer().print(".png", .{});
            //std.debug.print("{s}\n", .{fbs.getWritten()});
            res.value_ptr.* = .{ .tex = blk: {
                const bmp = graph.Bitmap.initFromPngFile(alloc, dir, fbs.getWritten()) catch {
                    std.debug.print("Can't find texture: {s}\n", .{side.material});
                    break :blk graph.Texture.initEmpty();
                };

                defer bmp.deinit();
                break :blk graph.Texture.initFromBitmap(bmp, .{});
            }, .mesh = undefined };
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
    const vinf = obj.value.getFirst("versioninfo").?.obj;
    defer obj.deinit();
    for (vinf.list.items) |item|
        std.debug.print("{s}\n", .{item.val.literal});

    var win = try graph.SDL.Window.createWindow("Rat Hammer - 鼠", .{
        .window_size = .{ .x = 800, .y = 600 },
    });
    defer win.destroyWindow();

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
        const dir = try std.fs.cwd().openDir("pngmat", .{});
        for (vmf_.world.solid) |solid| {
            try procSolid(&csgctx, alloc, solid, &matmap, dir);
            //try meshes.append(try csg.genMesh(solid.side, alloc));
        }
        for (vmf_.entity) |ent| {
            for (ent.solid) |solid|
                try procSolid(&csgctx, alloc, solid, &matmap, dir);
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
