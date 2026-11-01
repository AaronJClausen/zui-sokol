const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zui_dependency = b.dependency("zui", .{ .target = target, .optimize = optimize });
    const force_opengl = b.option(bool, "gl", "Render with OpenGL instead of D3D11 or Metal") orelse false;
    const sokol_dependency = b.dependency("sokol", .{ .target = target, .optimize = optimize, .gl = force_opengl });
    const zui_module = zui_dependency.module("zui");
    const zui_widgets_module = zui_dependency.module("zui_widgets");

    const backend_imports: []const std.Build.Module.Import = &.{
        .{ .name = "zui", .module = zui_module },
        .{ .name = "zui_widgets", .module = zui_widgets_module },
        .{ .name = "zui_reflect", .module = zui_dependency.module("zui_reflect") },
        .{ .name = "sokol", .module = sokol_dependency.module("sokol") },
    };
    const backend_module = b.addModule("zui_sokol", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = backend_imports,
    });

    const unit_tests = b.addTest(.{ .root_module = backend_module });
    b.step("test", "Run the backend's unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    const demo = b.addExecutable(.{
        .name = "zui-sokol-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_sokol", .module = backend_module },
                .{ .name = "zui", .module = zui_module },
                .{ .name = "zui_widgets", .module = zui_widgets_module },
            },
        }),
    });
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    if (b.args) |arguments| run_demo.addArgs(arguments);
    b.step("demo", "Run the demo (`-- --frames 120` quits after 120 frames)").dependOn(&run_demo.step);

    b.step("check", "Compile the backend and the demo without producing output").dependOn(&demo.step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "examples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}
