// SPDX-License-Identifier: BSD-2-Clause

//! Everything the pen draws, in one scene a camera goes round.
//!
//! ```bash
//! zig build example
//! zig build example -- --backend gl
//! zig build example -- --capture shapes.png --at 2.5
//! ```
//!
//! `--capture` draws the scene as it is at `--at` seconds into a texture and
//! writes it out, with no window shown: the same picture every time, which is
//! what the test at the bottom holds the two backends to.

const std = @import("std");
const Io = std.Io;

const math = @import("fluxion_math");
const rhi = @import("fluxion_rhi");
const image = @import("fluxion_image");
const debugdraw = @import("fluxion_debugdraw");
const render = @import("fluxion_debugdraw_rhi");

const windowing = @import("window.zig");
const Window = windowing.Window;

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Color = debugdraw.Color;
const Canvas = debugdraw.Canvas;
const Pen = debugdraw.Pen;

const background: [4]f32 = .{ 0.055, 0.063, 0.075, 1 };
const step: f32 = 1.0 / 60.0;

/// What the corner of the screen says besides what is in the world.
const Info = struct {
    backend: ?rhi.Backend = null,
    /// Null in a capture, which has a moment rather than a frame rate.
    fps: ?f32 = null,
};

fn viewAt(t: f32, width: f32, height: f32, clip: math.Clip) math.Mat4 {
    const angle = t * 0.3 + 0.7;
    const eye: Vec3 = .init(@cos(angle) * 11, 6, @sin(angle) * 11);
    const view = math.lookAt(eye, .init(0, 0.8, 0), .unit_y, .right);
    const projection = math.perspective(.{
        .fov_y = math.radians(55),
        .aspect = width / height,
        .near = 0.1,
        .far = 100,
        .clip = clip,
    });
    return projection.mul(view);
}

fn ballAt(t: f32) Vec3 {
    return .init(0, 1.3 + @sin(t * 2) * 0.6, 3);
}

fn drawScene(pen: Pen, t: f32) void {
    pen.grid(.zero, .init(1, 0, 0), .init(0, 0, 1), 8, Color.gray.withAlpha(0.35));
    pen.with(.{ .width = 3 }).axes(.identity, 1.5);

    const crate: math.Aabb = .init(.init(-4.5, 0, -3), .init(-2.5, 1.5, -1));
    pen.box(crate, .orange);
    pen.with(.{ .anchor = .bottom }).text(.init(-3.5, 1.7, -2), "box", .orange);

    const turn: math.Quat = .fromAxisAngle(.unit_y, t * 0.8);
    pen.with(.{ .width = 2 }).orientedBox(.init(3.5, 0.8, -2), .init(1, 0.6, 0.4), turn, .cyan);
    pen.with(.{ .anchor = .bottom }).text(.init(3.5, 1.7, -2), "oriented box", .cyan);

    const ball = ballAt(t);
    pen.sphere(ball, 0.8, .green);
    pen.with(.{ .width = 2 }).arrow(ball, ball.add(.init(0, @cos(t * 2) * 1.8, 0)), .yellow);
    pen.with(.{ .anchor = .left }).print(ball.add(.init(1, 0, 0)), "height {d:.2}", .{ball.y}, .white);

    pen.capsule(.init(-4, 0.6, 2), .init(-2.5, 2.2, 3.5), 0.5, .magenta);
    pen.cone(.init(4, 2.2, 2.5), .init(4, 0, 2.5), 0.8, .red);
    pen.cylinder(.init(1.8, 0, 5), .init(1.8, 1.4, 5), 0.5, .blue);

    const trigger: math.Aabb = .init(.init(-1, 0, -5.5), .init(1, 1.2, -4));
    pen.solidBox(trigger, Color.cyan.withAlpha(0.15));
    pen.box(trigger, Color.cyan.withAlpha(0.8));
    pen.with(.{ .anchor = .bottom }).text(.init(0, 1.4, -4.75), "trigger", Color.cyan.withAlpha(0.8));

    const lens_eye: Vec3 = .init(6, 3, -6);
    const lens = math.perspective(.{ .fov_y = math.radians(40), .aspect = 1.5, .near = 0.5, .far = 5, .clip = .gl })
        .mul(math.lookAt(lens_eye, .init(0, 0.5, 0), .unit_y, .right));
    pen.frustum(lens.inverse().?, .gl, .yellow);
    pen.point(lens_eye, 9, .yellow);
    pen.with(.{ .anchor = .bottom_left }).text(lens_eye.add(.init(0.3, 0.3, 0)), "camera 2", .yellow);

    const ring = pen.with(.{ .width = 4 });
    ring.circle(.init(0, 0.01, 0), .unit_y, 6.5, Color.white.withAlpha(0.25));
    ring.arc(.init(0, 0.01, 0), .unit_y, .init(@cos(t), 0, -@sin(t)), 1.2, 6.5, .green);
    for (0..12) |i| {
        const at = @as(f32, @floatFromInt(i)) / 12 * std.math.tau - t * 0.5;
        pen.point(.init(@cos(at) * 7.5, 0.05, @sin(at) * 7.5), 2 + @as(f32, @floatFromInt(i)), .white);
    }
    pen.lineGradient(.init(-6, 0.05, 6), .init(6, 0.05, 6), .red, .blue);
}

/// Every half second, a mark where the ball is that stays for two.
fn dropMarks(pen: Pen, from: f32, to: f32) void {
    if (@floor(to * 2) == @floor(from * 2)) return;
    pen.with(.{ .seconds = 2, .width = 2 }).cross(ballAt(to), 0.5, .yellow);
}

fn drawOverlay(pen: Pen, t: f32, width: f32, height: f32, world: Canvas.Count, info: Info) void {
    const hud = pen.screen();
    hud.solidRect2d(.init(12, 12), .init(300, 70), Color.black.withAlpha(0.6));
    hud.rect2d(.init(12, 12), .init(300, 70), Color.white.withAlpha(0.2));
    hud.with(.{ .text_scale = 2 }).text2d(.init(22, 20), "fluxion-debugdraw", .white);
    hud.print2d(.init(22, 48), "{d} lines, {d} triangles in the world", .{ world.lines, world.triangles }, .gray);

    var buffer: [64]u8 = undefined;
    var status: std.Io.Writer = .fixed(&buffer);
    if (info.backend) |backend| status.print("{t}, ", .{backend}) catch {};
    if (info.fps) |fps| {
        status.print("{d:.0} frames a second", .{fps}) catch {};
    } else {
        status.print("captured at {d:.2} seconds", .{t}) catch {};
    }
    hud.text2d(.init(22, 62), status.buffered(), .gray);

    const radius = 60;
    const middle: Vec2 = .init(width - radius - 16, height - radius - 16);
    hud.solidCircle2d(middle, radius, Color.black.withAlpha(0.55));
    hud.circle2d(middle, radius, Color.green.withAlpha(0.8));
    hud.circle2d(middle, radius / 2, Color.green.withAlpha(0.3));
    hud.line2d(middle.add(.init(-radius, 0)), middle.add(.init(radius, 0)), Color.green.withAlpha(0.3));
    hud.line2d(middle.add(.init(0, -radius)), middle.add(.init(0, radius)), Color.green.withAlpha(0.3));
    hud.with(.{ .width = 2 }).line2d(middle, middle.add(Vec2.fromAngle(t * 2).scale(radius)), .green);
    for ([_]Vec3{ .init(-3.5, 0, -2), .init(3.5, 0, -2), ballAt(t), .init(-3.2, 0, 2.7), .init(4, 0, 2.5) }) |thing| {
        hud.point2d(middle.add(Vec2.init(thing.x, thing.z).scale(7)), 6, .yellow);
    }
    hud.with(.{ .anchor = .bottom }).text2d(middle.sub(.init(0, radius + 6)), "above", .green);
}

/// The world first, so the corner can count all of it: this frame's number,
/// not the renderer's from the frame before - which a capture does not have.
fn drawFrame(canvas: *Canvas, t: f32, width: f32, height: f32, info: Info) void {
    const pen = canvas.pen();
    drawScene(pen, t);
    drawOverlay(pen, t, width, height, canvas.count(.world), info);
}

/// The scene at `at` seconds, into a texture: stepped there a sixtieth at a
/// time, so the lasting marks are where they would have been.
fn picture(gpa: std.mem.Allocator, device: *rhi.Device, renderer: *render.Renderer, width: u32, height: u32, at: f32, info: Info) ![]u8 {
    var canvas: Canvas = .init(gpa);
    defer canvas.deinit();

    var t: f32 = 0;
    while (t + step <= at) : (t += step) {
        dropMarks(canvas.pen(), t, t + step);
        canvas.advance(step);
    }

    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    drawFrame(&canvas, at, w, h, info);

    const target = try device.createTexture(.{ .width = width, .height = height, .usage = .{ .render_target = true } });
    defer device.destroyTexture(target);
    try renderer.draw(&.{&canvas}, .{ .color = .{ .texture = target }, .clear = background }, .{
        .view_projection = viewAt(at, w, h, device.clip()),
        .width = w,
        .height = h,
    });
    return device.readTexture(target, gpa);
}

const Options = struct {
    backend: rhi.Backend,
    width: u32 = 1280,
    height: u32 = 720,
    frames: ?u32 = null,
    capture: ?[]const u8 = null,
    at: f32 = 2.5,

    fn parse(arguments: []const []const u8) !Options {
        var self: Options = .{ .backend = windowing.defaultBackend() };
        var i: usize = 1;
        while (i + 1 < arguments.len) : (i += 2) {
            const name = arguments[i];
            const value = arguments[i + 1];
            if (std.mem.eql(u8, name, "--backend")) {
                self.backend = std.meta.stringToEnum(rhi.Backend, value) orelse return error.UnknownBackend;
            } else if (std.mem.eql(u8, name, "--width")) {
                self.width = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, name, "--height")) {
                self.height = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, name, "--frames")) {
                self.frames = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, name, "--capture")) {
                self.capture = value;
            } else if (std.mem.eql(u8, name, "--at")) {
                self.at = try std.fmt.parseFloat(f32, value);
            } else return error.UnknownFlag;
        }
        if (i < arguments.len) return error.MissingValue;
        return self;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout.interface;

    const options = try Options.parse(try init.minimal.args.toSlice(init.arena.allocator()));

    var window: Window = try .open(.{
        .backend = options.backend,
        .title = "Fluxion Debug Draw",
        .width = options.width,
        .height = options.height,
        .visible = options.capture == null,
    });
    defer window.close();
    var device = try window.openDevice(gpa);
    defer device.deinit();
    var renderer: render.Renderer = try .init(gpa, &device, .{});
    defer renderer.deinit();

    if (options.capture) |path| {
        const pixels = try picture(gpa, &device, &renderer, options.width, options.height, options.at, .{
            .backend = options.backend,
        });
        defer gpa.free(pixels);
        try image.png.writeFile(gpa, init.io, path, .{
            .width = options.width,
            .height = options.height,
            .pixels = pixels,
            .row_pitch = @as(usize, options.width) * 4,
        }, .{});
        try out.print("wrote {s}: {d} lines and {d} triangles in {d} draws, the corner's own included\n", .{
            path, renderer.stats.lines, renderer.stats.triangles, renderer.stats.draw_calls,
        });
        return out.flush();
    }

    const surface = try window.createSurface(&device);
    var canvas: Canvas = .init(gpa);
    defer canvas.deinit();

    var last = Io.Timestamp.now(init.io, .awake).nanoseconds;
    var t: f32 = 0;
    var fps: f32 = 60;
    var frames: u32 = 0;
    while (window.pump()) {
        if (window.width == 0 or window.height == 0) continue;
        if (window.resized) {
            window.resized = false;
            try device.resizeSurface(surface, window.width, window.height);
        }

        const now = Io.Timestamp.now(init.io, .awake).nanoseconds;
        const delta = @min(@as(f32, @floatFromInt(now - last)) / std.time.ns_per_s, 0.25);
        last = now;
        if (delta > 0) fps += (1 / delta - fps) * 0.05;

        dropMarks(canvas.pen(), t, t + delta);
        t += delta;

        const w: f32 = @floatFromInt(window.width);
        const h: f32 = @floatFromInt(window.height);
        drawFrame(&canvas, t, w, h, .{ .backend = options.backend, .fps = fps });
        try renderer.draw(&.{&canvas}, .{ .color = .{ .surface = surface }, .clear = background }, .{
            .view_projection = viewAt(t, w, h, device.clip()),
            .width = w,
            .height = h,
        });
        try device.present(surface);
        canvas.advance(delta);

        frames += 1;
        if (options.frames) |limit| if (frames >= limit) break;
    }
}

const testing = std.testing;

const test_width = 320;
const test_height = 200;

fn frameOn(backend: rhi.Backend) ![]u8 {
    var window: ?Window = null;
    defer if (window) |*w| w.close();

    var device = switch (backend) {
        .gl => gl: {
            window = Window.open(.{ .backend = .gl, .title = "test", .width = 64, .height = 64, .visible = false }) catch |err|
                return if (Window.isAbsent(err)) error.SkipZigTest else err;
            break :gl window.?.openDevice(testing.allocator) catch |err|
                return if (Window.isAbsent(err)) error.SkipZigTest else err;
        },
        .d3d11 => rhi.Device.init(testing.allocator, .{ .backend = .d3d11, .software = true }) catch |err|
            return if (Window.isAbsent(err)) error.SkipZigTest else err,
        else => return error.SkipZigTest,
    };
    defer device.deinit();

    var renderer: render.Renderer = try .init(testing.allocator, &device, .{});
    defer renderer.deinit();
    return picture(testing.allocator, &device, &renderer, test_width, test_height, 1.5, .{});
}

test "the scene is drawn, and it is the same picture on OpenGL and on Direct3D" {
    const direct3d = try frameOn(.d3d11);
    defer testing.allocator.free(direct3d);
    const opengl = try frameOn(.gl);
    defer testing.allocator.free(opengl);

    var drawn: usize = 0;
    var different: usize = 0;
    var i: usize = 0;
    while (i < direct3d.len) : (i += 4) {
        var worst: u8 = 0;
        var from_background: u8 = 0;
        for (0..3) |channel| {
            const clear: u8 = @intFromFloat(@round(background[channel] * 255));
            worst = @max(worst, @max(direct3d[i + channel], opengl[i + channel]) - @min(direct3d[i + channel], opengl[i + channel]));
            from_background = @max(from_background, @max(direct3d[i + channel], clear) - @min(direct3d[i + channel], clear));
        }
        if (worst > 48) different += 1;
        if (from_background > 24) drawn += 1;
    }

    const pixels = test_width * test_height;
    try testing.expect(drawn > pixels / 20);
    try testing.expect(different < pixels / 100);
}

test "the whole scene records and draws with no GPU at all" {
    var device = try rhi.Device.init(testing.allocator, .{ .backend = .none });
    defer device.deinit();
    var renderer: render.Renderer = try .init(testing.allocator, &device, .{});
    defer renderer.deinit();

    const pixels = try picture(testing.allocator, &device, &renderer, test_width, test_height, 3.0, .{ .backend = .none });
    defer testing.allocator.free(pixels);

    try testing.expect(renderer.stats.lines > 500);
    try testing.expect(renderer.stats.triangles > 100);
    try testing.expectEqual(@as(usize, test_width * test_height * 4), pixels.len);
}

test "a mark dropped every half second stays for two" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    var t: f32 = 0;
    while (t + step <= 4.75) : (t += step) {
        dropMarks(canvas.pen(), t, t + step);
        canvas.advance(step);
    }
    try testing.expectEqual(@as(usize, 4), canvas.runs.items.len);
}
