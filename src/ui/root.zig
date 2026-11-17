const std = @import("std");

/// The zui these types are built against; import it from here so the
/// application and the renderer always agree on zui's types.
pub const zui = @import("zui");

pub const Material = @import("material.zig").Material;
pub const truetype = @import("truetype.zig");

/// The optional commands zui-sokol's renderer draws.
pub const commands: zui.CommandSet = .initMany(&.{ .gradient, .shadow, .backdrop_blur, .transform, .material });

/// A texture as sokol_gl samples it: the ids of a sokol_gfx view and of
/// the sampler to draw it with. `zui_sokol.imageOf` makes one from sokol's
/// own handles.
pub const Image = struct {
    view: SokolId,
    sampler: SokolId,

    pub const SokolId = struct { id: u32 = 0 };
};

/// A `zui.Config` whose frames zui-sokol's renderer draws, declared
/// without sokol, so the application builds for targets sokol does not,
/// such as `wasm32-freestanding`, and streams its frames to a renderer
/// elsewhere. `zui_sokol.config` is this, checked against the renderer.
pub fn config(overrides: zui.Config) zui.Config {
    var result = overrides;
    result.Text = Text;
    result.commands = commands;
    result.extended_color = true;
    result.ImageHandle = Image;
    result.CustomData = void;
    result.MaterialHandle = Material;
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

test "config declares the renderer's text, images, materials and commands, and keeps the rest" {
    const derived = config(.{ .limits = .{ .max_elements = 128 }, .CustomData = u32 });
    try std.testing.expect(derived.ImageHandle == Image);
    try std.testing.expect(derived.MaterialHandle == Material);
    try std.testing.expect(derived.Text == Text);
    try std.testing.expect(derived.CustomData == void);
    try std.testing.expect(derived.extended_color);
    try std.testing.expectEqual(@as(u32, 128), derived.limits.max_elements);
}

test {
    _ = @import("material.zig");
    _ = @import("truetype.zig");
}
