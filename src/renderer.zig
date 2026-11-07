const std = @import("std");
const zui = @import("zui");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sgl = sokol.gl;
const sdtx = sokol.debugtext;
const Text = @import("root.zig").Text;
const Image = @import("root.zig").Image;

/// Hooks for payloads the renderer cannot draw on its own. They run while
/// sokol_gl is recording, so they draw with `sokol.gl` calls.
pub fn RenderOptions(comptime Command: type) type {
    const Payload = @FieldType(Command, "payload");
    return struct {
        /// Required when `Config.CustomData` is not void.
        draw_custom: ?*const fn (data: @FieldType(Payload, "custom"), bounds: zui.Rect) void = null,
        /// Required when `Config.ImageHandle` is not `zui_sokol.Image`.
        draw_image: ?*const fn (handle: @FieldType(@FieldType(Payload, "image"), "handle"), bounds: zui.Rect) void = null,
        /// Triangles per rounded corner.
        corner_segments: u8 = 8,
    };
}

/// Draws zui frames with sokol_gl (shapes, images) and sokol_debugtext
/// (text). Both record into numbered layers that are replayed in order, so
/// shapes and text interleave in zui's paint order, and each layer is
/// drawn under its own scissor rectangle.
pub const Renderer = struct {
    const max_layers = 1024;

    pipeline: sgl.Pipeline,
    /// Paint order breaks once a frame needs more layers than this; zui's
    /// commands then share the last layer.
    layer_overflows: u32 = 0,
    layer_scissors: [max_layers]?zui.Rect = undefined,

    /// Call after `sokol.gfx.setup`.
    pub fn init() Renderer {
        sgl.setup(.{ .max_vertices = 1 << 18, .max_commands = 1 << 14, .logger = .{ .func = sokol.log.func } });
        var debugtext_desc: sdtx.Desc = .{
            .context = .{ .char_buf_size = 1 << 16, .max_commands = 1 << 14 },
            .logger = .{ .func = sokol.log.func },
        };
        debugtext_desc.fonts[0] = sdtx.fontKc853();
        debugtext_desc.fonts[1] = sdtx.fontKc854();
        debugtext_desc.fonts[2] = sdtx.fontZ1013();
        debugtext_desc.fonts[3] = sdtx.fontCpc();
        debugtext_desc.fonts[4] = sdtx.fontC64();
        debugtext_desc.fonts[5] = sdtx.fontOric();
        sdtx.setup(debugtext_desc);

        var colors: [8]sg.ColorTargetState = @splat(.{});
        colors[0].blend = .{
            .enabled = true,
            .src_factor_rgb = .SRC_ALPHA,
            .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
            .src_factor_alpha = .ONE,
            .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        };
        return .{ .pipeline = sgl.makePipeline(.{ .colors = colors }) };
    }

    pub fn deinit(self: *Renderer) void {
        sgl.destroyPipeline(self.pipeline);
        sdtx.shutdown();
        sgl.shutdown();
    }

    /// Draws one frame's commands. Call inside a `sokol.gfx` swapchain pass.
    /// `params` are the frame record's: its viewport and the physical pixels
    /// per layout unit (`scale × zoom`).
    ///
    /// ```zig
    /// sg.beginPass(.{ .action = clear_action, .swapchain = sokol.glue.swapchain() });
    /// renderer.draw(Ui.RenderCommand, &text, frame.commands(), record.params, .{});
    /// sg.endPass();
    /// sg.commit();
    /// ```
    pub fn draw(self: *Renderer, comptime Command: type, text: *const Text, commands: []const Command, params: zui.FrameParams, options: RenderOptions(Command)) void {
        const viewport = params.viewport;
        const Payload = @FieldType(Command, "payload");
        const ImageHandle = @FieldType(@FieldType(Payload, "image"), "handle");

        sgl.defaults();
        sgl.loadPipeline(self.pipeline);
        sgl.matrixModeProjection();
        sgl.ortho(0, viewport[0], viewport[1], 0, -1, 1);

        var recorder: LayerRecorder = .{ .renderer = self };
        recorder.begin();
        var clips: ClipStack = .{};
        for (commands) |command| {
            const bounds = command.bounds;
            switch (command.payload) {
                .rectangle => |rectangle| {
                    recorder.beginShapes();
                    fillRectangle(bounds, rectangle.corner_radius, rectangle.color, options.corner_segments);
                },
                .border => |border| {
                    recorder.beginShapes();
                    strokeBorder(bounds, border.widths, border.corner_radius, border.color, options.corner_segments);
                },
                .text => |line| {
                    recorder.beginText();
                    drawText(text, line.content, bounds, line.style, viewport);
                },
                .image => |image| {
                    recorder.beginShapes();
                    if (ImageHandle == Image) {
                        drawImage(image.handle, bounds);
                    } else if (options.draw_image) |draw_image| {
                        draw_image(image.handle, bounds);
                    }
                },
                .custom => |data| {
                    recorder.beginShapes();
                    if (options.draw_custom) |draw_custom| draw_custom(data, bounds);
                },
                .clip_begin => |clip| {
                    clips.push(clip);
                    recorder.beginLayer(clips.current());
                },
                .clip_end => {
                    clips.pop();
                    recorder.beginLayer(clips.current());
                },
            }
        }

        const dpi_scale = params.scale * params.zoom;
        for (self.layer_scissors[0 .. recorder.layer + 1], 0..) |scissor, layer| {
            if (scissor) |rect| {
                sg.applyScissorRectf(rect.x * dpi_scale, rect.y * dpi_scale, rect.width * dpi_scale, rect.height * dpi_scale, true);
            } else {
                sg.applyScissorRectf(0, 0, viewport[0] * dpi_scale, viewport[1] * dpi_scale, true);
            }
            sgl.drawLayer(@intCast(layer));
            sdtx.drawLayer(@intCast(layer));
        }
    }
};

const LayerRecorder = struct {
    renderer: *Renderer,
    layer: usize = 0,
    has_shapes: bool = false,
    has_text: bool = false,

    fn begin(self: *LayerRecorder) void {
        self.renderer.layer_scissors[0] = null;
        sgl.layer(0);
        sdtx.layer(0);
    }

    /// Within a layer, shapes replay before text, so a shape that follows
    /// text must start a new layer to paint over it.
    fn beginShapes(self: *LayerRecorder) void {
        if (self.has_text) self.beginLayer(self.renderer.layer_scissors[self.layer]);
        self.has_shapes = true;
    }

    fn beginText(self: *LayerRecorder) void {
        self.has_text = true;
    }

    fn beginLayer(self: *LayerRecorder, scissor: ?zui.Rect) void {
        if (!self.has_shapes and !self.has_text) {
            self.renderer.layer_scissors[self.layer] = scissor;
            return;
        }
        if (self.layer + 1 == Renderer.max_layers) {
            self.renderer.layer_overflows += 1;
            return;
        }
        self.layer += 1;
        self.has_shapes = false;
        self.has_text = false;
        self.renderer.layer_scissors[self.layer] = scissor;
        sgl.layer(@intCast(self.layer));
        sdtx.layer(@intCast(self.layer));
    }
};

/// zui's clip rectangles are already intersected with every enclosing clip,
/// so `clip_end` only has to restore the enclosing one.
const ClipStack = struct {
    rects: [64]zui.Rect = undefined,
    depth: usize = 0,
    overflow: usize = 0,

    fn current(self: *const ClipStack) ?zui.Rect {
        return if (self.depth == 0) null else self.rects[self.depth - 1];
    }

    fn push(self: *ClipStack, rect: zui.Rect) void {
        if (self.depth == self.rects.len) {
            self.overflow += 1;
            return;
        }
        self.rects[self.depth] = rect;
        self.depth += 1;
    }

    fn pop(self: *ClipStack) void {
        if (self.overflow > 0) {
            self.overflow -= 1;
        } else if (self.depth > 0) {
            self.depth -= 1;
        }
    }
};

fn setColor(color: zui.Color) void {
    sgl.c4b(color.r, color.g, color.b, color.a);
}

fn hasRoundedCorners(radius: zui.CornerRadius) bool {
    return radius.top_left > 0 or radius.top_right > 0 or radius.bottom_left > 0 or radius.bottom_right > 0;
}

fn fillRectangle(bounds: zui.Rect, radius: zui.CornerRadius, color: zui.Color, corner_segments: u8) void {
    setColor(color);
    if (!hasRoundedCorners(radius)) {
        sgl.beginQuads();
        sgl.v2f(bounds.x, bounds.y);
        sgl.v2f(bounds.x + bounds.width, bounds.y);
        sgl.v2f(bounds.x + bounds.width, bounds.y + bounds.height);
        sgl.v2f(bounds.x, bounds.y + bounds.height);
        sgl.end();
        return;
    }
    var outline: Outline = .{};
    outline.trace(bounds, radius, .{}, corner_segments);
    const center: [2]f32 = .{ bounds.x + bounds.width / 2, bounds.y + bounds.height / 2 };
    sgl.beginTriangles();
    for (0..outline.count) |index| {
        const next = (index + 1) % outline.count;
        sgl.v2f(center[0], center[1]);
        sgl.v2f(outline.points[index][0], outline.points[index][1]);
        sgl.v2f(outline.points[next][0], outline.points[next][1]);
    }
    sgl.end();
}

/// Borders are drawn inside the bounds, as CSS draws them: a ring between
/// the outer outline and one inset by each edge's width.
fn strokeBorder(bounds: zui.Rect, widths: zui.Edges, radius: zui.CornerRadius, color: zui.Color, corner_segments: u8) void {
    var outer: Outline = .{};
    var inner: Outline = .{};
    outer.trace(bounds, radius, .{}, corner_segments);
    inner.trace(bounds, radius, widths, corner_segments);
    setColor(color);
    sgl.beginTriangles();
    for (0..outer.count) |index| {
        const next = (index + 1) % outer.count;
        const outer_here = outer.points[index];
        const outer_next = outer.points[next];
        const inner_here = inner.points[index];
        const inner_next = inner.points[next];
        sgl.v2f(outer_here[0], outer_here[1]);
        sgl.v2f(outer_next[0], outer_next[1]);
        sgl.v2f(inner_next[0], inner_next[1]);
        sgl.v2f(outer_here[0], outer_here[1]);
        sgl.v2f(inner_next[0], inner_next[1]);
        sgl.v2f(inner_here[0], inner_here[1]);
    }
    sgl.end();
}

/// The points around a rounded rectangle, clockwise from the top-left
/// corner, with the same number of points for any radius so that two
/// outlines of one rectangle can be joined point by point.
const Outline = struct {
    const max_segments = 32;

    points: [4 * (max_segments + 1)][2]f32 = undefined,
    count: usize = 0,

    fn trace(self: *Outline, bounds: zui.Rect, radius: zui.CornerRadius, inset: zui.Edges, corner_segments: u8) void {
        const segments = std.math.clamp(corner_segments, 1, max_segments);
        const left = bounds.x + inset.left;
        const top = bounds.y + inset.top;
        const right = bounds.x + bounds.width - inset.right;
        const bottom = bounds.y + bounds.height - inset.bottom;
        const limit = @max(0, @min(right - left, bottom - top) / 2);
        const corners = [4]struct { center_x: f32, center_y: f32, radius: f32, start_angle: f32 }{
            .{ .center_x = left, .center_y = top, .radius = radius.top_left - @max(inset.left, inset.top), .start_angle = std.math.pi },
            .{ .center_x = right, .center_y = top, .radius = radius.top_right - @max(inset.right, inset.top), .start_angle = 1.5 * std.math.pi },
            .{ .center_x = right, .center_y = bottom, .radius = radius.bottom_right - @max(inset.right, inset.bottom), .start_angle = 0 },
            .{ .center_x = left, .center_y = bottom, .radius = radius.bottom_left - @max(inset.left, inset.bottom), .start_angle = 0.5 * std.math.pi },
        };
        self.count = 0;
        for (corners, 0..) |corner, corner_index| {
            const corner_radius = std.math.clamp(corner.radius, 0, limit);
            const is_left = corner_index == 0 or corner_index == 3;
            const is_top = corner_index < 2;
            const arc_center_x = if (is_left) corner.center_x + corner_radius else corner.center_x - corner_radius;
            const arc_center_y = if (is_top) corner.center_y + corner_radius else corner.center_y - corner_radius;
            for (0..segments + 1) |step| {
                const angle = corner.start_angle + 0.5 * std.math.pi * @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(segments));
                self.points[self.count] = .{ arc_center_x + @cos(angle) * corner_radius, arc_center_y + @sin(angle) * corner_radius };
                self.count += 1;
            }
        }
    }
};

/// sokol_debugtext lays glyphs on a grid of 8×8 canvas pixels; sizing the
/// canvas per command scales that grid to the glyph size. Glyph size is
/// baked into vertices as they are emitted, so one context serves every
/// text size in a frame. With letter spacing, each glyph is placed on its
/// own, since the grid advances by whole glyphs.
fn drawText(text: *const Text, content: []const u8, bounds: zui.Rect, style: anytype, viewport: [2]f32) void {
    const glyph_size = text.glyphSize(style.size);
    if (glyph_size <= 0) return;
    const canvas_scale = 8 / glyph_size;
    sdtx.canvas(viewport[0] * canvas_scale, viewport[1] * canvas_scale);
    sdtx.font(@min(style.font, 5));
    sdtx.color4b(style.color.r, style.color.g, style.color.b, style.color.a);
    const row = (bounds.y + (bounds.height - glyph_size) / 2) / glyph_size;
    const glyph_pitch = (glyph_size + style.letter_spacing) / glyph_size;
    sdtx.pos(bounds.x / glyph_size, row);
    var glyph_index: f32 = 0;
    var codepoints = (std.unicode.Utf8View.init(content) catch return).iterator();
    while (codepoints.nextCodepoint()) |codepoint| : (glyph_index += 1) {
        if (style.letter_spacing != 0) sdtx.pos(bounds.x / glyph_size + glyph_index * glyph_pitch, row);
        const is_printable_ascii = codepoint >= 0x20 and codepoint < 0x7F;
        sdtx.putc(if (is_printable_ascii) @intCast(codepoint) else '?');
    }
}

fn drawImage(image: Image, bounds: zui.Rect) void {
    sgl.enableTexture();
    sgl.texture(image.view, image.sampler);
    sgl.c4b(255, 255, 255, 255);
    sgl.beginQuads();
    sgl.v2fT2f(bounds.x, bounds.y, 0, 0);
    sgl.v2fT2f(bounds.x + bounds.width, bounds.y, 1, 0);
    sgl.v2fT2f(bounds.x + bounds.width, bounds.y + bounds.height, 1, 1);
    sgl.v2fT2f(bounds.x, bounds.y + bounds.height, 0, 1);
    sgl.end();
    sgl.disableTexture();
}

test "outlines keep the same point count for any radius" {
    var square: Outline = .{};
    var rounded: Outline = .{};
    square.trace(.{ .width = 100, .height = 40 }, .zero, .{}, 8);
    rounded.trace(.{ .width = 100, .height = 40 }, .all(500), .{}, 8);
    try std.testing.expectEqual(square.count, rounded.count);
    try std.testing.expectEqual([2]f32{ 0, 0 }, square.points[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 20), rounded.points[0][1], 0.001);
}
