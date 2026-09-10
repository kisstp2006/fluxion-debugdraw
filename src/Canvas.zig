// SPDX-License-Identifier: BSD-2-Clause

//! Shapes waiting to be drawn, in the order they were drawn in. What draws
//! on it is a `Pen`; what empties it is `advance`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Color = @import("color.zig").Color;
const Pen = @import("Pen.zig");

const Canvas = @This();

/// In the world, through the camera; or in pixels from the top left of the
/// target, `y` down, over everything in the world.
pub const Space = enum { world, screen };

/// Whether a shape in the world hides behind what the scene drew in front of
/// it. Only a target with a depth buffer can hide anything.
pub const Depth = enum { tested, always };

pub const Kind = enum { lines, fills };

/// One segment: what the line shader reads per instance.
pub const Line = extern struct {
    start: [3]f32,
    end: [3]f32,
    start_color: Color,
    end_color: Color,
    /// Pixels, however far away it is.
    width: f32,
};

/// One corner of a filled triangle.
pub const Vertex = extern struct {
    position: [3]f32,
    /// Pixels right and down from where `position` lands, and one in the
    /// last lane to land it on a whole pixel first: how text keeps its size
    /// and stays crisp at any distance.
    nudge: [3]f32 = .{ 0, 0, 0 },
    uv: [2]f32,
    color: Color,
};

/// Shapes of one kind in one space, one after another.
pub const Run = struct {
    kind: Kind,
    space: Space,
    depth: Depth,
    first: u32,
    count: u32,
    /// Seconds it is still drawn for. Zero is until the next `advance`.
    left: f32,
};

gpa: Allocator,
lines: std.ArrayList(Line) = .empty,
vertices: std.ArrayList(Vertex) = .empty,
runs: std.ArrayList(Run) = .empty,
/// Shapes left out for want of memory: drawing never fails, it counts.
dropped: u32 = 0,

pub fn init(gpa: Allocator) Canvas {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Canvas) void {
    self.lines.deinit(self.gpa);
    self.vertices.deinit(self.gpa);
    self.runs.deinit(self.gpa);
    self.* = undefined;
}

/// A pen on this canvas, drawing in the world in the default style.
pub fn pen(self: *Canvas) Pen {
    return .{ .canvas = self };
}

/// Let `seconds` pass. What had no more time than that left is forgotten, and
/// the rest keep their order.
pub fn advance(self: *Canvas, seconds: f32) void {
    const passed = if (seconds > 0) seconds else 0;
    var runs_kept: usize = 0;
    var lines_kept: u32 = 0;
    var vertices_kept: u32 = 0;

    for (self.runs.items) |run| {
        if (run.left <= passed) continue;
        var kept = run;
        kept.left = run.left - passed;
        switch (run.kind) {
            .lines => {
                std.mem.copyForwards(Line, self.lines.items[lines_kept..], self.lines.items[run.first..][0..run.count]);
                kept.first = lines_kept;
                lines_kept += run.count;
            },
            .fills => {
                std.mem.copyForwards(Vertex, self.vertices.items[vertices_kept..], self.vertices.items[run.first..][0..run.count]);
                kept.first = vertices_kept;
                vertices_kept += run.count;
            },
        }
        self.runs.items[runs_kept] = kept;
        runs_kept += 1;
    }

    self.runs.shrinkRetainingCapacity(runs_kept);
    self.lines.shrinkRetainingCapacity(lines_kept);
    self.vertices.shrinkRetainingCapacity(vertices_kept);
}

/// Forget everything, what was meant to last included.
pub fn clear(self: *Canvas) void {
    self.lines.clearRetainingCapacity();
    self.vertices.clearRetainingCapacity();
    self.runs.clearRetainingCapacity();
}

pub fn isEmpty(self: *const Canvas) bool {
    return self.runs.items.len == 0;
}

pub const Count = struct {
    lines: u32 = 0,
    triangles: u32 = 0,
};

/// What is on the canvas in one space as it stands: what the renderer will
/// draw of it, known before it does. A renderer's own statistics are the
/// last frame's, and a frame that reports them is one frame late.
pub fn count(self: *const Canvas, space: Space) Count {
    var out: Count = .{};
    for (self.runs.items) |run| {
        if (run.space != space) continue;
        switch (run.kind) {
            .lines => out.lines += run.count,
            .fills => out.triangles += run.count / 3,
        }
    }
    return out;
}

pub fn addLine(self: *Canvas, space: Space, depth: Depth, seconds: f32, line: Line) void {
    const first: u32 = @intCast(self.lines.items.len);
    self.lines.append(self.gpa, line) catch return self.drop();
    self.extend(.lines, space, depth, seconds, first, 1) catch {
        self.lines.shrinkRetainingCapacity(first);
        self.drop();
    };
}

/// Whole triangles: three vertices each.
pub fn addVertices(self: *Canvas, space: Space, depth: Depth, seconds: f32, vertices: []const Vertex) void {
    std.debug.assert(vertices.len % 3 == 0);
    const first: u32 = @intCast(self.vertices.items.len);
    self.vertices.appendSlice(self.gpa, vertices) catch return self.drop();
    self.extend(.fills, space, depth, seconds, first, @intCast(vertices.len)) catch {
        self.vertices.shrinkRetainingCapacity(first);
        self.drop();
    };
}

fn extend(self: *Canvas, kind: Kind, space: Space, depth: Depth, seconds: f32, first: u32, added: u32) Allocator.Error!void {
    const left = if (seconds > 0) seconds else 0;
    if (self.runs.items.len > 0) {
        const last = &self.runs.items[self.runs.items.len - 1];
        if (last.kind == kind and last.space == space and last.depth == depth and last.left == left) {
            std.debug.assert(last.first + last.count == first);
            last.count += added;
            return;
        }
    }
    try self.runs.append(self.gpa, .{
        .kind = kind,
        .space = space,
        .depth = depth,
        .first = first,
        .count = added,
        .left = left,
    });
}

fn drop(self: *Canvas) void {
    self.dropped +|= 1;
}

fn lineAt(x: f32) Line {
    return .{
        .start = .{ x, 0, 0 },
        .end = .{ x, 1, 0 },
        .start_color = .white,
        .end_color = .white,
        .width = 1,
    };
}

fn triangleAt(x: f32) [3]Vertex {
    const corner: Vertex = .{ .position = .{ x, 0, 0 }, .uv = .{ 0, 0 }, .color = .white };
    return .{ corner, corner, corner };
}

test "shapes drawn one after another in one way are one run" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    for (0..5) |i| canvas.addLine(.world, .tested, 0, lineAt(@floatFromInt(i)));

    try testing.expectEqual(@as(usize, 1), canvas.runs.items.len);
    try testing.expectEqual(@as(u32, 5), canvas.runs.items[0].count);
    try testing.expectEqual(@as(usize, 5), canvas.lines.items.len);
}

test "a change of kind, space, depth or time starts a new run" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.addLine(.world, .tested, 0, lineAt(0));
    canvas.addVertices(.world, .tested, 0, &triangleAt(1));
    canvas.addLine(.world, .tested, 0, lineAt(2));
    canvas.addLine(.screen, .tested, 0, lineAt(3));
    canvas.addLine(.screen, .always, 0, lineAt(4));
    canvas.addLine(.screen, .always, 2, lineAt(5));

    try testing.expectEqual(@as(usize, 6), canvas.runs.items.len);
    try testing.expectEqual(Kind.fills, canvas.runs.items[1].kind);
    try testing.expectEqual(@as(u32, 1), canvas.runs.items[2].first);
    try testing.expectEqual(@as(u32, 0), canvas.runs.items[1].first);
    try testing.expectEqual(@as(u32, 3), canvas.runs.items[1].count);
}

test "advancing forgets this frame's shapes and keeps the lasting ones in order" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.addLine(.world, .tested, 0, lineAt(0));
    canvas.addLine(.world, .tested, 1, lineAt(1));
    canvas.addVertices(.world, .tested, 0, &triangleAt(2));
    canvas.addVertices(.world, .tested, 1, &triangleAt(3));
    canvas.addLine(.world, .tested, 0, lineAt(4));
    canvas.addLine(.world, .tested, 3, lineAt(5));

    canvas.advance(0.5);

    try testing.expectEqual(@as(usize, 3), canvas.runs.items.len);
    try testing.expectEqual(@as(usize, 2), canvas.lines.items.len);
    try testing.expectEqual(@as(f32, 1), canvas.lines.items[0].start[0]);
    try testing.expectEqual(@as(f32, 5), canvas.lines.items[1].start[0]);
    try testing.expectEqual(@as(f32, 3), canvas.vertices.items[0].position[0]);
    try testing.expectEqual(@as(u32, 1), canvas.runs.items[2].first);
    try testing.expectEqual(@as(f32, 0.5), canvas.runs.items[0].left);
    try testing.expectEqual(@as(f32, 2.5), canvas.runs.items[2].left);
}

test "a lasting shape goes once its time has passed" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.addLine(.world, .tested, 0.25, lineAt(0));
    canvas.advance(0.125);
    try testing.expect(!canvas.isEmpty());
    canvas.advance(0.125);
    try testing.expect(canvas.isEmpty());
    try testing.expectEqual(@as(usize, 0), canvas.lines.items.len);
}

test "a paused frame still forgets what was drawn for one frame" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.addLine(.world, .tested, 0, lineAt(0));
    canvas.addLine(.world, .tested, 1, lineAt(1));
    canvas.advance(0);

    try testing.expectEqual(@as(usize, 1), canvas.lines.items.len);
    try testing.expectEqual(@as(f32, 1), canvas.runs.items[0].left);
}

test "a canvas counts what is on it, space by space, lasting shapes included" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.addLine(.world, .tested, 0, lineAt(0));
    canvas.addLine(.world, .always, 5, lineAt(1));
    canvas.addVertices(.world, .tested, 0, &(triangleAt(2) ++ triangleAt(3)));
    canvas.addLine(.screen, .tested, 0, lineAt(4));
    canvas.addVertices(.screen, .tested, 0, &triangleAt(5));

    try testing.expectEqual(Count{ .lines = 2, .triangles = 2 }, canvas.count(.world));
    try testing.expectEqual(Count{ .lines = 1, .triangles = 1 }, canvas.count(.screen));

    canvas.advance(1);
    try testing.expectEqual(Count{ .lines = 1, .triangles = 0 }, canvas.count(.world));
    try testing.expectEqual(Count{}, canvas.count(.screen));
}

test "clearing forgets even what was meant to last" {
    var canvas: Canvas = .init(testing.allocator);
    defer canvas.deinit();

    canvas.addLine(.world, .tested, std.math.inf(f32), lineAt(0));
    canvas.advance(1000);
    try testing.expect(!canvas.isEmpty());
    canvas.clear();
    try testing.expect(canvas.isEmpty());
}

test "a shape that cannot be stored is dropped and counted, and nothing of it is left" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    var canvas: Canvas = .init(failing.allocator());
    defer canvas.deinit();
    try canvas.lines.ensureTotalCapacity(canvas.gpa, 4);

    canvas.addLine(.world, .tested, 0, lineAt(0));
    canvas.addVertices(.world, .tested, 0, &triangleAt(1));

    try testing.expectEqual(@as(u32, 2), canvas.dropped);
    try testing.expectEqual(@as(usize, 0), canvas.lines.items.len);
    try testing.expectEqual(@as(usize, 0), canvas.vertices.items.len);
    try testing.expect(canvas.isEmpty());
}

test "the vertex layouts are the ones the shaders are given" {
    try testing.expectEqual(@as(usize, 36), @sizeOf(Line));
    try testing.expectEqual(@as(usize, 24), @offsetOf(Line, "start_color"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(Line, "width"));
    try testing.expectEqual(@as(usize, 36), @sizeOf(Vertex));
    try testing.expectEqual(@as(usize, 12), @offsetOf(Vertex, "nudge"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(Vertex, "uv"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(Vertex, "color"));
}
