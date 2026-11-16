const std = @import("std");
const zui = @import("zui");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sgl = sokol.gl;
const linear_light = @import("linear_light.glsl.zig");

/// Where a frame is drawn: the sokol_gl context that records it, and the
/// pixels of the pass it ends in, which every pipeline drawing there
/// must be made for.
pub const Destination = struct {
    context: sgl.Context,
    pixels: Pixels,
    format: zui.OutputFormat,
    /// sokol_debugtext's context was made for the swapchain's pixels, so it
    /// draws only there.
    is_swapchain: bool,

    pub const Pixels = struct {
        color_format: sg.PixelFormat,
        depth_format: sg.PixelFormat,
        sample_count: i32,
    };

    /// The window's: sokol_app's swapchain, or a native host's, which
    /// sokol_gfx was set up with.
    pub fn swapchain() Destination {
        const defaults = sg.queryDesc().environment.defaults;
        return .{
            .context = sgl.defaultContext(),
            .pixels = .{ .color_format = defaults.color_format, .depth_format = defaults.depth_format, .sample_count = defaults.sample_count },
            .format = .sdr,
            .is_swapchain = true,
        };
    }
};

/// What an `.offscreen` surface is drawn into: an image of its size and
/// output format, recorded by a sokol_gl context of its own. In
/// `.scrgb_fp16` it holds linear light, drawn through the `linear_light`
/// shader.
pub const OffscreenTarget = struct {
    format: zui.OutputFormat = .sdr,
    size: [2]i32 = .{ 0, 0 },
    context: sgl.Context = .{},
    linear_light_shader: sg.Shader = .{},
    pipeline: sgl.Pipeline = .{},
    image: sg.Image = .{},
    attachment: sg.View = .{},

    pub fn deinit(self: *OffscreenTarget) void {
        self.destroy();
        if (self.linear_light_shader.id != 0) sg.destroyShader(self.linear_light_shader);
        self.* = .{};
    }

    /// Before a frame is recorded. False when the GPU cannot render and
    /// blend `format`.
    pub fn prepare(self: *OffscreenTarget, size: [2]u32, format: zui.OutputFormat) bool {
        const pixel_format = colorFormat(format);
        const capabilities = sg.queryPixelformat(pixel_format);
        if (!capabilities.render or !capabilities.blend) return false;
        const signed_size: [2]i32 = .{ @intCast(@max(size[0], 1)), @intCast(@max(size[1], 1)) };
        if (self.image.id != 0 and self.format == format and std.meta.eql(self.size, signed_size)) return true;
        self.destroy();
        self.format = format;
        self.size = signed_size;
        self.context = sgl.makeContext(.{ .max_vertices = 1 << 19, .max_commands = 1 << 14, .color_format = pixel_format, .depth_format = .NONE, .sample_count = 1 });
        var desc = blendingPipeline();
        if (format == .scrgb_fp16) {
            if (self.linear_light_shader.id == 0) self.linear_light_shader = sg.makeShader(linear_light.linearLightShaderDesc(sg.queryBackend()));
            desc.shader = self.linear_light_shader;
        }
        self.pipeline = sgl.contextMakePipeline(self.context, desc);
        self.image = sg.makeImage(.{ .usage = .{ .color_attachment = true }, .width = signed_size[0], .height = signed_size[1], .pixel_format = pixel_format, .sample_count = 1 });
        self.attachment = sg.makeView(.{ .color_attachment = .{ .image = self.image } });
        return true;
    }

    pub fn destination(self: *const OffscreenTarget) Destination {
        return .{
            .context = self.context,
            .pixels = .{ .color_format = colorFormat(self.format), .depth_format = .NONE, .sample_count = 1 },
            .format = self.format,
            .is_swapchain = false,
        };
    }

    pub fn pass(self: *const OffscreenTarget, action: sg.PassAction) sg.Pass {
        var attachments: sg.Attachments = .{};
        attachments.colors[0] = self.attachment;
        return .{ .action = action, .attachments = attachments };
    }

    fn colorFormat(format: zui.OutputFormat) sg.PixelFormat {
        return switch (format) {
            .sdr => .RGBA8,
            .scrgb_fp16 => .RGBA16F,
        };
    }

    fn destroy(self: *OffscreenTarget) void {
        if (self.attachment.id != 0) sg.destroyView(self.attachment);
        if (self.image.id != 0) sg.destroyImage(self.image);
        if (self.pipeline.id != 0) sgl.destroyPipeline(self.pipeline);
        if (self.context.id != 0) sgl.destroyContext(self.context);
        self.attachment = .{};
        self.image = .{};
        self.pipeline = .{};
        self.context = .{};
    }
};

/// Blends over what is drawn, and writes alpha too: sokol_gl writes none by
/// default, so a window composed with its alpha (a native host's, over a
/// system backdrop) would show the backdrop through every shape.
pub fn blendingPipeline() sg.PipelineDesc {
    var desc: sg.PipelineDesc = .{};
    desc.colors[0].write_mask = .RGBA;
    desc.colors[0].blend = .{
        .enabled = true,
        .src_factor_rgb = .SRC_ALPHA,
        .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
        .src_factor_alpha = .ONE,
        .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
    };
    return desc;
}

/// A color as sokol_gl's 8-bit vertex colors carry it. In an SDR target it
/// is clamped to `zui.Color`. In an `.scrgb_fp16` one, where the
/// `linear_light` shader decodes it, a color brighter than SDR white is
/// divided by its brightest channel, which the vertex carries as its
/// brightness in sokol_gl's point size, and the shader multiplies back.
pub const VertexColor = struct {
    rgba: zui.Color,
    brightness: f32 = 1,

    /// `color` is a `zui.Color` or a `zui.ExtendedColor`, as the
    /// application declares its colors.
    pub fn of(color: anytype, format: zui.OutputFormat) VertexColor {
        if (@TypeOf(color) != zui.ExtendedColor) return .{ .rgba = color };
        const brightest: f32 = @max(color.r, color.g, color.b);
        if (format == .sdr or brightest <= 1) return .{ .rgba = color.toColor() };
        const within_white: zui.ExtendedColor = .linear(color.r / brightest, color.g / brightest, color.b / brightest, color.a);
        return .{ .rgba = within_white.toColor(), .brightness = brightest };
    }

    pub fn withAlpha(self: VertexColor, alpha: u8) VertexColor {
        var result = self;
        result.rgba.a = alpha;
        return result;
    }

    /// For the vertices that follow.
    pub fn apply(self: VertexColor) void {
        sgl.c4b(self.rgba.r, self.rgba.g, self.rgba.b, self.rgba.a);
        sgl.pointSize(self.brightness);
    }
};

test "an extended color is clamped into an SDR target, and a color is carried as declared" {
    try std.testing.expectEqual(VertexColor{ .rgba = .white }, VertexColor.of(zui.ExtendedColor.linear(4, 4, 4, 1), .sdr));
    try std.testing.expectEqual(VertexColor{ .rgba = .rgb(0x3366ff) }, VertexColor.of(zui.ExtendedColor.rgb(0x3366ff), .sdr));
    try std.testing.expectEqual(VertexColor{ .rgba = .rgb(0x3366ff) }, VertexColor.of(zui.Color.rgb(0x3366ff), .scrgb_fp16));
    try std.testing.expectEqual(VertexColor{ .rgba = .rgb(0x3366ff) }, VertexColor.of(zui.ExtendedColor.rgb(0x3366ff), .scrgb_fp16));
}

test "HDR white reaches an scRGB target as SDR white four times as bright" {
    try std.testing.expectEqual(VertexColor{ .rgba = .white, .brightness = 4 }, VertexColor.of(zui.ExtendedColor.linear(4, 4, 4, 1), .scrgb_fp16));
    const orange = VertexColor.of(zui.ExtendedColor.linear(2, 1, 0, 0.5), .scrgb_fp16);
    try std.testing.expectEqual(2, orange.brightness);
    try std.testing.expectEqual(zui.ExtendedColor.linear(1, 0.5, 0, 0.5).toColor(), orange.rgba);
}
