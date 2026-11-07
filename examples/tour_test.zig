const std = @import("std");
const zui_sokol = @import("zui_sokol");
const kit = @import("kit.zig");
const zui = kit.zui;
const Ui = kit.Ui;
const App = @import("app.zig").App;

const testing = std.testing;

const Harness = struct {
    text: zui_sokol.Text = .{},
    ui: Ui = undefined,
    app: *App = undefined,
    frame_number: u64 = 0,

    fn init(harness: *Harness) !void {
        harness.ui = try .init(testing.allocator, testing.io, &harness.text);
        harness.app = try testing.allocator.create(App);
        harness.app.init(testing.io, .zero);
    }

    fn deinit(harness: *Harness) void {
        harness.app.deinit();
        testing.allocator.destroy(harness.app);
        harness.ui.deinit(testing.allocator);
    }

    fn frame(harness: *Harness, viewport: [2]f32) *const Ui.Frame {
        harness.frame_number += 1;
        var events: [16]zui.Event = undefined;
        var event_count: usize = 0;
        for (harness.app.environment_changes.drain()) |change| {
            events[event_count] = .{ .environment = change };
            event_count += 1;
        }
        const params: zui.FrameParams = .{ .now = .fromNanoseconds(harness.frame_number * std.time.ns_per_s / 60), .viewport = viewport };
        harness.ui.beginFrame(&.{ .params = params, .events = events[0..event_count] }, &harness.app.sources);
        harness.app.declare(&harness.ui);
        const result = harness.ui.endFrame();
        harness.app.afterFrame(&harness.ui);
        return result;
    }
};

/// Lines of text that run past the right edge of the stage, the area every
/// screen lays out in. Text cut off by a clip deeper inside a screen, like
/// the marquee's, is deliberate and not counted.
fn textPastStage(frame: *const Ui.Frame) u32 {
    const stage = frame.rectOf(stage_id).?;
    var clip_depth: usize = 0;
    var cut_off: u32 = 0;
    for (frame.commands()) |command| switch (command.payload) {
        .clip_begin => clip_depth += 1,
        .clip_end => clip_depth -= 1,
        .text => {
            const inside_stage_clip_only = clip_depth == 1;
            if (inside_stage_clip_only and command.bounds.x + command.bounds.width > stage.x + stage.width + 1) cut_off += 1;
        },
        else => {},
    };
    return cut_off;
}

const stage_id: zui.Id = .of("stage");

/// How far the screen's content reaches past the stage that scrolls it.
fn stageOverflow(frame: *const Ui.Frame) [2]f32 {
    const stage = frame.rectOf(stage_id).?;
    const content = frame.content_size[frame.lookup(stage_id.hash).?];
    return .{ @max(0, content[0] - stage.width), @max(0, content[1] - stage.height) };
}

/// The window the demo opens with.
const default_window: [2]f32 = .{ 1440, 900 };

fn settledFrame(harness: *Harness, screen: kit.Screen, viewport: [2]f32) *const Ui.Frame {
    harness.app.current = screen;
    for (0..3) |_| harness.ui.release(harness.frame(viewport));
    return harness.frame(viewport);
}

test "every screen declares within its limits, in the default window and a small one" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();
    for ([_][2]f32{ default_window, .{ 1100, 700 } }) |viewport| {
        for (std.enums.values(kit.Screen)) |screen| {
            const frame = settledFrame(&harness, screen, viewport);
            defer harness.ui.release(frame);
            try testing.expect(frame.diagnostics.ok());
            try testing.expect(frame.elementCount() > 20);
        }
    }
}

test "every screen fits the default window: no scrolling, no text cut off" {
    var harness: Harness = .{};
    try harness.init();
    defer harness.deinit();
    for (std.enums.values(kit.Screen)) |screen| {
        const frame = settledFrame(&harness, screen, default_window);
        defer harness.ui.release(frame);
        const root = frame.rectOf(.of("root")).?;
        try testing.expect(root.width <= default_window[0] and root.height <= default_window[1]);
        try testing.expectEqual([2]f32{ 0, 0 }, stageOverflow(frame));
        try testing.expectEqual(@as(u32, 0), textPastStage(frame));
    }
}
