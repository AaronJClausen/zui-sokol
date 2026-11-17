//! Runs zui's renderer suite in a sokol_app window, once into the window's
//! swapchain and once into each format of an `.offscreen` surface, and
//! exits with an error when the renderer does not conform. It always
//! renders with OpenGL, so each frame can be read back before the window
//! presents it.

const std = @import("std");
const zui_sokol = @import("zui_sokol");
const zui = zui_sokol.zui;
const sokol = zui_sokol.sokol;
const sapp = sokol.app;
const sg = sokol.gfx;
const zui_testing = @import("zui_testing");

extern fn glReadPixels(x: c_int, y: c_int, width: c_int, height: c_int, format: c_uint, pixel_type: c_uint, pixels: ?*anyopaque) callconv(.c) void;
extern fn glBindTexture(target: c_uint, texture: c_uint) callconv(.c) void;
extern fn glGetTexImage(target: c_uint, level: c_int, format: c_uint, pixel_type: c_uint, pixels: ?*anyopaque) callconv(.c) void;
const gl_rgba = 0x1908;
const gl_unsigned_byte = 0x1401;
const gl_float = 0x1406;

const width = zui_testing.renderer_viewport[0];
const height = zui_testing.renderer_viewport[1];

const Target = union(enum) {
    swapchain,
    offscreen: zui.OutputFormat,

    fn description(target: Target) []const u8 {
        return switch (target) {
            .swapchain => "into sokol_app's swapchain",
            .offscreen => |format| switch (format) {
                .sdr => "into an .sdr offscreen image",
                .scrgb_fp16 => "into an .scrgb_fp16 offscreen image",
            },
        };
    }
};

const targets = [_]Target{ .swapchain, .{ .offscreen = .sdr }, .{ .offscreen = .scrgb_fp16 } };

const WindowHarness = struct {
    pub const config = zui_sokol.config(.{});

    gpa: std.mem.Allocator,
    io: std.Io,
    text_contract: zui_sokol.Text = .{},
    drawn: zui_sokol.Renderer = undefined,
    target: Target = .swapchain,
    /// Bottom row first, as OpenGL reads them.
    read_back: [width * height][4]u8 = undefined,
    extended_read_back: [width * height][4]f32 = undefined,
    outcome: anyerror!?zui_testing.RendererViolation = null,

    pub fn renderer(self: *WindowHarness) *zui_sokol.Renderer {
        return &self.drawn;
    }

    pub fn text(self: *WindowHarness) *zui_sokol.Text {
        return &self.text_contract;
    }

    pub fn beginDraw(self: *WindowHarness, size: [2]u32) zui.Surface {
        switch (self.target) {
            .swapchain => {
                std.debug.assert(size[0] == sapp.width() and size[1] == sapp.height());
                return .library;
            },
            .offscreen => |format| return .{ .offscreen = .{ .size = size, .format = format } },
        }
    }

    /// The renderer has committed the frame, and the window shows it only
    /// when the frame callback returns, so it is still in the back buffer.
    pub fn endDraw(self: *WindowHarness) void {
        switch (self.target) {
            .swapchain => glReadPixels(0, 0, width, height, gl_rgba, gl_unsigned_byte, &self.read_back),
            .offscreen => |format| {
                const texture = sg.glQueryImageInfo(self.drawn.offscreenImage());
                glBindTexture(texture.tex_target, texture.tex[@intCast(texture.active_slot)]);
                switch (format) {
                    .sdr => glGetTexImage(texture.tex_target, 0, gl_rgba, gl_unsigned_byte, &self.read_back),
                    .scrgb_fp16 => glGetTexImage(texture.tex_target, 0, gl_rgba, gl_float, &self.extended_read_back),
                }
                glBindTexture(texture.tex_target, 0);
                // The texture binding was changed behind sokol_gfx's back.
                sg.resetStateCache();
            },
        }
    }

    pub fn pixel(self: *WindowHarness, x: u32, y: u32) zui.Color {
        const rgba = self.read_back[(height - 1 - y) * width + x];
        return .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
    }

    pub fn extendedPixel(self: *WindowHarness, x: u32, y: u32) zui.ExtendedColor {
        const rgba = self.extended_read_back[(height - 1 - y) * width + x];
        return .linear(rgba[0], rgba[1], rgba[2], rgba[3]);
    }

    pub fn image(_: *WindowHarness, color: zui.Color) zui_sokol.Image {
        const texels: [16 * 16]zui.Color = @splat(color);
        const solid = sg.makeImage(.{ .width = 16, .height = 16, .pixel_format = .RGBA8, .data = sg.asRange(&texels) });
        return zui_sokol.imageOf(sg.makeView(.{ .texture = .{ .image = solid } }), sg.makeSampler(.{}));
    }

    pub fn material(_: *WindowHarness, color: zui.Color) zui_sokol.Material {
        return .solid(color);
    }

    fn from(userdata: ?*anyopaque) *WindowHarness {
        return @ptrCast(@alignCast(userdata.?));
    }
};

fn onInit(userdata: ?*anyopaque) callconv(.c) void {
    const harness: *WindowHarness = .from(userdata);
    sg.setup(.{ .environment = sokol.glue.environment(), .logger = .{ .func = sokol.log.func } });
    harness.drawn = .init(&harness.text_contract);
}

/// Stops at the first target the renderer does not conform in, leaving it
/// in `harness.target`.
fn onFrame(userdata: ?*anyopaque) callconv(.c) void {
    const harness: *WindowHarness = .from(userdata);
    for (targets) |target| {
        harness.target = target;
        harness.outcome = zui_testing.findRendererViolation(zui_sokol.Renderer, harness, .{ .gpa = harness.gpa, .io = harness.io });
        const conforms = if (harness.outcome) |violation| violation == null else |_| false;
        if (!conforms) break;
    }
    sapp.requestQuit();
}

fn onCleanup(userdata: ?*anyopaque) callconv(.c) void {
    const harness: *WindowHarness = .from(userdata);
    harness.drawn.deinit();
    sg.shutdown();
}

pub fn main(init: std.process.Init) !void {
    const harness = try init.gpa.create(WindowHarness);
    defer init.gpa.destroy(harness);
    harness.* = .{ .gpa = init.gpa, .io = init.io, .outcome = error.FrameNeverDrawn };
    sapp.run(.{
        .init_userdata_cb = onInit,
        .frame_userdata_cb = onFrame,
        .cleanup_userdata_cb = onCleanup,
        .user_data = harness,
        .width = width,
        .height = height,
        .high_dpi = false,
        .window_title = "zui renderer suite",
        .logger = .{ .func = sokol.log.func },
    });
    const violation = harness.outcome catch |err| {
        std.debug.print("zui_testing.expectRendererConforms: zui_sokol.Renderer failed with error.{t} drawing {s}\n", .{ err, harness.target.description() });
        return err;
    } orelse {
        std.debug.print("zui_sokol.Renderer passes zui's renderer suite into its swapchain and into .sdr and .scrgb_fp16 offscreen images\n", .{});
        return;
    };
    std.debug.print("zui_testing.expectRendererConforms: zui_sokol.Renderer {s}, drawing {s}\n", .{ violation.description(), harness.target.description() });
    return violation.kind;
}
