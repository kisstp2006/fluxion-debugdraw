// SPDX-License-Identifier: BSD-2-Clause

//! Fluxion Debug Draw - lines, shapes and text for looking at what a program
//! is doing, from anywhere in it, in 2D and in 3D.
//!
//! ```zig
//! var canvas: debugdraw.Canvas = .init(gpa);
//! defer canvas.deinit();
//!
//! const pen = canvas.pen();
//! pen.box(bounds, .yellow);
//! pen.arrow(body.position, body.position.add(body.velocity), .cyan);
//! pen.with(.{ .anchor = .bottom }).text(head, "player", .white);
//!
//! try renderer.draw(&.{&canvas}, .{ .color = target }, .{ .view_projection = camera, .width = w, .height = h });
//! canvas.advance(delta);
//! ```
//!
//! This module draws nothing: it keeps shapes as vertices, in order, and
//! forgets them when their time is up. `fluxion_debugdraw_rhi` draws them
//! through Fluxion RHI; any other renderer reads `Canvas.lines` and
//! `Canvas.vertices`.

const std = @import("std");

pub const Canvas = @import("Canvas.zig");
pub const Pen = @import("Pen.zig");
pub const font = @import("font.zig");

pub const Color = @import("color.zig").Color;
pub const Style = Pen.Style;
pub const Anchor = Pen.Anchor;
pub const Space = Canvas.Space;
pub const Depth = Canvas.Depth;
pub const Line = Canvas.Line;
pub const Vertex = Canvas.Vertex;
pub const Run = Canvas.Run;

test {
    _ = Canvas;
    _ = Pen;
    _ = font;
    _ = @import("color.zig");
}

test "every name this file exports is one that exists" {
    std.testing.refAllDecls(@This());
}
