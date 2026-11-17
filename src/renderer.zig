const std = @import("std");
const zui = @import("zui");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sgl = sokol.gl;
const sdtx = sokol.debugtext;
const builtin = @import("builtin");
const options = @import("zui_sokol_options");
const zui_sokol_ui = @import("zui_sokol_ui");
const Text = zui_sokol_ui.Text;
const Image = zui_sokol_ui.Image;
const truetype = zui_sokol_ui.truetype;
const GlyphAtlas = @import("glyph_atlas.zig").GlyphAtlas;
const BackdropBlurs = @import("backdrop_blur.zig").BackdropBlurs;
const materials = @import("materials.zig");
const Material = zui_sokol_ui.Material;
const Materials = materials.Materials;
const bitmap_glyphs = @import("bitmap_glyphs.zig");
const BitmapGlyphs = bitmap_glyphs.BitmapGlyphs;
const destination = @import("destination.zig");
const Destination = destination.Destination;
const OffscreenTarget = destination.OffscreenTarget;
const VertexColor = destination.VertexColor;

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
/// text) into sokol_app's swapchain, its `.library` surface, into an image
/// of its own for an `.offscreen` surface, which may be `.scrgb_fp16`, or,
/// built with OpenGL on Windows, into a native host's `.win32` window.
/// Both record into numbered layers that are replayed in order, so shapes
/// and text interleave in zui's paint order, and each layer is drawn under
/// its own scissor rectangle. A frame with a backdrop blur is drawn offscreen and
/// copied to the surface, so that the blur can sample what is beneath it.
/// A transform is sokol_gl's modelview matrix; a clip inside one is
/// scissored to the box around it in the window, which is larger than a
/// turned clip. A material is drawn by its own shader at the start of a
/// layer, before the layer's shapes. In an `.scrgb_fp16` target every
/// color is drawn in linear light, and bitmap text by sokol_gl, since
/// sokol_debugtext would write its colors' sRGB encoding.
pub const Renderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = if (draws_into_win32) .initMany(&.{ .library, .offscreen, .win32 }) else .initMany(&.{ .library, .offscreen });
    pub const zui_commands: zui.CommandSet = zui_sokol_ui.commands;
    pub const zui_extended_color = true;
    pub const ImageHandle = Image;
    pub const MaterialHandle = Material;

    const max_layers = 1024;
    const present_layer = 2 * max_layers;

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
    glyph_view: sg.View = .{},
    glyph_sampler: sg.Sampler = .{},
    /// Times a frame needed more glyphs than the atlas holds; the ones
    /// that did not fit were not drawn.
    glyph_overflows: u32 = 0,
    backdrop_blurs: BackdropBlurs = .{},
    /// For bitmap text inside a transform, which sokol_debugtext cannot
    /// draw transformed.
    bitmap_glyphs: BitmapGlyphs = .{},
    /// Times transforms nested deeper than the renderer keeps; the deeper
    /// ones were drawn as their parent is.
    transform_overflows: u32 = 0,
    materials: Materials = .{},
    offscreen: OffscreenTarget = .{},
    /// The format of the frame being recorded.
    format: zui.OutputFormat = .sdr,

    /// Call after `sokol.gfx.setup`.
    pub fn init(text: *const Text) Renderer {
        sgl.setup(.{ .max_vertices = 1 << 19, .max_commands = 1 << 14, .logger = .{ .func = sokol.log.func } });
        var debugtext_desc: sdtx.Desc = .{
            .context = .{ .char_buf_size = 1 << 16, .max_commands = 1 << 14 },
            .logger = .{ .func = sokol.log.func },
        };
        debugtext_desc.fonts[0..bitmap_glyphs.font_count].* = bitmap_glyphs.fonts();
        sdtx.setup(debugtext_desc);

        var coverage: [8]sg.ColorTargetState = @splat(.{});
        coverage[0].write_mask = .A;
        coverage[0].blend = .{ .enabled = true, .src_factor_alpha = .ONE, .dst_factor_alpha = .ONE, .op_alpha = .MAX };
        return .{ .text = text, .pipeline = sgl.makePipeline(destination.blendingPipeline()), .alpha_coverage_pipeline = sgl.makePipeline(.{ .colors = coverage }) };
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
        self.backdrop_blurs.deinit();
        self.materials.deinit();
        self.offscreen.deinit();
        self.bitmap_glyphs.deinit();
        self.destroyGlyphTexture();
        if (self.glyph_sampler.id != 0) sg.destroySampler(self.glyph_sampler);
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

    /// Draws `frame` into `surface`, cleared to `clear_color`, and commits
    /// it. An `.offscreen` surface is drawn into `offscreenImage()`.
    ///
    /// ```zig
    /// const frame = ui.endFrame();
    /// try renderer.zuiSubmit(.library, frame);
    /// ui.release(frame);
    /// ```
    pub fn zuiSubmit(self: *Renderer, surface: zui.Surface, frame: anytype) error{UnsupportedSurface}!void {
        const Target = union(enum) { swapchain: sg.Swapchain, offscreen };
        const target: Target = switch (surface) {
            .library => .{ .swapchain = sokol.glue.swapchain() },
            .win32 => if (comptime !draws_into_win32) return error.UnsupportedSurface else if (self.native) |*context| .{ .swapchain = context.swapchain() } else return error.UnsupportedSurface,
            .offscreen => |offscreen| if (self.offscreen.prepare(offscreen.size, offscreen.format)) .offscreen else return error.UnsupportedSurface,
            else => return error.UnsupportedSurface,
        };
        const into: Destination, const size: [2]i32, const pipeline = switch (target) {
            .swapchain => |swapchain| .{ .swapchain(), .{ swapchain.width, swapchain.height }, self.pipeline },
            .offscreen => .{ self.offscreen.destination(), self.offscreen.size, self.offscreen.pipeline },
        };
        self.format = into.format;
        const clear_value = clearValue(self.clear_color, into.format);
        var action: sg.PassAction = .{};
        action.colors[0] = .{ .load_action = .CLEAR, .clear_value = clear_value };
        const final_pass: sg.Pass = switch (target) {
            .swapchain => |swapchain| .{ .action = action, .swapchain = swapchain },
            .offscreen => self.offscreen.pass(action),
        };
        self.backdrop_blurs.prepare(frame.commands(), size, into);
        self.materials.prepare(frame.commands(), into.pixels);
        const layer_count = self.record(frame.commands(), frame.params, into, pipeline);
        self.materials.upload();
        if (self.backdrop_blurs.count == 0) {
            sg.beginPass(final_pass);
            self.replay(layer_count, frame.params, clear_value, into);
            sg.endPass();
        } else {
            sg.beginPass(self.backdrop_blurs.scenePass(.CLEAR, clear_value));
            self.replay(layer_count, frame.params, clear_value, into);
            sg.endPass();
            sg.beginPass(final_pass);
            applyScissor(null, frame.params);
            sgl.contextDrawLayer(into.context, present_layer);
            sg.endPass();
        }
        sg.commit();
        if (comptime draws_into_win32) if (surface == .win32) self.native.?.present();
    }

    /// What the last `.offscreen` surface was drawn into, in its format:
    /// `.RGBA8` holding sRGB's encoding for `.sdr`, `.RGBA16F` holding
    /// linear scRGB for `.scrgb_fp16`. Stored bottom row first on OpenGL.
    pub fn offscreenImage(self: *const Renderer) sg.Image {
        return self.offscreen.image;
    }

    /// Records `commands` into numbered layers, returning how many.
    /// `params` are the frame record's: its viewport and the physical
    /// pixels per layout unit (`scale × zoom`).
    fn record(self: *Renderer, commands: anytype, params: zui.FrameParams, into: Destination, pipeline: sgl.Pipeline) usize {
        const viewport = params.viewport;
        const format = into.format;

        sgl.setContext(into.context);
        defer sgl.setContext(sgl.defaultContext());
        sgl.defaults();
        sgl.loadPipeline(pipeline);
        sgl.matrixModeProjection();
        sgl.ortho(0, viewport[0], viewport[1], 0, -1, 1);
        const pixels_per_unit = params.scale * params.zoom;
        self.prepareGlyphs(commands, pixels_per_unit);

        var recorder: LayerRecorder = .{ .renderer = self };
        recorder.begin();
        var clips: ClipStack = .{};
        var transforms: TransformStack = .{};
        for (commands) |command| {
            const bounds = command.bounds;
            switch (command.payload) {
                .rectangle => |rectangle| {
                    recorder.beginShapes();
                    const color: VertexColor = .of(rectangle.color, format);
                    fillRectangle(bounds, rectangle.corner_radius, color, self.corner_segments);
                    if (self.composes_alpha) self.coverAlpha(recorder.layer, fillRectangle, .{ bounds, rectangle.corner_radius, color, self.corner_segments });
                },
                .border => |border| {
                    recorder.beginShapes();
                    const color: VertexColor = .of(border.color, format);
                    strokeBorder(bounds, border.widths, border.corner_radius, color, self.corner_segments);
                    if (self.composes_alpha) self.coverAlpha(recorder.layer, strokeBorder, .{ bounds, border.widths, border.corner_radius, color, self.corner_segments });
                },
                .text => |line| if (self.text.trueTypeFont(line.style.font)) |font| {
                    recorder.beginShapes();
                    if (self.glyphs) |atlas| drawTrueTypeText(atlas, self.glyph_view, self.glyph_sampler, font, line.content, bounds, line.style, .of(line.style.color, format), pixels_per_unit);
                } else if (transforms.isActive() or !into.is_swapchain) {
                    recorder.beginShapes();
                    self.bitmap_glyphs.draw(line.content, bounds, line.style.font, self.text.glyphSize(line.style.size), line.style.letter_spacing, .of(line.style.color, format));
                } else {
                    recorder.beginText();
                    drawText(self.text, line.content, bounds, line.style, viewport);
                },
                .image => |image| {
                    recorder.beginShapes();
                    drawImage(image.handle, bounds, .of(image.tint, format), image.corner_radius, self.corner_segments);
                },
                .gradient => |gradient| {
                    recorder.beginShapes();
                    fillGradient(bounds, gradient, format, self.corner_segments);
                    if (self.composes_alpha) self.coverAlpha(recorder.layer, fillGradient, .{ bounds, gradient, format, self.corner_segments });
                },
                .shadow => |shadow| {
                    recorder.beginShapes();
                    drawShadow(bounds, shadow, format, self.corner_segments);
                    if (self.composes_alpha) self.coverAlpha(recorder.layer, drawShadow, .{ bounds, shadow, format, self.corner_segments });
                },
                .backdrop_blur => |blur| {
                    if (self.backdrop_blurs.ready) if (recorder.beginBackdropBlur()) |layer| {
                        const to_window = transforms.current();
                        if (self.backdrop_blurs.record(to_window.boundsOf(bounds), blur.radius, viewport, layer)) {
                            var outline: Outline = .{};
                            outline.trace(bounds, blur.corner_radius, .{}, self.corner_segments);
                            self.backdrop_blurs.drawBlurred(outline.points[0..outline.count], centerOf(bounds), to_window, viewport);
                        }
                    };
                    recorder.beginShapes();
                    const tint: VertexColor = .of(blur.tint, format);
                    fillRectangle(bounds, blur.corner_radius, tint, self.corner_segments);
                    if (self.composes_alpha) self.coverAlpha(recorder.layer, fillRectangle, .{ bounds, blur.corner_radius, tint, self.corner_segments });
                },
                .material => |material| if (!self.recordMaterial(&recorder, material, bounds, transforms.current(), viewport)) {
                    recorder.beginShapes();
                    const fallback: VertexColor = .of(material.fallback, format);
                    fillRectangle(bounds, material.corner_radius, fallback, self.corner_segments);
                    if (self.composes_alpha) self.coverAlpha(recorder.layer, fillRectangle, .{ bounds, material.corner_radius, fallback, self.corner_segments });
                },
                .clip_begin => |clip| {
                    clips.push(if (transforms.isActive()) transforms.current().boundsOf(clip).intersect(clips.current() orelse wholeViewport(viewport)) else clip);
                    recorder.beginLayer(clips.current());
                },
                .clip_end => {
                    clips.pop();
                    recorder.beginLayer(clips.current());
                },
                .transform_begin => |transform| {
                    if (!transforms.push(transform.affine(bounds))) self.transform_overflows += 1;
                    loadModelview(transforms.current());
                },
                .transform_end => {
                    transforms.pop();
                    loadModelview(transforms.current());
                },
            }
        }

        if (self.backdrop_blurs.count > 0) self.backdrop_blurs.recordPresent(viewport, present_layer);
        return recorder.layer + 1;
    }

    /// False when the material is to be drawn as its fallback: the backend
    /// cannot draw it, or the frame has no layer or room left for it.
    fn recordMaterial(self: *Renderer, recorder: *LayerRecorder, material: anytype, bounds: zui.Rect, to_window: zui.Affine, viewport: [2]f32) bool {
        if (!self.materials.isReady()) {
            self.materials.lowered += 1;
            return false;
        }
        const layer = recorder.beginMaterial() orelse {
            self.materials.lowered += 1;
            return false;
        };
        var outline: Outline = .{};
        outline.trace(bounds, material.corner_radius, .{}, self.corner_segments);
        if (!self.materials.record(material.handle, outline.points[0..outline.count], bounds, to_window, viewport, layer, self.format)) return false;
        if (self.composes_alpha) {
            const coverage: VertexColor = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = material.handle.opacity() } };
            self.coverAlpha(layer, fillRectangle, .{ bounds, material.corner_radius, coverage, self.corner_segments });
        }
        return true;
    }

    /// Draws the recorded layers in the current pass, which is the scene's
    /// when the frame has backdrop blurs: it ends before each blur's
    /// passes, and the scene's resumes after them.
    fn replay(self: *Renderer, layer_count: usize, params: zui.FrameParams, clear_value: sg.Color, into: Destination) void {
        const scissors = self.layer_scissors[0..layer_count];
        var next_blur: usize = 0;
        for (scissors, 0..) |scissor, layer| {
            while (next_blur < self.backdrop_blurs.count and self.backdrop_blurs.layers_after[next_blur] == layer) : (next_blur += 1) {
                sg.endPass();
                self.backdrop_blurs.runPasses(next_blur);
                sg.beginPass(self.backdrop_blurs.scenePass(.LOAD, clear_value));
            }
            applyScissor(scissor, params);
            self.materials.replayBefore(layer);
            sgl.contextDrawLayer(into.context, @intCast(layer));
            if (into.is_swapchain) sdtx.drawLayer(@intCast(layer));
        }
        if (self.composes_alpha) for (scissors, 0..) |scissor, layer| {
            applyScissor(scissor, params);
            sgl.drawLayer(alphaCoverageLayer(layer));
        };
    }

    fn applyScissor(scissor: ?zui.Rect, params: zui.FrameParams) void {
        const dpi_scale = params.scale * params.zoom;
        const rect = scissor orelse wholeViewport(params.viewport);
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
        self.glyph_view = sg.makeView(.{ .texture = .{ .image = self.glyph_image } });
        if (self.glyph_sampler.id == 0) self.glyph_sampler = sg.makeSampler(.{
            .min_filter = .LINEAR,
            .mag_filter = .LINEAR,
            .wrap_u = .CLAMP_TO_EDGE,
            .wrap_v = .CLAMP_TO_EDGE,
        });
        atlas.changed = false;
    }

    fn destroyGlyphTexture(self: *Renderer) void {
        if (self.glyph_view.id != 0) sg.destroyView(self.glyph_view);
        if (self.glyph_image.id != 0) sg.destroyImage(self.glyph_image);
        self.glyph_view = .{};
        self.glyph_image = .{};
    }
};

const LayerRecorder = struct {
    renderer: *Renderer,
    layer: usize = 0,
    has_materials: bool = false,
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

    /// A backdrop blur samples everything painted before it, so it starts a
    /// layer that its passes run before. Returns that layer, or null when
    /// no layer is left.
    fn beginBackdropBlur(self: *LayerRecorder) ?usize {
        if (self.isUsed()) {
            if (self.layer + 1 == Renderer.max_layers) return null;
            self.beginLayer(self.renderer.layer_scissors[self.layer]);
        }
        self.has_shapes = true;
        return self.layer;
    }

    /// Materials replay before their layer's shapes and text, so one that
    /// follows either starts a layer. Returns that layer, or null when no
    /// layer is left.
    fn beginMaterial(self: *LayerRecorder) ?usize {
        if (self.has_shapes or self.has_text) {
            if (self.layer + 1 == Renderer.max_layers) return null;
            self.beginLayer(self.renderer.layer_scissors[self.layer]);
        }
        self.has_materials = true;
        return self.layer;
    }

    fn isUsed(self: *const LayerRecorder) bool {
        return self.has_materials or self.has_shapes or self.has_text;
    }

    fn beginLayer(self: *LayerRecorder, scissor: ?zui.Rect) void {
        if (!self.isUsed()) {
            self.renderer.layer_scissors[self.layer] = scissor;
            return;
        }
        if (self.layer + 1 == Renderer.max_layers) {
            self.renderer.layer_overflows += 1;
            return;
        }
        self.layer += 1;
        self.has_materials = false;
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

/// Each entry maps the units inside a transform to the window's, through
/// every transform around it.
const TransformStack = struct {
    to_window: [64]zui.Affine = undefined,
    depth: usize = 0,
    overflow: usize = 0,

    fn isActive(self: *const TransformStack) bool {
        return self.depth > 0;
    }

    fn current(self: *const TransformStack) zui.Affine {
        return if (self.depth == 0) .identity else self.to_window[self.depth - 1];
    }

    /// False when the stack is full, leaving `affine` unapplied.
    fn push(self: *TransformStack, affine: zui.Affine) bool {
        if (self.depth == self.to_window.len) {
            self.overflow += 1;
            return false;
        }
        self.to_window[self.depth] = self.current().after(affine);
        self.depth += 1;
        return true;
    }

    fn pop(self: *TransformStack) void {
        if (self.overflow > 0) {
            self.overflow -= 1;
        } else if (self.depth > 0) {
            self.depth -= 1;
        }
    }
};

fn loadModelview(affine: zui.Affine) void {
    sgl.matrixModeModelview();
    sgl.loadMatrix(&columnMajor(affine)[0]);
}

fn columnMajor(affine: zui.Affine) [16]f32 {
    return .{
        affine.x_axis[0], affine.x_axis[1], 0, 0,
        affine.y_axis[0], affine.y_axis[1], 0, 0,
        0,                0,                1, 0,
        affine.offset[0], affine.offset[1], 0, 1,
    };
}

fn wholeViewport(viewport: [2]f32) zui.Rect {
    return .{ .x = 0, .y = 0, .width = viewport[0], .height = viewport[1] };
}

/// An `.scrgb_fp16` target is cleared in linear light.
fn clearValue(color: zui.Color, format: zui.OutputFormat) sg.Color {
    return switch (format) {
        .sdr => .{
            .r = @as(f32, @floatFromInt(color.r)) / 255,
            .g = @as(f32, @floatFromInt(color.g)) / 255,
            .b = @as(f32, @floatFromInt(color.b)) / 255,
            .a = @as(f32, @floatFromInt(color.a)) / 255,
        },
        .scrgb_fp16 => linear: {
            const linear: zui.ExtendedColor = .fromColor(color);
            break :linear .{ .r = linear.r, .g = linear.g, .b = linear.b, .a = linear.a };
        },
    };
}

fn hasRoundedCorners(radius: zui.CornerRadius) bool {
    return radius.top_left > 0 or radius.top_right > 0 or radius.bottom_left > 0 or radius.bottom_right > 0;
}

fn fillRectangle(bounds: zui.Rect, radius: zui.CornerRadius, color: VertexColor, corner_segments: u8) void {
    color.apply();
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
fn fillGradient(bounds: zui.Rect, gradient: anytype, format: zui.OutputFormat, corner_segments: u8) void {
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
                VertexColor.of(gradient.colorAt(bounds, point), format).apply();
                sgl.v2f(point[0], point[1]);
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
fn drawShadow(bounds: zui.Rect, shadow: anytype, format: zui.OutputFormat, corner_segments: u8) void {
    const caster: zui.Rect = .{ .x = bounds.x + shadow.offset[0], .y = bounds.y + shadow.offset[1], .width = bounds.width, .height = bounds.height };
    const spread = @max(shadow.spread, -@min(caster.width, caster.height) / 2);
    var inner: Outline = .{};
    inner.trace(caster, shadow.corner_radius, .all(-spread), corner_segments);
    const shadow_color: VertexColor = .of(shadow.color, format);
    shadow_color.apply();
    fillOutline(&inner, centerOf(caster));
    if (shadow.blur <= 0) return;

    var inner_alpha = shadow_color.rgba.a;
    sgl.beginTriangles();
    for (1..shadow_fade_rings + 1) |ring| {
        const reached = @as(f32, @floatFromInt(ring)) / shadow_fade_rings;
        var outer: Outline = .{};
        outer.trace(caster, shadow.corner_radius, .all(-(spread + shadow.blur * reached)), corner_segments);
        const outer_alpha: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(shadow_color.rgba.a)) * (1 - smoothstep(reached))));
        const inner_color = shadow_color.withAlpha(inner_alpha);
        const outer_color = shadow_color.withAlpha(outer_alpha);
        for (0..outer.count) |index| {
            const next = (index + 1) % outer.count;
            for ([6]struct { [2]f32, VertexColor }{
                .{ inner.points[index], inner_color },
                .{ outer.points[index], outer_color },
                .{ outer.points[next], outer_color },
                .{ inner.points[index], inner_color },
                .{ outer.points[next], outer_color },
                .{ inner.points[next], inner_color },
            }) |vertex| {
                const point, const color = vertex;
                color.apply();
                sgl.v2f(point[0], point[1]);
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
fn strokeBorder(bounds: zui.Rect, widths: zui.Edges, radius: zui.CornerRadius, color: VertexColor, corner_segments: u8) void {
    var outer: Outline = .{};
    var inner: Outline = .{};
    outer.trace(bounds, radius, .{}, corner_segments);
    inner.trace(bounds, radius, widths, corner_segments);
    color.apply();
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
    const color = VertexColor.of(style.color, .sdr).rgba;
    sdtx.color4b(color.r, color.g, color.b, color.a);
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
fn drawTrueTypeText(atlas: *const GlyphAtlas, view: sg.View, sampler: sg.Sampler, font: *const truetype.Font, content: []const u8, bounds: zui.Rect, style: anytype, color: VertexColor, pixels_per_unit: f32) void {
    const pixel_size = rasterPixelSize(style.size, pixels_per_unit);
    const units_per_raster_pixel = style.size / @as(f32, @floatFromInt(pixel_size));
    const scale = font.scaleFor(style.size);
    const glyph_box_height = (font.ascent - font.descent) * scale;
    const baseline = snapToPixel(bounds.y + (bounds.height - glyph_box_height) / 2 + font.ascent * scale, pixels_per_unit);
    const texel: f32 = 1.0 / @as(f32, GlyphAtlas.side);

    sgl.enableTexture();
    sgl.texture(view, sampler);
    color.apply();
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
fn drawImage(image: Image, bounds: zui.Rect, tint: VertexColor, radius: zui.CornerRadius, corner_segments: u8) void {
    sgl.enableTexture();
    sgl.texture(.{ .id = image.view.id }, .{ .id = image.sampler.id });
    tint.apply();
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

test "an scRGB target is cleared in linear light" {
    try std.testing.expectEqual(sg.Color{ .r = 1, .g = 1, .b = 1, .a = 1 }, clearValue(.white, .scrgb_fp16));
    const gray = clearValue(.rgb(0x808080), .scrgb_fp16);
    try std.testing.expectApproxEqAbs(@as(f32, 0.216), gray.r, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), clearValue(.rgb(0x808080), .sdr).r, 1e-6);
}

test "a shadow's fade starts at its color and ends clear" {
    try std.testing.expectEqual(0, smoothstep(0));
    try std.testing.expectEqual(1, smoothstep(1));
    try std.testing.expectEqual(0.5, smoothstep(0.5));
}

test "nested transforms map to the window innermost first" {
    var transforms: TransformStack = .{};
    try std.testing.expect(transforms.push(.{ .offset = .{ 10, 0 } }));
    try std.testing.expect(transforms.push(.{ .x_axis = .{ 0, 1 }, .y_axis = .{ -1, 0 } }));
    try std.testing.expectEqual([2]f32{ 10, 2 }, transforms.current().apply(.{ 2, 0 }));
    transforms.pop();
    try std.testing.expectEqual([2]f32{ 12, 0 }, transforms.current().apply(.{ 2, 0 }));
}

test "a full transform stack keeps what fits and pops what it skipped first" {
    var transforms: TransformStack = .{};
    for (0..transforms.to_window.len) |_| try std.testing.expect(transforms.push(.{ .offset = .{ 1, 0 } }));
    try std.testing.expect(!transforms.push(.{ .offset = .{ 1000, 0 } }));
    transforms.pop();
    try std.testing.expectEqual([2]f32{ 64, 0 }, transforms.current().apply(.{ 0, 0 }));
}

test "a column-major matrix carries the offset in its last column" {
    const matrix = columnMajor(.{ .x_axis = .{ 2, 3 }, .y_axis = .{ 4, 5 }, .offset = .{ 6, 7 } });
    try std.testing.expectEqualSlices(f32, &.{ 2, 3, 0, 0, 4, 5, 0, 0, 0, 0, 1, 0, 6, 7, 0, 1 }, &matrix);
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
