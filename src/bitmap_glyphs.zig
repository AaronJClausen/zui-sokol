const std = @import("std");
const zui = @import("zui");
const sokol = @import("sokol");
const sg = sokol.gfx;
const sgl = sokol.gl;
const sdtx = sokol.debugtext;

/// sokol_debugtext's built-in fonts, in `FontId` order.
pub fn fonts() [font_count]sdtx.FontDesc {
    return .{ sdtx.fontKc853(), sdtx.fontKc854(), sdtx.fontZ1013(), sdtx.fontCpc(), sdtx.fontC64(), sdtx.fontOric() };
}

pub const font_count = 6;
const glyph_side = 8;
const glyphs_per_font = 256;
const texture_width = glyphs_per_font * glyph_side;
const texture_height = font_count * glyph_side;

/// sokol_debugtext's fonts as one texture for sokol_gl, which, unlike
/// sokol_debugtext, draws through the modelview matrix and so can draw
/// bitmap text inside a transform. Made the first time it is needed.
pub const BitmapGlyphs = struct {
    image: sg.Image = .{},
    texture: sg.View = .{},
    sampler: sg.Sampler = .{},
    /// Allocating the texture's pixels failed, so text inside a transform
    /// is not drawn.
    unavailable: bool = false,

    pub fn deinit(self: *BitmapGlyphs) void {
        if (self.texture.id != 0) sg.destroyView(self.texture);
        if (self.image.id != 0) sg.destroyImage(self.image);
        if (self.sampler.id != 0) sg.destroySampler(self.sampler);
        self.* = .{};
    }

    /// Lays the glyphs out as sokol_debugtext does: in square cells of
    /// `glyph_size`, starting at `bounds.x`, centered down `bounds`.
    pub fn draw(self: *BitmapGlyphs, content: []const u8, bounds: zui.Rect, font: u16, glyph_size: f32, letter_spacing: f32, color: zui.Color) void {
        if (glyph_size <= 0 or !self.ready()) return;
        const utf8 = std.unicode.Utf8View.init(content) catch return;
        const font_index: u16 = @min(font, font_count - 1);
        const font_row: f32 = @floatFromInt(font_index * glyph_side);
        const top = bounds.y + (bounds.height - glyph_size) / 2;
        const texture_top = font_row / texture_height;
        const texture_bottom = (font_row + glyph_side) / texture_height;
        sgl.enableTexture();
        sgl.texture(self.texture, self.sampler);
        sgl.c4b(color.r, color.g, color.b, color.a);
        sgl.beginQuads();
        var glyph_index: f32 = 0;
        var codepoints = utf8.iterator();
        while (codepoints.nextCodepoint()) |codepoint| : (glyph_index += 1) {
            const is_printable_ascii = codepoint >= 0x20 and codepoint < 0x7F;
            const character: f32 = @floatFromInt(if (is_printable_ascii) codepoint else '?');
            const left = bounds.x + glyph_index * (glyph_size + letter_spacing);
            const texture_left = character * glyph_side / texture_width;
            const texture_right = (character + 1) * glyph_side / texture_width;
            sgl.v2fT2f(left, top, texture_left, texture_top);
            sgl.v2fT2f(left + glyph_size, top, texture_right, texture_top);
            sgl.v2fT2f(left + glyph_size, top + glyph_size, texture_right, texture_bottom);
            sgl.v2fT2f(left, top + glyph_size, texture_left, texture_bottom);
        }
        sgl.end();
        sgl.disableTexture();
    }

    fn ready(self: *BitmapGlyphs) bool {
        if (self.texture.id != 0) return true;
        if (self.unavailable) return false;
        const pixels = std.heap.page_allocator.alloc([4]u8, texture_width * texture_height) catch {
            self.unavailable = true;
            return false;
        };
        defer std.heap.page_allocator.free(pixels);
        unpack(pixels);
        self.image = sg.makeImage(.{ .width = texture_width, .height = texture_height, .pixel_format = .RGBA8, .data = sg.asRange(pixels) });
        self.texture = sg.makeView(.{ .texture = .{ .image = self.image } });
        self.sampler = sg.makeSampler(.{ .min_filter = .NEAREST, .mag_filter = .NEAREST, .wrap_u = .CLAMP_TO_EDGE, .wrap_v = .CLAMP_TO_EDGE });
        return true;
    }
};

/// White where a glyph's bit is set, clear elsewhere; each byte of a font
/// is one row of a glyph, its high bit leftmost.
fn unpack(pixels: [][4]u8) void {
    @memset(pixels, .{ 255, 255, 255, 0 });
    for (fonts(), 0..) |font, font_index| {
        const rows: [*]const u8 = @ptrCast(font.data.ptr.?);
        for (font.first_char..@as(usize, font.last_char) + 1, 0..) |character, glyph| {
            for (0..glyph_side) |line| {
                const bits = rows[glyph * glyph_side + line];
                const row_start = (font_index * glyph_side + line) * texture_width + character * glyph_side;
                for (0..glyph_side) |x| {
                    if ((bits >> @intCast(7 - x)) & 1 == 1) pixels[row_start + x][3] = 255;
                }
            }
        }
    }
}

test "the unpacked fonts set a glyph's bits and leave the space clear" {
    const pixels = try std.testing.allocator.alloc([4]u8, texture_width * texture_height);
    defer std.testing.allocator.free(pixels);
    unpack(pixels);
    for (0..font_count) |font| {
        var space_bits: usize = 0;
        var letter_bits: usize = 0;
        for (0..glyph_side) |line| for (0..glyph_side) |x| {
            const row = (font * glyph_side + line) * texture_width;
            if (pixels[row + ' ' * glyph_side + x][3] == 255) space_bits += 1;
            if (pixels[row + 'A' * glyph_side + x][3] == 255) letter_bits += 1;
        };
        try std.testing.expectEqual(0, space_bits);
        try std.testing.expect(letter_bits > 8);
    }
}
