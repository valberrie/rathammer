const std = @import("std");
const graph = @import("graph");
const R = graph.Rect;
//const R = struct { x: f32, y: f32, w: f32, h: f32 };

const Operation = enum { left, right, top, bottom };

pub const Op = struct { Operation, f32 };

pub fn calculateBounds(op: Op, area: R) [2]R {
    const vp = area.w * op[1];
    const hp = area.h * op[1];
    const L = R{ .x = area.x, .y = area.y, .w = vp, .h = area.h };
    const rr = R{ .x = area.x + vp, .y = area.y, .w = area.w - vp, .h = area.h };

    const T = R{ .x = area.x, .y = area.y, .w = area.w, .h = hp };
    const B = R{ .x = area.x, .y = area.y + hp, .w = area.w, .h = area.h - hp };
    return switch (op[0]) {
        .left => [2]R{ L, rr },
        .right => [2]R{ rr, L },
        .top => [2]R{ T, B },
        .bottom => [2]R{ B, T },
    };
}

pub fn fillBuf(in: []const Op, out: []R, root: R) []const R {
    var last = root;
    for (in, 0..) |inp, i| {
        const calc = calculateBounds(inp, last);
        out[i] = calc[0];
        last = calc[1];
    }
    return out[0..in.len];
}

test {
    const a = calculateBounds(.{ .left, 0.5 }, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    std.debug.print("{any}\n", .{a});

    var out: [4]R = undefined;
    _ = fillBuf(&.{
        .{ .left, 0.5 },
        .{ .top, 0.5 },
        .{ .left, 0.5 },
        .{ .bottom, 0.5 },
    }, &out, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    for (out) |o| {
        std.debug.print("{d:.2}, {d:.2}, {d}, {d}\n", .{ o.x, o.y, o.w, o.h });
    }
}

const Area = struct {
    split: struct { k: enum { vert, horiz } = .vert, perc: f32 = 1 }, //Default split gives left all, right nothing
    left: ?*const Area = null,
    right: ?*const Area = null,
};

const Workspace = struct {};

fn splitR(r: R, op: anytype) [2]R {
    switch (op.k) {
        .vert => return [2]R{
            .{ .x = r.x, .y = r.y, .w = r.w * op.perc, .h = r.h },
            .{ .x = r.x + r.w * op.perc, .y = r.y, .w = r.w - (r.w * op.perc), .h = r.h },
        },
        .horiz => return [2]R{
            .{ .x = r.x, .y = r.y, .h = r.h * op.perc, .w = r.w },
            .{ .y = r.y + r.h * op.perc, .x = r.x, .h = r.h - (r.h * op.perc), .w = r.w },
        },
    }
}

fn flattenTree(root_area: R, tree: ?*const Area, output_list: *std.ArrayList(R)) !void {
    if (tree) |t| {
        const sp = splitR(root_area, t.split);
        try flattenTree(sp[0], t.left, output_list);
        try flattenTree(sp[1], t.right, output_list);
    } else {
        try output_list.append(root_area);
    }
}

test {
    const alloc = std.testing.allocator;
    const root = Area{
        .split = .{ .k = .vert, .perc = 0.5 },
        .left = null, // index 0
        .right = &Area{
            .split = .{ .k = .horiz, .perc = 0.5 },
            .left = null, //Index 1
            .right = null, //index 2
        },
    };
    var list = std.ArrayList(R).init(alloc);
    defer list.deinit();
    try flattenTree(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, &root, &list);

    std.debug.print("STARTING\n", .{});
    for (list.items) |o| {
        std.debug.print("{d:.2}, {d:.2}, {d}, {d}\n", .{ o.x, o.y, o.w, o.h });
    }
}
