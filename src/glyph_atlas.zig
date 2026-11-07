const std = @import("std");
const truetype = @import("truetype.zig");

/// Glyphs rasterized on first use and packed into rows of one RGBA image:
/// white, with coverage in alpha, so a vertex color tints them. When it
/// fills up, it starts over empty.
pub const GlyphAtlas = struct {
    pub const side = 1024;
    /// Text rasterized larger than this is drawn from this size, scaled up.
    pub const max_pixel_size = 160;
    const slot_count = 4096;
    const padding = 1;
    /// Glyphs reach above the ascent and below the descent, so a raster may
    /// be taller than its pixel size.
    const max_raster_side = max_pixel_size * 2;

    pub const Key = struct {
        font: u16,
        pixel_size: u16,
        codepoint: u21,

        fn hash(key: Key) u64 {
            const packed_key = (@as(u64, key.font) << 48) | (@as(u64, key.pixel_size) << 32) | key.codepoint;
            return std.hash.int(packed_key);
        }
    };

    pub const Glyph = struct {
        x: u16 = 0,
        y: u16 = 0,
        width: u16 = 0,
        height: u16 = 0,
        /// From the pen on the baseline to the top-left corner, in pixels.
        offset: [2]i16 = .{ 0, 0 },
    };

    const Slot = struct { key: Key, glyph: Glyph };

    pixels: [side * side * 4]u8,
    slots: [slot_count]?Slot,
    glyph_count: u32,
    shelf_x: u32,
    shelf_y: u32,
    shelf_height: u32,
    coverage: [max_raster_side * max_raster_side]u8,
    /// The pixels changed since the texture was last made from them.
    changed: bool,

    pub fn create(gpa: std.mem.Allocator) error{OutOfMemory}!*GlyphAtlas {
        const atlas = try gpa.create(GlyphAtlas);
        atlas.reset();
        return atlas;
    }

    pub fn reset(self: *GlyphAtlas) void {
        @memset(&self.pixels, 0);
        self.slots = @splat(null);
        self.glyph_count = 0;
        self.shelf_x = 0;
        self.shelf_y = 0;
        self.shelf_height = 0;
        self.changed = true;
    }

    pub fn find(self: *const GlyphAtlas, key: Key) ?Glyph {
        var index = key.hash() % slot_count;
        while (self.slots[index]) |slot| : (index = (index + 1) % slot_count) {
            if (std.meta.eql(slot.key, key)) return slot.glyph;
        }
        return null;
    }

    /// The glyph, rasterizing and packing it first if it is new.
    pub fn findOrAdd(self: *GlyphAtlas, key: Key, font: *const truetype.Font) error{Full}!Glyph {
        if (self.find(key)) |glyph| return glyph;
        if (self.glyph_count * 4 >= slot_count * 3) return error.Full;
        const glyph_index = font.glyphFor(key.codepoint);
        const pixel_size: f32 = @floatFromInt(key.pixel_size);
        const box = font.glyphBitmapBox(glyph_index, pixel_size);
        if (box.width > max_raster_side or box.height > max_raster_side) return error.Full;
        var glyph: Glyph = .{
            .width = @intCast(box.width),
            .height = @intCast(box.height),
            .offset = .{ @intCast(box.offset[0]), @intCast(box.offset[1]) },
        };
        if (box.width != 0 and box.height != 0) {
            const position = try self.place(box.width, box.height);
            glyph.x = @intCast(position[0]);
            glyph.y = @intCast(position[1]);
            font.rasterize(glyph_index, pixel_size, box, &self.coverage, box.width);
            self.copyCoverage(glyph);
            self.changed = true;
        }
        self.insert(key, glyph);
        return glyph;
    }

    fn place(self: *GlyphAtlas, width: u32, height: u32) error{Full}![2]u32 {
        if (self.shelf_x + width + padding > side) {
            self.shelf_y += self.shelf_height + padding;
            self.shelf_x = 0;
            self.shelf_height = 0;
        }
        if (self.shelf_y + height + padding > side) return error.Full;
        const position: [2]u32 = .{ self.shelf_x + padding, self.shelf_y + padding };
        self.shelf_x += width + padding;
        self.shelf_height = @max(self.shelf_height, height + padding);
        return position;
    }

    fn copyCoverage(self: *GlyphAtlas, glyph: Glyph) void {
        for (0..glyph.height) |row| {
            for (0..glyph.width) |column| {
                const pixel = ((@as(usize, glyph.y) + row) * side + glyph.x + column) * 4;
                self.pixels[pixel..][0..4].* = .{ 255, 255, 255, self.coverage[row * glyph.width + column] };
            }
        }
    }

    fn insert(self: *GlyphAtlas, key: Key, glyph: Glyph) void {
        var index = key.hash() % slot_count;
        while (self.slots[index] != null) index = (index + 1) % slot_count;
        self.slots[index] = .{ .key = key, .glyph = glyph };
        self.glyph_count += 1;
    }
};

test "a full atlas refuses new glyphs and starts over empty after reset" {
    const atlas = try GlyphAtlas.create(std.testing.allocator);
    defer std.testing.allocator.destroy(atlas);
    var placed: u32 = 0;
    while (atlas.place(100, 100)) |_| placed += 1 else |_| {}
    try std.testing.expectEqual(@as(u32, 100), placed);
    atlas.reset();
    try std.testing.expectEqual([2]u32{ 1, 1 }, try atlas.place(100, 100));
}
