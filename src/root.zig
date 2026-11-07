const std = @import("std");

/// The zui this backend is built against; import it from here so the
/// application and the backend always agree on zui's types.
pub const zui = @import("zui");
pub const zui_widgets = @import("zui_widgets");
pub const zui_reflect = @import("zui_reflect");
pub const sokol = @import("sokol");

pub const Renderer = @import("renderer.zig").Renderer;
pub const truetype = @import("truetype.zig");
pub const InputCollector = @import("input.zig").InputCollector;

/// A texture as sokol_gl samples it.
pub const Image = struct {
    view: sokol.gfx.View,
    sampler: sokol.gfx.Sampler,
};

/// A `zui.Config` for `Renderer`: text measured by `Text`, images that are
/// `Image`s, and exactly the commands `Renderer` draws. Override any other
/// field:
/// `zui.Context(zui_sokol.config(.{ .limits = .{ .max_elements = 8192 } }))`.
pub fn config(overrides: zui.Config) zui.Config {
    comptime zui.checkRenderer(Renderer);
    var result = overrides;
    result.Text = Text;
    result.commands = .initEmpty();
    result.ImageHandle = Renderer.ImageHandle;
    result.CustomData = void;
    result.MaterialHandle = void;
    return result;
}

/// The text contract. `FontId` 0 to 5 are sokol_debugtext's built-in 8×8
/// bitmap fonts (0 = KC85/3), where every glyph is a square of the same
/// size; the TrueType fonts added with `addTrueTypeFont` follow them.
///
/// ```zig
/// var text: zui_sokol.Text = .{};
/// const body_font = try text.addTrueTypeFont(@embedFile("Inter-Regular.ttf"));
/// ui.text("Hello", .{ .font = body_font, .size = 16 });
/// ```
pub const Text = struct {
    pub const bitmap_font_count = 6;
    pub const max_truetype_fonts = 8;
    /// Measuring only reads the fonts, so zui may measure a cold frame's
    /// texts on several threads.
    pub const zui_thread_safe = true;

    /// A bitmap glyph's height and advance as a fraction of the text size.
    glyph_scale: f32 = 0.75,
    truetype_fonts: [max_truetype_fonts]truetype.Font = undefined,
    truetype_font_count: u8 = 0,

    /// Returns the font's `FontId`. `data` must outlive the `Text`, as an
    /// `@embedFile` does. Add fonts before the first frame: measuring may
    /// run on other threads.
    pub fn addTrueTypeFont(self: *Text, data: []const u8) error{ InvalidFont, TooManyFonts }!u16 {
        if (self.truetype_font_count == max_truetype_fonts) return error.TooManyFonts;
        self.truetype_fonts[self.truetype_font_count] = try .init(data);
        self.truetype_font_count += 1;
        return bitmap_font_count + self.truetype_font_count - 1;
    }

    /// Null for a bitmap font, or an id no font was added for.
    pub fn trueTypeFont(self: *const Text, font: u16) ?*const truetype.Font {
        if (font < bitmap_font_count) return null;
        const index = font - bitmap_font_count;
        return if (index < self.truetype_font_count) &self.truetype_fonts[index] else null;
    }

    pub fn zuiMeasure(self: *Text, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        if (self.trueTypeFont(key.font)) |font| return font.measure(run, key.size, key.letter_spacing);
        return .{ @as(f32, @floatFromInt(codepointCount(run))) * (self.glyphSize(key.size) + key.letter_spacing), key.size };
    }

    pub fn glyphSize(self: *const Text, size: f32) f32 {
        return size * self.glyph_scale;
    }
};

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

pub fn codepointCount(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        const is_continuation_byte = byte & 0xC0 == 0x80;
        if (!is_continuation_byte) count += 1;
    }
    return count;
}

fn measure(text: *Text, run: []const u8, letter_spacing: f32) [2]f32 {
    return text.zuiMeasure(run, .{ .font = 0, .size = 16, .letter_spacing = letter_spacing });
}

test "measurement is additive, with letter spacing after every glyph" {
    var text: Text = .{};
    const one = measure(&text, "one", 2);
    const space = measure(&text, " ", 2);
    const two = measure(&text, "two", 2);
    try std.testing.expectEqual(measure(&text, "one two", 2)[0], one[0] + space[0] + two[0]);
    try std.testing.expectEqual(@as(f32, 3 * (12 + 2)), one[0]);
}

test "config makes images sokol textures and text debugtext's" {
    const derived = config(.{ .limits = .{ .max_elements = 128 }, .CustomData = u32 });
    try std.testing.expect(derived.ImageHandle == Image);
    try std.testing.expect(derived.Text == Text);
    try std.testing.expect(derived.CustomData == void);
    try std.testing.expectEqual(@as(u32, 128), derived.limits.max_elements);
}

test "the renderer draws exactly the base commands and images, into sokol_app's swapchain" {
    const Ui = zui.Context(config(.{ .limits = .{ .max_elements = 8 } }));
    try std.testing.expectEqual(6, @typeInfo(Ui.RenderCommand.Payload).@"union".fields.len);
    var text: Text = .{};
    var ui = try Ui.init(std.testing.allocator, std.testing.io, &text);
    defer ui.deinit(std.testing.allocator);
    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 100, 100 } } });
    const frame = ui.endFrame();
    defer ui.release(frame);
    var renderer: Renderer = .{ .text = &text, .pipeline = .{}, .alpha_coverage_pipeline = .{} };
    try std.testing.expectError(error.UnsupportedSurface, renderer.zuiSubmit(.{ .offscreen = .{ .size = .{ 100, 100 } } }, frame));
}

test "every cursor maps to one of sokol's" {
    try std.testing.expectEqual(sokol.app.MouseCursor.IBEAM, mouseCursorFor(.text));
    try std.testing.expectEqual(sokol.app.MouseCursor.POINTING_HAND, mouseCursorFor(.pointer));
}

test {
    _ = @import("input.zig");
    _ = @import("renderer.zig");
    _ = @import("truetype.zig");
    _ = @import("glyph_atlas.zig");
}
