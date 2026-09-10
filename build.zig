// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const math = b.dependency("fluxion_math", .{ .target = target, .optimize = optimize });

    const mod = b.addModule("fluxion_debugdraw", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_math", .module = math.module("fluxion_math") },
        },
    });

    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "fluxion-debugdraw-tests",
        .root_module = mod,
    })).step);

    const docs_lib = b.addLibrary(.{ .name = "fluxion-debugdraw", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate API documentation into zig-out/docs").dependOn(&install_docs.step);

    const wants_renderer = b.option(bool, "renderer", "Build the fluxion_debugdraw_rhi module (default: yes)") orelse true;
    if (!wants_renderer) return;

    const rhi = b.lazyDependency("fluxion_rhi", .{ .target = target, .optimize = optimize }) orelse return;
    const shader = b.lazyDependency("fluxion_shader", .{ .target = target, .optimize = optimize }) orelse return;

    const render_mod = b.addModule("fluxion_debugdraw_rhi", .{
        .root_source_file = b.path("src/render/rhi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_debugdraw", .module = mod },
            .{ .name = "fluxion_math", .module = math.module("fluxion_math") },
            .{ .name = "fluxion_rhi", .module = rhi.module("fluxion_rhi") },
            .{ .name = "fluxion_shader", .module = shader.module("fluxion_shader") },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "fluxion-debugdraw-rhi-tests",
        .root_module = render_mod,
    })).step);
    test_step.dependOn(&wasmCheck(b).step);

    const wants_examples = b.option(bool, "examples", "Build the examples (default: only when this is the root package)") orelse
        (b.pkg_hash.len == 0);
    if (!wants_examples) return;

    const platform = b.lazyDependency("fluxion_platform", .{ .target = target, .optimize = optimize }) orelse return;
    const image = b.lazyDependency("fluxion_image", .{ .target = target, .optimize = optimize }) orelse return;

    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/shapes.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_debugdraw", .module = mod },
            .{ .name = "fluxion_debugdraw_rhi", .module = render_mod },
            .{ .name = "fluxion_math", .module = math.module("fluxion_math") },
            .{ .name = "fluxion_rhi", .module = rhi.module("fluxion_rhi") },
            .{ .name = "fluxion_platform", .module = platform.module("fluxion_platform") },
            .{ .name = "fluxion_image", .module = image.module("fluxion_image") },
        },
    });
    const exe = b.addExecutable(.{ .name = "fluxion-debugdraw-shapes", .root_module = example_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("example", "Boxes, spheres, a camera's frustum and labels, turning in a window").dependOn(&run.step);

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "fluxion-debugdraw-shapes-tests",
        .root_module = example_mod,
    })).step);
}

/// The renderer and everything under it, built for a browser. See
/// `src/wasm_check.zig`.
fn wasmCheck(b: *std.Build) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const optimize: std.builtin.OptimizeMode = .ReleaseSmall;
    const math = b.dependency("fluxion_math", .{ .target = target, .optimize = optimize }).module("fluxion_math");
    const rhi = b.lazyDependency("fluxion_rhi", .{ .target = target, .optimize = optimize }).?.module("fluxion_rhi");
    const shader = b.lazyDependency("fluxion_shader", .{ .target = target, .optimize = optimize }).?.module("fluxion_shader");

    const core = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fluxion_math", .module = math }},
    });
    const renderer = b.createModule(.{
        .root_source_file = b.path("src/render/rhi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "fluxion_debugdraw", .module = core },
            .{ .name = "fluxion_math", .module = math },
            .{ .name = "fluxion_rhi", .module = rhi },
            .{ .name = "fluxion_shader", .module = shader },
        },
    });
    const check = b.addExecutable(.{
        .name = "fluxion-debugdraw-wasm-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "fluxion_rhi", .module = rhi },
                .{ .name = "fluxion_debugdraw", .module = core },
                .{ .name = "fluxion_debugdraw_rhi", .module = renderer },
            },
        }),
    });
    check.entry = .disabled;
    check.rdynamic = true;
    return check;
}
