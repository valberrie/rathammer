const std = @import("std");
const graph = @import("graph");
const R = graph.Rect;

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
    fillBuf(&.{
        .{ .left, 0.5 },
        .{ .top, 0.5 },
        .{ .left, 0.5 },
        .{ .bottom, 0.5 },
    }, &out, .{ .x = 0, .y = 0, .w = 100, .h = 100 });
    for (out) |o| {
        std.debug.print("{d:.2}, {d:.2}, {d}, {d}\n", .{ o.x, o.y, o.w, o.h });
    }
}
