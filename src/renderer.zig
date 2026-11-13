const std = @import("std");
const zui = @import("zui");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sgl = sokol.gl;
const sdtx = sokol.debugtext;
const builtin = @import("builtin");
const options = @import("zui_sokol_options");
const Text = @import("root.zig").Text;
const Image = @import("root.zig").Image;
const truetype = @import("truetype.zig");
const GlyphAtlas = @import("glyph_atlas.zig").GlyphAtlas;

/// On Windows the renderer draws into a native host's window with a
/// context of its own: a Direct3D 11 swapchain composed into the window,
/// which keeps alpha so a system backdrop shows through, or with
/// `-Dgl=true` an OpenGL context, whose alpha Windows ignores.
pub const draws_into_win32 = builtin.os.tag == .windows;
const native = if (!draws_into_win32) struct {
    pub const Context = void;
} else if (options.opengl) @import("wgl.zig") else @import("composition.zig");

/// The renderer contract, through sokol_gfx: draws zui frames with
/// sokol_gl (shapes, images, TrueType text) and sokol_debugtext (bitmap
/// text) into sokol_app's swapchain, its `.library` surface, or, built with
/// OpenGL on Windows, into a native host's `.win32` window. Both record into
/// numbered layers that are replayed in order, so shapes and text
/// interleave in zui's paint order, and each layer is drawn under its own
/// scissor rectangle.
pub const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = if (draws_into_win32) .initMany(&.{ .library, .win32 }) else .initOne(.library);
    pub const zui_commands: zui.CommandSet = .initMany(&.{ .gradient, .shadow });
    pub const ImageHandle = Image;

    const max_layers = 1024;

    text: *const Text,
    /// What each frame's pass clears to before drawing.
    clear_color: zui.Color = .black,
    /// Triangles per rounded corner.
    corner_segments: u8 = 8,
    pipeline: sgl.Pipeline,
    alpha_coverage_pipeline: sgl.Pipeline,
    /// The surface keeps the alpha drawn, as a composed native window does.
    composes_alpha: bool = false,
    /// Paint order breaks once a frame needs more layers than this; zui's
    /// commands then share the last layer.
    layer_overflows: u32 = 0,
    layer_scissors: [max_layers]?zui.Rect = undefined,
    /// The context of a `.win32` surface, which the renderer set up itself.
    native: ?native.Context = null,
    /// Made on the first TrueType text, so bitmap-only applications never
    /// pay for it.
    glyphs: ?*GlyphAtlas = null,
    glyph_image: sg.Image = .{},
    glyph_texture: Image = .{ .view = .{}, .sampler = .{} },
    /// Times a frame needed more glyphs than the atlas holds; the ones
    /// that did not fit were not drawn.
    glyph_overflows: u32 = 0,

    /// Call after `sokol.gfx.setup`.
    pub fn init(text: *const Text) Renderer {
        sgl.setup(.{ .max_vertices = 1 << 19, .max_commands = 1 << 14, .logger = .{ .func = sokol.log.func } });
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
        // sokol_gl writes no alpha by default, so a window composed with its
        // alpha (a native host's, over a system backdrop) would show the
        // backdrop through every shape.
        colors[0].write_mask = .RGBA;
        colors[0].blend = .{
            .enabled = true,
            .src_factor_rgb = .SRC_ALPHA,
            .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
            .src_factor_alpha = .ONE,
            .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        };
        var coverage: [8]sg.ColorTargetState = @splat(.{});
        coverage[0].write_mask = .A;
        coverage[0].blend = .{ .enabled = true, .src_factor_alpha = .ONE, .dst_factor_alpha = .ONE, .op_alpha = .MAX };
        return .{ .text = text, .pipeline = sgl.makePipeline(.{ .colors = colors }), .alpha_coverage_pipeline = sgl.makePipeline(.{ .colors = coverage }) };
    }

    /// For a native host's window: makes its graphics context, sets
    /// sokol_gfx up on it, then does what `init` does. `deinit` then also
    /// shuts sokol_gfx down.
    pub fn initForSurface(text: *const Text, surface: zui.Surface) !Renderer {
        if (!draws_into_win32 or surface != .win32) return error.UnsupportedSurface;
        var context = try native.Context.init(surface.win32.hwnd);
        errdefer context.deinit();
        sg.setup(.{ .environment = context.environment(), .logger = .{ .func = sokol.log.func } });
        if (!sg.isvalid()) return error.SokolGfxSetupFailed;
        var renderer: Renderer = .init(text);
        renderer.native = context;
        renderer.composes_alpha = !options.opengl;
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        self.destroyGlyphTexture();
        if (self.glyph_texture.sampler.id != 0) sg.destroySampler(self.glyph_texture.sampler);
        if (self.glyphs) |atlas| std.heap.page_allocator.destroy(atlas);
        sgl.destroyPipeline(self.pipeline);
        sgl.destroyPipeline(self.alpha_coverage_pipeline);
        sdtx.shutdown();
        sgl.shutdown();
        if (comptime draws_into_win32) if (self.native) |*context| {
            sg.shutdown();
            context.deinit();
        };
    }

    /// Draws `frame` in one swapchain pass, cleared to `clear_color`, and
    /// commits it.
    ///
    /// ```zig
    /// const frame = ui.endFrame();
    /// try renderer.zuiSubmit(.library, frame);
    /// ui.release(frame);
    /// ```
    pub fn zuiSubmit(self: *Renderer, surface: zui.Surface, frame: anytype) error{UnsupportedSurface}!void {
        const swapchain = switch (surface) {
            .library => sokol.glue.swapchain(),
            .win32 => if (comptime !draws_into_win32) return error.UnsupportedSurface else if (self.native) |*context| context.swapchain() else return error.UnsupportedSurface,
            else => return error.UnsupportedSurface,
        };
        var action: sg.PassAction = .{};
        action.colors[0] = .{ .load_action = .CLEAR, .clear_value = .{
            .r = @as(f32, @floatFromInt(self.clear_color.r)) / 255,
            .g = @as(f32, @floatFromInt(self.clear_color.g)) / 255,
            .b = @as(f32, @floatFromInt(self.clear_color.b)) / 255,
            .a = @as(f32, @floatFromInt(self.clear_color.a)) / 255,
        } };
        sg.beginPass(.{ .action = action, .swapchain = swapchain });
        self.draw(frame.commands(), frame.params);
        sg.endPass();
        sg.commit();
        if (comptime draws_into_win32) if (surface == .win32) self.native.?.present();
    }

    /// `params` are the frame record's: its viewport and the physical
    /// pixels per layout unit (`scale × zoom`).
    fn draw(self: *Renderer, commands: anytype, params: zui.FrameParams) void {
        const viewport = params.viewport;

        sgl.defaults();
        sgl.loadPipeline(self.pipeline);
        sgl.matrixModeProjection();
        sgl.ortho(0, viewport[0], viewport[1], 0, -1, 1);
        const pixels_per_unit = params.scale * params.zoom;
        self.prepareGlyphs(commands, pixels_per_unit);

        var recorder: LayerRecorder = .{ .renderer = self };
        recorder.begin();
        var clips: ClipStack = .{};
        for (commands) |command| {
            const bounds = command.bounds;
            switch (command.payload) {
                .rectangle => |rectangle| {
                    recorder.beginShapes();
                    fillRectangle(bounds, rectangle.corner_radius, rectangle.color, self.corner_segments);
                    if (self.composes_alpha) self.coverAlpha(recorder.layer, fillRectangle, .{ bounds, rectangle.corner_radius, rectangle.color, self.corner_segments });
                },
                .border => |border| {
                    recorder.beginShapes();
                    strokeBorder(bounds, border.widths, border.corner_radius, border.color, self.corner_segments);
                    if (self.composes_alpha) self.coverAlpha(recorder.layer, strokeBorder, .{ bounds, border.widths, border.corner_radius, border.color, self.corner_segments });
                },
                .text => |line| if (self.text.trueTypeFont(line.style.font)) |font| {
                    recorder.beginShapes();
                    if (self.glyphs) |atlas| drawTrueTypeText(atlas, self.glyph_texture, font, line.content, bounds, line.style, pixels_per_unit);
                } else {
                    recorder.beginText();
                    drawText(self.text, line.content, bounds, line.style, viewport);
                },
                .image => |image| {
                    recorder.beginShapes();
                    drawImage(image.handle, bounds, image.tint, image.corner_radius, self.corner_segments);
                },
                .gradient => |gradient| {
                    recorder.beginShapes();
                    fillGradient(bounds, gradient, self.corner_segments);
                    if (self.composes_alpha) self.coverAlpha(recorder.layer, fillGradient, .{ bounds, gradient, self.corner_segments });
                },
                .shadow => |shadow| {
                    recorder.beginShapes();
                    drawShadow(bounds, shadow, self.corner_segments);
                    if (self.composes_alpha) self.coverAlpha(recorder.layer, drawShadow, .{ bounds, shadow, self.corner_segments });
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

        const scissors = self.layer_scissors[0 .. recorder.layer + 1];
        for (scissors, 0..) |scissor, layer| {
            applyScissor(scissor, params);
            sgl.drawLayer(@intCast(layer));
            sdtx.drawLayer(@intCast(layer));
        }
        if (self.composes_alpha) for (scissors, 0..) |scissor, layer| {
            applyScissor(scissor, params);
            sgl.drawLayer(alphaCoverageLayer(layer));
        };
    }

    fn applyScissor(scissor: ?zui.Rect, params: zui.FrameParams) void {
        const dpi_scale = params.scale * params.zoom;
        const rect = scissor orelse zui.Rect{ .x = 0, .y = 0, .width = params.viewport[0], .height = params.viewport[1] };
        sg.applyScissorRectf(rect.x * dpi_scale, rect.y * dpi_scale, rect.width * dpi_scale, rect.height * dpi_scale, true);
    }

    /// sokol_debugtext writes its font's alpha, 0 between the strokes of a
    /// glyph, which would let a composed window's backdrop show through
    /// each glyph's cell. So every shape is drawn again into the alpha
    /// channel after all the text, keeping the greater alpha.
    fn coverAlpha(self: *Renderer, layer: usize, comptime drawShape: anytype, arguments: anytype) void {
        sgl.layer(alphaCoverageLayer(layer));
        sgl.pushPipeline();
        sgl.loadPipeline(self.alpha_coverage_pipeline);
        @call(.auto, drawShape, arguments);
        sgl.popPipeline();
        sgl.layer(@intCast(layer));
    }

    fn alphaCoverageLayer(layer: usize) i32 {
        return @intCast(max_layers + layer);
    }

    /// Rasterizes every glyph the frame's TrueType text needs before any is
    /// drawn, so the texture is made at most once per frame. If the atlas
    /// fills up, it starts over with only this frame's glyphs.
    fn prepareGlyphs(self: *Renderer, commands: anytype, pixels_per_unit: f32) void {
        if (self.text.truetype_font_count == 0) return;
        const atlas = self.glyphs orelse created: {
            const created = GlyphAtlas.create(std.heap.page_allocator) catch return;
            self.glyphs = created;
            break :created created;
        };
        self.addGlyphs(atlas, commands, pixels_per_unit) catch {
            atlas.reset();
            self.addGlyphs(atlas, commands, pixels_per_unit) catch {
                self.glyph_overflows += 1;
            };
        };
        if (atlas.changed) self.uploadGlyphs(atlas);
    }

    fn addGlyphs(self: *Renderer, atlas: *GlyphAtlas, commands: anytype, pixels_per_unit: f32) error{Full}!void {
        for (commands) |command| switch (command.payload) {
            .text => |line| if (self.text.trueTypeFont(line.style.font)) |font| {
                const pixel_size = rasterPixelSize(line.style.size, pixels_per_unit);
                var codepoints = truetype.Codepoints.init(line.content);
                while (codepoints.next()) |codepoint| {
                    _ = try atlas.findOrAdd(.{ .font = line.style.font, .pixel_size = pixel_size, .codepoint = codepoint }, font);
                }
            },
            else => {},
        };
    }

    /// sokol_gfx images are immutable once made, so a changed atlas is a
    /// new image.
    fn uploadGlyphs(self: *Renderer, atlas: *GlyphAtlas) void {
        self.destroyGlyphTexture();
        self.glyph_image = sg.makeImage(.{
            .width = GlyphAtlas.side,
            .height = GlyphAtlas.side,
            .pixel_format = .RGBA8,
            .data = sg.asRange(&atlas.pixels),
        });
        self.glyph_texture.view = sg.makeView(.{ .texture = .{ .image = self.glyph_image } });
        if (self.glyph_texture.sampler.id == 0) self.glyph_texture.sampler = sg.makeSampler(.{
            .min_filter = .LINEAR,
            .mag_filter = .LINEAR,
            .wrap_u = .CLAMP_TO_EDGE,
            .wrap_v = .CLAMP_TO_EDGE,
        });
        atlas.changed = false;
    }

    fn destroyGlyphTexture(self: *Renderer) void {
        if (self.glyph_texture.view.id != 0) sg.destroyView(self.glyph_texture.view);
        if (self.glyph_image.id != 0) sg.destroyImage(self.glyph_image);
        self.glyph_texture.view = .{};
        self.glyph_image = .{};
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
    fillOutline(&outline, centerOf(bounds));
}

fn centerOf(bounds: zui.Rect) [2]f32 {
    return .{ bounds.x + bounds.width / 2, bounds.y + bounds.height / 2 };
}

/// In the current color, as a fan from `center`, which an outline of a
/// rounded rectangle always surrounds.
fn fillOutline(outline: *const Outline, center: [2]f32) void {
    sgl.beginTriangles();
    for (0..outline.count) |index| {
        const next = (index + 1) % outline.count;
        sgl.v2f(center[0], center[1]);
        sgl.v2f(outline.points[index][0], outline.points[index][1]);
        sgl.v2f(outline.points[next][0], outline.points[next][1]);
    }
    sgl.end();
}

/// The longest a gradient's band may be, along it, in layout units.
/// sokol_gl blends vertex colors in sRGB, so the gradient is drawn in bands
/// across it, each vertex taking the OKLab color at its point; over a short
/// band the two blends differ by less than a step of 8-bit color.
const gradient_band_length = 4;
const max_gradient_bands = 64;

/// A rounded rectangle is convex, so each band of it is a convex polygon:
/// the outline cut by the two lines that bound the band.
fn fillGradient(bounds: zui.Rect, gradient: anytype, corner_segments: u8) void {
    var outline: Outline = .{};
    outline.trace(bounds, gradient.corner_radius, .{}, corner_segments);
    const direction: [2]f32 = .{ @cos(gradient.angle), @sin(gradient.angle) };
    const length = @abs(bounds.width * direction[0]) + @abs(bounds.height * direction[1]);
    const band_count: usize = @intFromFloat(std.math.clamp(@ceil(length / gradient_band_length), 1, max_gradient_bands));
    const band_length = length / @as(f32, @floatFromInt(band_count));
    const center = centerOf(bounds);
    const reversed: [2]f32 = .{ -direction[0], -direction[1] };

    sgl.beginTriangles();
    for (0..band_count) |band| {
        const start = -length / 2 + band_length * @as(f32, @floatFromInt(band));
        var past_start: ConvexPolygon = .{};
        past_start.cut(outline.points[0..outline.count], center, direction, start);
        var band_polygon: ConvexPolygon = .{};
        band_polygon.cut(past_start.points[0..past_start.count], center, reversed, -(start + band_length));
        if (band_polygon.count < 3) continue;
        const first = band_polygon.points[0];
        for (1..band_polygon.count - 1) |index| {
            for ([3][2]f32{ first, band_polygon.points[index], band_polygon.points[index + 1] }) |point| {
                const color = gradient.colorAt(bounds, point);
                sgl.v2fC4b(point[0], point[1], color.r, color.g, color.b, color.a);
            }
        }
    }
    sgl.end();
}

const ConvexPolygon = struct {
    points: [Outline.max_points + 2][2]f32 = undefined,
    count: usize = 0,

    /// Keeps the part of `polygon` at least `distance` along `direction`
    /// from `origin`. Cutting a convex polygon by a line adds at most one
    /// point.
    fn cut(self: *ConvexPolygon, polygon: []const [2]f32, origin: [2]f32, direction: [2]f32, distance: f32) void {
        self.count = 0;
        for (polygon, 0..) |here, index| {
            const next = polygon[(index + 1) % polygon.len];
            const here_beyond = (here[0] - origin[0]) * direction[0] + (here[1] - origin[1]) * direction[1] - distance;
            const next_beyond = (next[0] - origin[0]) * direction[0] + (next[1] - origin[1]) * direction[1] - distance;
            if (here_beyond >= 0) self.add(here);
            if ((here_beyond >= 0) != (next_beyond >= 0)) {
                const along = here_beyond / (here_beyond - next_beyond);
                self.add(.{ here[0] + (next[0] - here[0]) * along, here[1] + (next[1] - here[1]) * along });
            }
        }
    }

    fn add(self: *ConvexPolygon, point: [2]f32) void {
        if (self.count == self.points.len) return;
        self.points[self.count] = point;
        self.count += 1;
    }
};

/// How many rings a shadow's blur fades through, from its color to clear.
const shadow_fade_rings = 6;

/// The box at the shadow's offset, grown by its spread, in its color; then
/// rings out to the blur, each fainter, easing out as a blurred edge does.
fn drawShadow(bounds: zui.Rect, shadow: anytype, corner_segments: u8) void {
    const caster: zui.Rect = .{ .x = bounds.x + shadow.offset[0], .y = bounds.y + shadow.offset[1], .width = bounds.width, .height = bounds.height };
    const spread = @max(shadow.spread, -@min(caster.width, caster.height) / 2);
    var inner: Outline = .{};
    inner.trace(caster, shadow.corner_radius, .all(-spread), corner_segments);
    setColor(shadow.color);
    fillOutline(&inner, centerOf(caster));
    if (shadow.blur <= 0) return;

    var inner_alpha = shadow.color.a;
    sgl.beginTriangles();
    for (1..shadow_fade_rings + 1) |ring| {
        const reached = @as(f32, @floatFromInt(ring)) / shadow_fade_rings;
        var outer: Outline = .{};
        outer.trace(caster, shadow.corner_radius, .all(-(spread + shadow.blur * reached)), corner_segments);
        const outer_alpha: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(shadow.color.a)) * (1 - smoothstep(reached))));
        const inner_color: zui.Color = .{ .r = shadow.color.r, .g = shadow.color.g, .b = shadow.color.b, .a = inner_alpha };
        const outer_color: zui.Color = .{ .r = shadow.color.r, .g = shadow.color.g, .b = shadow.color.b, .a = outer_alpha };
        for (0..outer.count) |index| {
            const next = (index + 1) % outer.count;
            for ([6]struct { [2]f32, zui.Color }{
                .{ inner.points[index], inner_color },
                .{ outer.points[index], outer_color },
                .{ outer.points[next], outer_color },
                .{ inner.points[index], inner_color },
                .{ outer.points[next], outer_color },
                .{ inner.points[next], inner_color },
            }) |vertex| {
                const point, const color = vertex;
                sgl.v2fC4b(point[0], point[1], color.r, color.g, color.b, color.a);
            }
        }
        inner = outer;
        inner_alpha = outer_alpha;
    }
    sgl.end();
}

fn smoothstep(amount: f32) f32 {
    return amount * amount * (3 - 2 * amount);
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
    const max_points = 4 * (max_segments + 1);

    points: [max_points][2]f32 = undefined,
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

/// Text is rasterized at its size in physical pixels, so it is drawn one
/// texel per pixel, up to the atlas's largest size.
fn rasterPixelSize(size: f32, pixels_per_unit: f32) u16 {
    return @intFromFloat(std.math.clamp(@round(size * pixels_per_unit), 1, GlyphAtlas.max_pixel_size));
}

fn snapToPixel(value: f32, pixels_per_unit: f32) f32 {
    return @round(value * pixels_per_unit) / pixels_per_unit;
}

/// The pen advances exactly as `Font.measure` measured, so the text fills
/// the bounds zui laid out; each glyph's quad starts on a whole pixel.
fn drawTrueTypeText(atlas: *const GlyphAtlas, texture: Image, font: *const truetype.Font, content: []const u8, bounds: zui.Rect, style: anytype, pixels_per_unit: f32) void {
    const pixel_size = rasterPixelSize(style.size, pixels_per_unit);
    const units_per_raster_pixel = style.size / @as(f32, @floatFromInt(pixel_size));
    const scale = font.scaleFor(style.size);
    const glyph_box_height = (font.ascent - font.descent) * scale;
    const baseline = snapToPixel(bounds.y + (bounds.height - glyph_box_height) / 2 + font.ascent * scale, pixels_per_unit);
    const texel: f32 = 1.0 / @as(f32, GlyphAtlas.side);

    sgl.enableTexture();
    sgl.texture(texture.view, texture.sampler);
    setColor(style.color);
    sgl.beginQuads();
    var pen = bounds.x;
    var codepoints = truetype.Codepoints.init(content);
    while (codepoints.next()) |codepoint| {
        if (atlas.find(.{ .font = style.font, .pixel_size = pixel_size, .codepoint = codepoint })) |glyph| if (glyph.width != 0) {
            const left = snapToPixel(pen, pixels_per_unit) + @as(f32, @floatFromInt(glyph.offset[0])) * units_per_raster_pixel;
            const top = baseline + @as(f32, @floatFromInt(glyph.offset[1])) * units_per_raster_pixel;
            const right = left + @as(f32, @floatFromInt(glyph.width)) * units_per_raster_pixel;
            const bottom = top + @as(f32, @floatFromInt(glyph.height)) * units_per_raster_pixel;
            const texture_left = @as(f32, @floatFromInt(glyph.x)) * texel;
            const texture_top = @as(f32, @floatFromInt(glyph.y)) * texel;
            const texture_right = texture_left + @as(f32, @floatFromInt(glyph.width)) * texel;
            const texture_bottom = texture_top + @as(f32, @floatFromInt(glyph.height)) * texel;
            sgl.v2fT2f(left, top, texture_left, texture_top);
            sgl.v2fT2f(right, top, texture_right, texture_top);
            sgl.v2fT2f(right, bottom, texture_right, texture_bottom);
            sgl.v2fT2f(left, bottom, texture_left, texture_bottom);
        };
        pen += font.advance(codepoint) * scale + style.letter_spacing;
    }
    sgl.end();
    sgl.disableTexture();
}

/// sokol_gl multiplies each texel by the vertex color, which is the tint.
/// A rounded image is a fan of textured triangles from its center.
fn drawImage(image: Image, bounds: zui.Rect, tint: zui.Color, radius: zui.CornerRadius, corner_segments: u8) void {
    sgl.enableTexture();
    sgl.texture(image.view, image.sampler);
    setColor(tint);
    if (!hasRoundedCorners(radius) or bounds.width <= 0 or bounds.height <= 0) {
        sgl.beginQuads();
        sgl.v2fT2f(bounds.x, bounds.y, 0, 0);
        sgl.v2fT2f(bounds.x + bounds.width, bounds.y, 1, 0);
        sgl.v2fT2f(bounds.x + bounds.width, bounds.y + bounds.height, 1, 1);
        sgl.v2fT2f(bounds.x, bounds.y + bounds.height, 0, 1);
    } else {
        var outline: Outline = .{};
        outline.trace(bounds, radius, .{}, corner_segments);
        const center: [2]f32 = .{ bounds.x + bounds.width / 2, bounds.y + bounds.height / 2 };
        sgl.beginTriangles();
        for (0..outline.count) |index| {
            const next = (index + 1) % outline.count;
            for ([3][2]f32{ center, outline.points[index], outline.points[next] }) |point| {
                sgl.v2fT2f(point[0], point[1], (point[0] - bounds.x) / bounds.width, (point[1] - bounds.y) / bounds.height);
            }
        }
    }
    sgl.end();
    sgl.disableTexture();
}

test "a band of a square is the strip between its two cuts" {
    const square = [_][2]f32{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    var past_start: ConvexPolygon = .{};
    past_start.cut(&square, .{ 5, 5 }, .{ 1, 0 }, -1);
    var band: ConvexPolygon = .{};
    band.cut(past_start.points[0..past_start.count], .{ 5, 5 }, .{ -1, 0 }, -1);
    try std.testing.expectEqual(4, band.count);
    for (band.points[0..band.count]) |point| try std.testing.expect(point[0] == 4 or point[0] == 6);
}

test "a shadow's fade starts at its color and ends clear" {
    try std.testing.expectEqual(0, smoothstep(0));
    try std.testing.expectEqual(1, smoothstep(1));
    try std.testing.expectEqual(0.5, smoothstep(0.5));
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
