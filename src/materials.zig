const std = @import("std");
const zui = @import("zui");
const sokol = @import("sokol");
const sg = sokol.gfx;
const shader = @import("material.glsl.zig");
const Destination = @import("destination.zig").Destination;
const Material = @import("zui_sokol_ui").Material;

/// The shader and pipeline are made the first time a frame has a material,
/// so applications without one never pay for them. During recording each
/// material's triangles and uniforms are kept, and before its layer's
/// shapes are replayed, its triangles are drawn through the shader.
pub const Materials = struct {
    pub const max_per_frame = 256;
    const max_vertices = 1 << 15;

    created: bool = false,
    /// The backend has no build of the shader, or it did not compile.
    unsupported: bool = false,
    /// Times a material was drawn as its fallback, because the backend
    /// cannot draw it or the frame had no room left for it.
    lowered: u32 = 0,

    shader: sg.Shader = .{},
    pipeline: sg.Pipeline = .{},
    /// What `pipeline` draws into.
    pipeline_pixels: ?Destination.Pixels = null,
    vertex_buffer: sg.Buffer = .{},
    recorded: ?*Recorded = null,
    draw_count: usize = 0,
    vertex_count: usize = 0,
    next_to_replay: usize = 0,

    const Vertex = extern struct {
        position: [2]f32,
        local_position: [2]f32,
    };

    const Draw = struct {
        layer: usize,
        first_vertex: u32,
        vertex_count: u32,
        vertex_uniforms: shader.VsParams,
        fragment_uniforms: shader.FsParams,
    };

    const Recorded = struct {
        vertices: [max_vertices]Vertex,
        draws: [max_per_frame]Draw,
    };

    pub fn deinit(self: *Materials) void {
        if (!self.created) return;
        if (self.recorded) |recorded| std.heap.page_allocator.destroy(recorded);
        if (self.vertex_buffer.id != 0) sg.destroyBuffer(self.vertex_buffer);
        if (self.pipeline.id != 0) sg.destroyPipeline(self.pipeline);
        if (self.shader.id != 0) sg.destroyShader(self.shader);
        self.* = .{};
    }

    pub fn isReady(self: *const Materials) bool {
        return self.created and !self.unsupported;
    }

    /// Before a frame drawn into `pixels` is recorded.
    pub fn prepare(self: *Materials, commands: anytype, pixels: Destination.Pixels) void {
        self.draw_count = 0;
        self.vertex_count = 0;
        self.next_to_replay = 0;
        if (!self.created) for (commands) |command| if (command.payload == .material) {
            self.create();
            break;
        };
        if (self.created and !self.unsupported and !std.meta.eql(self.pipeline_pixels, pixels)) self.makePipeline(pixels);
    }

    fn create(self: *Materials) void {
        self.created = true;
        self.shader = sg.makeShader(shader.materialShaderDesc(sg.queryBackend()));
        self.vertex_buffer = sg.makeBuffer(.{
            .usage = .{ .vertex_buffer = true, .write_transient = true },
            .size = max_vertices * @sizeOf(Vertex),
            .label = "zui-sokol material vertices",
        });
        self.recorded = std.heap.page_allocator.create(Recorded) catch null;
        self.unsupported = self.recorded == null or
            sg.queryShaderState(self.shader) != .VALID or
            sg.queryBufferState(self.vertex_buffer) != .VALID;
    }

    fn makePipeline(self: *Materials, pixels: Destination.Pixels) void {
        if (self.pipeline.id != 0) sg.destroyPipeline(self.pipeline);
        var pipeline_desc: sg.PipelineDesc = .{
            .shader = self.shader,
            .primitive_type = .TRIANGLES,
            .sample_count = pixels.sample_count,
            .depth = .{ .pixel_format = pixels.depth_format },
            .label = "zui-sokol material",
        };
        pipeline_desc.colors[0].pixel_format = pixels.color_format;
        pipeline_desc.layout.attrs[shader.ATTR_material_position].format = .FLOAT2;
        pipeline_desc.layout.attrs[shader.ATTR_material_local_position].format = .FLOAT2;
        pipeline_desc.colors[0].write_mask = .RGBA;
        pipeline_desc.colors[0].blend = .{
            .enabled = true,
            .src_factor_rgb = .SRC_ALPHA,
            .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
            .src_factor_alpha = .ONE,
            .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        };
        self.pipeline = sg.makePipeline(pipeline_desc);
        self.pipeline_pixels = pixels;
        self.unsupported = sg.queryPipelineState(self.pipeline) != .VALID;
    }

    /// Keeps `material` to draw over `outline`, a fan around `center`, before
    /// layer `layer`'s shapes. `to_window` maps the outline's units to the
    /// window's. False, counted in `lowered`, when the frame has no room.
    pub fn record(self: *Materials, material: Material, outline: []const [2]f32, bounds: zui.Rect, to_window: zui.Affine, viewport: [2]f32, layer: usize, format: zui.OutputFormat) bool {
        const recorded = self.recorded.?;
        const vertex_count = 3 * outline.len;
        if (self.draw_count == max_per_frame or self.vertex_count + vertex_count > max_vertices) {
            self.lowered += 1;
            return false;
        }
        const center: [2]f32 = .{ bounds.x + bounds.width / 2, bounds.y + bounds.height / 2 };
        const vertices = recorded.vertices[self.vertex_count..][0..vertex_count];
        for (outline, 0..) |point, index| {
            const next = outline[(index + 1) % outline.len];
            for ([3][2]f32{ center, point, next }, vertices[3 * index ..][0..3]) |corner, *vertex| {
                vertex.* = .{ .position = corner, .local_position = .{ corner[0] - bounds.x, corner[1] - bounds.y } };
            }
        }
        recorded.draws[self.draw_count] = .{
            .layer = layer,
            .first_vertex = @intCast(self.vertex_count),
            .vertex_count = @intCast(vertex_count),
            .vertex_uniforms = .{ .window_to_clip = windowToClip(to_window, viewport) },
            .fragment_uniforms = .{
                .first_color = colorComponents(material.first, format),
                .second_color = colorComponents(if (material.pattern == .solid) material.first else material.second, format),
                .size_and_scale = .{ bounds.width, bounds.height, material.scale, 0 },
                .pattern_and_phase = .{ @floatFromInt(@intFromEnum(material.pattern)), material.phase, 0, 0 },
            },
        };
        self.draw_count += 1;
        self.vertex_count += vertex_count;
        return true;
    }

    /// Once the frame is recorded, before any pass draws it.
    pub fn upload(self: *Materials) void {
        if (self.vertex_count == 0) return;
        const vertices = self.recorded.?.vertices[0..self.vertex_count];
        sg.writeBufferTransient(.{ .src = .{ .data = sg.asRange(vertices) }, .dst = .{ .buffer = self.vertex_buffer } });
    }

    /// Draws the materials recorded before layer `layer`'s shapes, in the
    /// current pass and scissor. Layers are replayed in order.
    pub fn replayBefore(self: *Materials, layer: usize) void {
        if (self.next_to_replay == self.draw_count) return;
        const draws = self.recorded.?.draws[0..self.draw_count];
        if (draws[self.next_to_replay].layer != layer) return;
        sg.applyPipeline(self.pipeline);
        var bindings: sg.Bindings = .{};
        bindings.vertex_buffers[0] = self.vertex_buffer;
        sg.applyBindings(bindings);
        while (self.next_to_replay < draws.len and draws[self.next_to_replay].layer == layer) : (self.next_to_replay += 1) {
            const draw = &draws[self.next_to_replay];
            sg.applyUniforms(shader.UB_vs_params, sg.asRange(&draw.vertex_uniforms));
            sg.applyUniforms(shader.UB_fs_params, sg.asRange(&draw.fragment_uniforms));
            sg.draw(draw.first_vertex, draw.vertex_count, 1);
        }
    }
};

/// Column-major: the transform into the window, then the window's layout
/// units into clip space, y down, as sokol_gl's orthographic projection.
fn windowToClip(to_window: zui.Affine, viewport: [2]f32) [16]f32 {
    const x_scale = 2 / viewport[0];
    const y_scale = -2 / viewport[1];
    return .{
        x_scale * to_window.x_axis[0],     y_scale * to_window.x_axis[1],     0, 0,
        x_scale * to_window.y_axis[0],     y_scale * to_window.y_axis[1],     0, 0,
        0,                                 0,                                 1, 0,
        x_scale * to_window.offset[0] - 1, y_scale * to_window.offset[1] + 1, 0, 1,
    };
}

/// In linear light for an `.scrgb_fp16` target.
fn colorComponents(color: zui.Color, format: zui.OutputFormat) [4]f32 {
    return switch (format) {
        .sdr => .{
            @as(f32, @floatFromInt(color.r)) / 255,
            @as(f32, @floatFromInt(color.g)) / 255,
            @as(f32, @floatFromInt(color.b)) / 255,
            @as(f32, @floatFromInt(color.a)) / 255,
        },
        .scrgb_fp16 => linear: {
            const linear: zui.ExtendedColor = .fromColor(color);
            break :linear .{ linear.r, linear.g, linear.b, linear.a };
        },
    };
}

test "the window's corners map to clip space's, y down" {
    const matrix = windowToClip(.identity, .{ 200, 100 });
    const corners = [_]struct { [2]f32, [2]f32 }{ .{ .{ 0, 0 }, .{ -1, 1 } }, .{ .{ 200, 100 }, .{ 1, -1 } } };
    for (corners) |corner| {
        const window, const clip = corner;
        try std.testing.expectApproxEqAbs(clip[0], matrix[0] * window[0] + matrix[4] * window[1] + matrix[12], 1e-6);
        try std.testing.expectApproxEqAbs(clip[1], matrix[1] * window[0] + matrix[5] * window[1] + matrix[13], 1e-6);
    }
}

test "a transform is applied before the projection" {
    const matrix = windowToClip(.{ .offset = .{ 100, 50 } }, .{ 200, 100 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), matrix[12], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), matrix[13], 1e-6);
}
