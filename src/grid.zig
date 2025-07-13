const std = @import("std");
const graph = @import("graph");
const Vec3 = graph.za.Vec3;
const DrawCtx = graph.ImmediateDrawingContext;
const util3d = @import("util_3d.zig");
//Get on the grid

pub const Snap = struct {
    s: Vec3,

    min: Vec3 = Vec3.set(1),
    max: Vec3 = Vec3.set(4096),

    pub fn double(self: *@This()) void {
        self.s = self.s.scale(2);
        self.s.data = std.math.clamp(self.s.data, self.min.data, self.max.data);
    }

    pub fn zero() @This() {
        return .{ .s = Vec3.zero() };
    }

    pub fn half(self: *@This()) void {
        self.s = self.s.scale(0.5);
        self.s.data = std.math.clamp(self.s.data, self.min.data, self.max.data);
    }

    pub fn setAll(self: *@This(), snap: f32) void {
        self.s = Vec3.set(snap);
    }

    pub fn snapV3(self: *const @This(), v: Vec3) Vec3 {
        return Vec3.new(
            snap1(v.x(), self.s.x()),
            snap1(v.y(), self.s.y()),
            snap1(v.z(), self.s.z()),
        );
    }

    pub fn isOne(self: *const @This()) bool {
        return self.s.x() == self.s.y() and self.s.y() == self.s.z();
    }

    pub fn swiz1(self: *const @This(), v: f32, comptime comp: []const u8) f32 {
        inline for (comp) |cc| {
            switch (cc) {
                'x' => return snap1(v, self.s.x()),
                'y' => return snap1(v, self.s.y()),
                'z' => return snap1(v, self.s.z()),
                else => @compileError("not a component"),
            }
        }
    }

    pub fn swiz(self: *const @This(), v: Vec3, comptime comp: []const u8) Vec3 {
        var ret = v;
        inline for (comp) |cc| {
            switch (cc) {
                'x' => ret.xMut().* = snap1(ret.x(), self.s.x()),
                'y' => ret.yMut().* = snap1(ret.y(), self.s.y()),
                'z' => ret.zMut().* = snap1(ret.z(), self.s.z()),
                else => @compileError("not a component"),
            }
        }
        return ret;
    }

    fn snap1(value: f32, snap: f32) f32 {
        if (snap < 1) return value;
        return @round(value / snap) * snap;
    }
};

pub fn drawGrid(inter: Vec3, plane_z: f32, d: *DrawCtx, snap: Snap, count: usize) void {
    //const cpos = inter;
    const cpos = snap.snapV3(inter);
    const nline: f32 = @floatFromInt(count);

    const iline2: f32 = @floatFromInt(count / 2);

    const sx = snap.s.x();
    const sy = snap.s.y();
    const othx = @trunc(nline * sx / 2);
    const othy = @trunc(nline * sy / 2);
    for (0..count) |n| {
        const fnn: f32 = @floatFromInt(n);
        {
            const start = Vec3.new((fnn - iline2) * sx + cpos.x(), cpos.y() - othy, plane_z);
            const end = start.add(Vec3.new(0, 2 * othy, 0));
            d.line3D(start, end, 0xffffffff);
        }
        const start = Vec3.new(cpos.x() - othx, (fnn - iline2) * sy + cpos.y(), plane_z);
        const end = start.add(Vec3.new(2 * othx, 0, 0));
        d.line3D(start, end, 0xffffffff);
    }
    //d.point3D(cpos, 0xff0000ee);
}
