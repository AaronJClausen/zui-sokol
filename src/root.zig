const std = @import("std");

/// The zui this backend is built against; import it from here so the
/// application and the backend always agree on zui's types.
pub const zui = @import("zui");
pub const zui_widgets = @import("zui_widgets");
pub const zui_reflect = @import("zui_reflect");
pub const sokol = @import("sokol");

pub const Renderer = @import("renderer.zig").Renderer;
pub const RenderOptions = @import("renderer.zig").RenderOptions;
pub const InputCollector = @import("input.zig").InputCollector;

/// A texture as sokol_gl samples it.
pub const Image = struct {
    view: sokol.gfx.View,
    sampler: sokol.gfx.Sampler,
};

/// A `zui.Config` whose images are `Image`s; override any field:
/// `zui.Context(zui_sokol.config(.{ .max_elements = 8192 }), zui_sokol.Platform)`.
pub fn config(overrides: zui.Config) zui.Config {
    var result = overrides;
    result.ImageHandle = Image;
    return result;
}

/// Text is drawn with sokol_debugtext's built-in 8×8 bitmap fonts, so every
/// glyph is a square of the same size and `FontId` selects one of its six
/// fonts (0 = KC85/3).
pub const Platform = struct {
    /// Glyph height and advance as a fraction of the text size.
    glyph_scale: f32 = 0.75,
    /// Physical pixels per layout unit. Update it each frame from
    /// `sokol.app.dpiScale()`.
    dpi_scale: f32 = 1,

    pub fn measureText(self: *Platform, text: []const u8, _: u16, size: f32) [2]f32 {
        return .{ @as(f32, @floatFromInt(codepointCount(text))) * self.glyphSize(size), size };
    }

    pub fn scale(self: *const Platform) f32 {
        return self.dpi_scale;
    }

    pub fn glyphSize(self: *const Platform, size: f32) f32 {
        return size * self.glyph_scale;
    }
};

pub fn codepointCount(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        const is_continuation_byte = byte & 0xC0 == 0x80;
        if (!is_continuation_byte) count += 1;
    }
    return count;
}

test "measurement is additive" {
    var platform: Platform = .{};
    const one = platform.measureText("one", 0, 16);
    const space = platform.measureText(" ", 0, 16);
    const two = platform.measureText("two", 0, 16);
    try std.testing.expectEqual(platform.measureText("one two", 0, 16)[0], one[0] + space[0] + two[0]);
}

test "config makes images sokol textures" {
    const derived = config(.{ .max_elements = 128 });
    try std.testing.expect(derived.ImageHandle == Image);
    try std.testing.expectEqual(@as(u32, 128), derived.max_elements);
}

test {
    _ = @import("input.zig");
    _ = @import("renderer.zig");
}
