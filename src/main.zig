const std = @import("std");
const graph = @import("graph");
const Rec = graph.Rec;
const Vec2f = graph.Vec2f;
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.detectLeaks();
    const alloc = gpa.allocator();

    var win = try graph.SDL.Window.createWindow("My window", .{
        // Optional, see Window.createWindow definition for full list of options
        .window_size = .{ .x = 800, .y = 600 },
    });
    defer win.destroyWindow();

    var draw = graph.ImmediateDrawingContext.init(alloc);
    defer draw.deinit();

    var font = try graph.Font.init(alloc, std.fs.cwd(), "ratgraph/asset/fonts/roboto.ttf", 40, .{});
    defer font.deinit();
    const r = Rec(0, 0, 100, 100);
    const v1 = Vec2f.new(0, 0);
    const v2 = Vec2f.new(3, 3);
    const v3 = Vec2f.new(30, 30);

    while (!win.should_exit) {
        try draw.begin(0x2f2f2fff, win.screen_dimensions.toF());
        win.pumpEvents(.poll); //Important that this is called after draw.begin for input lag reasons

        draw.text(.{ .x = 50, .y = 300 }, "Hello", &font.font, 20, 0xffffffff);
        draw.rect(r, 0xff00ffff);
        draw.rectVertexColors(r, &.{ 0xff, 0xff, 0xff, 0xff });
        draw.nineSlice(r, r, font.font.texture, 1);
        draw.rectTex(r, r, font.font.texture);
        draw.line(v1, v2, 0xff);
        draw.triangle(v1, v2, v3, 0xfffffff0);

        try draw.flush(null, null); //Flush any draw commands

        draw.triangle(v1, v2, v3, 0xfffffff0);
        try draw.end(null);
        win.swap();
        win.should_exit = true;
    }
}
