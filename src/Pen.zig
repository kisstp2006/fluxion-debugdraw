// SPDX-License-Identifier: BSD-2-Clause

//! What draws on a `Canvas`. A value: copy it, change its style, keep it -
//! nothing it does changes any other pen.
//!
//! ```zig
//! const pen = canvas.pen();
//! pen.line(.zero, .init(0, 2, 0), .green);
//! pen.with(.{ .width = 3, .seconds = 2 }).sphere(hit, 0.25, .red);
//! pen.screen().print2d(.init(8, 8), "{d} bodies", .{count}, .white);
//! ```
//!
//! The functions ending in `2d` take `Vec2`s and put them at `z = 0`, with
//! angles turning `x` towards `y`: clockwise on a screen whose `y` points
//! down. Filled shapes start with `solid`; everything else is lines.

const std = @import("std");
const testing = std.testing;
const math = @import("fluxion_math");

const Canvas = @import("Canvas.zig");
const Color = @import("color.zig").Color;
const font = @import("font.zig");

const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Quat = math.Quat;
const Aabb = math.Aabb;
const Line = Canvas.Line;
const Vertex = Canvas.Vertex;

const Pen = @This();

const tau = std.math.tau;
const arrow_head = 0.2;

/// Which point of a piece of text goes where it is drawn.
pub const Anchor = enum {
    top_left,
    top,
    top_right,
    left,
    center,
    right,
    bottom_left,
    bottom,
    bottom_right,

    fn fractions(self: Anchor) [2]f32 {
        const index = @intFromEnum(self);
        return .{
            @as(f32, @floatFromInt(index % 3)) / 2,
            @as(f32, @floatFromInt(index / 3)) / 2,
        };
    }
};

pub const Style = struct {
    /// Pixels.
    width: f32 = 1,
    depth: Canvas.Depth = .tested,
    /// How long it stays. Zero is until the canvas next advances: one frame.
    seconds: f32 = 0,
    /// Straight pieces in a whole circle.
    segments: u16 = 32,
    /// Screen pixels to a font pixel. Whole numbers stay sharp.
    text_scale: f32 = 1,
    anchor: Anchor = .top_left,
    text_shadow: bool = true,

    /// The same fields, each left alone when null. See `Pen.with`.
    pub const Changes = struct {
        width: ?f32 = null,
        depth: ?Canvas.Depth = null,
        seconds: ?f32 = null,
        segments: ?u16 = null,
        text_scale: ?f32 = null,
        anchor: ?Anchor = null,
        text_shadow: ?bool = null,
    };

    pub fn changed(self: Style, changes: Changes) Style {
        var out = self;
        inline for (@typeInfo(Changes).@"struct".fields) |field| {
            if (@field(changes, field.name)) |value| @field(out, field.name) = value;
        }
        return out;
    }
};

canvas: *Canvas,
space: Canvas.Space = .world,
style: Style = .{},
/// Applied to every point before it is stored. Pixel sizes are not moved by
/// it: widths and text stay the size they were asked to be.
transform: ?Mat4 = null,

/// This pen with some of its style changed.
pub fn with(self: Pen, changes: Style.Changes) Pen {
    var out = self;
    out.style = self.style.changed(changes);
    return out;
}

/// This pen, drawing in pixels from the top left of the target, over the
/// world. The transform stays behind: it was the world's.
pub fn screen(self: Pen) Pen {
    var out = self;
    out.space = .screen;
    out.transform = null;
    return out;
}

/// This pen, drawing in the frame `transform` puts things in: a body's local
/// space, or a bone's.
pub fn within(self: Pen, transform: Mat4) Pen {
    var out = self;
    out.transform = if (self.transform) |outer| outer.mul(transform) else transform;
    return out;
}

pub fn within2d(self: Pen, at: Vec2, angle: f32) Pen {
    return self.within(Mat4.fromTranslation(flat(at)).mul(.fromAxisAngle(.unit_z, angle)));
}

// -------------------------------------------------------------------------
// Lines and points
// -------------------------------------------------------------------------

pub fn line(self: Pen, from: Vec3, to: Vec3, color: Color) void {
    self.lineGradient(from, to, color, color);
}

pub fn lineGradient(self: Pen, from: Vec3, to: Vec3, from_color: Color, to_color: Color) void {
    self.canvas.addLine(self.space, self.style.depth, self.style.seconds, .{
        .start = self.place(from),
        .end = self.place(to),
        .start_color = from_color,
        .end_color = to_color,
        .width = self.style.width,
    });
}

pub fn polyline(self: Pen, points: []const Vec3, color: Color) void {
    if (points.len < 2) return;
    for (points[0 .. points.len - 1], points[1..]) |a, b| self.line(a, b, color);
}

/// A polyline back to where it started.
pub fn polygon(self: Pen, points: []const Vec3, color: Color) void {
    self.polyline(points, color);
    if (points.len > 2) self.line(points[points.len - 1], points[0], color);
}

/// A round dot `size` pixels across, however far away.
pub fn point(self: Pen, at: Vec3, size: f32, color: Color) void {
    const where = self.place(at);
    self.canvas.addLine(self.space, self.style.depth, self.style.seconds, .{
        .start = where,
        .end = where,
        .start_color = color,
        .end_color = color,
        .width = size,
    });
}

/// Three lines through a point, along the axes, `size` long.
pub fn cross(self: Pen, at: Vec3, size: f32, color: Color) void {
    const half = size / 2;
    self.line(at.add(.init(-half, 0, 0)), at.add(.init(half, 0, 0)), color);
    self.line(at.add(.init(0, -half, 0)), at.add(.init(0, half, 0)), color);
    self.line(at.add(.init(0, 0, -half)), at.add(.init(0, 0, half)), color);
}

pub fn arrow(self: Pen, from: Vec3, to: Vec3, color: Color) void {
    self.line(from, to, color);
    const shaft = to.sub(from);
    const direction = shaft.tryNorm() orelse return;
    const head = shaft.len() * arrow_head;
    const side = direction.anyPerp().scale(head * 0.4);
    const other = direction.cross(side);
    const base = to.sub(direction.scale(head));
    self.line(to, base.add(side), color);
    self.line(to, base.sub(side), color);
    self.line(to, base.add(other), color);
    self.line(to, base.sub(other), color);
}

// -------------------------------------------------------------------------
// Curves
// -------------------------------------------------------------------------

pub fn circle(self: Pen, center: Vec3, normal: Vec3, radius: f32, color: Color) void {
    const plane = planeOf(normal) orelse return;
    self.curve(center, plane[0].scale(radius), plane[1].scale(radius), 0, tau, color);
}

/// Part of a circle, from `start` round the normal by `sweep` radians,
/// anticlockwise looking down the normal at it.
pub fn arc(self: Pen, center: Vec3, normal: Vec3, start: Vec3, sweep: f32, radius: f32, color: Color) void {
    const n = normal.tryNorm() orelse return;
    const u = start.reject(n).tryNorm() orelse return;
    self.curve(center, u.scale(radius), n.cross(u).scale(radius), 0, sweep, color);
}

/// Three rings, one round each axis.
pub fn sphere(self: Pen, center: Vec3, radius: f32, color: Color) void {
    const x = Vec3.unit_x.scale(radius);
    const y = Vec3.unit_y.scale(radius);
    const z = Vec3.unit_z.scale(radius);
    self.curve(center, x, y, 0, tau, color);
    self.curve(center, y, z, 0, tau, color);
    self.curve(center, z, x, 0, tau, color);
}

// -------------------------------------------------------------------------
// Volumes
// -------------------------------------------------------------------------

pub fn box(self: Pen, bounds: Aabb, color: Color) void {
    self.edges(cornersOf(bounds), color);
}

pub fn orientedBox(self: Pen, center: Vec3, half_extents: Vec3, rotation: Quat, color: Color) void {
    var corners: [8]Vec3 = undefined;
    for (&corners, 0..) |*corner, i| {
        const signs: Vec3 = .init(sign(i, 1), sign(i, 2), sign(i, 4));
        corner.* = center.add(rotation.rotate(half_extents.mul(signs)));
    }
    self.edges(corners, color);
}

/// The edges of what a camera sees, from the inverse of the view-projection
/// it was drawn with.
pub fn frustum(self: Pen, inverse_view_projection: Mat4, clip: math.Clip, color: Color) void {
    const range = clip.depthRange();
    var corners: [8]Vec3 = undefined;
    for (&corners, 0..) |*corner, i| {
        const ndc: Vec3 = .init(sign(i, 1), sign(i, 2), if (i & 4 != 0) range.far else range.near);
        corner.* = inverse_view_projection.project(ndc) orelse return;
    }
    self.edges(corners, color);
}

/// A ring at the base, and four lines up to the point.
pub fn cone(self: Pen, apex: Vec3, base: Vec3, radius: f32, color: Color) void {
    const plane = planeOf(base.sub(apex)) orelse return;
    const u = plane[0].scale(radius);
    const v = plane[1].scale(radius);
    self.curve(base, u, v, 0, tau, color);
    for ([_]Vec3{ u, v, u.neg(), v.neg() }) |out| self.line(apex, base.add(out), color);
}

pub fn cylinder(self: Pen, from: Vec3, to: Vec3, radius: f32, color: Color) void {
    const plane = planeOf(to.sub(from)) orelse return;
    const u = plane[0].scale(radius);
    const v = plane[1].scale(radius);
    self.curve(from, u, v, 0, tau, color);
    self.curve(to, u, v, 0, tau, color);
    for ([_]Vec3{ u, v, u.neg(), v.neg() }) |out| self.line(from.add(out), to.add(out), color);
}

/// Every point within `radius` of the segment: a sphere when the two ends
/// meet.
pub fn capsule(self: Pen, from: Vec3, to: Vec3, radius: f32, color: Color) void {
    const along = to.sub(from).tryNorm() orelse return self.sphere(from, radius, color);
    const plane = planeOf(along) orelse return;
    const u = plane[0].scale(radius);
    const v = plane[1].scale(radius);
    const up = along.scale(radius);
    self.curve(from, u, v, 0, tau, color);
    self.curve(to, u, v, 0, tau, color);
    for ([_]Vec3{ u, v, u.neg(), v.neg() }) |out| self.line(from.add(out), to.add(out), color);
    self.curve(to, u, up, 0, std.math.pi, color);
    self.curve(to, v, up, 0, std.math.pi, color);
    self.curve(from, u, up.neg(), 0, std.math.pi, color);
    self.curve(from, v, up.neg(), 0, std.math.pi, color);
}

/// A frame's three axes, `length` long: `x` red, `y` green, `z` blue.
pub fn axes(self: Pen, frame: Mat4, length: f32) void {
    const origin = frame.mulPoint(.zero);
    self.line(origin, frame.mulPoint(.init(length, 0, 0)), .red);
    self.line(origin, frame.mulPoint(.init(0, length, 0)), .green);
    self.line(origin, frame.mulPoint(.init(0, 0, length)), .blue);
}

/// `count` cells out from the centre each way, each cell one `cell_u` by one
/// `cell_v`.
pub fn grid(self: Pen, center: Vec3, cell_u: Vec3, cell_v: Vec3, count: u32, color: Color) void {
    const reach: f32 = @floatFromInt(count);
    for (0..2 * count + 1) |i| {
        const at = @as(f32, @floatFromInt(i)) - reach;
        const across_u = center.add(cell_u.scale(at));
        const across_v = center.add(cell_v.scale(at));
        self.line(across_u.sub(cell_v.scale(reach)), across_u.add(cell_v.scale(reach)), color);
        self.line(across_v.sub(cell_u.scale(reach)), across_v.add(cell_u.scale(reach)), color);
    }
}

// -------------------------------------------------------------------------
// Filled
// -------------------------------------------------------------------------

pub fn solidTriangle(self: Pen, a: Vec3, b: Vec3, c: Vec3, color: Color) void {
    self.fill(&.{ self.solid(a, color), self.solid(b, color), self.solid(c, color) });
}

pub fn solidQuad(self: Pen, a: Vec3, b: Vec3, c: Vec3, d: Vec3, color: Color) void {
    const corners = [4]Vertex{ self.solid(a, color), self.solid(b, color), self.solid(c, color), self.solid(d, color) };
    self.fill(&.{ corners[0], corners[1], corners[2], corners[0], corners[2], corners[3] });
}

pub fn solidBox(self: Pen, bounds: Aabb, color: Color) void {
    const corners = cornersOf(bounds);
    const faces = [6][4]u3{
        .{ 0, 2, 6, 4 }, .{ 1, 3, 7, 5 },
        .{ 0, 1, 5, 4 }, .{ 2, 3, 7, 6 },
        .{ 0, 1, 3, 2 }, .{ 4, 5, 7, 6 },
    };
    for (faces) |face| {
        self.solidQuad(corners[face[0]], corners[face[1]], corners[face[2]], corners[face[3]], color);
    }
}

// -------------------------------------------------------------------------
// Text
// -------------------------------------------------------------------------

/// Printable ASCII, at the same size in pixels however far away it is.
/// `\n` starts a line and `\t` moves to the next column of four; anything
/// else the font has not got is a hollow box.
pub fn text(self: Pen, at: Vec3, string: []const u8, color: Color) void {
    const scale = if (self.style.text_scale > 0) self.style.text_scale else 1;
    const size = measure(string);
    if (size.columns == 0) return;

    const width: f32 = @floatFromInt(size.columns * font.advance - (font.advance - font.glyph_width));
    const height: f32 = @floatFromInt(size.lines * font.line_height - (font.line_height - font.glyph_height));
    const fractions = self.style.anchor.fractions();
    const left = @round(-fractions[0] * width * scale);
    const top = @round(-fractions[1] * height * scale);
    const where = self.place(at);

    if (self.style.text_shadow) {
        const shade: Color = .{ .r = 0, .g = 0, .b = 0, .a = @intCast(@as(u16, color.a) * 3 / 4) };
        self.glyphs(where, string, left + scale, top + scale, scale, shade);
    }
    self.glyphs(where, string, left, top, scale, color);
}

/// `text`, formatted first. What does not fit in 256 bytes is left off.
pub fn print(self: Pen, at: Vec3, comptime format: []const u8, arguments: anytype, color: Color) void {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.print(format, arguments) catch {};
    self.text(at, writer.buffered(), color);
}

// -------------------------------------------------------------------------
// In the plane
// -------------------------------------------------------------------------

pub fn line2d(self: Pen, from: Vec2, to: Vec2, color: Color) void {
    self.line(flat(from), flat(to), color);
}

pub fn polyline2d(self: Pen, points: []const Vec2, color: Color) void {
    if (points.len < 2) return;
    for (points[0 .. points.len - 1], points[1..]) |a, b| self.line2d(a, b, color);
}

pub fn polygon2d(self: Pen, points: []const Vec2, color: Color) void {
    self.polyline2d(points, color);
    if (points.len > 2) self.line2d(points[points.len - 1], points[0], color);
}

/// A convex polygon, filled.
pub fn solidPolygon2d(self: Pen, points: []const Vec2, color: Color) void {
    if (points.len < 3) return;
    for (points[1 .. points.len - 1], points[2..]) |b, c| {
        self.solidTriangle(flat(points[0]), flat(b), flat(c), color);
    }
}

pub fn point2d(self: Pen, at: Vec2, size: f32, color: Color) void {
    self.point(flat(at), size, color);
}

pub fn cross2d(self: Pen, at: Vec2, size: f32, color: Color) void {
    const half = size / 2;
    self.line2d(at.add(.init(-half, 0)), at.add(.init(half, 0)), color);
    self.line2d(at.add(.init(0, -half)), at.add(.init(0, half)), color);
}

pub fn arrow2d(self: Pen, from: Vec2, to: Vec2, color: Color) void {
    self.line2d(from, to, color);
    const shaft = to.sub(from);
    const direction = shaft.tryNorm() orelse return;
    const head = shaft.len() * arrow_head;
    const side = direction.perp().scale(head * 0.4);
    const base = to.sub(direction.scale(head));
    self.line2d(to, base.add(side), color);
    self.line2d(to, base.sub(side), color);
}

pub fn circle2d(self: Pen, center: Vec2, radius: f32, color: Color) void {
    self.curve(flat(center), .init(radius, 0, 0), .init(0, radius, 0), 0, tau, color);
}

pub fn solidCircle2d(self: Pen, center: Vec2, radius: f32, color: Color) void {
    const pieces = @max(self.style.segments, 3);
    var previous = center.add(.init(radius, 0));
    for (1..pieces + 1) |i| {
        const angle = tau * @as(f32, @floatFromInt(i % pieces)) / @as(f32, @floatFromInt(pieces));
        const next = center.add(Vec2.fromAngle(angle).scale(radius));
        self.solidTriangle(flat(center), flat(previous), flat(next), color);
        previous = next;
    }
}

/// From angle `from` to angle `to`, in radians.
pub fn arc2d(self: Pen, center: Vec2, radius: f32, from: f32, to: f32, color: Color) void {
    self.curve(flat(center), .init(radius, 0, 0), .init(0, radius, 0), from, to - from, color);
}

/// From its top left corner, `size` across and down.
pub fn rect2d(self: Pen, corner: Vec2, size: Vec2, color: Color) void {
    const far = corner.add(size);
    self.polygon2d(&.{ corner, .init(far.x, corner.y), far, .init(corner.x, far.y) }, color);
}

pub fn solidRect2d(self: Pen, corner: Vec2, size: Vec2, color: Color) void {
    const far = corner.add(size);
    self.solidQuad(flat(corner), .init(far.x, corner.y, 0), flat(far), .init(corner.x, far.y, 0), color);
}

pub fn capsule2d(self: Pen, from: Vec2, to: Vec2, radius: f32, color: Color) void {
    const along = to.sub(from).tryNorm() orelse return self.circle2d(from, radius, color);
    const side = along.perp().scale(radius);
    const reach = along.scale(radius);
    self.line2d(from.add(side), to.add(side), color);
    self.line2d(from.sub(side), to.sub(side), color);
    self.curve(flat(to), flat(side), flat(reach), 0, std.math.pi, color);
    self.curve(flat(from), flat(side), flat(reach.neg()), 0, std.math.pi, color);
}

/// Where a body is and which way it faces: `x` red, `y` green.
pub fn axes2d(self: Pen, at: Vec2, angle: f32, length: f32) void {
    const x = Vec2.fromAngle(angle).scale(length);
    self.line2d(at, at.add(x), .red);
    self.line2d(at, at.add(x.perp()), .green);
}

pub fn grid2d(self: Pen, center: Vec2, spacing: f32, count: u32, color: Color) void {
    self.grid(flat(center), .init(spacing, 0, 0), .init(0, spacing, 0), count, color);
}

pub fn text2d(self: Pen, at: Vec2, string: []const u8, color: Color) void {
    self.text(flat(at), string, color);
}

pub fn print2d(self: Pen, at: Vec2, comptime format: []const u8, arguments: anytype, color: Color) void {
    self.print(flat(at), format, arguments, color);
}

// -------------------------------------------------------------------------
// The workings
// -------------------------------------------------------------------------

fn place(self: Pen, at: Vec3) [3]f32 {
    const moved = if (self.transform) |m| m.mulPoint(at) else at;
    return .{ moved.x, moved.y, moved.z };
}

fn flat(at: Vec2) Vec3 {
    return .init(at.x, at.y, 0);
}

fn solid(self: Pen, at: Vec3, color: Color) Vertex {
    return .{ .position = self.place(at), .uv = font.white_uv, .color = color };
}

fn fill(self: Pen, vertices: []const Vertex) void {
    self.canvas.addVertices(self.space, self.style.depth, self.style.seconds, vertices);
}

/// `center + u cos t + v sin t` for `t` from `from` to `from + sweep`: a
/// circle when `u` and `v` are at right angles and as long as each other,
/// and an ellipse when they are not.
fn curve(self: Pen, center: Vec3, u: Vec3, v: Vec3, from: f32, wanted_sweep: f32, color: Color) void {
    if (!(@abs(wanted_sweep) > 0) or !std.math.isFinite(from)) return;
    const sweep = std.math.clamp(wanted_sweep, -tau, tau);
    const whole: f32 = @floatFromInt(@max(self.style.segments, 3));
    const pieces: u32 = @intFromFloat(@max(1, @ceil(whole * @abs(sweep) / tau)));
    const closed = @abs(sweep) >= tau;
    const step = sweep / @as(f32, @floatFromInt(pieces));
    const turn: Vec2 = .init(@cos(step), @sin(step));

    var at: Vec2 = .init(@cos(from), @sin(from));
    const first = center.add(u.scale(at.x)).add(v.scale(at.y));
    var previous = first;
    for (1..pieces + 1) |i| {
        const next = if (i < pieces) blk: {
            at = .init(at.x * turn.x - at.y * turn.y, at.x * turn.y + at.y * turn.x);
            break :blk center.add(u.scale(at.x)).add(v.scale(at.y));
        } else if (closed)
            first
        else
            center.add(u.scale(@cos(from + sweep))).add(v.scale(@sin(from + sweep)));
        self.line(previous, next, color);
        previous = next;
    }
}

/// Two unit vectors at right angles to each other and to `normal`.
fn planeOf(normal: Vec3) ?[2]Vec3 {
    const n = normal.tryNorm() orelse return null;
    const u = n.anyPerp();
    return .{ u, n.cross(u) };
}

/// Minus one or one, by one bit of a corner's index.
fn sign(index: usize, bit: usize) f32 {
    return if (index & bit != 0) 1 else -1;
}

/// The corners of a box, `x` in the first bit of the index, `y` in the
/// second and `z` in the third.
fn cornersOf(bounds: Aabb) [8]Vec3 {
    var corners: [8]Vec3 = undefined;
    for (&corners, 0..) |*corner, i| corner.* = .init(
        if (i & 1 != 0) bounds.max.x else bounds.min.x,
        if (i & 2 != 0) bounds.max.y else bounds.min.y,
        if (i & 4 != 0) bounds.max.z else bounds.min.z,
    );
    return corners;
}

/// The twelve edges between corners one bit apart.
fn edges(self: Pen, corners: [8]Vec3, color: Color) void {
    for (0..8) |i| {
        for ([_]usize{ 1, 2, 4 }) |bit| {
            if (i & bit == 0) self.line(corners[i], corners[i | bit], color);
        }
    }
}

const Size = struct { columns: u32, lines: u32 };

fn measure(string: []const u8) Size {
    var widest: u32 = 0;
    var column: u32 = 0;
    var lines: u32 = 1;
    for (string) |byte| {
        switch (byte) {
            '\n' => {
                widest = @max(widest, column);
                column = 0;
                lines += 1;
            },
            '\t' => column = nextTab(column),
            else => if (startsCharacter(byte)) {
                column += 1;
            },
        }
    }
    return .{ .columns = @max(widest, column), .lines = lines };
}

fn glyphs(self: Pen, where: [3]f32, string: []const u8, left: f32, top: f32, scale: f32, color: Color) void {
    var column: u32 = 0;
    var row: u32 = 0;
    for (string) |byte| {
        switch (byte) {
            '\n' => {
                column = 0;
                row += 1;
                continue;
            },
            '\t' => {
                column = nextTab(column);
                continue;
            },
            else => if (!startsCharacter(byte)) continue,
        }
        defer column += 1;
        if (byte == ' ') continue;

        const x0 = left + @as(f32, @floatFromInt(column * font.advance)) * scale;
        const y0 = top + @as(f32, @floatFromInt(row * font.line_height)) * scale;
        const x1 = x0 + font.glyph_width * scale;
        const y1 = y0 + font.glyph_height * scale;
        const uv = font.uvOf(font.glyphOf(byte));

        const corners = [4]Vertex{
            .{ .position = where, .nudge = .{ x0, y0, 1 }, .uv = .{ uv[0], uv[1] }, .color = color },
            .{ .position = where, .nudge = .{ x1, y0, 1 }, .uv = .{ uv[2], uv[1] }, .color = color },
            .{ .position = where, .nudge = .{ x1, y1, 1 }, .uv = .{ uv[2], uv[3] }, .color = color },
            .{ .position = where, .nudge = .{ x0, y1, 1 }, .uv = .{ uv[0], uv[3] }, .color = color },
        };
        self.fill(&.{ corners[0], corners[1], corners[2], corners[0], corners[2], corners[3] });
    }
}

fn nextTab(column: u32) u32 {
    return (column / 4 + 1) * 4;
}

/// Not a carriage return, and not the second, third or fourth byte of one
/// UTF-8 character.
fn startsCharacter(byte: u8) bool {
    return byte != '\r' and byte & 0xC0 != 0x80;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

fn expectNear(expected: Vec3, actual: [3]f32) !void {
    try testing.expectApproxEqAbs(expected.x, actual[0], 1e-4);
    try testing.expectApproxEqAbs(expected.y, actual[1], 1e-4);
    try testing.expectApproxEqAbs(expected.z, actual[2], 1e-4);
}

fn vec(at: [3]f32) Vec3 {
    return .init(at[0], at[1], at[2]);
}

test "a line is one instance, as wide as the pen and in its colours" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().with(.{ .width = 3 }).lineGradient(.init(1, 2, 3), .init(4, 5, 6), .red, .blue);

    try testing.expectEqual(@as(usize, 1), canvas.lines.items.len);
    const drawn = canvas.lines.items[0];
    try testing.expectEqual([3]f32{ 1, 2, 3 }, drawn.start);
    try testing.expectEqual([3]f32{ 4, 5, 6 }, drawn.end);
    try testing.expectEqual(Color.red, drawn.start_color);
    try testing.expectEqual(Color.blue, drawn.end_color);
    try testing.expectEqual(@as(f32, 3), drawn.width);
}

test "changing a pen's style changes only what was named, and only that pen" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    const plain = canvas.pen().with(.{ .width = 2, .seconds = 5 });
    const changed = plain.with(.{ .depth = .always });

    try testing.expectEqual(@as(f32, 2), changed.style.width);
    try testing.expectEqual(@as(f32, 5), changed.style.seconds);
    try testing.expectEqual(Canvas.Depth.always, changed.style.depth);
    try testing.expectEqual(Canvas.Depth.tested, plain.style.depth);
}

test "every field of a style can be changed by name" {
    const style_fields = @typeInfo(Style).@"struct".fields;
    const change_fields = @typeInfo(Style.Changes).@"struct".fields;
    try testing.expectEqual(style_fields.len, change_fields.len);
    inline for (style_fields) |field| {
        try testing.expect(@FieldType(Style.Changes, field.name) == ?field.type);
    }
}

test "the style decides the run a shape goes into" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    const pen = canvas.pen();
    pen.line(.zero, .unit_x, .white);
    pen.with(.{ .depth = .always, .seconds = 2 }).line(.zero, .unit_y, .white);
    pen.screen().line(.zero, .unit_z, .white);

    const runs = canvas.runs.items;
    try testing.expectEqual(@as(usize, 3), runs.len);
    try testing.expectEqual(Canvas.Depth.always, runs[1].depth);
    try testing.expectEqual(@as(f32, 2), runs[1].left);
    try testing.expectEqual(Canvas.Space.screen, runs[2].space);
}

test "a transform moves every point, and one inside another applies the inner first" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    const moved = canvas.pen().within(.fromTranslation(.init(10, 0, 0)));
    const turned = moved.within2d(.init(0, 5), std.math.pi / 2.0);
    turned.line2d(.zero, .init(1, 0), .white);

    const drawn = canvas.lines.items[0];
    try expectNear(.init(10, 5, 0), drawn.start);
    try expectNear(.init(10, 6, 0), drawn.end);
}

test "the screen pen leaves the world's transform behind" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().within(.fromTranslation(.init(100, 100, 0))).screen().line2d(.init(1, 2), .init(3, 4), .white);
    try expectNear(.init(1, 2, 0), canvas.lines.items[0].start);
}

test "a circle is its segments, and it closes on itself" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().with(.{ .segments = 12 }).circle(.init(1, 1, 1), .unit_z, 2, .white);

    const drawn = canvas.lines.items;
    try testing.expectEqual(@as(usize, 12), drawn.len);
    try testing.expectEqual(drawn[0].start, drawn[11].end);
    for (drawn) |segment| {
        try testing.expectApproxEqAbs(@as(f32, 2), vec(segment.start).dist(.init(1, 1, 1)), 1e-4);
        try testing.expectApproxEqAbs(@as(f32, 1), segment.start[2], 1e-4);
    }
}

test "an arc gets its share of the circle's segments and ends where it was sent" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().with(.{ .segments = 32 }).arc2d(.zero, 10, 0, std.math.pi / 2.0, .white);

    const drawn = canvas.lines.items;
    try testing.expectEqual(@as(usize, 8), drawn.len);
    try expectNear(.init(10, 0, 0), drawn[0].start);
    try expectNear(.init(0, 10, 0), drawn[7].end);
}

test "an arc in space turns anticlockwise round its normal" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().arc(.zero, .unit_z, .init(3, 0, 1), std.math.pi / 2.0, 1, .white);

    const drawn = canvas.lines.items;
    try expectNear(.init(1, 0, 0), drawn[0].start);
    try expectNear(.init(0, 1, 0), drawn[drawn.len - 1].end);
}

test "an arc of no angle, or of nonsense, draws nothing and does not stop the program" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    const pen = canvas.pen().with(.{ .segments = 8 });
    pen.arc2d(.zero, 1, 0, 0, .white);
    pen.arc2d(.zero, 1, 0, std.math.nan(f32), .white);
    pen.arc2d(.zero, 1, std.math.inf(f32), 1, .white);
    try testing.expect(canvas.isEmpty());

    pen.arc2d(.zero, 1, 0, 1e30, .white);
    try testing.expectEqual(@as(usize, 8), canvas.lines.items.len);
}

test "a box is its twelve edges, each along one axis" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().box(.init(.init(0, 0, 0), .init(1, 2, 3)), .white);

    const drawn = canvas.lines.items;
    try testing.expectEqual(@as(usize, 12), drawn.len);
    var total: f32 = 0;
    for (drawn) |edge| {
        const along = vec(edge.end).sub(vec(edge.start));
        var axes_used: u32 = 0;
        for ([_]f32{ along.x, along.y, along.z }) |part| axes_used += @intFromBool(part != 0);
        try testing.expectEqual(@as(u32, 1), axes_used);
        total += along.len();
    }
    try testing.expectApproxEqAbs(@as(f32, 4 * (1 + 2 + 3)), total, 1e-4);
}

test "a turned box keeps its size" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().orientedBox(.init(5, 5, 5), .init(1, 2, 3), .fromAxisAngle(.unit_y, 0.7), .white);

    for (canvas.lines.items) |edge| {
        const length = vec(edge.end).dist(vec(edge.start));
        const expected = for ([_]f32{ 2, 4, 6 }) |side| {
            if (@abs(length - side) < 1e-3) break true;
        } else false;
        try testing.expect(expected);
    }
}

test "a sphere is three rings round its centre" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().with(.{ .segments = 16 }).sphere(.init(0, 1, 0), 3, .white);

    try testing.expectEqual(@as(usize, 48), canvas.lines.items.len);
    for (canvas.lines.items) |segment| {
        try testing.expectApproxEqAbs(@as(f32, 3), vec(segment.start).dist(.init(0, 1, 0)), 1e-4);
    }
}

test "a frustum's corners are the near and far corners of the camera it came from" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    const clip: math.Clip = .gl;
    const projection = math.perspective(.{ .fov_y = math.radians(90), .aspect = 1, .near = 1, .far = 10, .clip = clip });
    canvas.pen().frustum(projection.inverse().?, clip, .white);

    const drawn = canvas.lines.items;
    try testing.expectEqual(@as(usize, 12), drawn.len);
    try expectNear(.init(-1, -1, -1), drawn[0].start);
    var farthest: f32 = 0;
    for (drawn) |edge| farthest = @min(farthest, @min(edge.start[2], edge.end[2]));
    try testing.expectApproxEqAbs(@as(f32, -10), farthest, 1e-3);
}

test "a capsule with no length is a sphere" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().with(.{ .segments = 8 }).capsule(.init(1, 1, 1), .init(1, 1, 1), 2, .white);
    try testing.expectEqual(@as(usize, 24), canvas.lines.items.len);
}

test "a shape with no direction to it draws nothing rather than something wrong" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    const pen = canvas.pen();
    pen.circle(.zero, .zero, 1, .white);
    pen.cone(.zero, .zero, 1, .white);
    pen.arc(.zero, .unit_z, .unit_z, 1, 1, .white);
    try testing.expect(canvas.isEmpty());

    pen.arrow(.zero, .zero, .white);
    try testing.expectEqual(@as(usize, 1), canvas.lines.items.len);
}

test "a point is a line that goes nowhere, as wide as asked" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().point2d(.init(4, 5), 6, .yellow);

    const dot = canvas.lines.items[0];
    try testing.expectEqual(dot.start, dot.end);
    try testing.expectEqual(@as(f32, 6), dot.width);
}

test "a filled shape is triangles that sample the white block of the font" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    const pen = canvas.pen();
    pen.solidRect2d(.init(0, 0), .init(4, 2), .green);
    pen.with(.{ .segments = 10 }).solidCircle2d(.init(0, 0), 1, .green);
    pen.solidBox(.init(.zero, .one), .green);
    pen.solidPolygon2d(&.{ .init(0, 0), .init(1, 0), .init(1, 1), .init(0, 1), .init(-1, 0.5) }, .green);

    try testing.expectEqual(@as(usize, (2 + 10 + 12 + 3) * 3), canvas.vertices.items.len);
    try testing.expectEqual(@as(usize, 1), canvas.runs.items.len);
    for (canvas.vertices.items) |corner| {
        try testing.expectEqual(font.white_uv, corner.uv);
        try testing.expectEqual([3]f32{ 0, 0, 0 }, corner.nudge);
    }
}

test "text is two triangles per inked character, each with a shadow beneath" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    const pen = canvas.pen();
    pen.text(.init(1, 2, 3), "Hi !", .white);
    try testing.expectEqual(@as(usize, 3 * 6 * 2), canvas.vertices.items.len);

    canvas.clear();
    pen.with(.{ .text_shadow = false }).text(.init(1, 2, 3), "Hi !", .white);
    try testing.expectEqual(@as(usize, 3 * 6), canvas.vertices.items.len);
    for (canvas.vertices.items) |corner| {
        try testing.expectEqual([3]f32{ 1, 2, 3 }, corner.position);
        try testing.expectEqual(@as(f32, 1), corner.nudge[2]);
    }
}

test "each character is a cell further along, and a new line starts under the first" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().with(.{ .text_shadow = false, .text_scale = 2 }).text(.zero, "ab\nc", .white);

    const corners = canvas.vertices.items;
    try testing.expectEqual(@as(f32, 0), corners[0].nudge[0]);
    try testing.expectEqual(@as(f32, font.advance * 2), corners[6].nudge[0]);
    try testing.expectEqual(@as(f32, 0), corners[12].nudge[0]);
    try testing.expectEqual(@as(f32, font.line_height * 2), corners[12].nudge[1]);
    try testing.expectEqual(@as(f32, font.glyph_width * 2), corners[1].nudge[0]);
}

test "text is placed by its anchor, on whole pixels" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().with(.{ .text_shadow = false, .anchor = .center }).text2d(.zero, "abc", .white);

    const width = 3 * font.advance - 1;
    const corners = canvas.vertices.items;
    try testing.expectEqual(@round(-@as(f32, width) / 2), corners[0].nudge[0]);
    try testing.expectEqual(@round(-@as(f32, font.glyph_height) / 2), corners[0].nudge[1]);
}

test "a character the font has not got is a box, and takes one cell whatever its length" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().with(.{ .text_shadow = false }).text(.zero, "é\tx", .white);

    const corners = canvas.vertices.items;
    try testing.expectEqual(@as(usize, 12), corners.len);
    try testing.expectEqual(font.uvOf(font.missing)[0], corners[0].uv[0]);
    try testing.expectEqual(@as(f32, 4 * font.advance), corners[6].nudge[0]);
}

test "printing formats first, and what does not fit is left off" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    const pen = canvas.pen().with(.{ .text_shadow = false });
    pen.print2d(.zero, "{d}+{d}", .{ 12, 34 }, .white);
    try testing.expectEqual(@as(usize, 5 * 6), canvas.vertices.items.len);

    canvas.clear();
    pen.print2d(.zero, "{s}", .{"x" ** 300}, .white);
    try testing.expectEqual(@as(usize, 256 * 6), canvas.vertices.items.len);
}

test "blank text draws nothing" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().text(.zero, "", .white);
    canvas.pen().text(.zero, "\n\n", .white);
    canvas.pen().text(.zero, "   ", .white);
    try testing.expect(canvas.isEmpty());
}

test "a grid is its lines both ways" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().grid2d(.zero, 10, 2, .gray);

    const drawn = canvas.lines.items;
    try testing.expectEqual(@as(usize, 10), drawn.len);
    try expectNear(.init(-20, -20, 0), drawn[0].start);
    try expectNear(.init(-20, 20, 0), drawn[0].end);
}

test "a 2D frame's y axis is a quarter turn on from its x" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.pen().axes2d(.init(1, 1), 0, 2);

    try expectNear(.init(3, 1, 0), canvas.lines.items[0].end);
    try expectNear(.init(1, 3, 0), canvas.lines.items[1].end);
    try testing.expectEqual(Color.red, canvas.lines.items[0].start_color);
}
