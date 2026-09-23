// SPDX-License-Identifier: BSD-2-Clause

//! A window and the device on it: the two things a device needs from a
//! window - a `GlHooks` for OpenGL, an `HWND` for Direct3D - and a pump that
//! Escape closes. Not part of the library, which opens no windows.

const std = @import("std");
const builtin = @import("builtin");

const rhi = @import("fluxion_rhi");
const platform = @import("fluxion_platform");

pub fn defaultBackend() rhi.Backend {
    return if (builtin.os.tag == .windows) .d3d11 else .gl;
}

pub const Window = struct {
    inner: *Inner,
    backend: rhi.Backend,
    width: u32,
    height: u32,
    resized: bool = false,

    /// Boxed: the platform window points at its context and the hooks at
    /// this, so neither may move.
    const Inner = struct {
        ctx: platform.Context,
        win: platform.Window,
    };

    pub const Options = struct {
        backend: rhi.Backend,
        title: []const u8,
        width: u32,
        height: u32,
        visible: bool = true,
    };

    pub fn open(options: Options) platform.Error!Window {
        const gpa = std.heap.smp_allocator;
        const inner = try gpa.create(Inner);
        errdefer gpa.destroy(inner);
        inner.ctx = try platform.Context.init(gpa, .{});
        errdefer inner.ctx.deinit();
        inner.win = try inner.ctx.createWindow(.{
            .title = options.title,
            .width = options.width,
            .height = options.height,
            .visible = options.visible,
            .gl = if (options.backend == .gl) .{ .major = 3, .minor = 3, .profile = .core } else null,
        });
        errdefer inner.win.destroy();

        if (options.backend == .gl) {
            try inner.win.makeContextCurrent();
            inner.win.setSwapInterval(.vsync) catch {};
        }
        const size = inner.win.framebufferSize();
        return .{ .inner = inner, .backend = options.backend, .width = size[0], .height = size[1] };
    }

    pub fn isAbsent(err: anyerror) bool {
        return switch (err) {
            error.Unsupported, error.NoDisplay, error.ConnectionFailed, error.WindowCreationFailed, error.Unavailable, error.NoDevice => true,
            else => false,
        };
    }

    pub fn openDevice(self: *const Window, gpa: std.mem.Allocator) rhi.Error!rhi.Device {
        return rhi.Device.init(gpa, .{
            .backend = switch (self.backend) {
                .gl => .gl,
                .d3d11 => .d3d11,
                .d3d12 => .d3d12,
                .none => .none,
                .webgl => return error.Unsupported,
                .vulkan => return error.Unsupported,
                // Made by `Device.initWith`; this glue knows no such backend.
                .other => return error.Unsupported,
            },
            .gl = if (self.backend == .gl) .{
                .context = self.inner,
                .get_proc_address = getProcAddress,
                .swap_buffers = swapBuffers,
                .framebuffer_size = framebufferSize,
            } else null,
        });
    }

    pub fn createSurface(self: *const Window, device: *rhi.Device) rhi.Error!rhi.Surface {
        return device.createSurface(.{ .native_window = self.inner.win.native(), .width = self.width, .height = self.height });
    }

    fn getProcAddress(context: *anyopaque, name: [*:0]const u8) ?rhi.GlProc {
        const inner: *Inner = @ptrCast(@alignCast(context));
        return inner.win.getProcAddress(name);
    }

    fn swapBuffers(context: *anyopaque) void {
        const inner: *Inner = @ptrCast(@alignCast(context));
        inner.win.swapBuffers() catch {};
    }

    fn framebufferSize(context: *anyopaque) [2]u32 {
        const inner: *Inner = @ptrCast(@alignCast(context));
        return inner.win.framebufferSize();
    }

    /// Drain the events, and say whether the window is still open.
    pub fn pump(self: *Window) bool {
        self.inner.ctx.pump() catch return false;
        while (self.inner.ctx.poll()) |event| switch (event) {
            .close => self.inner.win.setShouldClose(true),
            .key => |key| if (key.key == .escape and key.action == .press) self.inner.win.setShouldClose(true),
            .framebuffer_resize => |size| {
                self.width = size.width;
                self.height = size.height;
                self.resized = true;
            },
            else => {},
        };
        return !self.inner.win.shouldClose();
    }

    pub fn close(self: *Window) void {
        self.inner.win.destroy();
        self.inner.ctx.deinit();
        std.heap.smp_allocator.destroy(self.inner);
        self.* = undefined;
    }
};
