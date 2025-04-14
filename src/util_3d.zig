const std = @import("std");
const graph = @import("graph");
const V3f = graph.za.Vec3;

//Zig port of:
//Fast Ray-Box Intersection
//by Andrew Woo
//from "Graphics Gems", Academic Press, 1990
//
//returns null or the point of intersection in slice form
pub fn doesRayIntersectBoundingBox(comptime numdim: usize, comptime ft: type, min_b: [numdim]ft, max_b: [numdim]ft, ray_origin: [numdim]ft, ray_dir: [numdim]ft) ?[numdim]ft {
    const RIGHT = 0;
    const LEFT = 1;
    const MIDDLE = 2;

    const zeros = [_]ft{0} ** numdim;
    var quadrant = zeros;
    var candidate_plane = zeros;
    var inside = true;
    var max_t = zeros;

    // Find candidate planes; this loop can be avoided if
    // rays cast all from the eye(assume perpsective view)
    for (0..numdim) |i| {
        if (ray_origin[i] < min_b[i]) {
            quadrant[i] = LEFT;
            candidate_plane[i] = min_b[i];
            inside = false;
        } else if (ray_origin[i] > max_b[i]) {
            quadrant[i] = RIGHT;
            candidate_plane[i] = max_b[i];
            inside = false;
        } else {
            quadrant[i] = MIDDLE;
        }
    }

    // Ray origin inside bounding box
    if (inside)
        return ray_origin;

    // Calculate T distances to candidate planes
    for (0..numdim) |i| {
        if (quadrant[i] != MIDDLE and ray_dir[i] != 0) {
            max_t[i] = (candidate_plane[i] - ray_origin[i]) / ray_dir[i];
        } else {
            max_t[i] = -1;
        }
    }

    // Get largest of the maxT's for final choice of intersection
    var which_plane: usize = 0;
    for (1..numdim) |i| {
        if (max_t[which_plane] < max_t[i])
            which_plane = i;
    }

    // Check final candidate actually inside box
    if (max_t[which_plane] < 0)
        return null;

    var coord = zeros;
    for (0..numdim) |i| {
        if (which_plane != i) {
            coord[i] = ray_origin[i] + max_t[which_plane] * ray_dir[i];
            if (coord[i] < min_b[i] or coord[i] > max_b[i])
                return null;
        } else {
            coord[i] = candidate_plane[i];
        }
    }

    return coord;
}

pub fn trianglePlane(verts: [3]V3f) V3f {
    const a = verts[2].sub(verts[0]);
    const b = verts[1].sub(verts[0]);
    return b.cross(a).norm();
}

pub fn doesRayIntersectConvexPolygon(ray_origin: V3f, ray_dir: V3f, plane_normal: V3f, verts: []const V3f) ?V3f {
    if (verts.len == 0) return null;

    const plane_int = doesRayIntersectPlane(ray_origin, ray_dir, verts[0], plane_normal) orelse return null;
    for (1..verts.len) |i| {
        const a = verts[i - 1];
        const b = verts[i];
        const l1 = a.sub(plane_int); //legs of triangle
        const l2 = b.sub(plane_int);

        const th = std.math.atan2(l1.cross(l2).dot(plane_normal), l1.dot(l2));
        if (th < 0)
            return null;
    }
    return plane_int;
}
pub fn doesRayIntersectConvexPolygondo(ray_origin: V3f, ray_dir: V3f, plane_normal: V3f, verts: []const V3f) ?V3f {
    if (verts.len == 0) return null;

    const help = struct {
        fn rej(v: V3f, i: usize) graph.za.Vec2 {
            const V2 = graph.za.Vec2;
            return switch (i) {
                0 => V2.new(v.y(), v.z()),
                1 => V2.new(v.x(), v.z()),
                2 => V2.new(v.x(), v.y()),
                else => unreachable,
            };
        }
    };

    const plane_int = doesRayIntersectPlane(ray_origin, ray_dir, verts[0], plane_normal) orelse return null;

    var reject: usize = 0;
    var min = @abs(plane_normal.x());
    for (1..2) |i| {
        if (@abs(plane_normal.data[i]) > min) {
            min = @abs(plane_normal.data[i]);
            reject = i;
        }
    }
    const pint = help.rej(plane_int, reject);

    var cd = false;
    for (1..verts.len) |i| {
        const a = help.rej(verts[i - 1], reject);
        const b = help.rej(verts[i], reject);
        if ((a.y() > pint.y()) != (b.y() > pint.y()) and
            (pint.x() < (b.x() - a.x()) * (pint.y() - a.y()) / (b.y() - a.y()) + a.x()))
            cd = !cd;
    }

    return if (cd) plane_int else null;
}

//pub fn pnpoly(verts: )

//int pnpoly(int nvert, float *vertx, float *verty, float testx, float testy)
//{
//  int i, j, c = 0;
//  for (i = 0, j = nvert-1; i < nvert; j = i++) {
//    if ( ((verty[i]>testy) != (verty[j]>testy)) &&
//	 (testx < (vertx[j]-vertx[i]) * (testy-verty[i]) / (verty[j]-verty[i]) + vertx[i]) )
//       c = !c;
//  }
//  return c;
//}

pub fn doesRayIntersectBBZ(ray_origin: V3f, ray_dir: V3f, min: V3f, max: V3f) ?V3f {
    const ret = doesRayIntersectBoundingBox(3, f32, min.data, max.data, ray_origin.data, ray_dir.data);
    return if (ret) |r| V3f.new(r[0], r[1], r[2]) else null;
}

pub fn doesRayIntersectPlane(ray_0: V3f, ray_norm: V3f, plane_0: V3f, plane_norm: V3f) ?V3f {
    const ln = ray_norm.dot(plane_norm);
    if (@abs(ln) < 0.0001)
        return null;

    const d = (plane_0.sub(ray_0).dot(plane_norm)) / ln;
    return ray_0.add(ray_norm.scale(d));
}

pub fn snapV3(v: V3f, snap: f32) V3f {
    return V3f{ .data = @divFloor(v.data, @as(@Vector(3, f32), @splat(snap))) * @as(@Vector(3, f32), @splat(snap)) };
}

pub fn snap1(comp: f32, snap: f32) f32 {
    return @divFloor(comp, snap) * snap;
}
