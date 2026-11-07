//! Runs zui's renderer suite in a sokol_app window, which the renderer
//! draws into, and exits with an error when the renderer does not conform.
//! It always renders with OpenGL, so each frame can be read back with
//! `glReadPixels` before the window presents it.

const std = @import("std");
const zui_sokol = @import("zui_sokol");
const zui = zui_sokol.zui;
const sokol = zui_sokol.sokol;
const sapp = sokol.app;
const sg = sokol.gfx;
const zui_testing = @import("zui_testing");

extern fn glReadPixels(x: c_int, y: c_int, width: c_int, height: c_int, format: c_uint, pixel_type: c_uint, pixels: ?*anyopaque) callconv(.c) void;
const gl_rgba = 0x1908;
const gl_unsigned_byte = 0x1401;

const width = zui_testing.renderer_viewport[0];
const height = zui_testing.renderer_viewport[1];

const SwapchainHarness = struct {
    pub const config = zui_sokol.config(.{});

    gpa: std.mem.Allocator,
    io: std.Io,
    text_contract: zui_sokol.Text = .{},
    drawn: zui_sokol.Renderer = undefined,
    /// Bottom row first, as OpenGL reads them.
    read_back: [width * height][4]u8 = undefined,
    outcome: anyerror!?zui_testing.RendererViolation = null,

    pub fn renderer(self: *SwapchainHarness) *zui_sokol.Renderer {
        return &self.drawn;
    }

    pub fn text(self: *SwapchainHarness) *zui_sokol.Text {
        return &self.text_contract;
    }

    pub fn beginDraw(_: *SwapchainHarness, size: [2]u32) zui.Surface {
        std.debug.assert(size[0] == sapp.width() and size[1] == sapp.height());
        return .library;
    }

    /// The renderer has committed the frame, and the window shows it only
    /// when the frame callback returns, so it is still in the back buffer.
    pub fn endDraw(self: *SwapchainHarness) void {
        glReadPixels(0, 0, width, height, gl_rgba, gl_unsigned_byte, &self.read_back);
    }

    pub fn pixel(self: *SwapchainHarness, x: u32, y: u32) zui.Color {
        const rgba = self.read_back[(height - 1 - y) * width + x];
        return .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
    }

    pub fn image(_: *SwapchainHarness, color: zui.Color) zui_sokol.Image {
        const texels: [16 * 16]zui.Color = @splat(color);
        const solid = sg.makeImage(.{ .width = 16, .height = 16, .pixel_format = .RGBA8, .data = sg.asRange(&texels) });
        return .{
            .view = sg.makeView(.{ .texture = .{ .image = solid } }),
            .sampler = sg.makeSampler(.{}),
        };
    }

    fn from(userdata: ?*anyopaque) *SwapchainHarness {
        return @ptrCast(@alignCast(userdata.?));
    }
};

fn onInit(userdata: ?*anyopaque) callconv(.c) void {
    const harness: *SwapchainHarness = .from(userdata);
    sg.setup(.{ .environment = sokol.glue.environment(), .logger = .{ .func = sokol.log.func } });
    harness.drawn = .init(&harness.text_contract);
}

fn onFrame(userdata: ?*anyopaque) callconv(.c) void {
    const harness: *SwapchainHarness = .from(userdata);
    harness.outcome = zui_testing.findRendererViolation(zui_sokol.Renderer, harness, .{ .gpa = harness.gpa, .io = harness.io });
    sapp.requestQuit();
}

fn onCleanup(userdata: ?*anyopaque) callconv(.c) void {
    const harness: *SwapchainHarness = .from(userdata);
    harness.drawn.deinit();
    sg.shutdown();
}

pub fn main(init: std.process.Init) !void {
    const harness = try init.gpa.create(SwapchainHarness);
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
    const violation = try harness.outcome orelse {
        std.debug.print("zui_sokol.Renderer passes zui's renderer suite\n", .{});
        return;
    };
    std.debug.print("zui_testing.expectRendererConforms: zui_sokol.Renderer {s}\n", .{violation.description()});
    return violation.kind;
}
