// SPDX-License-Identifier: BSD-2-Clause

//! The built-in font: printable ASCII, five pixels by nine, in one small
//! texture made at compile time.

const std = @import("std");
const testing = std.testing;

pub const glyph_width = 5;
/// Seven above the baseline and two below it.
pub const glyph_height = 9;
pub const advance = 6;
pub const line_height = 11;

pub const first = ' ';
pub const last = '~';
/// What a character with no glyph of its own is drawn as: a hollow box.
pub const missing = last - first + 1;
pub const count = missing + 1;

pub const atlas_width = 128;
pub const atlas_height = 80;

const columns = 16;
const cell_width = 8;
const cell_height = 12;
const white_top = 72;

/// One byte of coverage per texel, top row first.
pub const atlas: [atlas_width * atlas_height]u8 = buildAtlas();

/// Where in the atlas a filled shape samples from: the middle of a block that
/// is all ink, so a solid triangle and a glyph share one texture.
pub const white_uv: [2]f32 = .{ 4.0 / @as(f32, atlas_width), (white_top + 4.0) / @as(f32, atlas_height) };

/// Which glyph draws this byte of text.
pub fn glyphOf(byte: u8) u8 {
    return if (byte >= first and byte <= last) byte - first else missing;
}

/// `u0, v0, u1, v1` of a glyph in the atlas.
pub fn uvOf(glyph: u8) [4]f32 {
    const origin = cellOrigin(glyph);
    return .{
        @as(f32, @floatFromInt(origin[0])) / atlas_width,
        @as(f32, @floatFromInt(origin[1])) / atlas_height,
        @as(f32, @floatFromInt(origin[0] + glyph_width)) / atlas_width,
        @as(f32, @floatFromInt(origin[1] + glyph_height)) / atlas_height,
    };
}

/// Whether a glyph has ink at a column and row of its own box.
pub fn inked(glyph: u8, x: usize, y: usize) bool {
    const row = bitmaps[glyph][y];
    return (row >> @intCast(glyph_width - 1 - x)) & 1 == 1;
}

fn cellOrigin(glyph: u8) [2]usize {
    return .{
        (glyph % columns) * cell_width + 1,
        (glyph / columns) * cell_height + 1,
    };
}

const art =
    \\..... ..#.. .#.#. .#.#. ..#.. ##... .##.. ..#.. ...#. .#... ..... ..... ..... ..... ..... .....
    \\..... ..#.. .#.#. .#.#. .#### ##..# #..#. ..#.. ..#.. ..#.. ..#.. ..#.. ..... ..... ..... ....#
    \\..... ..#.. .#.#. ##### #.#.. ...#. #.#.. .#... .#... ...#. #.#.# ..#.. ..... ..... ..... ...#.
    \\..... ..#.. ..... .#.#. .###. ..#.. .#... ..... .#... ...#. .###. ##### ..... ##### ..... ..#..
    \\..... ..#.. ..... ##### ..#.# .#... #.#.# ..... .#... ...#. #.#.# ..#.. ..... ..... ..... .#...
    \\..... ..... ..... .#.#. ####. #..## #..#. ..... ..#.. ..#.. ..#.. ..#.. .##.. ..... .##.. #....
    \\..... ..#.. ..... .#.#. ..#.. ...## .##.# ..... ...#. .#... ..... ..... .##.. ..... .##.. .....
    \\..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..#.. ..... ..... .....
    \\..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... .#... ..... ..... .....
    \\.###. ..#.. .###. ##### ...#. ##### ..##. ##### .###. .###. ..... ..... ...#. ..... .#... .###.
    \\#...# .##.. #...# ...#. ..##. #.... .#... ....# #...# #...# .##.. .##.. ..#.. ..... ..#.. #...#
    \\#..## ..#.. ....# ..#.. .#.#. ####. #.... ...#. #...# #...# .##.. .##.. .#... ##### ...#. ....#
    \\#.#.# ..#.. ...#. ...#. #..#. ....# ####. ..#.. .###. .#### ..... ..... #.... ..... ....# ...#.
    \\##..# ..#.. ..#.. ....# ##### ....# #...# .#... #...# ....# .##.. .##.. .#... ##### ...#. ..#..
    \\#...# ..#.. .#... #...# ...#. #...# #...# .#... #...# ...#. .##.. .##.. ..#.. ..... ..#.. .....
    \\.###. .###. ##### .###. ...#. .###. .###. .#... .###. .##.. ..... ..#.. ...#. ..... .#... ..#..
    \\..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... .#... ..... ..... ..... .....
    \\..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... .....
    \\.###. .###. ####. .###. ###.. ##### ##### .###. #...# .###. ..### #...# #.... #...# #...# .###.
    \\#...# #...# #...# #...# #..#. #.... #.... #...# #...# ..#.. ...#. #..#. #.... ##.## #...# #...#
    \\....# #...# #...# #.... #...# #.... #.... #.... #...# ..#.. ...#. #.#.. #.... #.#.# ##..# #...#
    \\.##.# ##### ####. #.... #...# ####. ####. #.### ##### ..#.. ...#. ##... #.... #.#.# #.#.# #...#
    \\#.#.# #...# #...# #.... #...# #.... #.... #...# #...# ..#.. ...#. #.#.. #.... #...# #..## #...#
    \\#.#.# #...# #...# #...# #..#. #.... #.... #...# #...# ..#.. #..#. #..#. #.... #...# #...# #...#
    \\.###. #...# ####. .###. ###.. ##### #.... .#### #...# .###. .##.. #...# ##### #...# #...# .###.
    \\..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... .....
    \\..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... .....
    \\####. .###. ####. .#### ##### #...# #...# #...# #...# #...# ##### .###. ..... .###. ..#.. .....
    \\#...# #...# #...# #.... ..#.. #...# #...# #...# #...# #...# ....# .#... #.... ...#. .#.#. .....
    \\#...# #...# #...# #.... ..#.. #...# #...# #...# .#.#. #...# ...#. .#... .#... ...#. #...# .....
    \\####. #...# ####. .###. ..#.. #...# #...# #.#.# ..#.. .#.#. ..#.. .#... ..#.. ...#. ..... .....
    \\#.... #.#.# #.#.. ....# ..#.. #...# #...# #.#.# .#.#. ..#.. .#... .#... ...#. ...#. ..... .....
    \\#.... #..#. #..#. ....# ..#.. #...# .#.#. #.#.# #...# ..#.. #.... .#... ....# ...#. ..... .....
    \\#.... .##.# #...# ####. ..#.. .###. ..#.. .#.#. #...# ..#.. ##### .###. ..... .###. ..... .....
    \\..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... #####
    \\..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... .....
    \\.#... ..... #.... ..... ....# ..... ..##. ..... #.... ..#.. ...#. #.... .##.. ..... ..... .....
    \\..#.. ..... #.... ..... ....# ..... .#..# ..... #.... ..... ..... #.... ..#.. ..... ..... .....
    \\..... .###. #.##. .###. .##.# .###. .#... .#### #.##. .##.. ..##. #..#. ..#.. ##.#. #.##. .###.
    \\..... ....# ##..# #.... #..## #...# ###.. #...# ##..# ..#.. ...#. #.#.. ..#.. #.#.# ##..# #...#
    \\..... .#### #...# #.... #...# ##### .#... #...# #...# ..#.. ...#. ##... ..#.. #.#.# #...# #...#
    \\..... #...# #...# #...# #...# #.... .#... #...# #...# ..#.. ...#. #.#.. ..#.. #...# #...# #...#
    \\..... .#### ####. .###. .#### .###. .#... .#### #...# .###. ...#. #..#. .###. #...# #...# .###.
    \\..... ..... ..... ..... ..... ..... ..... ....# ..... ..... #..#. ..... ..... ..... ..... .....
    \\..... ..... ..... ..... ..... ..... ..... .###. ..... ..... .##.. ..... ..... ..... ..... .....
    \\..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ..... ...#. ..#.. .#... ..... #####
    \\..... ..... ..... ..... .#... ..... ..... ..... ..... ..... ..... ..#.. ..#.. ..#.. ..... #...#
    \\####. .#### #.##. .#### ###.. #...# #...# #...# #...# #...# ##### ..#.. ..#.. ..#.. .#... #...#
    \\#...# #...# ##..# #.... .#... #...# #...# #...# .#.#. #...# ...#. .#... ..#.. ...#. #.#.# #...#
    \\#...# #...# #.... .###. .#... #...# #...# #.#.# ..#.. #...# ..#.. ..#.. ..#.. ..#.. ...#. #...#
    \\#...# #...# #.... ....# .#..# #..## .#.#. #.#.# .#.#. #...# .#... ..#.. ..#.. ..#.. ..... #...#
    \\####. .#### #.... ####. ..##. .##.# ..#.. .#.#. #...# .#### ##### ...#. ..#.. .#... ..... #####
    \\#.... ....# ..... ..... ..... ..... ..... ..... ..... ....# ..... ..... ..#.. ..... ..... .....
    \\#.... ....# ..... ..... ..... ..... ..... ..... ..... .###. ..... ..... ..... ..... ..... .....
;

const bitmaps: [count][glyph_height]u8 = parse();

fn parse() [count][glyph_height]u8 {
    @setEvalBranchQuota(50_000);
    var glyphs: [count][glyph_height]u8 = undefined;
    var lines = std.mem.tokenizeScalar(u8, art, '\n');
    for (0..count / columns) |band| {
        for (0..glyph_height) |row| {
            const text = std.mem.trimEnd(u8, lines.next().?, "\r");
            if (text.len != columns * (glyph_width + 1) - 1) @compileError("a line of the font is the wrong length");
            for (0..columns) |column| {
                var bits: u8 = 0;
                for (text[column * (glyph_width + 1) ..][0..glyph_width]) |c| {
                    bits = bits << 1 | @intFromBool(c == '#');
                }
                glyphs[band * columns + column][row] = bits;
            }
        }
    }
    if (lines.next() != null) @compileError("the font has more lines than glyphs");
    return glyphs;
}

fn buildAtlas() [atlas_width * atlas_height]u8 {
    @setEvalBranchQuota(200_000);
    var pixels: [atlas_width * atlas_height]u8 = @splat(0);
    for (0..count) |glyph| {
        const origin = cellOrigin(glyph);
        for (0..glyph_height) |y| {
            for (0..glyph_width) |x| {
                if (inked(glyph, x, y)) pixels[(origin[1] + y) * atlas_width + origin[0] + x] = 0xFF;
            }
        }
    }
    for (white_top..white_top + 8) |y| {
        @memset(pixels[y * atlas_width ..][0..8], 0xFF);
    }
    return pixels;
}

test "every printable character has a glyph, and the rest share the missing one" {
    try testing.expectEqual(@as(u8, 0), glyphOf(' '));
    try testing.expectEqual(@as(u8, 'A' - ' '), glyphOf('A'));
    try testing.expectEqual(@as(u8, missing), glyphOf(0x7F));
    try testing.expectEqual(@as(u8, missing), glyphOf('\t'));
    try testing.expectEqual(@as(u8, missing), glyphOf(0xC3));
}

test "a space has no ink and every other glyph has some" {
    for (0..count) |glyph| {
        var ink: u32 = 0;
        for (0..glyph_height) |y| {
            for (0..glyph_width) |x| ink += @intFromBool(inked(@intCast(glyph), x, y));
        }
        if (glyph == glyphOf(' ')) {
            try testing.expectEqual(@as(u32, 0), ink);
        } else {
            try testing.expect(ink > 0);
        }
    }
}

test "the letters sit on the baseline and only the tails go below it" {
    for ("ABCHIMNOSTXZabcdehikmnostuvwxz0123456789") |c| {
        const glyph = glyphOf(c);
        try testing.expect(bitmaps[glyph][6] != 0);
        try testing.expectEqual(@as(u8, 0), bitmaps[glyph][7]);
    }
    for ("gjpqy") |c| try testing.expect(bitmaps[glyphOf(c)][8] != 0);
}

test "a glyph's rectangle in the atlas holds exactly its ink" {
    const glyph = glyphOf('E');
    const uv = uvOf(glyph);
    const x0: usize = @intFromFloat(uv[0] * atlas_width);
    const y0: usize = @intFromFloat(uv[1] * atlas_height);
    try testing.expectEqual(@as(usize, glyph_width), @as(usize, @intFromFloat(uv[2] * atlas_width)) - x0);
    try testing.expectEqual(@as(usize, glyph_height), @as(usize, @intFromFloat(uv[3] * atlas_height)) - y0);

    for (0..glyph_height) |y| {
        for (0..glyph_width) |x| {
            const texel = atlas[(y0 + y) * atlas_width + x0 + x];
            try testing.expectEqual(inked(glyph, x, y), texel == 0xFF);
        }
    }
    try testing.expectEqual(@as(u8, 0), atlas[(y0 - 1) * atlas_width + x0]);
    try testing.expectEqual(@as(u8, 0), atlas[y0 * atlas_width + x0 + glyph_width]);
}

test "the white block is ink all the way round the point filled shapes sample" {
    const x: usize = @intFromFloat(white_uv[0] * atlas_width);
    const y: usize = @intFromFloat(white_uv[1] * atlas_height);
    for (y - 1..y + 2) |row| {
        for (x - 1..x + 2) |column| try testing.expectEqual(@as(u8, 0xFF), atlas[row * atlas_width + column]);
    }
}
