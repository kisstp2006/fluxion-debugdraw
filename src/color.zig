// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const testing = std.testing;

/// Four bytes, as a vertex buffer holds them: `ubyte4_norm`, straight alpha.
pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 0xFF,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .hex(0x000000);
    pub const white: Color = .hex(0xFFFFFF);
    pub const gray: Color = .hex(0x808080);
    pub const red: Color = .hex(0xFF3B30);
    pub const green: Color = .hex(0x34C759);
    pub const blue: Color = .hex(0x2F7BFF);
    pub const yellow: Color = .hex(0xFFD60A);
    pub const orange: Color = .hex(0xFF9500);
    pub const cyan: Color = .hex(0x32D2F0);
    pub const magenta: Color = .hex(0xE040FB);

    /// `0xRRGGBB`, opaque.
    pub fn hex(value: u24) Color {
        return .{
            .r = @truncate(value >> 16),
            .g = @truncate(value >> 8),
            .b = @truncate(value),
        };
    }

    /// `0xRRGGBBAA`: the alpha is last, as in CSS.
    pub fn hexa(value: u32) Color {
        return .{
            .r = @truncate(value >> 24),
            .g = @truncate(value >> 16),
            .b = @truncate(value >> 8),
            .a = @truncate(value),
        };
    }

    /// From four numbers between zero and one, as a renderer keeps them.
    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = byte(r), .g = byte(g), .b = byte(b), .a = byte(a) };
    }

    pub fn withAlpha(self: Color, a: f32) Color {
        var out = self;
        out.a = byte(a);
        return out;
    }

    pub fn mix(from: Color, to: Color, t: f32) Color {
        const k = std.math.clamp(t, 0, 1);
        return .{
            .r = lerpByte(from.r, to.r, k),
            .g = lerpByte(from.g, to.g, k),
            .b = lerpByte(from.b, to.b, k),
            .a = lerpByte(from.a, to.a, k),
        };
    }

    fn byte(value: f32) u8 {
        return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
    }

    fn lerpByte(from: u8, to: u8, t: f32) u8 {
        const a: f32 = @floatFromInt(from);
        const b: f32 = @floatFromInt(to);
        return @intFromFloat(@round(a + (b - a) * t));
    }
};

test "hex puts the bytes where the name says" {
    const c: Color = .hex(0xFF8000);
    try testing.expectEqual(Color{ .r = 0xFF, .g = 0x80, .b = 0x00, .a = 0xFF }, c);
    try testing.expectEqual(@as(u8, 0x40), Color.hexa(0x10203040).a);
    try testing.expectEqual(@as(u8, 0x10), Color.hexa(0x10203040).r);
}

test "floats are clamped and rounded into bytes" {
    try testing.expectEqual(Color{ .r = 255, .g = 128, .b = 0, .a = 0 }, Color.rgba(2, 0.5, -1, 0));
    try testing.expectEqual(@as(u8, 64), Color.white.withAlpha(0.25).a);
}

test "mixing goes all the way at one and nowhere at zero" {
    try testing.expectEqual(Color.white, Color.mix(.black, .white, 1));
    try testing.expectEqual(Color.black, Color.mix(.black, .white, 0));
    try testing.expectEqual(@as(u8, 128), Color.mix(.black, .white, 0.5).g);
}

test "a colour is the four bytes a vertex attribute reads" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(Color));
    try testing.expectEqual(@as(usize, 3), @offsetOf(Color, "a"));
}
