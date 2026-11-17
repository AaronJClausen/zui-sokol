const std = @import("std");

/// The zui this backend is built against; import it from here so the
/// application and the backend always agree on zui's types.
pub const zui = @import("zui");
pub const zui_widgets = @import("zui_widgets");
pub const zui_reflect = @import("zui_reflect");
pub const sokol = @import("sokol");

pub const Renderer = @import("renderer.zig").Renderer;
pub const InputCollector = @import("input.zig").InputCollector;

/// The types a context drawn by `Renderer` declares, which build without
/// sokol: an application that only declares frames, for a renderer
/// elsewhere to draw, can import `zui_sokol_ui` alone.
pub const zui_sokol_ui = @import("zui_sokol_ui");
pub const Text = zui_sokol_ui.Text;
pub const Image = zui_sokol_ui.Image;
pub const Material = zui_sokol_ui.Material;
pub const truetype = zui_sokol_ui.truetype;
pub const codepointCount = zui_sokol_ui.codepointCount;

/// The `Image` for a sokol_gfx view and the sampler to draw it with.
pub fn imageOf(view: sokol.gfx.View, sampler: sokol.gfx.Sampler) Image {
    return .{ .view = .{ .id = view.id }, .sampler = .{ .id = sampler.id } };
}

/// A `zui.Config` for `Renderer`: text measured by `Text`, images that are
/// `Image`s, materials that are `Material`s, and exactly the commands
/// `Renderer` draws, gradients, shadows, backdrop blurs, transforms and
/// materials among them. The renderer draws `zui.ExtendedColor`, clamped
/// into an 8-bit sRGB target and as declared into an `.scrgb_fp16` one, so
/// an application may declare its colors in either. Override any other field:
/// `zui.Context(zui_sokol.config(.{ .Color = zui.ExtendedColor, .limits = .{ .max_elements = 8192 } }))`.
pub fn config(overrides: zui.Config) zui.Config {
    comptime zui.checkRenderer(Renderer);
    return zui_sokol_ui.config(overrides);
}

/// Applies what a frame asks of the host that sokol_app can do: the cursor.
/// It has no IME window to place.
pub const HostRequestApplier = struct {
    applied_cursor: ?zui.Cursor = null,

    pub fn apply(self: *HostRequestApplier, requests: zui.HostRequests) void {
        if (self.applied_cursor == requests.cursor) return;
        self.applied_cursor = requests.cursor;
        sokol.app.setMouseCursor(mouseCursorFor(requests.cursor));
    }
};

/// The nearest of sokol_app's cursors.
pub fn mouseCursorFor(cursor: zui.Cursor) sokol.app.MouseCursor {
    return switch (cursor) {
        .default, .wait, .progress, .help => .DEFAULT,
        .pointer, .grab => .POINTING_HAND,
        .text => .IBEAM,
        .crosshair => .CROSSHAIR,
        .move, .grabbing => .RESIZE_ALL,
        .not_allowed => .NOT_ALLOWED,
        .resize_horizontal => .RESIZE_EW,
        .resize_vertical => .RESIZE_NS,
        .resize_nwse => .RESIZE_NWSE,
        .resize_nesw => .RESIZE_NESW,
    };
}

test "config makes images sokol textures and text debugtext's" {
    const derived = config(.{ .limits = .{ .max_elements = 128 }, .CustomData = u32 });
    try std.testing.expect(derived.ImageHandle == Image);
    try std.testing.expect(derived.MaterialHandle == Material);
    try std.testing.expect(derived.Text == Text);
    try std.testing.expect(derived.CustomData == void);
    try std.testing.expectEqual(@as(u32, 128), derived.limits.max_elements);
}

test "the renderer draws the base commands, images, gradients, shadows, backdrop blurs, transforms and materials, into sokol_app's swapchain or an image of its own" {
    const Ui = zui.Context(config(.{ .limits = .{ .max_elements = 8 } }));
    const Payload = Ui.RenderCommand.Payload;
    try std.testing.expectEqual(12, @typeInfo(Payload).@"union".fields.len);
    inline for (.{ "gradient", "shadow", "backdrop_blur", "transform_begin", "transform_end", "material" }) |optional| try std.testing.expect(@hasField(Payload, optional));
    var text: Text = .{};
    var ui = try Ui.init(std.testing.allocator, std.testing.io, &text);
    defer ui.deinit(std.testing.allocator);
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    const frame = ui.endFrame();
    defer ui.release(frame);
    var renderer: Renderer = .{ .text = &text, .pipeline = .{}, .alpha_coverage_pipeline = .{} };
    try std.testing.expectError(error.UnsupportedSurface, renderer.zuiSubmit(.{ .terminal = .{ .columns = 80, .rows = 24 } }, frame));
}

test "every cursor maps to one of sokol's" {
    try std.testing.expectEqual(sokol.app.MouseCursor.IBEAM, mouseCursorFor(.text));
    try std.testing.expectEqual(sokol.app.MouseCursor.POINTING_HAND, mouseCursorFor(.pointer));
}

test {
    _ = @import("input.zig");
    _ = @import("renderer.zig");
    _ = @import("backdrop_blur.zig");
    _ = @import("materials.zig");
    _ = @import("destination.zig");
    _ = @import("bitmap_glyphs.zig");
    _ = @import("glyph_atlas.zig");
}
