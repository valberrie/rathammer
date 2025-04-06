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

var texture_time: u64 = 0;
fn procSolid(csgctx: *csg.Context, alloc: std.mem.Allocator, solid: vmf.Solid, matmap: *csg.MeshMap, dir: std.fs.Dir) !void {
    var buf: [256]u8 = undefined;
    var fbs = std.io.FixedBufferStream([]u8){ .buffer = &buf, .pos = 0 };
    for (solid.side) |side| {
        const res = try matmap.getOrPut(side.material);
        if (!res.found_existing) {
            var t = try std.time.Timer.start();
            defer texture_time += t.read();
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

    if (true) {
        var vpkctx = vpk.Context.init(alloc);
        defer vpkctx.deinit();

        try vpkctx.addDir(try std.fs.cwd().openDir("hl2", .{}), "hl2_textures.vpk");
        try vpkctx.addDir(try std.fs.cwd().openDir("hl2", .{}), "hl2_misc.vpk");
        //try vpkctx.addDir(try std.fs.cwd().openDir("hl2", .{}), "hl2_sound_misc_");
        const out = try std.fs.cwd().createFile("out.vtf", .{});
        defer out.close();

        var outbuf = std.ArrayList(u8).init(alloc);
        const o = try vpkctx.getFile("vtf", "materials/tools", "toolsnodraw", &outbuf);
        try out.writer().writeAll(o.?);
        outbuf.deinit();

        vpk.timer.log("Vpk dir");
        return;
    }

    const Arg = graph.ArgGen.Arg;
    const args = try graph.ArgGen.parseArgs(&.{
        Arg("vmf", .string, "vmf to load"),
        Arg("scale", .number, "scale the model"),
    }, &arg_it);
    var draw_tools = true;
    if (true) {
        const VPK_PREFIX = "hl2/hl2_misc_";
        const infile = try std.fs.cwd().openFile(VPK_PREFIX ++ "dir.vpk", .{});
        const Vpk = struct {
            fn readString(r: anytype, str: *std.ArrayList(u8)) ![]const u8 {
                str.clearRetainingCapacity();
                while (true) {
                    const char = try r.readByte();
                    if (char == 0)
                        return str.items;
                    try str.append(char);
                }
            }

            fn dumpFile(archive_index: u32, offset: u32, entry_len: u32, out_path: []const u8, al: std.mem.Allocator) !void {
                var buf: [256]u8 = undefined;
                var fbs = std.io.FixedBufferStream([]u8){ .buffer = &buf, .pos = 0 };
                try fbs.writer().print("{s}{d:0>3}.vpk", .{ VPK_PREFIX, archive_index });
                std.debug.print("{s}\n", .{fbs.getWritten()});
                const in = try std.fs.cwd().openFile(fbs.getWritten(), .{});
                defer in.close();

                var invec = std.ArrayList(u8).init(al);
                defer invec.deinit();
                try invec.resize(entry_len);
                try in.seekTo(offset);
                try in.reader().readNoEof(invec.items);

                const out = try std.fs.cwd().createFile(out_path, .{});
                try out.writeAll(invec.items);
            }
        };
        var strbuf = std.ArrayList(u8).init(alloc);
        defer strbuf.deinit();
        defer infile.close();
        const r = infile.reader();
        const VPK_SIG: u32 = 0x55aa1234;
        const sig = try r.readInt(u32, .little);
        if (sig != VPK_SIG)
            return error.invalidVpk;
        const version = try r.readInt(u32, .little);
        std.debug.print("{d}\n", .{version});
        //materials/tools/toolstrigger.vtf
        switch (version) {
            1 => {},
            2 => {
                const tree_size = try r.readInt(u32, .little);
                const filedata_section_size = try r.readInt(u32, .little);
                const archive_md5_sec_size = try r.readInt(u32, .little);
                const other_md5_sec_size = try r.readInt(u32, .little);
                const sig_sec_size = try r.readInt(u32, .little);

                if (other_md5_sec_size != 48) return error.invalidMd5Size;
                std.debug.print("{d} {d} {d} {d}\n", .{ tree_size, filedata_section_size, archive_md5_sec_size, sig_sec_size });

                while (true) {
                    const ext = try Vpk.readString(r, &strbuf);
                    if (ext.len == 0)
                        break;
                    std.debug.print("{s}\n", .{ext});
                    while (true) {
                        const path = try Vpk.readString(r, &strbuf);
                        if (path.len == 0)
                            break;
                        const is_path = std.mem.eql(u8, path, "materials/tools");
                        std.debug.print("\t{s}\n", .{path});
                        while (true) {
                            const fname = try Vpk.readString(r, &strbuf);
                            if (fname.len == 0)
                                break;

                            _ = try r.readInt(u32, .little); //CRC
                            _ = try r.readInt(u16, .little); //preload bytes
                            const arch_index = try r.readInt(u16, .little); //archive index
                            const offset = try r.readInt(u32, .little); //entry offset
                            const entry_len = try r.readInt(u32, .little); //Entry len

                            const term = try r.readInt(u16, .little);
                            _ = offset;
                            if (term != 0xffff) return error.broken;
                            std.debug.print("\t\t{s}: {d}bytes, i:{d}\n", .{ fname, entry_len, arch_index });
                            if (is_path and std.mem.eql(u8, "toolstrigger", fname)) {
                                //try Vpk.dumpFile(arch_index, offset, entry_len, "crass.vtf", alloc);
                            }
                        }
                    }
                }
            },
            else => return error.unsupportedVpkVersion,
        }

        return;
    }

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
