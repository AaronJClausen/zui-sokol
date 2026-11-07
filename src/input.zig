const std = @import("std");
const zui = @import("zui");
const sapp = @import("sokol").app;

/// Collects sokol_app's events, which arrive between frames, into the next
/// frame record's events, in order. A press and release between two frames
/// stay in order, so zui sees a click.
///
/// ```zig
/// fn event(e: [*c]const sapp.Event) callconv(.c) void { state.input.handleEvent(e, sapp.dpiScale(), now()); }
/// fn frame() callconv(.c) void { state.ui.beginFrame(&.{ .params = params, .events = state.input.take() }); ... }
/// ```
pub const InputCollector = struct {
    pub const event_capacity = 512;
    pub const text_capacity = 1024;

    /// Layout units scrolled per wheel notch.
    wheel_step: f32 = 40,
    /// Events that did not fit since the last `take`.
    dropped_events: u32 = 0,

    pointer: ?[2]f32 = null,
    events: [event_capacity]zui.Event = undefined,
    event_count: usize = 0,
    text: [text_capacity]u8 = undefined,
    text_length: usize = 0,

    /// The events since the last `take`. They point into the collector, so
    /// they stay valid until the next `handleEvent`; `beginFrame` copies them.
    pub fn take(self: *InputCollector) []const zui.Event {
        const events = self.events[0..self.event_count];
        self.event_count = 0;
        self.text_length = 0;
        self.dropped_events = 0;
        return events;
    }

    /// sokol_app reports positions in framebuffer pixels; `dpi_scale`
    /// converts them to layout units. `now` is when the event arrived.
    pub fn handleEvent(self: *InputCollector, event: *const sapp.Event, dpi_scale: f32, now: zui.Instant) void {
        const position: [2]f32 = .{ event.mouse_x / dpi_scale, event.mouse_y / dpi_scale };
        const mouse: zui.Pointer = .{ .id = .mouse, .kind = .mouse, .position = position, .at = now };
        const modifiers = modifiersFrom(event.modifiers);
        switch (event.type) {
            .MOUSE_MOVE, .MOUSE_ENTER => {
                self.pointer = position;
                self.push(.{ .pointer_move = .{ .pointer = mouse } });
            },
            .MOUSE_LEAVE => {
                self.pointer = null;
                self.push(.{ .pointer_leave = .mouse });
            },
            .MOUSE_DOWN => if (buttonFor(event.mouse_button)) |button| self.push(.{ .pointer_down = .{ .pointer = mouse, .button = button } }),
            .MOUSE_UP => if (buttonFor(event.mouse_button)) |button| self.push(.{ .pointer_up = .{ .pointer = mouse, .button = button } }),
            .MOUSE_SCROLL => self.push(.{ .wheel = .{
                .position = self.pointer orelse position,
                .delta = .{ -event.scroll_x * self.wheel_step, -event.scroll_y * self.wheel_step },
                .at = now,
            } }),
            .KEY_DOWN, .KEY_UP => {
                const key_event: zui.KeyEvent = .{
                    .key = keyFor(event.key_code),
                    .modifiers = modifiers,
                    .repeat = event.key_repeat,
                    .scancode = @bitCast(@intFromEnum(event.key_code)),
                    .at = now,
                };
                self.push(if (event.type == .KEY_DOWN) .{ .key_down = key_event } else .{ .key_up = key_event });
            },
            .CHAR => self.pushCodepoint(event.char_code),
            .TOUCHES_BEGAN, .TOUCHES_MOVED, .TOUCHES_ENDED, .TOUCHES_CANCELLED => {
                const touch_count: usize = @intCast(std.math.clamp(event.num_touches, 0, event.touches.len));
                for (event.touches[0..touch_count]) |touch| {
                    if (!touch.changed) continue;
                    const finger: zui.Pointer = .{
                        .id = touchPointerId(touch.identifier),
                        .kind = .touch,
                        .position = .{ touch.pos_x / dpi_scale, touch.pos_y / dpi_scale },
                        .at = now,
                    };
                    self.push(switch (event.type) {
                        .TOUCHES_BEGAN => .{ .pointer_down = .{ .pointer = finger } },
                        .TOUCHES_MOVED => .{ .pointer_move = .{ .pointer = finger } },
                        .TOUCHES_ENDED => .{ .pointer_up = .{ .pointer = finger } },
                        else => .{ .pointer_cancel = finger.id },
                    });
                }
            },
            .FOCUSED, .UNFOCUSED => self.push(.{ .environment = .{ .window_focused = event.type == .FOCUSED } }),
            else => {},
        }
    }

    fn pushCodepoint(self: *InputCollector, char_code: u32) void {
        if (char_code < 0x20 or char_code == 0x7F) return;
        const codepoint = std.math.cast(u21, char_code) orelse return;
        var bytes: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &bytes) catch return;
        if (self.text_length + length > self.text.len) {
            self.dropped_events += 1;
            return;
        }
        const start = self.text_length;
        @memcpy(self.text[start..][0..length], bytes[0..length]);
        self.text_length += length;
        if (self.event_count > 0) {
            const last = &self.events[self.event_count - 1];
            if (last.* == .text and @intFromPtr(last.text.ptr) + last.text.len == @intFromPtr(&self.text[start])) {
                last.text = self.text[start - last.text.len .. self.text_length];
                return;
            }
        }
        self.push(.{ .text = self.text[start..self.text_length] });
    }

    fn push(self: *InputCollector, event: zui.Event) void {
        if (self.event_count == self.events.len) {
            self.dropped_events += 1;
            return;
        }
        self.events[self.event_count] = event;
        self.event_count += 1;
    }
};

/// Touches take the ids after the mouse's.
fn touchPointerId(identifier: usize) zui.PointerId {
    return @enumFromInt(@as(u32, @truncate(identifier)) | 0x8000_0000);
}

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

fn keyFor(key_code: sapp.Keycode) zui.Key {
    const code = @intFromEnum(key_code);
    const a = @intFromEnum(sapp.Keycode.A);
    const digit_0 = @intFromEnum(sapp.Keycode._0);
    const f1 = @intFromEnum(sapp.Keycode.F1);
    if (code >= a and code <= @intFromEnum(sapp.Keycode.Z)) return @enumFromInt(@intFromEnum(zui.Key.a) + (code - a));
    if (code >= digit_0 and code <= @intFromEnum(sapp.Keycode._9)) return @enumFromInt(@intFromEnum(zui.Key.digit_0) + (code - digit_0));
    if (code >= f1 and code <= @intFromEnum(sapp.Keycode.F12)) return @enumFromInt(@intFromEnum(zui.Key.f1) + (code - f1));
    return switch (key_code) {
        .TAB => .tab,
        .ENTER, .KP_ENTER => .enter,
        .ESCAPE => .escape,
        .SPACE => .space,
        .BACKSPACE => .backspace,
        .DELETE => .delete,
        .INSERT => .insert,
        .LEFT => .left,
        .RIGHT => .right,
        .UP => .up,
        .DOWN => .down,
        .HOME => .home,
        .END => .end,
        .PAGE_UP => .page_up,
        .PAGE_DOWN => .page_down,
        .MENU => .menu,
        .LEFT_SHIFT, .RIGHT_SHIFT => .shift,
        .LEFT_CONTROL, .RIGHT_CONTROL => .control,
        .LEFT_ALT, .RIGHT_ALT => .alt,
        .LEFT_SUPER, .RIGHT_SUPER => .super,
        .CAPS_LOCK => .caps_lock,
        .MINUS => .minus,
        .EQUAL => .equals,
        .LEFT_BRACKET => .left_bracket,
        .RIGHT_BRACKET => .right_bracket,
        .BACKSLASH => .backslash,
        .SEMICOLON => .semicolon,
        .APOSTROPHE => .apostrophe,
        .GRAVE_ACCENT => .grave,
        .COMMA => .comma,
        .PERIOD => .period,
        .SLASH => .slash,
        else => .unidentified,
    };
}

const testing = std.testing;
const Tag = std.meta.Tag(zui.Event);

fn expectTags(expected: []const Tag, events: []const zui.Event) !void {
    try testing.expectEqual(expected.len, events.len);
    for (expected, events) |tag, event| try testing.expectEqual(tag, std.meta.activeTag(event));
}

test "a click within one frame stays a press and a release in order" {
    var collector: InputCollector = .{};
    collector.handleEvent(&.{ .type = .MOUSE_DOWN, .mouse_button = .LEFT }, 1, .zero);
    collector.handleEvent(&.{ .type = .MOUSE_UP, .mouse_button = .LEFT }, 1, .zero);
    try expectTags(&.{ .pointer_down, .pointer_up }, collector.take());
    try testing.expectEqual(@as(usize, 0), collector.take().len);
}

test "positions are converted to layout units and the wheel is flipped" {
    var collector: InputCollector = .{};
    collector.handleEvent(&.{ .type = .MOUSE_MOVE, .mouse_x = 200, .mouse_y = 100 }, 2, .fromNanoseconds(7));
    collector.handleEvent(&.{ .type = .MOUSE_SCROLL, .scroll_y = 1 }, 2, .zero);
    const events = collector.take();
    try testing.expectEqual([2]f32{ 100, 50 }, events[0].pointer_move.pointer.position);
    try testing.expectEqual(@as(u64, 7), events[0].pointer_move.pointer.at.nanoseconds);
    try testing.expectEqual([2]f32{ 100, 50 }, events[1].wheel.position);
    try testing.expectEqual([2]f32{ -0.0, -40 }, events[1].wheel.delta);
}

test "typed characters become UTF-8 text and keys keep their modifiers" {
    var collector: InputCollector = .{};
    collector.handleEvent(&.{ .type = .CHAR, .char_code = 'é' }, 1, .zero);
    collector.handleEvent(&.{ .type = .CHAR, .char_code = 'a' }, 1, .zero);
    collector.handleEvent(&.{ .type = .KEY_DOWN, .key_code = .S, .modifiers = sapp.modifier_ctrl }, 1, .zero);
    collector.handleEvent(&.{ .type = .KEY_UP, .key_code = .F5 }, 1, .zero);
    const events = collector.take();
    try expectTags(&.{ .text, .key_down, .key_up }, events);
    try testing.expectEqualStrings("éa", events[0].text);
    try testing.expectEqual(zui.Key.s, events[1].key_down.key);
    try testing.expect(events[1].key_down.modifiers.control);
    try testing.expectEqual(zui.Key.f5, events[2].key_up.key);
}

test "touches are pointers of their own" {
    var collector: InputCollector = .{};
    var began: sapp.Event = .{ .type = .TOUCHES_BEGAN, .num_touches = 2 };
    began.touches[0] = .{ .identifier = 1, .pos_x = 10, .pos_y = 20, .changed = true };
    began.touches[1] = .{ .identifier = 2, .pos_x = 30, .pos_y = 40, .changed = false };
    collector.handleEvent(&began, 1, .zero);
    const events = collector.take();
    try expectTags(&.{.pointer_down}, events);
    try testing.expectEqual(zui.PointerKind.touch, events[0].pointer_down.pointer.kind);
    try testing.expect(events[0].pointer_down.pointer.id != .mouse);
}

test "focus changes the environment" {
    var collector: InputCollector = .{};
    collector.handleEvent(&.{ .type = .UNFOCUSED }, 1, .zero);
    try testing.expect(!collector.take()[0].environment.window_focused);
}
