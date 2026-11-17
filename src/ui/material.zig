const std = @import("std");
const zui = @import("zui");

/// The renderer's `MaterialHandle`: a pattern between two colors, drawn by
/// its own shader over the element, in its corners. A renderer without
/// `.material` draws the element's background instead.
///
/// ```zig
/// ui.open(.{ .decoration = .{
///     .background = .rgb(0x1a3050),
///     .material = .{ .pattern = .aurora, .first = .rgb(0x10304a), .second = .rgb(0x40e0a0), .phase = seconds / 8 },
///     .corner_radius = .all(12),
/// } });
/// ```
pub const Material = struct {
    pattern: Pattern = .solid,
    first: zui.Color,
    second: zui.Color = .transparent,
    /// Where the pattern is in its cycle, in turns; a pattern moves as its
    /// phase grows, and repeats each whole turn.
    phase: f32 = 0,
    /// The width of one wave of `aurora`, in layout units.
    scale: f32 = 48,

    pub const Pattern = enum(u8) {
        /// `first` alone.
        solid,
        /// `first` with a soft band of `second` sweeping across it from the
        /// top left to the bottom right once per turn of the phase.
        sheen,
        /// `first` and `second` flowing into each other in waves.
        aurora,
    };

    pub fn solid(color: zui.Color) Material {
        return .{ .first = color, .second = color };
    }

    /// The most opaque it draws anywhere.
    pub fn opacity(self: Material) u8 {
        return if (self.pattern == .solid) self.first.a else @max(self.first.a, self.second.a);
    }
};

test "a material is as opaque as its most opaque color" {
    try std.testing.expectEqual(200, (Material{ .pattern = .sheen, .first = .{ .r = 0, .g = 0, .b = 0, .a = 120 }, .second = .{ .r = 0, .g = 0, .b = 0, .a = 200 } }).opacity());
    try std.testing.expectEqual(120, Material.solid(.{ .r = 0, .g = 0, .b = 0, .a = 120 }).opacity());
}
