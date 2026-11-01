const std = @import("std");
const zui = @import("zui");
const sapp = @import("sokol").app;

/// sokol_app delivers input as events between frames; this collects them
/// into one `zui.Input` per frame.
///
/// ```zig
/// fn event(e: [*c]const sapp.Event) callconv(.c) void { state.input.handleEvent(e, sapp.dpiScale()); }
/// fn frame() callconv(.c) void { state.ui.beginFrame(state.input.take(viewport, dt_seconds)); ... }
/// ```
pub const InputCollector = struct {
    /// Layout units scrolled per wheel notch.
    wheel_step: f32 = 40,

    pointer: ?[2]f32 = null,
    held_buttons: std.EnumSet(zui.Button) = .initEmpty(),
    modifiers: zui.Modifiers = .{},

    buttons_pressed_this_frame: std.EnumSet(zui.Button) = .initEmpty(),
    releases_for_next_frame: std.EnumSet(zui.Button) = .initEmpty(),
    keys: [zui.max_keys_per_frame]zui.Key = undefined,
    key_count: usize = 0,
    text: [zui.max_text_input_bytes]u8 = undefined,
    text_length: usize = 0,
    wheel: [2]f32 = .{ 0, 0 },

    /// sokol_app reports positions in framebuffer pixels; `dpi_scale`
    /// converts them to layout units.
    pub fn handleEvent(self: *InputCollector, event: *const sapp.Event, dpi_scale: f32) void {
        self.modifiers = modifiersFrom(event.modifiers);
        switch (event.type) {
            .KEY_DOWN => if (keyFor(event.key_code)) |key| self.pushKey(key),
            .CHAR => self.pushCodepoint(event.char_code),
            .MOUSE_MOVE, .MOUSE_ENTER => self.pointer = .{ event.mouse_x / dpi_scale, event.mouse_y / dpi_scale },
            .MOUSE_LEAVE => self.pointer = null,
            .MOUSE_SCROLL => {
                self.wheel[0] -= event.scroll_x * self.wheel_step;
                self.wheel[1] -= event.scroll_y * self.wheel_step;
            },
            .MOUSE_DOWN => if (buttonFor(event.mouse_button)) |button| {
                self.held_buttons.insert(button);
                self.buttons_pressed_this_frame.insert(button);
            },
            .MOUSE_UP => if (buttonFor(event.mouse_button)) |button| {
                // A press and release in the same frame would otherwise be
                // invisible to zui, which samples held buttons once a frame.
                if (self.buttons_pressed_this_frame.contains(button)) {
                    self.releases_for_next_frame.insert(button);
                } else {
                    self.held_buttons.remove(button);
                }
            },
            else => {},
        }
    }

    /// This frame's input. Its slices point into the collector, which must
    /// stay alive until `beginFrame` returns.
    pub fn take(self: *InputCollector, viewport: [2]f32, dt_seconds: f32) zui.Input {
        const input: zui.Input = .{
            .viewport = viewport,
            .dt_seconds = dt_seconds,
            .pointer = self.pointer,
            .buttons = self.held_buttons,
            .wheel = self.wheel,
            .keys_pressed = self.keys[0..self.key_count],
            .modifiers = self.modifiers,
            .text_input = self.text[0..self.text_length],
        };
        self.held_buttons = self.held_buttons.differenceWith(self.releases_for_next_frame);
        self.releases_for_next_frame = .initEmpty();
        self.buttons_pressed_this_frame = .initEmpty();
        self.key_count = 0;
        self.text_length = 0;
        self.wheel = .{ 0, 0 };
        return input;
    }

    fn pushKey(self: *InputCollector, key: zui.Key) void {
        if (self.key_count == self.keys.len) return;
        self.keys[self.key_count] = key;
        self.key_count += 1;
    }

    fn pushCodepoint(self: *InputCollector, char_code: u32) void {
        if (char_code < 0x20 or char_code == 0x7F) return;
        const codepoint = std.math.cast(u21, char_code) orelse return;
        var bytes: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &bytes) catch return;
        if (self.text_length + length > self.text.len) return;
        @memcpy(self.text[self.text_length..][0..length], bytes[0..length]);
        self.text_length += length;
    }
};

fn modifiersFrom(bits: u32) zui.Modifiers {
    return .{
        .shift = bits & sapp.modifier_shift != 0,
        .control = bits & sapp.modifier_ctrl != 0,
        .alt = bits & sapp.modifier_alt != 0,
        .super = bits & sapp.modifier_super != 0,
    };
}

fn buttonFor(button: sapp.Mousebutton) ?zui.Button {
    return switch (button) {
        .LEFT => .primary,
        .RIGHT => .secondary,
        .MIDDLE => .middle,
        else => null,
    };
}

fn keyFor(key_code: sapp.Keycode) ?zui.Key {
    return switch (key_code) {
        .TAB => .tab,
        .ENTER, .KP_ENTER => .enter,
        .ESCAPE => .escape,
        .SPACE => .space,
        .BACKSPACE => .backspace,
        .DELETE => .delete,
        .LEFT => .left,
        .RIGHT => .right,
        .UP => .up,
        .DOWN => .down,
        .HOME => .home,
        .END => .end,
        .PAGE_UP => .page_up,
        .PAGE_DOWN => .page_down,
        else => null,
    };
}

const testing = std.testing;

test "a click within one frame is spread over two" {
    var collector: InputCollector = .{};
    collector.handleEvent(&.{ .type = .MOUSE_DOWN, .mouse_button = .LEFT }, 1);
    collector.handleEvent(&.{ .type = .MOUSE_UP, .mouse_button = .LEFT }, 1);
    try testing.expect(collector.take(.{ 100, 100 }, 0).buttons.contains(.primary));
    try testing.expect(!collector.take(.{ 100, 100 }, 0).buttons.contains(.primary));
}

test "positions are converted to layout units and the wheel is flipped" {
    var collector: InputCollector = .{};
    collector.handleEvent(&.{ .type = .MOUSE_MOVE, .mouse_x = 200, .mouse_y = 100 }, 2);
    collector.handleEvent(&.{ .type = .MOUSE_SCROLL, .scroll_y = 1 }, 2);
    const input = collector.take(.{ 100, 100 }, 0);
    try testing.expectEqual([2]f32{ 100, 50 }, input.pointer.?);
    try testing.expectEqual([2]f32{ -0.0, -40 }, input.wheel);
}

test "typed characters become UTF-8 and keys map" {
    var collector: InputCollector = .{};
    collector.handleEvent(&.{ .type = .CHAR, .char_code = 'é' }, 1);
    collector.handleEvent(&.{ .type = .KEY_DOWN, .key_code = .TAB, .modifiers = sapp.modifier_shift }, 1);
    const input = collector.take(.{ 100, 100 }, 0);
    try testing.expectEqualStrings("é", input.text_input);
    try testing.expectEqualSlices(zui.Key, &.{.tab}, input.keys_pressed);
    try testing.expect(input.modifiers.shift);
}
