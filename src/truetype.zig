const std = @import("std");
const stbtt = @import("stb_truetype");

/// A TrueType font, with what measuring needs read once. Measuring only
/// reads it, so it is safe from many threads at once.
///
/// Sizes follow `ScaleForPixelHeight`: a text size of 16 makes the font's
/// ascent minus its descent 16 units tall.
pub const Font = struct {
    info: stbtt.stbtt_fontinfo,
    /// In font units, like every metric here.
    ascent: f32,
    descent: f32,
    line_gap: f32,
    ascii_advances: [128]f32,
    ascii_glyphs: [128]c_int,

    /// `data` must outlive the font: stb_truetype reads it in place.
    pub fn init(data: []const u8) error{InvalidFont}!Font {
        var font: Font = undefined;
        const offset = stbtt.stbtt_GetFontOffsetForIndex(data.ptr, 0);
        if (offset < 0 or stbtt.stbtt_InitFont(&font.info, data.ptr, offset) == 0) return error.InvalidFont;
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        stbtt.stbtt_GetFontVMetrics(&font.info, &ascent, &descent, &line_gap);
        if (ascent - descent <= 0) return error.InvalidFont;
        font.ascent = @floatFromInt(ascent);
        font.descent = @floatFromInt(descent);
        font.line_gap = @floatFromInt(line_gap);
        for (0..128) |codepoint| {
            font.ascii_glyphs[codepoint] = stbtt.stbtt_FindGlyphIndex(&font.info, @intCast(codepoint));
            font.ascii_advances[codepoint] = font.glyphAdvance(font.ascii_glyphs[codepoint]);
        }
        return font;
    }

    /// Layout units per font unit for text of `size`.
    pub fn scaleFor(self: *const Font, size: f32) f32 {
        return size / (self.ascent - self.descent);
    }

    pub fn lineHeight(self: *const Font, size: f32) f32 {
        return (self.ascent - self.descent + self.line_gap) * self.scaleFor(size);
    }

    pub fn glyphFor(self: *const Font, codepoint: u21) c_int {
        if (codepoint < 128) return self.ascii_glyphs[codepoint];
        return stbtt.stbtt_FindGlyphIndex(&self.info, codepoint);
    }

    /// In font units.
    pub fn advance(self: *const Font, codepoint: u21) f32 {
        if (codepoint < 128) return self.ascii_advances[codepoint];
        return self.glyphAdvance(self.glyphFor(codepoint));
    }

    fn glyphAdvance(self: *const Font, glyph: c_int) f32 {
        var advance_width: c_int = 0;
        var left_side_bearing: c_int = 0;
        stbtt.stbtt_GetGlyphHMetrics(&self.info, glyph, &advance_width, &left_side_bearing);
        return @floatFromInt(advance_width);
    }

    /// Without kerning, so a run measures the same split at any word
    /// boundary, which zui's segment cache relies on.
    pub fn measure(self: *const Font, run: []const u8, size: f32, letter_spacing: f32) [2]f32 {
        var font_units: f32 = 0;
        var glyph_count: f32 = 0;
        var codepoints = Codepoints.init(run);
        while (codepoints.next()) |codepoint| {
            font_units += self.advance(codepoint);
            glyph_count += 1;
        }
        return .{ font_units * self.scaleFor(size) + glyph_count * letter_spacing, self.lineHeight(size) };
    }

    pub const GlyphBitmapBox = struct {
        /// From the pen on the baseline to the bitmap's top-left corner, in pixels.
        offset: [2]i32,
        width: u32,
        height: u32,
    };

    /// For a glyph rasterized so the font's ascent minus descent spans
    /// `pixel_size` pixels.
    pub fn glyphBitmapBox(self: *const Font, glyph: c_int, pixel_size: f32) GlyphBitmapBox {
        const scale = self.scaleFor(pixel_size);
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        stbtt.stbtt_GetGlyphBitmapBox(&self.info, glyph, scale, scale, &x0, &y0, &x1, &y1);
        return .{ .offset = .{ x0, y0 }, .width = @intCast(@max(0, x1 - x0)), .height = @intCast(@max(0, y1 - y0)) };
    }

    /// Writes the glyph's coverage, one byte per pixel, `stride` bytes per row.
    pub fn rasterize(self: *const Font, glyph: c_int, pixel_size: f32, box: GlyphBitmapBox, output: []u8, stride: usize) void {
        std.debug.assert(output.len >= stride * box.height);
        const scale = self.scaleFor(pixel_size);
        stbtt.stbtt_MakeGlyphBitmap(&self.info, output.ptr, @intCast(box.width), @intCast(box.height), @intCast(stride), scale, scale, glyph);
    }
};

/// The codepoints of UTF-8 text; each invalid byte reads as U+FFFD.
pub const Codepoints = struct {
    bytes: []const u8,
    index: usize = 0,

    pub fn init(bytes: []const u8) Codepoints {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Codepoints) ?u21 {
        if (self.index >= self.bytes.len) return null;
        const first = self.bytes[self.index];
        if (first < 0x80) {
            self.index += 1;
            return first;
        }
        const length = std.unicode.utf8ByteSequenceLength(first) catch return self.replace();
        if (self.index + length > self.bytes.len) return self.replace();
        const codepoint = std.unicode.utf8Decode(self.bytes[self.index..][0..length]) catch return self.replace();
        self.index += length;
        return codepoint;
    }

    fn replace(self: *Codepoints) u21 {
        self.index += 1;
        return std.unicode.replacement_character;
    }
};

test "invalid UTF-8 reads as one replacement character per byte" {
    var codepoints = Codepoints.init("a\xffb\xc3\xa9");
    try std.testing.expectEqual(@as(?u21, 'a'), codepoints.next());
    try std.testing.expectEqual(@as(?u21, std.unicode.replacement_character), codepoints.next());
    try std.testing.expectEqual(@as(?u21, 'b'), codepoints.next());
    try std.testing.expectEqual(@as(?u21, 0xe9), codepoints.next());
    try std.testing.expectEqual(@as(?u21, null), codepoints.next());
}
