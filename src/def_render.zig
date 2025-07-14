const std = @import("std");
const graph = @import("graph");
const glID = graph.glID;
const c = graph.c;
const GL = graph.GL;
const Mat4 = graph.za.Mat4;
const Vec3 = graph.za.Vec3;
const DrawCtx = graph.ImmediateDrawingContext;

pub const DrawCall = struct {
    prim: GL.PrimitiveMode,
    num_elements: c_int,
    element_type: c_uint,
    vao: c_uint,
    //view: *const Mat4,
    diffuse: c_uint,
};
const LightQuadBatch = graph.NewBatch(packed struct { pos: graph.Vec3f, uv: graph.Vec2f }, .{ .index_buffer = false, .primitive_mode = .triangles });

pub const Renderer = struct {
    const Self = @This();
    shader: struct {
        csm: glID,
        forward: glID,
        gbuffer: glID,
        light: glID,
        sun: glID,
    },
    mode: enum { forward, def } = .forward,
    gbuffer: GBuffer,
    csm: Csm,

    draw_calls: std.ArrayList(DrawCall),
    last_frame_view_mat: Mat4 = undefined,
    light_batch: LightQuadBatch,

    param: struct {
        exposure: f32 = 1,
        gamma: f32 = 2.2,
    } = .{},

    pub fn init(alloc: std.mem.Allocator, shader_dir: std.fs.Dir) !Self {
        const shadow_shader = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{
            .{ .path = "shadow_map.vert", .t = .vert },
            .{ .path = "shadow_map.frag", .t = .frag },
            .{ .path = "shadow_map.geom", .t = .geom },
        });
        const forward = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{
            .{ .path = "basic.vert", .t = .vert },
            .{ .path = "basic.frag", .t = .frag },
        });
        const gbuffer_shader = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{
            .{ .path = "gbuffer_model.vert", .t = .vert },
            .{ .path = "gbuffer_model.frag", .t = .frag },
        });
        const light_shader = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{
            .{ .path = "light.vert", .t = .vert },
            .{ .path = "light.frag", .t = .frag },
        });
        const def_sun_shad = try graph.Shader.loadFromFilesystem(alloc, shader_dir, &.{
            .{ .path = "sun.vert", .t = .vert },
            .{ .path = "sun.frag", .t = .frag },
        });
        return Self{
            .shader = .{
                .csm = shadow_shader,
                .forward = forward,
                .gbuffer = gbuffer_shader,
                .light = light_shader,
                .sun = def_sun_shad,
            },
            .light_batch = LightQuadBatch.init(alloc),
            .draw_calls = std.ArrayList(DrawCall).init(alloc),
            .csm = Csm.createCsm(2048, Csm.CSM_COUNT, light_shader),
            .gbuffer = GBuffer.create(100, 100),
        };
    }

    pub fn beginFrame(self: *Self) void {
        self.draw_calls.clearRetainingCapacity();
    }

    pub fn submitDrawCall(self: *Self, d: DrawCall) !void {
        try self.draw_calls.append(d);
    }

    pub fn draw(
        self: *Self,
        cam: graph.Camera3D,
        w: f32,
        h: f32,
        param: struct {
            far: f32,
            near: f32,
            fac: f32,
            pad: f32,
            index: usize,
        },
        dctx: *DrawCtx,
        pl: anytype,
    ) !void {
        const view1 = cam.getMatrix(w / h, param.near, param.far);
        self.csm.pad = param.pad;
        switch (self.mode) {
            .forward => {
                const view = view1;
                const sh = self.shader.forward;
                c.glUseProgram(sh);
                GL.passUniform(sh, "view", view);
                for (self.draw_calls.items) |dc| {
                    if (dc.diffuse != 0) {
                        const diffuse_loc = c.glGetUniformLocation(sh, "diffuse_texture");

                        c.glUniform1i(diffuse_loc, 0);
                        c.glBindTextureUnit(0, dc.diffuse);
                    }
                    //GL.passUniform(sh, "model", model);
                    c.glBindVertexArray(dc.vao);
                    c.glDrawElements(@intFromEnum(dc.prim), dc.num_elements, dc.element_type, null);
                }
            },
            .def => {
                //self.csm.pad = param.fac;
                //const view = view1;
                const view = if (param.index == 0) view1 else self.csm.mats[(param.index - 1) % self.csm.mats.len];
                //self.csm.mats[0];
                self.last_frame_view_mat = cam.getViewMatrix();
                const light_dir = Vec3.new(1, 1, 1).norm();
                //const light_dir = Vec3.new(0, 0, param.fac - 10).norm();
                //const light_dir = Vec3.new(-20, 50, -20).norm();
                const far = param.far;
                const planes = [_]f32{
                    pl[0],
                    pl[1],
                    pl[2],

                    //far * 0.005,
                    //far * 0.015,
                    //far * 0.058,
                };
                const last_plane = pl[3];
                //const last_plane = far * 0.58;
                self.csm.calcMats(cam.fov, w / h, param.near, far, self.last_frame_view_mat, light_dir, planes);
                self.csm.draw(self);
                self.gbuffer.updateResolution(@intFromFloat(w), @intFromFloat(h));
                c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.gbuffer.buffer);
                c.glViewport(0, 0, self.gbuffer.scr_w, self.gbuffer.scr_h);
                c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);
                { //Write to gbuffer
                    const sh = self.shader.gbuffer;
                    c.glUseProgram(sh);
                    const diffuse_loc = c.glGetUniformLocation(sh, "diffuse_texture");

                    c.glUniform1i(diffuse_loc, 0);
                    c.glBindBufferBase(c.GL_UNIFORM_BUFFER, 0, self.csm.mat_ubo);
                    for (self.draw_calls.items) |dc| {
                        c.glBindTextureUnit(0, dc.diffuse);
                        GL.passUniform(sh, "view", view);
                        GL.passUniform(sh, "model", Mat4.identity());
                        c.glBindVertexArray(dc.vao);
                        c.glDrawElements(@intFromEnum(dc.prim), dc.num_elements, dc.element_type, null);
                    }

                    if (false) {
                        dctx.rectTex(graph.Rec(0, 0, w, h), graph.Rec(0, 0, w, -h), .{
                            .id = self.gbuffer.albedo,
                            .w = @intFromFloat(w),
                            .h = @intFromFloat(h),
                        });
                    }
                }
                c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

                if (true) {
                    { //Draw sun
                        //c.glDepthMask(c.GL_FALSE);
                        //defer c.glDepthMask(c.GL_TRUE);
                        //c.glEnable(c.GL_BLEND);
                        //c.glBlendFunc(c.GL_ONE, c.GL_ONE);
                        //c.glBlendEquation(c.GL_FUNC_ADD);
                        //defer c.glDisable(c.GL_BLEND);
                        //c.glClear(c.GL_DEPTH_BUFFER_BIT);

                        try self.light_batch.clear();
                        try self.light_batch.vertices.appendSlice(&.{
                            .{ .pos = graph.Vec3f.new(-1, 1, 0), .uv = graph.Vec2f.new(0, 1) },
                            .{ .pos = graph.Vec3f.new(-1, -1, 0), .uv = graph.Vec2f.new(0, 0) },
                            .{ .pos = graph.Vec3f.new(1, 1, 0), .uv = graph.Vec2f.new(1, 1) },
                            .{ .pos = graph.Vec3f.new(1, -1, 0), .uv = graph.Vec2f.new(1, 0) },
                        });
                        const exposure: f32 = 1;
                        const gamma: f32 = 1.8;
                        //var sun_color = graph.Hsva.fromInt(0xef8825ff);
                        var sun_color = graph.Hsva.fromInt(0xedda8fff);
                        self.light_batch.pushVertexData();
                        const sh1 = self.shader.sun;
                        c.glUseProgram(sh1);
                        c.glBindVertexArray(self.light_batch.vao);
                        c.glBindBufferBase(c.GL_UNIFORM_BUFFER, 0, self.csm.mat_ubo);
                        c.glBindTextureUnit(0, self.gbuffer.pos);
                        c.glBindTextureUnit(1, self.gbuffer.normal);
                        c.glBindTextureUnit(2, self.gbuffer.albedo);
                        c.glBindTextureUnit(3, self.csm.textures);
                        graph.GL.passUniform(sh1, "view_pos", cam.pos);
                        graph.GL.passUniform(sh1, "exposure", exposure);
                        graph.GL.passUniform(sh1, "gamma", gamma);
                        graph.GL.passUniform(sh1, "light_dir", light_dir);
                        graph.GL.passUniform(sh1, "screenSize", graph.Vec2i{ .x = @intFromFloat(w), .y = @intFromFloat(h) });
                        graph.GL.passUniform(sh1, "light_color", sun_color.toFloat());
                        graph.GL.passUniform(sh1, "cascadePlaneDistances[0]", @as(f32, planes[0]));
                        graph.GL.passUniform(sh1, "cascadePlaneDistances[1]", @as(f32, planes[1]));
                        graph.GL.passUniform(sh1, "cascadePlaneDistances[2]", @as(f32, planes[2]));
                        graph.GL.passUniform(sh1, "cascadePlaneDistances[3]", @as(f32, last_plane));
                        graph.GL.passUniform(sh1, "cam_view", cam.getViewMatrix());

                        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, @as(c_int, @intCast(self.light_batch.vertices.items.len)));
                    }
                }
            },
        }
        self.last_frame_view_mat = cam.getViewMatrix();
    }

    pub fn deinit(self: *Self) void {
        self.draw_calls.deinit();
        self.light_batch.deinit();
    }
};
//In forward, we just do the draw call
//otherwise, we need to draw that and the next
//then draw it again later? yes

const GBuffer = struct {
    buffer: c_uint = 0,
    depth: c_uint = 0,
    pos: c_uint = 0,
    normal: c_uint = 0,
    albedo: c_uint = 0,

    scr_w: i32 = 0,
    scr_h: i32 = 0,

    pub fn updateResolution(self: *@This(), new_w: i32, new_h: i32) void {
        if (new_w != self.scr_w or new_h != self.scr_h) {
            c.glDeleteTextures(1, &self.pos);
            c.glDeleteTextures(1, &self.normal);
            c.glDeleteTextures(1, &self.albedo);
            c.glDeleteRenderbuffers(1, &self.depth);
            c.glDeleteFramebuffers(1, &self.buffer);
            self.* = create(new_w, new_h);
        }
    }

    pub fn create(scrw: i32, scrh: i32) @This() {
        var ret: GBuffer = .{};
        ret.scr_w = scrw;
        ret.scr_h = scrh;
        c.glGenFramebuffers(1, &ret.buffer);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, ret.buffer);
        const pos_fmt = c.GL_RGBA32F;
        const norm_fmt = c.GL_RGBA16F;

        c.glGenTextures(1, &ret.pos);
        c.glBindTexture(c.GL_TEXTURE_2D, ret.pos);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, pos_fmt, scrw, scrh, 0, c.GL_RGBA, c.GL_FLOAT, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, ret.pos, 0);

        // - normal color buffer
        c.glGenTextures(1, &ret.normal);
        c.glBindTexture(c.GL_TEXTURE_2D, ret.normal);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, norm_fmt, scrw, scrh, 0, c.GL_RGBA, c.GL_HALF_FLOAT, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT1, c.GL_TEXTURE_2D, ret.normal, 0);

        // - color + specular color buffer
        c.glGenTextures(1, &ret.albedo);
        c.glBindTexture(c.GL_TEXTURE_2D, ret.albedo);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA16F, scrw, scrh, 0, c.GL_RGBA, c.GL_HALF_FLOAT, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT2, c.GL_TEXTURE_2D, ret.albedo, 0);

        // - tell OpenGL which color attachments we'll use (of this framebuffer) for rendering
        const attachments = [_]c_int{ c.GL_COLOR_ATTACHMENT0, c.GL_COLOR_ATTACHMENT1, c.GL_COLOR_ATTACHMENT2, 0 };
        c.glDrawBuffers(3, @ptrCast(&attachments[0]));

        c.glGenRenderbuffers(1, &ret.depth);
        c.glBindRenderbuffer(c.GL_RENDERBUFFER, ret.depth);
        c.glRenderbufferStorage(c.GL_RENDERBUFFER, c.GL_DEPTH_COMPONENT, scrw, scrh);
        c.glFramebufferRenderbuffer(c.GL_FRAMEBUFFER, c.GL_DEPTH_ATTACHMENT, c.GL_RENDERBUFFER, ret.depth);
        if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE)
            std.debug.print("gbuffer FBO not complete\n", .{});
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        return ret;
    }
};

const Csm = struct {
    const CSM_COUNT = 4;
    fbo: c_uint,
    textures: c_uint,
    res: i32,

    mat_ubo: c_uint = 0,

    mats: [CSM_COUNT]Mat4 = undefined,
    pad: f32 = 15 * 32,

    fn createCsm(resolution: i32, cascade_count: i32, light_shader: c_uint) Csm {
        var fbo: c_uint = 0;
        var textures: c_uint = 0;
        c.glGenFramebuffers(1, &fbo);
        c.glGenTextures(1, &textures);
        c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, textures);
        c.glTexImage3D(
            c.GL_TEXTURE_2D_ARRAY,
            0,
            c.GL_DEPTH_COMPONENT32F,
            resolution,
            resolution,
            cascade_count,
            0,
            c.GL_DEPTH_COMPONENT,
            c.GL_FLOAT,
            null,
        );
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_BORDER);
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_BORDER);

        const border_color = [_]f32{1} ** 4;
        c.glTexParameterfv(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_BORDER_COLOR, &border_color);

        c.glBindFramebuffer(c.GL_FRAMEBUFFER, fbo);
        c.glFramebufferTexture(c.GL_FRAMEBUFFER, c.GL_DEPTH_ATTACHMENT, textures, 0);
        c.glDrawBuffer(c.GL_NONE);
        c.glReadBuffer(c.GL_NONE);

        const status = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER);
        if (status != c.GL_FRAMEBUFFER_COMPLETE)
            std.debug.print("Framebuffer is broken\n", .{});

        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

        var lmu: c_uint = 0;
        {
            c.glGenBuffers(1, &lmu);
            c.glBindBuffer(c.GL_UNIFORM_BUFFER, lmu);
            c.glBufferData(c.GL_UNIFORM_BUFFER, @sizeOf([4][4]f32) * 16, null, c.GL_DYNAMIC_DRAW);
            c.glBindBufferBase(c.GL_UNIFORM_BUFFER, 0, lmu);
            c.glBindBuffer(c.GL_UNIFORM_BUFFER, 0);

            const li = c.glGetUniformBlockIndex(light_shader, "LightSpaceMatrices");
            c.glUniformBlockBinding(light_shader, li, 0);
        }

        return .{
            .fbo = fbo,
            .textures = textures,
            .res = resolution,
            .mat_ubo = lmu,
        };
    }

    pub fn calcMats(self: *Csm, fov: f32, aspect: f32, near: f32, far: f32, last_frame_view_mat: Mat4, sun_dir: Vec3, planes: [CSM_COUNT - 1]f32) void {
        self.mats = self.getLightMatrices(fov, aspect, near, far, last_frame_view_mat, sun_dir, planes);
        c.glBindBuffer(c.GL_UNIFORM_BUFFER, self.mat_ubo);
        for (self.mats, 0..) |mat, i| {
            const ms = @sizeOf([4][4]f32);
            c.glBufferSubData(c.GL_UNIFORM_BUFFER, @as(c_long, @intCast(i)) * ms, ms, &mat.data[0][0]);
        }
        c.glBindBuffer(c.GL_UNIFORM_BUFFER, 0);
    }

    pub fn draw(csm: *Csm, rend: *const Renderer) void {
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, csm.fbo);
        c.glDisable(graph.c.GL_SCISSOR_TEST); //BRUH
        c.glViewport(0, 0, csm.res, csm.res);
        c.glClear(c.GL_DEPTH_BUFFER_BIT);

        const sh = rend.shader.csm;
        c.glUseProgram(sh);
        for (rend.draw_calls.items) |dc| {
            //GL.passUniform(sh, "view", dc.view.*);
            c.glBindVertexArray(dc.vao);
            c.glDrawElements(@intFromEnum(dc.prim), dc.num_elements, dc.element_type, null);
        }
    }

    fn getLightMatrices(self: *const Csm, fov: f32, aspect: f32, near: f32, far: f32, cam_view: Mat4, light_dir: Vec3, planes: [CSM_COUNT - 1]f32) [CSM_COUNT]Mat4 {
        var ret: [CSM_COUNT]Mat4 = undefined;
        //fov, aspect, near, far, cam_view, light_Dir
        for (0..CSM_COUNT) |i| {
            if (i == 0) {
                ret[i] = self.getLightMatrix(fov, aspect, near, planes[i], cam_view, light_dir);
            } else if (i < CSM_COUNT - 1) {
                ret[i] = self.getLightMatrix(fov, aspect, planes[i - 1], planes[i], cam_view, light_dir);
            } else {
                ret[i] = self.getLightMatrix(fov, aspect, planes[i - 1], far, cam_view, light_dir);
            }
        }
        return ret;
    }

    fn getLightMatrix(self: *const Csm, fov: f32, aspect: f32, near: f32, far: f32, cam_view: Mat4, light_dir: Vec3) Mat4 {
        const cam_persp = graph.za.perspective(fov, aspect, near, far);
        const corners = getFrustumCornersWorldSpace(cam_persp.mul(cam_view));
        var center = Vec3.zero();
        for (corners) |corner| {
            center = center.add(corner.toVec3());
        }
        center = center.scale(1.0 / @as(f32, @floatFromInt(corners.len)));
        const lview = graph.za.lookAt(
            center.add(light_dir),
            center,
            Vec3.new(0, 1, 0),
        );
        var min_x = std.math.floatMax(f32);
        var min_y = std.math.floatMax(f32);
        var min_z = std.math.floatMax(f32);

        var max_x = -std.math.floatMax(f32);
        var max_y = -std.math.floatMax(f32);
        var max_z = -std.math.floatMax(f32);
        for (corners) |corner| {
            const trf = lview.mulByVec4(corner);
            min_x = @min(min_x, trf.x());
            min_y = @min(min_y, trf.y());
            min_z = @min(min_z, trf.z());

            max_x = @max(max_x, trf.x());
            max_y = @max(max_y, trf.y());
            max_z = @max(max_z, trf.z());
        }

        //min_z -= self.pad;
        //max_z += self.pad;
        //min_z -= far / 2;

        const tw = self.pad;
        min_z = if (min_z < 0) min_z * tw else min_z / tw;
        max_z = if (max_z < 0) max_z / tw else max_z * tw;

        //const ortho = graph.za.orthographic(-20, 20, -20, 20, 0.1, 300).mul(lview);
        const ortho = graph.za.orthographic(min_x, max_x, min_y, max_y, min_z, max_z).mul(lview);
        return ortho;
    }

    fn getFrustumCornersWorldSpace(frustum: Mat4) [8]graph.za.Vec4 {
        const inv = frustum.inv();
        var corners: [8]graph.za.Vec4 = undefined;
        var i: usize = 0;
        for (0..2) |x| {
            for (0..2) |y| {
                for (0..2) |z| {
                    const pt = inv.mulByVec4(graph.za.Vec4.new(
                        2 * @as(f32, @floatFromInt(x)) - 1,
                        2 * @as(f32, @floatFromInt(y)) - 1,
                        2 * @as(f32, @floatFromInt(z)) - 1,
                        1.0,
                    ));
                    corners[i] = pt.scale(1 / pt.w());
                    i += 1;
                }
            }
        }
        if (i != 8)
            unreachable;

        return corners;
    }
};
