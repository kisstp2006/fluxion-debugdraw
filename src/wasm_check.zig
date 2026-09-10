// SPDX-License-Identifier: BSD-2-Clause

//! What `zig build test` compiles for `wasm32-freestanding` and never runs:
//! shapes, text and a frame through the renderer on WebGL, so a browser build
//! that would not compile fails the suite rather than a page.

const std = @import("std");
const rhi = @import("fluxion_rhi");
const debugdraw = @import("fluxion_debugdraw");
const render = @import("fluxion_debugdraw_rhi");

var heap: [8 * 1024 * 1024]u8 = undefined;

export fn fluxion_debugdraw_wasm_check() u32 {
    var fba: std.heap.FixedBufferAllocator = .init(&heap);
    const gpa = fba.allocator();

    var device = rhi.Device.init(gpa, .{}) catch return 1;
    defer device.deinit();
    var renderer = render.Renderer.init(gpa, &device, .{ .depth_format = .depth24_stencil8 }) catch return 2;
    defer renderer.deinit();
    var canvas: debugdraw.Canvas = .init(gpa);
    defer canvas.deinit();

    const pen = canvas.pen().with(.{ .width = 2 });
    pen.box(.init(.zero, .one), .yellow);
    pen.sphere(.zero, 1, .green);
    pen.capsule(.zero, .unit_y, 0.5, .cyan);
    pen.frustum(.identity, .gl, .white);
    pen.solidBox(.init(.zero, .one), .red);
    pen.print(.zero, "{d} bodies", .{3}, .white);
    pen.screen().solidRect2d(.init(4, 4), .init(40, 12), .black);
    pen.screen().circle2d(.init(20, 20), 8, .blue);

    const surface = device.createSurface(.{}) catch return 3;
    renderer.draw(&.{&canvas}, .{ .color = .{ .surface = surface } }, .{
        .view_projection = .identity,
        .width = 640,
        .height = 480,
    }) catch return 4;
    canvas.advance(1.0 / 60.0);
    return 0;
}
