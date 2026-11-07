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

/// A `zui.Config` whose text is measured by `Text` and whose images are
/// `Image`s; override any field:
/// `zui.Context(zui_sokol.config(.{ .limits = .{ .max_elements = 8192 } }))`.
pub fn config(overrides: zui.Config) zui.Config {
    var result = overrides;
    result.Text = Text;
    result.ImageHandle = Image;
    return result;
}

/// The text contract for sokol_debugtext's built-in 8×8 bitmap fonts:
/// every glyph is a square of the same size, followed by the letter
/// spacing, and `FontId` selects one of its six fonts (0 = KC85/3).
pub const Text = struct {
    /// Glyph height and advance as a fraction of the text size.
    glyph_scale: f32 = 0.75,

    pub fn zuiMeasure(self: *Text, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
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
    const derived = config(.{ .limits = .{ .max_elements = 128 } });
    try std.testing.expect(derived.ImageHandle == Image);
    try std.testing.expect(derived.Text == Text);
    try std.testing.expectEqual(@as(u32, 128), derived.limits.max_elements);
}

test "every cursor maps to one of sokol's" {
    try std.testing.expectEqual(sokol.app.MouseCursor.IBEAM, mouseCursorFor(.text));
    try std.testing.expectEqual(sokol.app.MouseCursor.POINTING_HAND, mouseCursorFor(.pointer));
}

test {
    _ = @import("input.zig");
    _ = @import("renderer.zig");
}
