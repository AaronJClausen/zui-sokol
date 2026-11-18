const sokol = @import("sokol");
const sg = sokol.gfx;
const shader = @import("present_scrgb.glsl.zig");

/// Copies a frame drawn into an `.scrgb_fp16` image into a window's
/// half-float swapchain, each color multiplied from zui's scRGB, where 1.0
/// is SDR white, into the swapchain's, where 1.0 is 80 nits.
pub const ScrgbPresent = struct {
    shader: sg.Shader = .{},
    pipeline: sg.Pipeline = .{},
    sampler: sg.Sampler = .{},
    scene: sg.Image = .{},
    scene_view: sg.View = .{},

    pub fn deinit(self: *ScrgbPresent) void {
        if (self.scene_view.id != 0) sg.destroyView(self.scene_view);
        if (self.sampler.id != 0) sg.destroySampler(self.sampler);
        if (self.pipeline.id != 0) sg.destroyPipeline(self.pipeline);
        if (self.shader.id != 0) sg.destroyShader(self.shader);
        self.* = .{};
    }

    /// Before the first frame is presented. False when the GPU cannot.
    pub fn prepare(self: *ScrgbPresent) bool {
        if (self.pipeline.id == 0) {
            self.shader = sg.makeShader(shader.presentScrgbShaderDesc(sg.queryBackend()));
            var desc: sg.PipelineDesc = .{ .shader = self.shader, .depth = .{ .pixel_format = .DEPTH_STENCIL }, .label = "zui-sokol scRGB present" };
            desc.colors[0].pixel_format = .RGBA16F;
            self.pipeline = sg.makePipeline(desc);
            self.sampler = sg.makeSampler(.{ .min_filter = .NEAREST, .mag_filter = .NEAREST, .wrap_u = .CLAMP_TO_EDGE, .wrap_v = .CLAMP_TO_EDGE });
        }
        return sg.queryPipelineState(self.pipeline) == .VALID;
    }

    /// Covers every pixel of `swapchain`, an `.RGBA16F` one with a depth
    /// and stencil buffer, with `scene`, an image of its size.
    pub fn draw(self: *ScrgbPresent, swapchain: sg.Swapchain, scene: sg.Image, sdr_white_scale: f32) void {
        if (scene.id != self.scene.id) {
            if (self.scene_view.id != 0) sg.destroyView(self.scene_view);
            self.scene_view = sg.makeView(.{ .texture = .{ .image = scene } });
            self.scene = scene;
        }
        var action: sg.PassAction = .{};
        action.colors[0] = .{ .load_action = .DONTCARE };
        sg.beginPass(.{ .action = action, .swapchain = swapchain });
        sg.applyPipeline(self.pipeline);
        var bindings: sg.Bindings = .{};
        bindings.views[shader.VIEW_scene] = self.scene_view;
        bindings.samplers[shader.SMP_scene_sampler] = self.sampler;
        sg.applyBindings(bindings);
        const vertex_params: shader.VsParams = .{ .flips_rows = if (sg.queryFeatures().origin_top_left) 0 else 1 };
        sg.applyUniforms(shader.UB_vs_params, sg.asRange(&vertex_params));
        const fragment_params: shader.FsParams = .{ .sdr_white_scale = sdr_white_scale };
        sg.applyUniforms(shader.UB_fs_params, sg.asRange(&fragment_params));
        sg.draw(0, 3, 1);
        sg.endPass();
    }
};
