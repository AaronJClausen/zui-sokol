const std = @import("std");
const zui = @import("zui");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sgl = sokol.gl;
const Destination = @import("destination.zig").Destination;

/// A frame with a backdrop blur is drawn into `scene`, a target like the
/// frame's destination, which stops at each blur: two passes blur the scene under the
/// element into float targets, along x then along y, the scene resumes with
/// the blurred pixels drawn inside the element's outline, and the finished
/// scene is copied to the destination. Frames without one never touch it.
pub const BackdropBlurs = struct {
    pub const max_per_frame = 16;
    const max_vertices = 1 << 17;
    const max_commands = 1 << 14;
    const float_format: sg.PixelFormat = .RGBA16F;

    /// False until a frame first has a blur, which then makes the context,
    /// pipelines and targets.
    created: bool = false,
    /// The GPU cannot render, blend and filter `float_format`.
    unsupported: bool = false,
    /// What this frame can blur in: set up, sized to the destination.
    ready: bool = false,
    /// Times a blur was drawn as its tint alone, because the GPU cannot
    /// blur or the frame had no room left for it.
    lowered: u32 = 0,

    context: sgl.Context = .{},
    /// Each tap's weight is split in two, since sokol_gl's vertex colors are
    /// 8-bit: a coarse part in steps of 1/255, and the remainder in steps of
    /// 1/65025, scaled down by the fine pipeline's blend color.
    coarse_pipeline: sgl.Pipeline = .{},
    fine_pipeline: sgl.Pipeline = .{},
    /// In the context recording the frame, `scene_destination`'s: writes
    /// what it samples, alpha too.
    replace_pipeline: sgl.Pipeline = .{},
    scene_destination: ?Destination = null,
    sampler: sg.Sampler = .{},
    flips_render_target_rows: bool = false,

    size: [2]i32 = .{ 0, 0 },
    scene: Scene = .{},
    blurred_along_x: FloatTarget = .{},
    blurred: FloatTarget = .{},

    /// Blur `index` runs before scene layer `layers_after[index]` is drawn.
    layers_after: [max_per_frame]usize = undefined,
    count: usize = 0,

    const Scene = struct {
        color: sg.Image = .{},
        color_attachment: sg.View = .{},
        resolve: sg.Image = .{},
        resolve_attachment: sg.View = .{},
        depth: sg.Image = .{},
        depth_attachment: sg.View = .{},
        texture: sg.View = .{},
    };

    const FloatTarget = struct {
        image: sg.Image = .{},
        attachment: sg.View = .{},
        texture: sg.View = .{},
    };

    pub fn deinit(self: *BackdropBlurs) void {
        if (!self.created) return;
        self.destroyTargets();
        sg.destroySampler(self.sampler);
        if (self.replace_pipeline.id != 0) sgl.destroyPipeline(self.replace_pipeline);
        sgl.destroyPipeline(self.coarse_pipeline);
        sgl.destroyPipeline(self.fine_pipeline);
        sgl.destroyContext(self.context);
        self.* = .{};
    }

    /// Before a frame drawn into `into`, of `size` pixels, is recorded:
    /// readies the targets if the frame has a backdrop blur.
    pub fn prepare(self: *BackdropBlurs, commands: anytype, size: [2]i32, into: Destination) void {
        self.count = 0;
        self.ready = false;
        const has_blur = for (commands) |command| {
            if (command.payload == .backdrop_blur) break true;
        } else false;
        if (!has_blur or size[0] <= 0 or size[1] <= 0) return;
        if (!self.created) self.create();
        if (self.unsupported) return;
        const same_destination = if (self.scene_destination) |scene| scene.context.id == into.context.id and std.meta.eql(scene.pixels, into.pixels) else false;
        if (!same_destination) {
            if (self.replace_pipeline.id != 0) sgl.destroyPipeline(self.replace_pipeline);
            var replace: sg.PipelineDesc = .{};
            replace.colors[0].write_mask = .RGBA;
            self.replace_pipeline = sgl.contextMakePipeline(into.context, replace);
        }
        if (!same_destination or !std.meta.eql(self.size, size)) {
            self.destroyTargets();
            self.createTargets(size, into.pixels);
        }
        self.scene_destination = into;
        self.ready = true;
    }

    /// Records the two passes that blur what lies under `window_bounds`, to run
    /// before scene layer `layer`. Returns false, recording nothing, when
    /// the frame cannot blur or has no room left for this blur.
    pub fn record(self: *BackdropBlurs, window_bounds: zui.Rect, radius: f32, viewport: [2]f32, layer: usize) bool {
        if (!self.ready or self.count == max_per_frame) {
            self.lowered += 1;
            return false;
        }
        const pixels_per_unit = self.pixelsPerUnit(viewport);
        const region: PixelRegion = .covering(window_bounds, pixels_per_unit, self.size);
        if (region.isEmpty()) return false;
        const taps: Taps = .gaussian(radius * pixels_per_unit[0]);
        const vertices_per_tap = 2 * 3 * 6;
        const passes = 2;
        const recording_context = sgl.getContext();
        sgl.setContext(self.context);
        defer sgl.setContext(recording_context);
        const fits = sgl.numVertices() + @as(i32, @intCast(taps.count * vertices_per_tap * passes)) <= max_vertices and
            sgl.numCommands() + @as(i32, @intCast(taps.count * 2 * passes)) <= max_commands;
        if (!fits) {
            self.lowered += 1;
            return false;
        }
        if (self.count == 0) {
            sgl.defaults();
            sgl.matrixModeProjection();
            sgl.ortho(0, @floatFromInt(self.size[0]), @floatFromInt(self.size[1]), 0, -1, 1);
            sgl.enableTexture();
        }
        const size: [2]f32 = .{ @floatFromInt(self.size[0]), @floatFromInt(self.size[1]) };
        sgl.layer(@intCast(2 * self.count));
        sgl.texture(self.scene.texture, self.sampler);
        self.recordTaps(.x, region, taps, size);
        sgl.layer(@intCast(2 * self.count + 1));
        sgl.texture(self.blurred_along_x.texture, self.sampler);
        self.recordTaps(.y, region, taps, size);
        self.layers_after[self.count] = layer;
        self.count += 1;
        return true;
    }

    fn recordTaps(self: *const BackdropBlurs, axis: Axis, region: PixelRegion, taps: Taps, size: [2]f32) void {
        for (taps.offsets[0..taps.count], taps.weights[0..taps.count]) |offset, weight| {
            const parts: SplitWeight = .of(weight);
            sgl.loadPipeline(self.coarse_pipeline);
            self.recordTap(axis, region, offset, parts.coarse, size);
            sgl.loadPipeline(self.fine_pipeline);
            self.recordTap(axis, region, offset, parts.fine, size);
        }
    }

    /// One tap samples `offset` pixels along `axis` from each pixel, as
    /// three quads: where the sample falls inside the region, and before and
    /// after it, where the region's first and last pixels are repeated.
    fn recordTap(self: *const BackdropBlurs, axis: Axis, region: PixelRegion, offset: f32, weight: u8, size: [2]f32) void {
        if (weight == 0) return;
        const start, const end = region.span(axis);
        const across = region.span(axis.other());
        const first_inside = std.math.clamp(start + 0.5 - offset, start, end);
        const last_inside = std.math.clamp(end - 0.5 - offset, start, end);
        const pieces = [3]struct { from: f32, to: f32, sample_from: f32, sample_to: f32 }{
            .{ .from = start, .to = first_inside, .sample_from = start + 0.5, .sample_to = start + 0.5 },
            .{ .from = first_inside, .to = last_inside, .sample_from = first_inside + offset, .sample_to = last_inside + offset },
            .{ .from = last_inside, .to = end, .sample_from = end - 0.5, .sample_to = end - 0.5 },
        };
        sgl.c4b(weight, weight, weight, weight);
        sgl.beginQuads();
        for (pieces) |piece| {
            if (piece.to <= piece.from) continue;
            const corners = [4]struct { along: f32, sample: f32, across: f32 }{
                .{ .along = piece.from, .sample = piece.sample_from, .across = across[0] },
                .{ .along = piece.to, .sample = piece.sample_to, .across = across[0] },
                .{ .along = piece.to, .sample = piece.sample_to, .across = across[1] },
                .{ .along = piece.from, .sample = piece.sample_from, .across = across[1] },
            };
            for (corners) |corner| switch (axis) {
                .x => sgl.v2fT2f(corner.along, corner.across, corner.sample / size[0], self.textureRow(corner.across / size[1])),
                .y => sgl.v2fT2f(corner.across, corner.along, corner.across / size[0], self.textureRow(corner.sample / size[1])),
            };
        }
        sgl.end();
    }

    /// In the context recording the frame, into the current layer: the last
    /// recorded blur, filling `outline` as a fan from `center`, both in
    /// units that `to_window` maps to the window's.
    pub fn drawBlurred(self: *const BackdropBlurs, outline: []const [2]f32, center: [2]f32, to_window: zui.Affine, viewport: [2]f32) void {
        const pixels_per_unit = self.pixelsPerUnit(viewport);
        const size: [2]f32 = .{ @floatFromInt(self.size[0]), @floatFromInt(self.size[1]) };
        sgl.pushPipeline();
        sgl.loadPipeline(self.replace_pipeline);
        sgl.enableTexture();
        sgl.texture(self.blurred.texture, self.sampler);
        sgl.c4b(255, 255, 255, 255);
        sgl.beginTriangles();
        for (0..outline.len) |index| {
            for ([3][2]f32{ center, outline[index], outline[(index + 1) % outline.len] }) |point| {
                const in_window = to_window.apply(point);
                sgl.v2fT2f(point[0], point[1], in_window[0] * pixels_per_unit[0] / size[0], self.textureRow(in_window[1] * pixels_per_unit[1] / size[1]));
            }
        }
        sgl.end();
        sgl.disableTexture();
        sgl.popPipeline();
    }

    /// In the context recording the frame, into `layer`: the whole scene, to
    /// be copied to the destination.
    pub fn recordPresent(self: *const BackdropBlurs, viewport: [2]f32, layer: i32) void {
        sgl.layer(layer);
        sgl.pushPipeline();
        sgl.loadPipeline(self.replace_pipeline);
        sgl.enableTexture();
        sgl.texture(self.scene.texture, self.sampler);
        sgl.c4b(255, 255, 255, 255);
        sgl.beginQuads();
        sgl.v2fT2f(0, 0, 0, self.textureRow(0));
        sgl.v2fT2f(viewport[0], 0, 1, self.textureRow(0));
        sgl.v2fT2f(viewport[0], viewport[1], 1, self.textureRow(1));
        sgl.v2fT2f(0, viewport[1], 0, self.textureRow(1));
        sgl.end();
        sgl.disableTexture();
        sgl.popPipeline();
    }

    /// The scene's pass: `.CLEAR` to start the frame, `.LOAD` to resume it
    /// after a blur.
    pub fn scenePass(self: *const BackdropBlurs, load_action: sg.LoadAction, clear_value: sg.Color) sg.Pass {
        var action: sg.PassAction = .{};
        action.colors[0] = .{ .load_action = load_action, .store_action = .STORE, .clear_value = clear_value };
        var attachments: sg.Attachments = .{};
        attachments.colors[0] = self.scene.color_attachment;
        attachments.resolves[0] = self.scene.resolve_attachment;
        attachments.depth_stencil = self.scene.depth_attachment;
        return .{ .action = action, .attachments = attachments };
    }

    /// Between two of the scene's passes.
    pub fn runPasses(self: *const BackdropBlurs, index: usize) void {
        for ([2]FloatTarget{ self.blurred_along_x, self.blurred }, 0..) |target, pass| {
            var action: sg.PassAction = .{};
            action.colors[0] = .{ .load_action = .CLEAR, .clear_value = .{} };
            var attachments: sg.Attachments = .{};
            attachments.colors[0] = target.attachment;
            sg.beginPass(.{ .action = action, .attachments = attachments });
            sgl.contextDrawLayer(self.context, @intCast(2 * index + pass));
            sg.endPass();
        }
    }

    fn pixelsPerUnit(self: *const BackdropBlurs, viewport: [2]f32) [2]f32 {
        return .{ @as(f32, @floatFromInt(self.size[0])) / viewport[0], @as(f32, @floatFromInt(self.size[1])) / viewport[1] };
    }

    /// Render targets are stored bottom row first on OpenGL.
    fn textureRow(self: *const BackdropBlurs, fraction_down: f32) f32 {
        return if (self.flips_render_target_rows) 1 - fraction_down else fraction_down;
    }

    fn create(self: *BackdropBlurs) void {
        self.created = true;
        const format = sg.queryPixelformat(float_format);
        if (!format.render or !format.blend or !format.filter) {
            self.unsupported = true;
            return;
        }
        self.flips_render_target_rows = !sg.queryFeatures().origin_top_left;
        self.context = sgl.makeContext(.{ .max_vertices = max_vertices, .max_commands = max_commands, .color_format = float_format, .depth_format = .NONE, .sample_count = 1 });
        const step = 1.0 / 255.0;
        self.coarse_pipeline = sgl.contextMakePipeline(self.context, accumulating(.ONE, .{}));
        self.fine_pipeline = sgl.contextMakePipeline(self.context, accumulating(.BLEND_COLOR, .{ .r = step, .g = step, .b = step, .a = step }));
        self.sampler = sg.makeSampler(.{ .min_filter = .LINEAR, .mag_filter = .LINEAR, .wrap_u = .CLAMP_TO_EDGE, .wrap_v = .CLAMP_TO_EDGE });
    }

    fn accumulating(source_factor: sg.BlendFactor, blend_color: sg.Color) sg.PipelineDesc {
        var desc: sg.PipelineDesc = .{ .blend_color = blend_color };
        desc.colors[0].write_mask = .RGBA;
        desc.colors[0].blend = .{
            .enabled = true,
            .src_factor_rgb = source_factor,
            .dst_factor_rgb = .ONE,
            .src_factor_alpha = source_factor,
            .dst_factor_alpha = .ONE,
        };
        return desc;
    }

    fn createTargets(self: *BackdropBlurs, size: [2]i32, pixels: Destination.Pixels) void {
        self.size = size;
        const multisampled = pixels.sample_count > 1;
        self.scene.color = sg.makeImage(.{ .usage = .{ .color_attachment = true }, .width = size[0], .height = size[1], .pixel_format = pixels.color_format, .sample_count = pixels.sample_count });
        self.scene.color_attachment = sg.makeView(.{ .color_attachment = .{ .image = self.scene.color } });
        if (multisampled) {
            self.scene.resolve = sg.makeImage(.{ .usage = .{ .resolve_attachment = true }, .width = size[0], .height = size[1], .pixel_format = pixels.color_format, .sample_count = 1 });
            self.scene.resolve_attachment = sg.makeView(.{ .resolve_attachment = .{ .image = self.scene.resolve } });
        }
        if (pixels.depth_format != .NONE) {
            self.scene.depth = sg.makeImage(.{ .usage = .{ .depth_stencil_attachment = true }, .width = size[0], .height = size[1], .pixel_format = pixels.depth_format, .sample_count = pixels.sample_count });
            self.scene.depth_attachment = sg.makeView(.{ .depth_stencil_attachment = .{ .image = self.scene.depth } });
        }
        self.scene.texture = sg.makeView(.{ .texture = .{ .image = if (multisampled) self.scene.resolve else self.scene.color } });
        for ([2]*FloatTarget{ &self.blurred_along_x, &self.blurred }) |target| {
            target.image = sg.makeImage(.{ .usage = .{ .color_attachment = true }, .width = size[0], .height = size[1], .pixel_format = float_format, .sample_count = 1 });
            target.attachment = sg.makeView(.{ .color_attachment = .{ .image = target.image } });
            target.texture = sg.makeView(.{ .texture = .{ .image = target.image } });
        }
    }

    fn destroyTargets(self: *BackdropBlurs) void {
        const views = [_]sg.View{
            self.scene.color_attachment, self.scene.resolve_attachment,   self.scene.depth_attachment,
            self.scene.texture,          self.blurred_along_x.attachment, self.blurred_along_x.texture,
            self.blurred.attachment,     self.blurred.texture,
        };
        for (views) |view| if (view.id != 0) sg.destroyView(view);
        for ([_]sg.Image{ self.scene.color, self.scene.resolve, self.scene.depth, self.blurred_along_x.image, self.blurred.image }) |image| {
            if (image.id != 0) sg.destroyImage(image);
        }
        self.scene = .{};
        self.blurred_along_x = .{};
        self.blurred = .{};
        self.size = .{ 0, 0 };
    }
};

const Axis = enum {
    x,
    y,

    fn other(axis: Axis) Axis {
        return if (axis == .x) .y else .x;
    }
};

/// Whole pixels, so every sample lands on a texel's center.
const PixelRegion = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,

    fn covering(bounds: zui.Rect, pixels_per_unit: [2]f32, size: [2]i32) PixelRegion {
        const width: f32 = @floatFromInt(size[0]);
        const height: f32 = @floatFromInt(size[1]);
        return .{
            .left = std.math.clamp(@floor(bounds.x * pixels_per_unit[0]), 0, width),
            .top = std.math.clamp(@floor(bounds.y * pixels_per_unit[1]), 0, height),
            .right = std.math.clamp(@ceil((bounds.x + bounds.width) * pixels_per_unit[0]), 0, width),
            .bottom = std.math.clamp(@ceil((bounds.y + bounds.height) * pixels_per_unit[1]), 0, height),
        };
    }

    fn isEmpty(region: PixelRegion) bool {
        return region.right - region.left < 1 or region.bottom - region.top < 1;
    }

    fn span(region: PixelRegion, axis: Axis) [2]f32 {
        return switch (axis) {
            .x => .{ region.left, region.right },
            .y => .{ region.top, region.bottom },
        };
    }
};

/// A Gaussian sampled at whole pixels out to three standard deviations,
/// with each pair of neighbouring pixels taken by one linearly filtered
/// sample between them, weighted so the filter splits it as the two
/// weights do.
const Taps = struct {
    const max_pairs_per_side = 64;
    /// Wider blurs are drawn at this standard deviation, in pixels.
    const max_sigma: f32 = 2.0 * max_pairs_per_side / 3.0;

    offsets: [2 * max_pairs_per_side + 1]f32 = undefined,
    weights: [2 * max_pairs_per_side + 1]f32 = undefined,
    count: usize = 0,

    fn gaussian(sigma_pixels: f32) Taps {
        var taps: Taps = .{};
        const sigma = @min(sigma_pixels, max_sigma);
        if (!(sigma > 0)) {
            taps.add(0, 1);
            return taps;
        }
        const reach: usize = @min(@as(usize, @intFromFloat(@ceil(3 * sigma))), 2 * max_pairs_per_side);
        var total = weightAt(0, sigma);
        for (1..reach + 1) |distance| total += 2 * weightAt(distance, sigma);
        taps.add(0, weightAt(0, sigma) / total);
        var near: usize = 1;
        while (near <= reach) : (near += 2) {
            const near_weight = weightAt(near, sigma);
            const far_weight = if (near + 1 <= reach) weightAt(near + 1, sigma) else 0;
            const pair_weight = near_weight + far_weight;
            const near_distance: f32 = @floatFromInt(near);
            const offset = near_distance + far_weight / pair_weight;
            taps.add(offset, pair_weight / total);
            taps.add(-offset, pair_weight / total);
        }
        return taps;
    }

    fn weightAt(distance: usize, sigma: f32) f32 {
        const pixels: f32 = @floatFromInt(distance);
        return @exp(-pixels * pixels / (2 * sigma * sigma));
    }

    fn add(self: *Taps, offset: f32, weight: f32) void {
        self.offsets[self.count] = offset;
        self.weights[self.count] = weight;
        self.count += 1;
    }
};

const SplitWeight = struct {
    coarse: u8,
    fine: u8,

    fn of(weight: f32) SplitWeight {
        const in_steps = std.math.clamp(weight, 0, 1) * 255;
        const coarse = @floor(in_steps);
        const fine = @round((in_steps - coarse) * 255);
        if (fine == 255) return .{ .coarse = @intFromFloat(@min(coarse + 1, 255)), .fine = 0 };
        return .{ .coarse = @intFromFloat(coarse), .fine = @intFromFloat(fine) };
    }

    fn value(self: SplitWeight) f32 {
        return @as(f32, @floatFromInt(self.coarse)) / 255 + @as(f32, @floatFromInt(self.fine)) / (255 * 255);
    }
};

test "a blur's taps sum to one and are symmetric" {
    for ([_]f32{ 0.5, 3, 8, 21.3, 42, 200 }) |sigma| {
        const taps: Taps = .gaussian(sigma);
        var total: f32 = 0;
        for (taps.weights[0..taps.count]) |weight| total += weight;
        try std.testing.expectApproxEqAbs(@as(f32, 1), total, 1e-5);
        try std.testing.expect(taps.count % 2 == 1 and taps.count <= taps.offsets.len);
        for (1..taps.count / 2 + 1) |pair| try std.testing.expectEqual(taps.offsets[2 * pair - 1], -taps.offsets[2 * pair]);
    }
}

test "a pair's sample sits between its two pixels, nearer the heavier" {
    const taps: Taps = .gaussian(8);
    try std.testing.expectEqual(@as(f32, 0), taps.offsets[0]);
    try std.testing.expect(taps.offsets[1] > 1 and taps.offsets[1] < 1.5);
}

test "no blur is a single tap of the pixel itself" {
    const taps: Taps = .gaussian(0);
    try std.testing.expectEqual(1, taps.count);
    try std.testing.expectEqual(@as(f32, 1), taps.weights[0]);
}

test "a weight split in two parts is within half a fine step" {
    var weight: f32 = 0;
    while (weight <= 1) : (weight += 0.000371) {
        try std.testing.expectApproxEqAbs(weight, SplitWeight.of(weight).value(), 0.5 / (255.0 * 255.0) + 1e-7);
    }
}

test "the widest blur's split weights sum to one within a quarter of a color step" {
    const taps: Taps = .gaussian(Taps.max_sigma);
    var total: f32 = 0;
    for (taps.weights[0..taps.count]) |weight| total += SplitWeight.of(weight).value();
    try std.testing.expectApproxEqAbs(@as(f32, 1), total, 0.25 / 255.0);
}

test "a region covers every pixel the bounds touch, inside the target" {
    const region: PixelRegion = .covering(.{ .x = -3.2, .y = 1.5, .width = 10, .height = 4 }, .{ 2, 2 }, .{ 12, 100 });
    try std.testing.expectEqual(PixelRegion{ .left = 0, .top = 3, .right = 12, .bottom = 11 }, region);
}
