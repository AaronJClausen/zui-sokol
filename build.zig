const std = @import("std");
const sokol = @import("sokol");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zui_dependency = b.dependency("zui", .{ .target = target, .optimize = optimize });
    const force_opengl = b.option(bool, "gl", "Render with OpenGL instead of D3D11 or Metal") orelse false;
    const sokol_dependency = b.dependency("sokol", .{ .target = target, .optimize = optimize, .gl = force_opengl });
    const zui_module = zui_dependency.module("zui");
    const zui_widgets_module = zui_dependency.module("zui_widgets");
    const stb_truetype_module = stbTruetypeModule(b, target, optimize);

    const backend_imports: []const std.Build.Module.Import = &.{
        .{ .name = "zui", .module = zui_module },
        .{ .name = "zui_widgets", .module = zui_widgets_module },
        .{ .name = "zui_reflect", .module = zui_dependency.module("zui_reflect") },
        .{ .name = "sokol", .module = sokol_dependency.module("sokol") },
        .{ .name = "stb_truetype", .module = stb_truetype_module },
    };
    const backend_module = b.addModule("zui_sokol", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = backend_imports,
    });
    addRendererOptions(b, backend_module, force_opengl);

    const unit_tests = b.addTest(.{ .root_module = backend_module });
    linkThroughLlvmOnLinux(unit_tests);
    b.step("test", "Run the backend's unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    const demo_imports: []const std.Build.Module.Import = &.{
        .{ .name = "zui_sokol", .module = backend_module },
        .{ .name = "zui", .module = zui_module },
        .{ .name = "zui_widgets", .module = zui_widgets_module },
        .{ .name = "zui_async", .module = zui_dependency.module("zui_async") },
    };
    const demo = b.addExecutable(.{
        .name = "zui-sokol-demo",
        .root_module = b.createModule(.{ .root_source_file = b.path("examples/demo.zig"), .target = target, .optimize = optimize, .imports = demo_imports }),
    });
    if (target.result.os.tag == .windows) demo.subsystem = .windows;
    linkThroughLlvmOnLinux(demo);
    _ = b.addModule("zui_sokol_tour", .{ .root_source_file = b.path("examples/tour_app.zig"), .target = target, .optimize = optimize, .imports = demo_imports });

    const tour_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/tour_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = demo_imports,
    }) });
    linkThroughLlvmOnLinux(tour_tests);
    b.step("test-tour", "Declare every screen of the demo headlessly; fail if one exceeds its limits or does not fit the default window").dependOn(&b.addRunArtifact(tour_tests).step);
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    if (b.args) |arguments| run_demo.addArgs(arguments);
    b.step("demo", "Run the demo (`-- --frames 120` quits after 120 frames)").dependOn(&run_demo.step);

    b.step("check", "Compile the backend and the demo without producing output").dependOn(&demo.step);

    // The renderer suite reads frames back with glReadPixels, so it always
    // renders with OpenGL, and needs a window: on Linux CI, under Xvfb.
    const gl_sokol_dependency = b.dependency("sokol", .{ .target = target, .optimize = optimize, .gl = true });
    const gl_backend_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui", .module = zui_module },
            .{ .name = "zui_widgets", .module = zui_widgets_module },
            .{ .name = "zui_reflect", .module = zui_dependency.module("zui_reflect") },
            .{ .name = "sokol", .module = gl_sokol_dependency.module("sokol") },
            .{ .name = "stb_truetype", .module = stb_truetype_module },
        },
    });
    addRendererOptions(b, gl_backend_module, true);
    const conformance = b.addExecutable(.{
        .name = "zui-sokol-conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_sokol", .module = gl_backend_module },
                .{ .name = "zui_testing", .module = zui_dependency.module("zui_testing") },
            },
        }),
    });
    linkThroughLlvmOnLinux(conformance);
    b.step("conformance", "Run zui's renderer suite against the renderer, in a window, with OpenGL").dependOn(&b.addRunArtifact(conformance).step);

    const regenerate_shaders = sokol.shdc.createSourceFile(b, .{
        .shdc_dep = sokol_dependency.builder.dependency("shdc", .{}),
        .input = material_shader ++ ".glsl",
        .output = material_shader ++ ".glsl.zig",
        .slang = .{ .glsl410 = true, .hlsl5 = true, .metal_macos = true },
    }) catch |err| std.debug.panic("sokol-shdc cannot run here: {t}", .{err});
    b.step("shaders", "Regenerate " ++ material_shader ++ ".glsl.zig from its GLSL with sokol-shdc").dependOn(regenerate_shaders);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "src", "examples" };
    const generated_paths: []const []const u8 = &.{material_shader ++ ".glsl.zig"};
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths, .exclude_paths = generated_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .exclude_paths = generated_paths, .check = true }).step);
}

/// Checked in, so that building zui_sokol never runs sokol-shdc.
const material_shader = "src/material";

/// Zig 0.16's own ELF linker rejects the R_X86_64_PC64 relocations in the
/// `.sframe` section that GCC 16's crt1.o carries, and LLD crashes the
/// compiler unless the LLVM backend produced the objects.
fn linkThroughLlvmOnLinux(compile: *std.Build.Step.Compile) void {
    if (compile.rootModuleTarget().os.tag == .linux) {
        compile.use_llvm = true;
        compile.use_lld = true;
    }
}

/// On Windows the renderer draws into a native host's window with a
/// context of its own: OpenGL through opengl32 and gdi32, or Direct3D 11
/// composed into the window through DirectComposition.
fn addRendererOptions(b: *std.Build, module: *std.Build.Module, opengl: bool) void {
    const options = b.addOptions();
    options.addOption(bool, "opengl", opengl);
    module.addOptions("zui_sokol_options", options);
    if (module.resolved_target.?.result.os.tag != .windows) return;
    if (opengl) {
        module.linkSystemLibrary("opengl32", .{});
        module.linkSystemLibrary("gdi32", .{});
    } else {
        module.addCSourceFile(.{ .file = b.path("src/composition.c") });
        module.linkSystemLibrary("d3d11", .{});
        module.linkSystemLibrary("dxgi", .{});
    }
}

/// stb_truetype's declarations, translated to Zig, with its implementation
/// compiled in, for the TrueType fonts of `zui_sokol.Text`.
fn stbTruetypeModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const stb_dependency = b.dependency("stb", .{});
    const translated = b.addTranslateC(.{
        .root_source_file = stb_dependency.path("stb_truetype.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const module = translated.createModule();
    module.addCSourceFile(.{ .file = b.path("src/stb_truetype.c") });
    module.addIncludePath(stb_dependency.path(""));
    return module;
}
