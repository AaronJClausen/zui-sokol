//! A Direct3D 11 swapchain composed into a Win32 window a host owns, for
//! sokol_gfx without sokol_app. It keeps the alpha the renderer writes, so
//! the window's system backdrop shows wherever nothing is drawn, and holds
//! 8-bit sRGB or, for an `.scrgb_fp16` surface, half-float scRGB.

const zui = @import("zui");
const sokol = @import("sokol");
const sg = sokol.gfx;

const HWND = *opaque {};
const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
const Composition = opaque {};

extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) c_int;
extern fn zui_sokol_composition_create(hwnd: HWND, width: c_uint, height: c_uint, out: *?*Composition) callconv(.c) i32;
extern fn zui_sokol_composition_destroy(self: *Composition) callconv(.c) void;
extern fn zui_sokol_composition_device(self: *Composition) callconv(.c) ?*anyopaque;
extern fn zui_sokol_composition_device_context(self: *Composition) callconv(.c) ?*anyopaque;
extern fn zui_sokol_composition_frame(self: *Composition, width: c_uint, height: c_uint, in_scrgb: c_int, render_view: *?*anyopaque, depth_stencil_view: *?*anyopaque) callconv(.c) i32;
extern fn zui_sokol_composition_sdr_white_scale(self: *Composition) callconv(.c) f32;
extern fn zui_sokol_composition_present(self: *Composition) callconv(.c) i32;

pub const Context = struct {
    hwnd: HWND,
    composition: *Composition,

    pub fn init(window: *anyopaque) error{NoCompositionSwapchain}!Context {
        const hwnd: HWND = @ptrCast(window);
        const size = clientSize(hwnd);
        var composition: ?*Composition = null;
        if (zui_sokol_composition_create(hwnd, size[0], size[1], &composition) < 0) return error.NoCompositionSwapchain;
        return .{ .hwnd = hwnd, .composition = composition.? };
    }

    pub fn deinit(self: *Context) void {
        zui_sokol_composition_destroy(self.composition);
    }

    pub fn environment(self: *const Context) sg.Environment {
        return .{
            .defaults = .{ .color_format = .BGRA8, .depth_format = .DEPTH_STENCIL, .sample_count = 1 },
            .d3d11 = .{ .device = zui_sokol_composition_device(self.composition), .device_context = zui_sokol_composition_device_context(self.composition) },
        };
    }

    /// The swapchain's views, its buffers first resized to the client area
    /// and changed to `format` when either changed. A failed resize draws
    /// into the old size.
    pub fn swapchain(self: *const Context, format: zui.OutputFormat) sg.Swapchain {
        const size = clientSize(self.hwnd);
        var render_view: ?*anyopaque = null;
        var depth_stencil_view: ?*anyopaque = null;
        _ = zui_sokol_composition_frame(self.composition, size[0], size[1], @intFromBool(format == .scrgb_fp16), &render_view, &depth_stencil_view);
        return .{
            .width = @intCast(size[0]),
            .height = @intCast(size[1]),
            .sample_count = 1,
            .color_format = switch (format) {
                .sdr => .BGRA8,
                .scrgb_fp16 => .RGBA16F,
            },
            .depth_format = .DEPTH_STENCIL,
            .d3d11 = .{ .render_view = render_view, .depth_stencil_view = depth_stencil_view },
        };
    }

    /// What a color in zui's scRGB, where 1.0 is SDR white, is multiplied
    /// by in the swapchain's, where 1.0 is 80 nits: the monitor's SDR white
    /// over 80 nits, read again at most twice a second.
    pub fn sdrWhiteScale(self: *const Context) f32 {
        return zui_sokol_composition_sdr_white_scale(self.composition);
    }

    /// Waits for the display's next refresh.
    pub fn present(self: *const Context) void {
        _ = zui_sokol_composition_present(self.composition);
    }

    fn clientSize(hwnd: HWND) [2]c_uint {
        var client: RECT = .{};
        _ = GetClientRect(hwnd, &client);
        return .{ @intCast(@max(client.right - client.left, 1)), @intCast(@max(client.bottom - client.top, 1)) };
    }
};
