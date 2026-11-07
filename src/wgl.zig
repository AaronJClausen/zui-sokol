//! An OpenGL context on a Win32 window a host owns, for sokol_gfx without
//! sokol_app.

const std = @import("std");
const sokol = @import("sokol");
const sg = sokol.gfx;

const BOOL = c_int;
const HWND = *opaque {};
const HDC = *opaque {};
const HGLRC = *opaque {};
const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16 = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: u16 = 1,
    dwFlags: u32 = 0,
    iPixelType: u8 = 0,
    cColorBits: u8 = 0,
    cRedBits: u8 = 0,
    cRedShift: u8 = 0,
    cGreenBits: u8 = 0,
    cGreenShift: u8 = 0,
    cBlueBits: u8 = 0,
    cBlueShift: u8 = 0,
    cAlphaBits: u8 = 0,
    cAlphaShift: u8 = 0,
    cAccumBits: u8 = 0,
    cAccumRedBits: u8 = 0,
    cAccumGreenBits: u8 = 0,
    cAccumBlueBits: u8 = 0,
    cAccumAlphaBits: u8 = 0,
    cDepthBits: u8 = 0,
    cStencilBits: u8 = 0,
    cAuxBuffers: u8 = 0,
    iLayerType: u8 = 0,
    bReserved: u8 = 0,
    dwLayerMask: u32 = 0,
    dwVisibleMask: u32 = 0,
    dwDamageMask: u32 = 0,
};

const PFD_DOUBLEBUFFER = 0x00000001;
const PFD_DRAW_TO_WINDOW = 0x00000004;
const PFD_SUPPORT_OPENGL = 0x00000020;
const PFD_TYPE_RGBA = 0;
const WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
const WGL_CONTEXT_FLAGS_ARB = 0x2094;
const WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001;
const WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB = 0x0002;

const CreateContextAttribs = *const fn (HDC, ?HGLRC, [*]const c_int) callconv(.winapi) ?HGLRC;
const SwapInterval = *const fn (c_int) callconv(.winapi) BOOL;

extern "user32" fn GetDC(hwnd: HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(hwnd: HWND, hdc: HDC) callconv(.winapi) c_int;
extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
extern "gdi32" fn ChoosePixelFormat(hdc: HDC, descriptor: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "gdi32" fn SetPixelFormat(hdc: HDC, format: c_int, descriptor: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;
extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) ?HGLRC;
extern "opengl32" fn wglDeleteContext(context: HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglMakeCurrent(hdc: ?HDC, context: ?HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

/// The window's OpenGL 4.3 core context, current on the thread that made
/// it, presenting with vsync. Windows composes its pixels as opaque, so a
/// system backdrop behind the window does not show through.
pub const Context = struct {
    hwnd: HWND,
    hdc: HDC,
    context: HGLRC,

    pub fn init(window: *anyopaque) error{ NoDeviceContext, NoPixelFormat, NoOpenGlContext, NoCoreProfile }!Context {
        const hwnd: HWND = @ptrCast(window);
        const hdc = GetDC(hwnd) orelse return error.NoDeviceContext;
        errdefer _ = ReleaseDC(hwnd, hdc);
        const descriptor: PIXELFORMATDESCRIPTOR = .{
            .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
            .iPixelType = PFD_TYPE_RGBA,
            .cColorBits = 32,
            .cAlphaBits = 8,
            .cDepthBits = 24,
            .cStencilBits = 8,
        };
        const format = ChoosePixelFormat(hdc, &descriptor);
        if (format == 0 or SetPixelFormat(hdc, format, &descriptor) == 0) return error.NoPixelFormat;

        // The core profile's entry point is only reachable through a
        // context, so a legacy one is made first and replaced.
        const legacy = wglCreateContext(hdc) orelse return error.NoOpenGlContext;
        defer _ = wglDeleteContext(legacy);
        if (wglMakeCurrent(hdc, legacy) == 0) return error.NoOpenGlContext;
        const create: CreateContextAttribs = @ptrCast(@alignCast(wglGetProcAddress("wglCreateContextAttribsARB") orelse return error.NoCoreProfile));
        const attributes = [_]c_int{
            WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
            WGL_CONTEXT_MINOR_VERSION_ARB, 3,
            WGL_CONTEXT_FLAGS_ARB,         WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB,
            WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
            0,
        };
        const context = create(hdc, null, &attributes) orelse return error.NoCoreProfile;
        if (wglMakeCurrent(hdc, context) == 0) {
            _ = wglDeleteContext(context);
            return error.NoOpenGlContext;
        }
        if (wglGetProcAddress("wglSwapIntervalEXT")) |address| {
            const swap_interval: SwapInterval = @ptrCast(@alignCast(address));
            _ = swap_interval(1);
        }
        return .{ .hwnd = hwnd, .hdc = hdc, .context = context };
    }

    pub fn deinit(self: *Context) void {
        _ = wglMakeCurrent(null, null);
        _ = wglDeleteContext(self.context);
        _ = ReleaseDC(self.hwnd, self.hdc);
    }

    const defaults: sg.EnvironmentDefaults = .{ .color_format = .RGBA8, .depth_format = .DEPTH_STENCIL, .sample_count = 1 };

    pub fn environment(_: *const Context) sg.Environment {
        return .{ .defaults = defaults };
    }

    /// The window's default framebuffer, at the client area's size now.
    pub fn swapchain(self: *const Context) sg.Swapchain {
        var client: RECT = .{};
        _ = GetClientRect(self.hwnd, &client);
        return .{
            .width = @max(client.right - client.left, 1),
            .height = @max(client.bottom - client.top, 1),
            .sample_count = defaults.sample_count,
            .color_format = defaults.color_format,
            .depth_format = defaults.depth_format,
            .gl = .{ .framebuffer = 0 },
        };
    }

    /// Waits for the display's next refresh.
    pub fn present(self: *const Context) void {
        _ = SwapBuffers(self.hdc);
    }
};

comptime {
    std.debug.assert(@sizeOf(PIXELFORMATDESCRIPTOR) == 40);
}
