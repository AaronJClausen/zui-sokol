//! An OpenGL context on a Wayland surface a host owns, through EGL, for
//! sokol_gfx without sokol_app.

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;

const EGLDisplay = *opaque {};
const EGLConfig = *opaque {};
const EGLContext = *opaque {};
const EGLSurface = *opaque {};
const EGLBoolean = c_uint;
const EGLint = i32;
const WaylandEglWindow = opaque {};

const EGL_PLATFORM_WAYLAND_KHR = 0x31D8;
const EGL_OPENGL_API = 0x30A2;
const EGL_NONE = 0x3038;
const EGL_SURFACE_TYPE = 0x3033;
const EGL_WINDOW_BIT = 0x0004;
const EGL_RENDERABLE_TYPE = 0x3040;
const EGL_OPENGL_BIT = 0x0008;
const EGL_RED_SIZE = 0x3024;
const EGL_GREEN_SIZE = 0x3023;
const EGL_BLUE_SIZE = 0x3022;
const EGL_ALPHA_SIZE = 0x3021;
const EGL_DEPTH_SIZE = 0x3025;
const EGL_STENCIL_SIZE = 0x3026;
const EGL_CONTEXT_MAJOR_VERSION = 0x3098;
const EGL_CONTEXT_MINOR_VERSION = 0x30FB;
const EGL_CONTEXT_OPENGL_PROFILE_MASK = 0x30FD;
const EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT = 0x0001;

extern "EGL" fn eglGetPlatformDisplay(platform: c_uint, native_display: *anyopaque, attributes: ?[*]const isize) callconv(.c) ?EGLDisplay;
extern "EGL" fn eglInitialize(display: EGLDisplay, major: ?*EGLint, minor: ?*EGLint) callconv(.c) EGLBoolean;
extern "EGL" fn eglTerminate(display: EGLDisplay) callconv(.c) EGLBoolean;
extern "EGL" fn eglBindAPI(api: c_uint) callconv(.c) EGLBoolean;
extern "EGL" fn eglChooseConfig(display: EGLDisplay, attributes: [*]const EGLint, configs: [*]EGLConfig, capacity: EGLint, count: *EGLint) callconv(.c) EGLBoolean;
extern "EGL" fn eglGetConfigAttrib(display: EGLDisplay, config: EGLConfig, attribute: EGLint, value: *EGLint) callconv(.c) EGLBoolean;
extern "EGL" fn eglCreateContext(display: EGLDisplay, config: EGLConfig, share: ?EGLContext, attributes: [*]const EGLint) callconv(.c) ?EGLContext;
extern "EGL" fn eglDestroyContext(display: EGLDisplay, context: EGLContext) callconv(.c) EGLBoolean;
extern "EGL" fn eglCreatePlatformWindowSurface(display: EGLDisplay, config: EGLConfig, native_window: *anyopaque, attributes: ?[*]const isize) callconv(.c) ?EGLSurface;
extern "EGL" fn eglDestroySurface(display: EGLDisplay, surface: EGLSurface) callconv(.c) EGLBoolean;
extern "EGL" fn eglMakeCurrent(display: EGLDisplay, draw: ?EGLSurface, read: ?EGLSurface, context: ?EGLContext) callconv(.c) EGLBoolean;
extern "EGL" fn eglSwapInterval(display: EGLDisplay, interval: EGLint) callconv(.c) EGLBoolean;
extern "EGL" fn eglSwapBuffers(display: EGLDisplay, surface: EGLSurface) callconv(.c) EGLBoolean;

extern "wayland-egl" fn wl_egl_window_create(surface: *anyopaque, width: c_int, height: c_int) callconv(.c) ?*WaylandEglWindow;
extern "wayland-egl" fn wl_egl_window_destroy(window: *WaylandEglWindow) callconv(.c) void;
extern "wayland-egl" fn wl_egl_window_resize(window: *WaylandEglWindow, width: c_int, height: c_int, dx: c_int, dy: c_int) callconv(.c) void;

/// The surface's OpenGL 4.3 core context, current on the thread that made
/// it, presenting with vsync. Its pixels are opaque: the configuration has
/// no alpha, so the compositor never blends what is behind the window.
pub const Context = struct {
    display: EGLDisplay,
    context: EGLContext,
    egl_surface: EGLSurface,
    window: *WaylandEglWindow,
    size: [2]i32,

    pub fn init(wayland_display: *anyopaque, wayland_surface: *anyopaque) error{ NoEglDisplay, NoEglConfig, NoOpenGlContext, NoWindowSurface }!Context {
        const display = eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, wayland_display, null) orelse return error.NoEglDisplay;
        if (eglInitialize(display, null, null) == 0) return error.NoEglDisplay;
        errdefer _ = eglTerminate(display);
        if (eglBindAPI(EGL_OPENGL_API) == 0) return error.NoOpenGlContext;
        const config = try opaqueConfig(display);

        const context_attributes = [_]EGLint{
            EGL_CONTEXT_MAJOR_VERSION,       4,
            EGL_CONTEXT_MINOR_VERSION,       3,
            EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
            EGL_NONE,
        };
        const context = eglCreateContext(display, config, null, &context_attributes) orelse return error.NoOpenGlContext;
        errdefer _ = eglDestroyContext(display, context);

        const initial_size: [2]i32 = .{ 1, 1 };
        const window = wl_egl_window_create(wayland_surface, initial_size[0], initial_size[1]) orelse return error.NoWindowSurface;
        errdefer wl_egl_window_destroy(window);
        const egl_surface = eglCreatePlatformWindowSurface(display, config, window, null) orelse return error.NoWindowSurface;
        errdefer _ = eglDestroySurface(display, egl_surface);
        if (eglMakeCurrent(display, egl_surface, egl_surface, context) == 0) return error.NoOpenGlContext;
        _ = eglSwapInterval(display, 1);
        return .{ .display = display, .context = context, .egl_surface = egl_surface, .window = window, .size = initial_size };
    }

    /// The first configuration without alpha, since a Wayland compositor
    /// blends a surface by the alpha it holds.
    fn opaqueConfig(display: EGLDisplay) error{NoEglConfig}!EGLConfig {
        const attributes = [_]EGLint{
            EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
            EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
            EGL_RED_SIZE,        8,
            EGL_GREEN_SIZE,      8,
            EGL_BLUE_SIZE,       8,
            EGL_ALPHA_SIZE,      0,
            EGL_DEPTH_SIZE,      24,
            EGL_STENCIL_SIZE,    8,
            EGL_NONE,
        };
        var configs: [64]EGLConfig = undefined;
        var count: EGLint = 0;
        if (eglChooseConfig(display, &attributes, &configs, configs.len, &count) == 0 or count == 0) return error.NoEglConfig;
        for (configs[0..@intCast(count)]) |config| {
            var alpha_bits: EGLint = -1;
            if (eglGetConfigAttrib(display, config, EGL_ALPHA_SIZE, &alpha_bits) != 0 and alpha_bits == 0) return config;
        }
        return configs[0];
    }

    pub fn deinit(self: *Context) void {
        _ = eglMakeCurrent(self.display, null, null, null);
        _ = eglDestroySurface(self.display, self.egl_surface);
        wl_egl_window_destroy(self.window);
        _ = eglDestroyContext(self.display, self.context);
        _ = eglTerminate(self.display);
    }

    const defaults: sg.EnvironmentDefaults = .{ .color_format = .RGBA8, .depth_format = .DEPTH_STENCIL, .sample_count = 1 };

    pub fn environment(_: *const Context) sg.Environment {
        return .{ .defaults = defaults };
    }

    /// The surface's default framebuffer, resized to `size` in physical
    /// pixels: a Wayland surface has no size of its own until a buffer is
    /// attached, so the frame's viewport decides it.
    pub fn swapchain(self: *Context, size: [2]i32) sg.Swapchain {
        const wanted: [2]i32 = .{ @max(size[0], 1), @max(size[1], 1) };
        if (!std.meta.eql(wanted, self.size)) {
            wl_egl_window_resize(self.window, wanted[0], wanted[1], 0, 0);
            self.size = wanted;
        }
        return .{
            .width = wanted[0],
            .height = wanted[1],
            .sample_count = defaults.sample_count,
            .color_format = defaults.color_format,
            .depth_format = defaults.depth_format,
            .gl = .{ .framebuffer = 0 },
        };
    }

    /// Attaches the frame to the surface and commits it, waiting for the
    /// compositor's frame callback of the one before.
    pub fn present(self: *const Context) void {
        _ = eglSwapBuffers(self.display, self.egl_surface);
    }
};
