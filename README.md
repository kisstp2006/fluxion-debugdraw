# Fluxion Debug Draw

Lines, shapes and text for seeing what a program is doing, drawn from anywhere
in it, in 2D and in 3D. For Zig 0.16.

| Module | What it is |
| --- | --- |
| `Canvas` | Shapes waiting to be drawn, in the order they were drawn in, and how long each one stays. |
| `Pen` | What draws on a canvas: lines, curves, volumes, filled shapes and text, each in 2D and 3D. |
| `Color` | Four bytes, as a vertex buffer holds them. |
| `font` | Printable ASCII, five pixels by nine, made into a texture at compile time. |
| `fluxion_debugdraw_rhi` | The renderer: canvases in, pixels out, through [Fluxion RHI](https://github.com/kisstp2006/fluxion-rhi). A second module. |

```zig
const debugdraw = @import("fluxion_debugdraw");
const render = @import("fluxion_debugdraw_rhi");

var canvas: debugdraw.Canvas = .init(gpa);
defer canvas.deinit();
var renderer: render.Renderer = try .init(gpa, &device, .{});
defer renderer.deinit();

while (running) {
    const pen = canvas.pen();
    pen.box(bounds, .yellow);
    pen.arrow(position, position.add(velocity), .cyan);
    pen.with(.{ .anchor = .bottom }).text(head, "player", .white);
    pen.with(.{ .width = 3, .seconds = 2 }).cross(hit, 0.5, .red);
    pen.screen().print2d(.init(8, 8), "{d} bodies", .{count}, .white);

    try renderer.draw(&.{&canvas}, .{ .color = .{ .surface = surface } }, .{
        .view_projection = projection.mul(view),
        .width = 1280,
        .height = 720,
    });
    canvas.advance(delta);
}
```

Six decisions run through it:

**Recording is not drawing.** A canvas is vertices in memory and knows no GPU.
The renderer is a second module, so a program with a renderer of its own reads
`canvas.lines`, `canvas.vertices` and `canvas.runs` and never fetches Fluxion
RHI - pass `.renderer = false` to the dependency and it is not asked for.

**Drawing cannot fail.** There is no `try` in front of a line. Debug drawing
happens in the middle of other code - a physics step, a path search - and
threading an error out of every call there is the price of a feature nobody
wants to pay for a line. A shape that cannot be stored for want of memory is
left out and counted in `canvas.dropped`.

**A pen is a value.** Its style, its space and its transform are fields, and
`with`, `screen` and `within` hand back a changed copy. Nothing is set on a
shared object and forgotten, so a system that draws thick red lines cannot
leave the next one drawing thick red lines too.

**A line is as wide as it was asked to be, on every backend.** OpenGL's core
profile, Direct3D 11 and WebGL draw one-pixel lines and nothing wider. So each
segment is one instanced quad, widened across the screen in the vertex shader
and faded over its last pixel in the fragment shader: the width is in pixels
at any distance, the edge is smooth without multisampling, the ends are round,
and a point is a segment that goes nowhere. A segment that runs behind the
camera is cut at the near plane on the GPU before it is measured, rather than
being turned inside out by the perspective divide.

**Text needs no font file.** A debug label has to work on a build server, in a
browser and in the first minute of a project, which is before anybody has
chosen a font. The font is in the source as pictures of its glyphs, parsed and
laid out into a ten-kilobyte texture at compile time. Labels stay the same size
in pixels however far away they are, are put on whole pixels so they stay
sharp, and have a shadow so they can be read over anything.

**Order is kept.** Shapes are drawn in the order they were drawn in, lines and
triangles alike - a panel, then the graph on it, then its labels - with the
world first and the screen over it. Shapes of one kind in a row are one draw
call.

## Space, depth and time

```zig
const pen = canvas.pen();                      // the world, through the camera
const hud = pen.screen();                      // pixels from the top left, over the world
const body = pen.within2d(position, angle);    // a body's own frame
const hidden = pen.with(.{ .depth = .tested }); // behind the scene's depth buffer
const lasting = pen.with(.{ .seconds = 2 });   // for two seconds
```

- **Two spaces.** `.world` goes through the `view_projection` the renderer is
  given - a 2D camera's orthographic matrix or a 3D camera's perspective one,
  it does not matter which. `.screen` is pixels from the top left, `y` down,
  always drawn after the world.
- **2D is 3D at `z = 0`.** The functions ending in `2d` take `Vec2`s. Angles
  turn `x` towards `y`, which is clockwise on a screen whose `y` points down -
  the engine's convention and the physics package's.
- **Depth.** A `.tested` shape hides behind what the scene drew in front of
  it, when the renderer was made with the scene's `depth_format` and is given
  its depth texture; `.always` draws over it. Neither writes depth, so debug
  shapes never hide each other.
- **Time.** `seconds` is how long a shape stays. `canvas.advance(delta)`
  forgets what has had its time, so zero means until the next advance - one
  frame - and `std.math.inf(f32)` means until `canvas.clear()`.
- **Counting.** `canvas.count(.world)` is how many lines and triangles are on
  a canvas in one space now; `renderer.stats` is what the last `draw` drew. A
  frame that reports its own numbers wants the first: the second is a frame
  late, and nothing at all in the first frame or in a capture.

## What a pen draws

| | 3D | 2D |
| --- | --- | --- |
| Lines | `line`, `lineGradient`, `polyline`, `polygon`, `arrow` | `line2d`, `polyline2d`, `polygon2d`, `arrow2d` |
| Marks | `point`, `cross` | `point2d`, `cross2d` |
| Curves | `circle`, `arc`, `sphere` | `circle2d`, `arc2d` |
| Volumes | `box`, `orientedBox`, `frustum`, `cone`, `cylinder`, `capsule` | `rect2d`, `capsule2d` |
| Frames | `axes`, `grid` | `axes2d`, `grid2d` |
| Filled | `solidTriangle`, `solidQuad`, `solidBox` | `solidRect2d`, `solidCircle2d`, `solidPolygon2d` |
| Text | `text`, `print` | `text2d`, `print2d` |

The style is `width` in pixels, `depth`, `seconds`, `segments` in a whole
circle, `text_scale`, the text's `anchor` - which of its nine points goes where
it is drawn - and `text_shadow`.

## Install

```bash
zig fetch --save git+https://github.com/kisstp2006/fluxion-debugdraw
```

```zig
const debugdraw = b.dependency("fluxion_debugdraw", .{ .target = target, .optimize = optimize });
exe_mod.addImport("fluxion_debugdraw", debugdraw.module("fluxion_debugdraw"));
exe_mod.addImport("fluxion_debugdraw_rhi", debugdraw.module("fluxion_debugdraw_rhi"));
```

[Fluxion Math](https://github.com/kisstp2006/fluxion-math) comes with it,
pinned to the commit Fluxion RHI pins, so a `Vec3` here is the same type as a
`Vec3` there. The renderer module brings Fluxion RHI and
[Fluxion Shader](https://github.com/kisstp2006/fluxion-shader), which its two
shaders are written in and compiled by when the renderer is made - GLSL,
GLSL ES and HLSL from one source each. The example alone uses
[Fluxion Platform](https://github.com/kisstp2006/fluxion-platform) and
[Fluxion Image](https://github.com/kisstp2006/fluxion-image); every one of
those is `lazy`.

## The example

```bash
zig build example                     # Direct3D on Windows, OpenGL elsewhere
zig build example -- --backend gl
zig build example -- --capture shapes.png --at 2.5
```

A camera goes round a grid with a box, a turning box, a bouncing ball with its
velocity, a capsule, a cone, a cylinder, a translucent trigger volume and a
second camera's frustum, each labelled, and a mark dropped every half second
that stays for two. Over it, drawn in pixels: a panel, and a radar of where
things are seen from above. `--capture` draws the scene as it is at `--at`
seconds into a texture and writes it out with no window shown.

## Tests

`zig build test` runs three suites. The canvas and the pen are checked for
what they store: counts, positions, runs, what time does to them, and that a
failed allocation leaves nothing half-stored. The renderer is checked against
the `none` backend for its batches and buffers, and then on Direct3D 11's
software rasteriser for pixels: a one-pixel line lights one row, a nine-pixel
line is nine pixels wide with round ends, a point is a disc, text lands on the
whole pixel it was put near, a line from behind the camera is cut rather than
turned inside out, and a tested line hides behind a depth buffer that an
untested one draws over. The example's own test draws the whole scene on
OpenGL and on Direct3D and holds the two pictures to one another. Where there
is no GPU or no display, those skip.

## What is not here

- **Hidden parts drawn faintly.** A tested shape behind the scene is not
  drawn at all; the x-ray look, where it shows through dimmer, is a second
  pipeline with the depth test turned round.
- **Depth bias.** A tested line lying exactly on a surface fights it for the
  pixels.
- **Letters beyond ASCII.** Anything else is a hollow box, one cell wide.
- **Mitred joins.** A polyline's segments meet in overlapping round ends, so
  a translucent one is darker where two meet.
- **Smooth edges on filled shapes.** Lines are antialiased; triangles are not.
- **WebGL in a browser.** The renderer hands the WebGL backend its GLSL ES,
  and nothing has drawn it in a browser yet.
- **Threads.** A canvas is drawn on from one thread. Two threads draw on two
  canvases, and the renderer takes a list of them.

## Licence

BSD-2-Clause, the third rung of [the ladder](../licensing/README.md): a
subsystem built on tier-two libraries, beside `fluxion-ui`.
