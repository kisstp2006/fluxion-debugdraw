// SPDX-License-Identifier: BSD-2-Clause

//! Canvases in, pixels out, through Fluxion RHI.
//!
//! ```zig
//! var renderer: Renderer = try .init(gpa, &device, .{});
//! defer renderer.deinit();
//!
//! try renderer.draw(&.{&canvas}, .{ .color = .{ .surface = surface } }, .{
//!     .view_projection = projection.mul(view),
//!     .width = 1280,
//!     .height = 720,
//! });
//! ```
//!
//! One pass over what the scene left in the target. Lines are one instanced
//! quad each, widened on the screen and faded at the edge, so a line is as
//! wide as it was asked to be at any distance and on every backend - none of
//! them draws a wide line of its own. Filled shapes and text are triangles
//! from one texture. World shapes go first, screen shapes after, and each in
//! the order it was drawn.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const rhi = @import("fluxion_rhi");
const math = @import("fluxion_math");
const shader = @import("fluxion_shader");
const debugdraw = @import("fluxion_debugdraw");

const Canvas = debugdraw.Canvas;
const Line = debugdraw.Line;
const Vertex = debugdraw.Vertex;
const font = debugdraw.font;

pub const Error = rhi.Error || shader.Error;

const log = std.log.scoped(.fluxion_debugdraw);

const lines_source = @embedFile("shaders/lines.fxs");
const fills_source = @embedFile("shaders/fills.fxs");

pub const Options = struct {
    color_format: rhi.Format = .rgba8_unorm,
    /// The format of the depth buffer the scene is drawn with, for shapes
    /// that hide behind it. Null when there is none: everything is drawn over
    /// the scene.
    depth_format: ?rhi.Format = null,
    /// The scene's depth runs from one at the near plane to zero at the far,
    /// as `Clip.reverse_z` builds it.
    reverse_z: bool = false,
};

/// What the world is seen through.
pub const View = struct {
    view_projection: math.Mat4,
    /// The target, in pixels.
    width: f32,
    height: f32,
    /// What `view_projection` was built for. Null is the device's own.
    clip: ?math.Clip = null,
};

/// Where it is drawn.
pub const Target = struct {
    color: rhi.RenderTarget,
    /// The scene's depth buffer, in `Options.depth_format`, to hide tested
    /// shapes behind.
    depth: ?rhi.Texture = null,
    /// Null keeps what is there, which is what drawing over a scene is.
    clear: ?[4]f32 = null,
};

pub const Stats = struct {
    lines: u32 = 0,
    triangles: u32 = 0,
    draw_calls: u32 = 0,
};

const Frame = extern struct {
    view_projection: math.Mat4,
    /// Width, height, and which way `y` points in clip space.
    viewport: [4]f32,
    near_plane: [4]f32,
};

const Batch = struct {
    kind: Canvas.Kind,
    space: Canvas.Space,
    depth: Canvas.Depth,
    first: u32,
    count: u32,
};

const corners = [8]f32{ 0, -1, 1, -1, 0, 1, 1, 1 };

pub const Renderer = struct {
    gpa: Allocator,
    device: *rhi.Device,

    line_shader: rhi.Shader,
    fill_shader: rhi.Shader,
    /// By depth: tested, then always. The same pipeline twice when there is
    /// no depth buffer.
    line_pipelines: [2]rhi.Pipeline,
    fill_pipelines: [2]rhi.Pipeline,

    quad: rhi.Buffer,
    line_buffer: rhi.Buffer,
    line_capacity: u32,
    vertex_buffer: rhi.Buffer,
    vertex_capacity: u32,
    frames: [2]rhi.Buffer,

    glyphs: rhi.Texture,
    sampler: rhi.Sampler,

    lines: std.ArrayList(Line) = .empty,
    vertices: std.ArrayList(Vertex) = .empty,
    batches: std.ArrayList(Batch) = .empty,

    /// What the last `draw` drew.
    stats: Stats = .{},

    pub fn init(gpa: Allocator, device: *rhi.Device, options: Options) Error!Renderer {
        var line_module = try compile(gpa, lines_source, "lines");
        defer line_module.deinit();
        var fill_module = try compile(gpa, fills_source, "fills");
        defer fill_module.deinit();

        const line_shader = try createShader(device, &line_module, "debug lines");
        errdefer device.destroyShader(line_shader);
        const fill_shader = try createShader(device, &fill_module, "debug fills");
        errdefer device.destroyShader(fill_shader);

        const line_desc: rhi.PipelineDesc = .{
            .shader = line_shader,
            .attributes = &.{
                .{ .location = 0, .format = .float2, .offset = 0, .buffer = 0 },
                .{ .location = 1, .format = .float3, .offset = @offsetOf(Line, "start"), .buffer = 1 },
                .{ .location = 2, .format = .float3, .offset = @offsetOf(Line, "end"), .buffer = 1 },
                .{ .location = 3, .format = .ubyte4_norm, .offset = @offsetOf(Line, "start_color"), .buffer = 1 },
                .{ .location = 4, .format = .ubyte4_norm, .offset = @offsetOf(Line, "end_color"), .buffer = 1 },
                .{ .location = 5, .format = .float, .offset = @offsetOf(Line, "width"), .buffer = 1 },
            },
            .buffers = &.{
                .{ .stride = 2 * @sizeOf(f32) },
                .{ .stride = @sizeOf(Line), .step = .instance },
            },
            .topology = .triangle_strip,
            .blend = .alpha,
            .uniform_blocks = (try line_module.uniformBlockNames()) orelse return error.ShaderFailed,
            .color_format = options.color_format,
            .depth_format = options.depth_format,
            .label = "debug lines",
        };
        const fill_desc: rhi.PipelineDesc = .{
            .shader = fill_shader,
            .attributes = &.{
                .{ .location = 0, .format = .float3, .offset = @offsetOf(Vertex, "position") },
                .{ .location = 1, .format = .float3, .offset = @offsetOf(Vertex, "nudge") },
                .{ .location = 2, .format = .float2, .offset = @offsetOf(Vertex, "uv") },
                .{ .location = 3, .format = .ubyte4_norm, .offset = @offsetOf(Vertex, "color") },
            },
            .buffers = &.{.{ .stride = @sizeOf(Vertex) }},
            .topology = .triangles,
            .blend = .alpha,
            .uniform_blocks = (try fill_module.uniformBlockNames()) orelse return error.ShaderFailed,
            .textures = (try fill_module.textureNames()) orelse return error.ShaderFailed,
            .color_format = options.color_format,
            .depth_format = options.depth_format,
            .label = "debug fills",
        };

        const line_pipelines = try createPipelines(device, line_desc, options);
        errdefer destroyPipelines(device, line_pipelines);
        const fill_pipelines = try createPipelines(device, fill_desc, options);
        errdefer destroyPipelines(device, fill_pipelines);

        const quad = try device.createBuffer(.{
            .kind = .vertex,
            .size = @sizeOf(@TypeOf(corners)),
            .data = std.mem.asBytes(&corners),
            .label = "debug quad",
        });
        errdefer device.destroyBuffer(quad);

        const initial_lines = 1024;
        const line_buffer = try device.createBuffer(.{
            .kind = .vertex,
            .size = initial_lines * @sizeOf(Line),
            .dynamic = true,
            .label = "debug lines",
        });
        errdefer device.destroyBuffer(line_buffer);

        const initial_vertices = 3 * 1024;
        const vertex_buffer = try device.createBuffer(.{
            .kind = .vertex,
            .size = initial_vertices * @sizeOf(Vertex),
            .dynamic = true,
            .label = "debug fills",
        });
        errdefer device.destroyBuffer(vertex_buffer);

        var frames: [2]rhi.Buffer = undefined;
        for (&frames, 0..) |*frame, made| {
            errdefer for (frames[0..made]) |done| device.destroyBuffer(done);
            frame.* = try device.createBuffer(.{ .kind = .uniform, .size = @sizeOf(Frame), .label = "debug frame" });
        }
        errdefer for (frames) |frame| device.destroyBuffer(frame);

        const glyphs = try device.createTexture(.{
            .width = font.atlas_width,
            .height = font.atlas_height,
            .format = .r8_unorm,
            .data = &font.atlas,
            .label = "debug font",
        });
        errdefer device.destroyTexture(glyphs);

        const sampler = try device.createSampler(.nearest);

        return .{
            .gpa = gpa,
            .device = device,
            .line_shader = line_shader,
            .fill_shader = fill_shader,
            .line_pipelines = line_pipelines,
            .fill_pipelines = fill_pipelines,
            .quad = quad,
            .line_buffer = line_buffer,
            .line_capacity = initial_lines,
            .vertex_buffer = vertex_buffer,
            .vertex_capacity = initial_vertices,
            .frames = frames,
            .glyphs = glyphs,
            .sampler = sampler,
        };
    }

    pub fn deinit(self: *Renderer) void {
        const device = self.device;
        device.destroySampler(self.sampler);
        device.destroyTexture(self.glyphs);
        for (self.frames) |frame| device.destroyBuffer(frame);
        device.destroyBuffer(self.vertex_buffer);
        device.destroyBuffer(self.line_buffer);
        device.destroyBuffer(self.quad);
        destroyPipelines(device, self.fill_pipelines);
        destroyPipelines(device, self.line_pipelines);
        device.destroyShader(self.fill_shader);
        device.destroyShader(self.line_shader);
        self.lines.deinit(self.gpa);
        self.vertices.deinit(self.gpa);
        self.batches.deinit(self.gpa);
        self.* = undefined;
    }

    /// Draw every canvas into the target, each as it stands. The canvases are
    /// only read: forgetting is `Canvas.advance`, and the caller's.
    pub fn draw(self: *Renderer, canvases: []const *const Canvas, target: Target, view: View) Error!void {
        try self.gather(canvases);
        self.stats = .{
            .lines = @intCast(self.lines.items.len),
            .triangles = @intCast(self.vertices.items.len / 3),
        };
        if (self.batches.items.len == 0 and target.clear == null) return;

        try self.upload();

        const clip = view.clip orelse self.device.clip();
        const viewport: [4]f32 = .{ view.width, view.height, if (clip.flip_y) -1 else 1, 0 };
        const near = nearPlane(clip);
        try self.device.updateBuffer(self.frames[@intFromEnum(Canvas.Space.world)], 0, std.mem.asBytes(&Frame{
            .view_projection = view.view_projection,
            .viewport = viewport,
            .near_plane = near,
        }));
        try self.device.updateBuffer(self.frames[@intFromEnum(Canvas.Space.screen)], 0, std.mem.asBytes(&Frame{
            .view_projection = math.proj.screen(view.width, view.height, clip),
            .viewport = viewport,
            .near_plane = near,
        }));

        const list = self.device.begin();
        try list.beginPass(.{
            .color = .{
                .target = target.color,
                .load = if (target.clear == null) .load else .clear,
                .clear_color = target.clear orelse .{ 0, 0, 0, 1 },
            },
            .depth = if (target.depth) |texture| .{ .texture = texture, .load = .load } else null,
        });
        try list.setViewport(.{ .width = view.width, .height = view.height });

        var bound: ?rhi.Pipeline = null;
        for (self.batches.items) |batch| {
            const depth = if (batch.space == .screen) .always else batch.depth;
            const pipeline = switch (batch.kind) {
                .lines => self.line_pipelines[@intFromEnum(depth)],
                .fills => self.fill_pipelines[@intFromEnum(depth)],
            };
            if (bound == null or !std.meta.eql(bound.?, pipeline)) {
                try list.setPipeline(pipeline);
                bound = pipeline;
            }
            try list.setUniformBuffer(0, self.frames[@intFromEnum(batch.space)]);
            switch (batch.kind) {
                .lines => {
                    try list.setVertexBuffer(0, self.quad, 0);
                    try list.setVertexBuffer(1, self.line_buffer, batch.first * @sizeOf(Line));
                    try list.draw(.{ .vertex_count = 4, .instance_count = batch.count });
                },
                .fills => {
                    try list.setVertexBuffer(0, self.vertex_buffer, 0);
                    try list.setTexture(0, self.glyphs, self.sampler);
                    try list.draw(.{ .vertex_count = batch.count, .first_vertex = batch.first });
                },
            }
            self.stats.draw_calls += 1;
        }

        try list.endPass();
        try self.device.submit();
    }

    /// Lay every canvas's shapes out in drawing order, and cut them into
    /// batches: the world before the screen, each in the order it was drawn.
    fn gather(self: *Renderer, canvases: []const *const Canvas) Allocator.Error!void {
        self.lines.clearRetainingCapacity();
        self.vertices.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();

        for ([_]Canvas.Space{ .world, .screen }) |space| {
            for (canvases) |canvas| {
                for (canvas.runs.items) |run| {
                    if (run.space != space or run.count == 0) continue;
                    const first: u32 = switch (run.kind) {
                        .lines => first: {
                            const at: u32 = @intCast(self.lines.items.len);
                            try self.lines.appendSlice(self.gpa, canvas.lines.items[run.first..][0..run.count]);
                            break :first at;
                        },
                        .fills => first: {
                            const at: u32 = @intCast(self.vertices.items.len);
                            try self.vertices.appendSlice(self.gpa, canvas.vertices.items[run.first..][0..run.count]);
                            break :first at;
                        },
                    };
                    try self.addBatch(.{ .kind = run.kind, .space = space, .depth = run.depth, .first = first, .count = run.count });
                }
            }
        }
    }

    fn addBatch(self: *Renderer, batch: Batch) Allocator.Error!void {
        if (self.batches.items.len > 0) {
            const last = &self.batches.items[self.batches.items.len - 1];
            if (last.kind == batch.kind and last.space == batch.space and last.depth == batch.depth) {
                last.count += batch.count;
                return;
            }
        }
        try self.batches.append(self.gpa, batch);
    }

    fn upload(self: *Renderer) Error!void {
        if (self.lines.items.len > 0) {
            try self.reserve(&self.line_buffer, &self.line_capacity, @intCast(self.lines.items.len), @sizeOf(Line), "debug lines");
            try self.device.updateBuffer(self.line_buffer, 0, std.mem.sliceAsBytes(self.lines.items));
        }
        if (self.vertices.items.len > 0) {
            try self.reserve(&self.vertex_buffer, &self.vertex_capacity, @intCast(self.vertices.items.len), @sizeOf(Vertex), "debug fills");
            try self.device.updateBuffer(self.vertex_buffer, 0, std.mem.sliceAsBytes(self.vertices.items));
        }
    }

    fn reserve(self: *Renderer, buffer: *rhi.Buffer, capacity: *u32, wanted: u32, stride: usize, label: []const u8) Error!void {
        if (wanted <= capacity.*) return;
        var grown = capacity.*;
        while (grown < wanted) grown *= 2;
        const bigger = try self.device.createBuffer(.{ .kind = .vertex, .size = grown * stride, .dynamic = true, .label = label });
        self.device.destroyBuffer(buffer.*);
        buffer.* = bigger;
        capacity.* = grown;
    }
};

fn compile(gpa: Allocator, source: []const u8, name: []const u8) Error!shader.Module {
    var messages: std.Io.Writer.Allocating = .init(gpa);
    defer messages.deinit();
    return shader.compile(gpa, source, &messages.writer) catch |err| {
        complain("{s} shader:\n{s}", .{ name, messages.written() });
        return err;
    };
}

fn createShader(device: *rhi.Device, module: *const shader.Module, label: []const u8) Error!rhi.Shader {
    return device.createShader(.{
        .glsl = .{ .vertex = module.glsl.vertex, .fragment = module.glsl.fragment },
        .glsl_es = .{ .vertex = module.glsl_es.vertex, .fragment = module.glsl_es.fragment },
        .hlsl = .{ .vertex = module.hlsl.vertex, .fragment = module.hlsl.fragment },
        .spirv = .{ .vertex = module.spirv.vertex, .fragment = module.spirv.fragment },
        .label = label,
    }) catch |err| {
        complain("{s}: {s}", .{ label, device.diagnostics() });
        return err;
    };
}

/// On wasm32-freestanding `std.log` needs a `logFn` from the program, so a
/// library says nothing there: the error, and `Device.diagnostics`, remain.
fn complain(comptime format: []const u8, arguments: anytype) void {
    if (builtin.os.tag != .freestanding) log.err(format, arguments);
}

fn createPipelines(device: *rhi.Device, desc: rhi.PipelineDesc, options: Options) Error![2]rhi.Pipeline {
    var always = desc;
    always.depth = .none;
    const drawn_over = try device.createPipeline(always);
    if (options.depth_format == null) return .{ drawn_over, drawn_over };
    errdefer device.destroyPipeline(drawn_over);

    var tested = desc;
    tested.depth = .{ .test_enabled = true, .write = false, .compare = if (options.reverse_z) .greater_equal else .less_equal };
    return .{ try device.createPipeline(tested), drawn_over };
}

fn destroyPipelines(device: *rhi.Device, pipelines: [2]rhi.Pipeline) void {
    device.destroyPipeline(pipelines[1]);
    if (!std.meta.eql(pipelines[0], pipelines[1])) device.destroyPipeline(pipelines[0]);
}

/// The plane at the near end of clip space, as the coefficients whose dot
/// product with a clip-space point is positive in front of it.
fn nearPlane(clip: math.Clip) [4]f32 {
    if (clip.reverse_z) return .{ 0, 0, -1, 1 };
    return switch (clip.depth) {
        .neg_one_to_one => .{ 0, 0, 1, 1 },
        .zero_to_one => .{ 0, 0, 1, 0 },
    };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn nothing() !rhi.Device {
    return rhi.Device.init(testing.allocator, .{ .backend = .none });
}

const screen_view: View = .{ .view_projection = .identity, .width = 64, .height = 64 };

test "the shaders read the vertices where the pipelines put them" {
    var lines = try compile(testing.allocator, lines_source, "lines");
    defer lines.deinit();
    var fills = try compile(testing.allocator, fills_source, "fills");
    defer fills.deinit();

    const expected_lines = [_]struct { []const u8, u32 }{
        .{ "corner", 0 },      .{ "start_point", 1 }, .{ "end_point", 2 },
        .{ "start_color", 3 }, .{ "end_color", 4 },   .{ "thickness", 5 },
    };
    for (expected_lines, lines.attributes) |expected, attribute| {
        try testing.expectEqualStrings(expected[0], attribute.name);
        try testing.expectEqual(expected[1], attribute.location);
    }
    const expected_fills = [_]struct { []const u8, u32 }{ .{ "place", 0 }, .{ "nudge", 1 }, .{ "texel", 2 }, .{ "tint", 3 } };
    for (expected_fills, fills.attributes) |expected, attribute| {
        try testing.expectEqualStrings(expected[0], attribute.name);
        try testing.expectEqual(expected[1], attribute.location);
    }

    for ([_]*shader.Module{ &lines, &fills }) |module| {
        const frame = module.block("Frame").?;
        try testing.expectEqual(@as(u32, @sizeOf(Frame)), frame.size);
        try testing.expectEqual(@as(?u32, @offsetOf(Frame, "viewport")), frame.offsetOf("viewport"));
        try testing.expectEqual(@as(?u32, @offsetOf(Frame, "near_plane")), frame.offsetOf("near_plane"));
    }
}

test "nothing to draw is no pass at all" {
    var device = try nothing();
    defer device.deinit();
    var renderer: Renderer = try .init(testing.allocator, &device, .{});
    defer renderer.deinit();
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    const target = try device.createTexture(.{ .width = 64, .height = 64, .usage = .{ .render_target = true } });
    try renderer.draw(&.{&canvas}, .{ .color = .{ .texture = target } }, screen_view);
    try testing.expectEqual(@as(u32, 0), renderer.stats.draw_calls);
}

test "the world is drawn before the screen, and each in the order it was drawn" {
    var device = try nothing();
    defer device.deinit();
    var renderer: Renderer = try .init(testing.allocator, &device, .{});
    defer renderer.deinit();

    var first: Canvas = .init(testing.allocator);
    defer first.deinit();
    var second: Canvas = .init(testing.allocator);
    defer second.deinit();

    const pen = first.pen();
    pen.screen().text2d(.init(4, 4), "hud", .white);
    pen.line(.zero, .unit_x, .red);
    pen.line(.zero, .unit_y, .green);
    pen.solidTriangle(.zero, .unit_x, .unit_y, .blue);
    second.pen().line(.zero, .unit_z, .blue);
    second.pen().screen().line2d(.init(0, 0), .init(8, 8), .white);

    const target = try device.createTexture(.{ .width = 64, .height = 64, .usage = .{ .render_target = true } });
    try renderer.draw(&.{ &first, &second }, .{ .color = .{ .texture = target } }, screen_view);

    const batches = renderer.batches.items;
    try testing.expectEqual(@as(usize, 5), batches.len);
    try testing.expectEqual(Canvas.Kind.lines, batches[0].kind);
    try testing.expectEqual(@as(u32, 2), batches[0].count);
    try testing.expectEqual(Canvas.Kind.fills, batches[1].kind);
    try testing.expectEqual(Canvas.Kind.lines, batches[2].kind);
    try testing.expectEqual(@as(u32, 2), batches[2].first);
    try testing.expectEqual(Canvas.Space.screen, batches[3].space);
    try testing.expectEqual(Canvas.Kind.fills, batches[3].kind);
    try testing.expectEqual(Canvas.Space.screen, batches[4].space);

    try testing.expectEqual(@as(u32, 5), renderer.stats.draw_calls);
    try testing.expectEqual(@as(u32, 4), renderer.stats.lines);
    try testing.expectEqual([3]f32{ 0, 0, 1 }, renderer.lines.items[2].end);
}

test "what a canvas counts is what the renderer draws of it" {
    var device = try nothing();
    defer device.deinit();
    var renderer: Renderer = try .init(testing.allocator, &device, .{});
    defer renderer.deinit();
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    const pen = canvas.pen();
    pen.sphere(.zero, 1, .green);
    pen.with(.{ .seconds = 3 }).solidBox(.init(.zero, .one), .red);
    pen.text(.zero, "label", .white);
    pen.screen().print2d(.init(4, 4), "{d} lines", .{canvas.count(.world).lines}, .white);
    pen.screen().circle2d(.init(30, 30), 10, .white);

    const world = canvas.count(.world);
    const screen = canvas.count(.screen);
    const target = try device.createTexture(.{ .width = 64, .height = 64, .usage = .{ .render_target = true } });
    try renderer.draw(&.{&canvas}, .{ .color = .{ .texture = target } }, screen_view);

    try testing.expectEqual(world.lines + screen.lines, renderer.stats.lines);
    try testing.expectEqual(world.triangles + screen.triangles, renderer.stats.triangles);
    try testing.expect(world.lines > 0 and world.triangles > 0 and screen.lines > 0 and screen.triangles > 0);
}

test "more shapes than the buffers hold grow them" {
    var device = try nothing();
    defer device.deinit();
    var renderer: Renderer = try .init(testing.allocator, &device, .{});
    defer renderer.deinit();
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    const lines_before = renderer.line_capacity;
    const vertices_before = renderer.vertex_capacity;
    const pen = canvas.pen();
    for (0..lines_before + 1) |i| pen.line(.zero, .init(@floatFromInt(i), 1, 0), .white);
    for (0..vertices_before / 3 + 1) |_| pen.solidTriangle(.zero, .unit_x, .unit_y, .white);

    const target = try device.createTexture(.{ .width = 64, .height = 64, .usage = .{ .render_target = true } });
    try renderer.draw(&.{&canvas}, .{ .color = .{ .texture = target } }, screen_view);

    try testing.expect(renderer.line_capacity > lines_before);
    try testing.expect(renderer.vertex_capacity > vertices_before);
    try testing.expectEqual(lines_before + 1, renderer.stats.lines);
}

test "with a depth buffer, tested and untested shapes use different pipelines" {
    var device = try nothing();
    defer device.deinit();
    var renderer: Renderer = try .init(testing.allocator, &device, .{ .depth_format = .depth32_float });
    defer renderer.deinit();

    try testing.expect(!std.meta.eql(renderer.line_pipelines[0], renderer.line_pipelines[1]));

    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();
    canvas.pen().line(.zero, .unit_x, .white);
    canvas.pen().with(.{ .depth = .always }).line(.zero, .unit_y, .white);

    const color = try device.createTexture(.{ .width = 64, .height = 64, .usage = .{ .render_target = true } });
    const depth = try device.createTexture(.{ .width = 64, .height = 64, .format = .depth32_float, .usage = .{ .sampled = false, .render_target = true } });
    try renderer.draw(&.{&canvas}, .{ .color = .{ .texture = color }, .depth = depth }, screen_view);
    try testing.expectEqual(@as(u32, 2), renderer.stats.draw_calls);
}

test "the near plane is in front for every convention" {
    const eye_point: math.Vec3 = .init(0, 0, -5);
    const behind: math.Vec3 = .init(0, 0, 5);
    for ([_]math.Clip{ .gl, .d3d, .{ .depth = .zero_to_one, .reverse_z = true }, .{ .depth = .neg_one_to_one, .reverse_z = true } }) |clip| {
        const projection = math.perspective(.{ .fov_y = 1, .aspect = 1, .near = 0.5, .far = 50, .clip = clip });
        const plane = nearPlane(clip);
        const in_front = projection.mulVec4(eye_point.point());
        const in_back = projection.mulVec4(behind.point());
        try testing.expect(in_front.dot(.fromArray(plane)) > 0);
        try testing.expect(in_back.dot(.fromArray(plane)) < 0);
    }
}

// -------------------------------------------------------------------------
// On a real GPU: Direct3D 11's software rasteriser, where there is one
// -------------------------------------------------------------------------

const Picture = struct {
    device: rhi.Device,
    renderer: Renderer,
    canvas: Canvas,
    target: rhi.Texture,
    size: u32,

    fn open(size: u32, options: Options) !*Picture {
        const self = try testing.allocator.create(Picture);
        errdefer testing.allocator.destroy(self);
        self.device = rhi.Device.init(testing.allocator, .{ .backend = .d3d11, .software = true }) catch return error.SkipZigTest;
        errdefer self.device.deinit();
        self.renderer = try .init(testing.allocator, &self.device, options);
        errdefer self.renderer.deinit();
        self.canvas = .init(testing.allocator);
        self.size = size;
        self.target = try self.device.createTexture(.{ .width = size, .height = size, .usage = .{ .sampled = true, .render_target = true } });
        return self;
    }

    fn close(self: *Picture) void {
        self.canvas.deinit();
        self.renderer.deinit();
        self.device.deinit();
        testing.allocator.destroy(self);
    }

    fn render(self: *Picture, view: View, depth: ?rhi.Texture) ![]u8 {
        try self.renderer.draw(&.{&self.canvas}, .{ .color = .{ .texture = self.target }, .depth = depth, .clear = .{ 0, 0, 0, 1 } }, view);
        return self.device.readTexture(self.target, testing.allocator);
    }

    fn flat(self: *const Picture) View {
        const side: f32 = @floatFromInt(self.size);
        return .{ .view_projection = math.proj.screen(side, side, .d3d), .width = side, .height = side };
    }
};

fn red(pixels: []const u8, size: u32, x: usize, y: usize) u8 {
    return pixels[(y * size + x) * 4];
}

test "a line one pixel wide lights the row it runs along and not the rows beside it" {
    const picture = try Picture.open(64, .{});
    defer picture.close();

    picture.canvas.pen().line2d(.init(8, 32.5), .init(56, 32.5), .white);
    const pixels = try picture.render(picture.flat(), null);
    defer testing.allocator.free(pixels);

    try testing.expect(red(pixels, 64, 32, 32) > 240);
    try testing.expect(red(pixels, 64, 32, 30) < 10);
    try testing.expect(red(pixels, 64, 32, 34) < 10);
    try testing.expect(red(pixels, 64, 3, 32) < 10);
    try testing.expect(red(pixels, 64, 61, 32) < 10);
}

test "a wide line is as wide as asked, with round ends" {
    const picture = try Picture.open(64, .{});
    defer picture.close();

    picture.canvas.pen().with(.{ .width = 9 }).line2d(.init(20, 32), .init(44, 32), .white);
    const pixels = try picture.render(picture.flat(), null);
    defer testing.allocator.free(pixels);

    try testing.expect(red(pixels, 64, 32, 29) > 240);
    try testing.expect(red(pixels, 64, 32, 35) > 240);
    try testing.expect(red(pixels, 64, 32, 38) < 10);
    try testing.expect(red(pixels, 64, 16, 32) > 240);
    try testing.expect(red(pixels, 64, 16, 28) < 60);
}

test "a point is a disc of the size asked" {
    const picture = try Picture.open(32, .{});
    defer picture.close();

    picture.canvas.pen().point2d(.init(16, 16), 10, .white);
    const pixels = try picture.render(picture.flat(), null);
    defer testing.allocator.free(pixels);

    try testing.expect(red(pixels, 32, 16, 16) > 240);
    try testing.expect(red(pixels, 32, 18, 18) > 200);
    try testing.expect(red(pixels, 32, 20, 20) < 60);
    try testing.expect(red(pixels, 32, 23, 16) < 10);
}

test "text lands on whole pixels where it was put" {
    const picture = try Picture.open(32, .{});
    defer picture.close();

    picture.canvas.pen().with(.{ .text_shadow = false }).screen().text2d(.init(10.3, 10.4), "|", .white);
    const pixels = try picture.render(picture.flat(), null);
    defer testing.allocator.free(pixels);

    for (10..17) |y| try testing.expectEqual(@as(u8, 255), red(pixels, 32, 12, y));
    try testing.expectEqual(@as(u8, 0), red(pixels, 32, 11, 13));
    try testing.expectEqual(@as(u8, 0), red(pixels, 32, 13, 13));
    try testing.expectEqual(@as(u8, 0), red(pixels, 32, 12, 9));
}

test "a line from behind the camera is cut at the near plane, not turned inside out" {
    const picture = try Picture.open(64, .{});
    defer picture.close();

    const projection = math.perspective(.{ .fov_y = math.radians(90), .aspect = 1, .near = 0.1, .far = 100, .clip = .d3d });
    picture.canvas.pen().with(.{ .width = 3 }).line(.init(0, -1, 5), .init(0, -1, -10), .white);
    const pixels = try picture.render(.{ .view_projection = projection, .width = 64, .height = 64 }, null);
    defer testing.allocator.free(pixels);

    try testing.expect(red(pixels, 64, 32, 36) > 200);
    try testing.expect(red(pixels, 64, 32, 60) > 200);
    try testing.expect(red(pixels, 64, 32, 20) < 10);
    try testing.expect(red(pixels, 64, 10, 50) < 10);
}

test "a tested shape hides behind the scene and an untested one does not" {
    const picture = try Picture.open(32, .{ .depth_format = .depth32_float });
    defer picture.close();

    const depth = try picture.device.createTexture(.{ .width = 32, .height = 32, .format = .depth32_float, .usage = .{ .sampled = false, .render_target = true } });
    const list = picture.device.begin();
    try list.beginPass(.{ .color = .{ .target = .{ .texture = picture.target } }, .depth = .{ .texture = depth, .clear_depth = 0.25 } });
    try list.endPass();
    try picture.device.submit();

    const pen = picture.canvas.pen().with(.{ .width = 3 });
    pen.line2d(.init(4, 8), .init(28, 8), .white);
    pen.with(.{ .depth = .always }).line2d(.init(4, 24), .init(28, 24), .white);

    const pixels = try picture.render(picture.flat(), depth);
    defer testing.allocator.free(pixels);

    try testing.expect(red(pixels, 32, 16, 8) < 10);
    try testing.expect(red(pixels, 32, 16, 24) > 240);
}
