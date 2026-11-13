//! The tour's frame: a header, a rail of screens, the screen itself, and a
//! performance strip that is always on screen.

const std = @import("std");
const kit = @import("kit.zig");
const zui = kit.zui;
const Ui = kit.Ui;
const Shell = kit.Shell;
const Screen = kit.Screen;
const Perf = kit.Perf;
const showcase = @import("showcase.zig");

const rail_width = 236;

const Screens = struct {
    welcome: @import("screens/welcome.zig").Welcome = .{},
    layout_lab: @import("screens/layout_lab.zig").LayoutLab = .{},
    box_storm: @import("screens/box_storm.zig").BoxStorm = .{},
    gallery: @import("screens/gallery.zig").Gallery = .{},
    mission_control: @import("screens/mission_control.zig").MissionControl = .{},
    window_manager: @import("screens/window_manager.zig").WindowManager = .{},
    robot_workshop: @import("screens/robot_workshop.zig").RobotWorkshop = .{},
    pixel_pad: @import("screens/pixel_pad.zig").PixelPad = .{},
    typography: @import("screens/typography.zig").Typography = .{},
    light_and_depth: @import("screens/light_and_depth.zig").LightAndDepth = .{},
    classic: showcase.Showcase(Ui) = .{ .title = "zui + sokol", .widgets = .{} },
};

const ids = zui.ids(.{
    "root",
    "header",
    "zoom_out",
    "zoom_reset",
    "zoom_in",
    "theme",
    "live",
    "heartbeat",
    "inspector_toggle",
    "rail",
    "stage",
    "strip",
    "inspector",
    "inspector_title",
    "inspector_close",
});

pub const App = struct {
    io: std.Io,
    sources: kit.Sources = .{},
    screens: Screens = .{},
    current: Screen = .welcome,
    requested_screen: ?Screen = null,
    perf: Perf = .{},
    environment_changes: kit.EnvironmentQueue = .{},
    wakes: std.atomic.Value(u32) = .init(0),
    host_waker: ?zui.Waker = null,
    started_at: zui.Instant,

    zoom: f32 = 1,
    /// Refreshes the strip once a second through `requestFrameAt`, so an
    /// idle tour still shows its counters moving.
    heartbeat: bool = true,
    /// Declares a frame at every display refresh, to watch the costs live.
    live: bool = false,
    inspector_open: bool = false,
    inspector_position: [2]f32 = .{ 760, 90 },
    /// Advances to the next screen every this many zui frames, for smoke tests.
    cycle_every: ?u32 = null,
    frames_on_screen: u32 = 0,

    pub fn init(app: *App, io: std.Io, started_at: zui.Instant) void {
        app.* = .{ .io = io, .started_at = started_at };
        inline for (@typeInfo(Screens).@"struct".fields) |field| {
            if (@hasDecl(field.type, "init")) @field(app.screens, field.name).init();
        }
        app.screens.classic.widgets = .{ .theme = .{ .text = .{ .size = 16, .color = .rgb(0xe8e8f0) } } };
        app.environment_changes.push(.{ .theme = .dark });
    }

    /// Stops every producer, so the sources outlive them.
    pub fn deinit(app: *App) void {
        inline for (@typeInfo(Screens).@"struct".fields) |field| {
            if (@hasDecl(field.type, "deinit")) @field(app.screens, field.name).deinit(app.io);
        }
    }

    pub fn waker(app: *App) zui.Waker {
        return .{ .context = app, .wakeFn = countWake };
    }

    /// Counts each wake, and passes it on to a host that sleeps between
    /// frames. sokol_app polls at every display refresh, so under it
    /// counting is enough: its next poll of `nextFrame` sees the source.
    fn countWake(context: *anyopaque) void {
        const app: *App = @ptrCast(@alignCast(context));
        _ = app.wakes.fetchAdd(1, .monotonic);
        if (app.host_waker) |host_waker| host_waker.wake();
    }

    fn shell(app: *App, ui: *const Ui) Shell {
        const seconds: f64 = ui.now().secondsSince(app.started_at);
        return .init(ui, app.io, seconds, &app.perf, &app.sources, app.waker(), &app.environment_changes, &app.requested_screen);
    }

    pub fn declare(app: *App, ui: *Ui) void {
        var frame_shell = app.shell(ui);
        app.handleShortcuts(ui);

        ui.open(.{ .id = ids.root, .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both }, .decoration = .{ .background = frame_shell.palette.background } });
        app.header(ui, &frame_shell);
        {
            ui.open(.{ .layout = .{ .sizing = .grow_both } });
            defer ui.close();
            app.rail(ui, &frame_shell);
            // Scrolling, not just clipping: a scrolled axis does not pass its
            // content's minimum size up, so a screen too wide for a small
            // window scrolls instead of pushing the header off screen. Not
            // vertically: along a scrolled main axis zui never shrinks
            // children, so the screens' own scroll containers would stop
            // fitting the window.
            ui.open(.{
                .id = ids.stage,
                .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(16), .child_gap = 12 },
                .scroll = .{ .horizontal = true, .vertical = false },
            });
            app.declareScreen(ui, &frame_shell);
            ui.close();
        }
        app.strip(ui, &frame_shell);
        ui.close();
        if (app.inspector_open) app.inspector(ui, &frame_shell);

        if (app.live) ui.requestFrame();
        if (app.heartbeat) {
            const next_second = @floor(frame_shell.seconds) + 1;
            ui.requestFrameAt(app.started_at.addSeconds(next_second));
        }
        app.advanceCycle();
        if (app.requested_screen) |screen| {
            app.current = screen;
            app.requested_screen = null;
            app.frames_on_screen = 0;
            ui.requestFrame();
        }
    }

    /// The loaders: start what this frame asked for, stop what it stopped reading.
    pub fn afterFrame(app: *App, ui: *Ui) void {
        const frame_shell = app.shell(ui);
        inline for (@typeInfo(Screens).@"struct".fields) |field| {
            if (@hasDecl(field.type, "afterFrame")) @field(app.screens, field.name).afterFrame(ui, &frame_shell);
        }
    }

    fn advanceCycle(app: *App) void {
        const cycle_every = app.cycle_every orelse return;
        app.live = true;
        app.frames_on_screen += 1;
        if (app.frames_on_screen < cycle_every) return;
        const next = (@intFromEnum(app.current) + 1) % @typeInfo(Screen).@"enum".fields.len;
        app.requested_screen = @enumFromInt(next);
    }

    fn declareScreen(app: *App, ui: *Ui, frame_shell: *const Shell) void {
        switch (app.current) {
            .classic => app.screens.classic.declare(ui),
            inline else => |screen| @field(app.screens, @tagName(screen)).declare(ui, frame_shell),
        }
    }

    fn handleShortcuts(app: *App, ui: *Ui) void {
        const control: zui.Modifiers = .{ .control = true };
        const digit_keys = [_]zui.Key{ .digit_1, .digit_2, .digit_3, .digit_4, .digit_5, .digit_6, .digit_7, .digit_8, .digit_9, .digit_0 };
        for (digit_keys, 0..) |key, index| {
            if (ui.chordPressed(.{ .key = key, .modifiers = control })) app.requested_screen = @enumFromInt(index);
        }
        const screen_count = @typeInfo(Screen).@"enum".fields.len;
        if (ui.chordPressed(.{ .key = .page_down, .modifiers = control })) app.requested_screen = @enumFromInt((@intFromEnum(app.current) + 1) % screen_count);
        if (ui.chordPressed(.{ .key = .page_up, .modifiers = control })) app.requested_screen = @enumFromInt((@intFromEnum(app.current) + screen_count - 1) % screen_count);
        if (ui.chordPressed(.{ .key = .equals, .modifiers = control })) app.setZoom(app.zoom + 0.1);
        if (ui.chordPressed(.{ .key = .minus, .modifiers = control })) app.setZoom(app.zoom - 0.1);
        if (ui.chordPressed(.{ .key = .i, .modifiers = control })) app.inspector_open = !app.inspector_open;
        if (ui.chordPressed(.{ .key = .l, .modifiers = control })) app.live = !app.live;
    }

    fn setZoom(app: *App, zoom: f32) void {
        app.zoom = std.math.clamp(@round(zoom * 10) / 10, 0.5, 2);
    }

    fn header(app: *App, ui: *Ui, frame_shell: *const Shell) void {
        const palette = frame_shell.palette;
        const widgets = frame_shell.widgets;
        const info = app.current.info();
        ui.open(.{
            .id = ids.header,
            .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(60) }, .padding = .symmetric(16, 0), .child_gap = 14, .child_alignment = .{ .y = .center } },
            .decoration = .{ .background = palette.surface, .border = .{ .color = palette.border, .widths = .{ .bottom = 1 } } },
        });
        defer ui.close();

        ui.open(.{
            .layout = .{ .padding = .symmetric(10, 6) },
            .decoration = .{ .background = palette.accent, .corner_radius = .{ .top_left = 12, .bottom_right = 12, .top_right = 3, .bottom_left = 3 } },
        });
        ui.text("zui", .{ .size = 26, .font = kit.bold_font, .letter_spacing = 1, .color = palette.on_accent });
        ui.close();
        {
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 4 } });
            defer ui.close();
            frame_shell.label(ui, .heading, info.title);
            frame_shell.label(ui, .caption, info.tagline);
        }

        if (widgets.button(ui, ids.zoom_out, "-", .{})) app.setZoom(app.zoom - 0.1);
        var zoom_buffer: [16]u8 = undefined;
        if (widgets.button(ui, ids.zoom_reset, std.fmt.bufPrint(&zoom_buffer, "{d:.0}%", .{app.zoom * 100}) catch "zoom", .{})) app.zoom = 1;
        if (widgets.button(ui, ids.zoom_in, "+", .{})) app.setZoom(app.zoom + 0.1);
        const dark = ui.environment().theme == .dark;
        if (widgets.button(ui, ids.theme, if (dark) "Light" else "Dark", .{})) frame_shell.changeEnvironment(.{ .theme = if (dark) .light else .dark });
        _ = widgets.checkbox(ui, ids.live, "Live", &app.live, .{});
        _ = widgets.checkbox(ui, ids.heartbeat, "1 Hz", &app.heartbeat, .{});
        _ = widgets.checkbox(ui, ids.inspector_toggle, "Inspector", &app.inspector_open, .{});
    }

    fn rail(app: *App, ui: *Ui, frame_shell: *const Shell) void {
        const palette = frame_shell.palette;
        ui.open(.{
            .id = ids.rail,
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(rail_width), .height = .grow }, .padding = .all(10), .child_gap = 4 },
            .decoration = .{ .background = palette.surface, .border = .{ .color = palette.border, .widths = .{ .right = 1 } } },
            .scroll = .{},
        });
        defer ui.close();

        inline for (@typeInfo(Screen).@"enum".fields, 0..) |field, index| {
            const screen: Screen = @enumFromInt(field.value);
            const id: zui.Id = .indexed("rail_item", index);
            const selected = app.current == screen;
            const state = ui.widgetState(id);
            const info = screen.info();
            const swatch = kit.hueColor(info.hue, 0.55, 0.95);
            ui.open(.{
                .id = id,
                .focusable = true,
                .cursor = .pointer,
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(40) }, .padding = .{ .left = 8, .right = 6 }, .child_gap = 8, .child_alignment = .{ .y = .center } },
                .decoration = .{
                    .background = if (selected) palette.hovered else if (state == .hovered or state == .pressed) palette.raised else null,
                    .border = if (ui.focused(id)) .{ .color = palette.focus, .widths = .all(1) } else if (selected) .{ .color = swatch, .widths = .{ .left = 3 } } else null,
                    .corner_radius = .all(6),
                },
            });
            ui.open(.{
                .layout = .{ .sizing = .{ .width = .fixed(22), .height = .fixed(22) }, .child_alignment = .{ .x = .center, .y = .center } },
                .decoration = .{ .background = if (selected) swatch else palette.sunken, .corner_radius = .all(11) },
            });
            if (screen.shortcutDigit()) |digit| frame_shell.printColored(ui, .caption, if (selected) palette.on_accent else palette.muted, "{d}", .{digit});
            ui.close();
            ui.text(info.title, .{ .size = 15 * frame_shell.text_scale, .font = if (selected) kit.bold_font else kit.body_font, .color = if (selected) palette.text else palette.muted, .wrap = .none });
            ui.close();
            if (ui.clicked(id)) app.requested_screen = screen;
        }
        frame_shell.spacer(ui);
        frame_shell.label(ui, .tiny, "Ctrl+1..0  jump to a screen");
        frame_shell.label(ui, .tiny, "Ctrl+PgUp/PgDn  prev/next");
        frame_shell.label(ui, .tiny, "Ctrl+= / Ctrl+-  zoom");
        frame_shell.label(ui, .tiny, "Ctrl+I  frame inspector");
        frame_shell.label(ui, .tiny, "Ctrl+L  live mode");
        frame_shell.label(ui, .tiny, "Tab  move focus");
    }

    fn strip(app: *App, ui: *Ui, frame_shell: *const Shell) void {
        const palette = frame_shell.palette;
        const perf = &app.perf;
        const latest = perf.latest();
        ui.open(.{
            .id = ids.strip,
            .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(78) }, .padding = .symmetric(14, 8), .child_gap = 18, .child_alignment = .{ .y = .center } },
            .decoration = .{ .background = palette.sunken, .border = .{ .color = palette.border, .widths = .{ .top = 1 } } },
        });
        defer ui.close();

        sparkline(ui, frame_shell, perf, 56);
        {
            ui.open(.{ .id = .of("strip.stats"), .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 6 }, .scroll = .{ .horizontal = true, .vertical = false } });
            defer ui.close();
            {
                ui.open(.{ .layout = .{ .child_gap = 16, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                stat(ui, frame_shell, "zui frames", "{d}", .{perf.zui_frames}, palette.accent);
                stat(ui, frame_shell, "display frames", "{d}", .{perf.display_frames}, palette.text);
                const skipped = if (perf.display_frames == 0) 0 else 100 * (1 - @as(f64, @floatFromInt(perf.zui_frames)) / @as(f64, @floatFromInt(perf.display_frames)));
                stat(ui, frame_shell, "redrawn, not declared", "{d:.1}%", .{skipped}, palette.good);
                stat(ui, frame_shell, "this frame because", "{s}", .{latest.reason.describe()}, palette.warn);
                switch (perf.next_frame) {
                    .immediately => stat(ui, frame_shell, "next", "immediately", .{}, palette.bad),
                    .at => stat(ui, frame_shell, "next", "in {d:.2} s", .{perf.next_frame_seconds}, palette.warn),
                    .on_event => stat(ui, frame_shell, "next", "on input (sleeping)", .{}, palette.good),
                }
            }
            {
                ui.open(.{ .layout = .{ .child_gap = 16, .child_alignment = .{ .y = .center } } });
                defer ui.close();
                stat(ui, frame_shell, "beginFrame", "{d:.1} us", .{latest.begin_frame_us}, palette.text);
                stat(ui, frame_shell, "declare", "{d:.1} us", .{latest.declare_us}, palette.text);
                stat(ui, frame_shell, "layout+emit", "{d:.1} us", .{latest.end_frame_us}, palette.text);
                stat(ui, frame_shell, "sokol submit", "{d:.0} us", .{perf.submit_us}, palette.text);
                stat(ui, frame_shell, "elements", "{d}", .{latest.elements}, palette.text);
                stat(ui, frame_shell, "commands", "{d}", .{latest.commands}, palette.text);
                stat(ui, frame_shell, "texts measured", "{d}", .{latest.measure_calls}, if (latest.measure_calls == 0) palette.good else palette.warn);
                stat(ui, frame_shell, "fps", "{d:.0}", .{perf.display_fps}, palette.text);
            }
        }
    }

    fn inspector(app: *App, ui: *Ui, frame_shell: *const Shell) void {
        const palette = frame_shell.palette;
        const perf = &app.perf;
        const viewport = ui.viewport();
        app.inspector_position[0] = std.math.clamp(app.inspector_position[0], 0, @max(0, viewport[0] - 120));
        app.inspector_position[1] = std.math.clamp(app.inspector_position[1], 0, @max(0, viewport[1] - 40));
        ui.open(.{
            .id = ids.inspector,
            .interactive = true,
            .floating = .{ .attach_to = .root, .offset = app.inspector_position, .z = 500 },
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(360) } },
            .decoration = .{ .background = palette.surface, .border = .{ .color = palette.accent, .widths = .all(2) }, .corner_radius = .all(10) },
        });
        defer ui.close();
        const dragging = kit.drag(ui, ids.inspector_title, &app.inspector_position);
        {
            ui.open(.{
                .id = ids.inspector_title,
                .interactive = true,
                .cursor = if (dragging) .grabbing else .grab,
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(34) }, .padding = .symmetric(12, 0), .child_alignment = .{ .y = .center } },
                .decoration = .{ .background = palette.accent, .corner_radius = .{ .top_left = 8, .top_right = 8 } },
            });
            defer ui.close();
            frame_shell.labelColored(ui, .body, palette.on_accent, "Frame inspector");
            frame_shell.spacer(ui);
            ui.open(.{
                .id = ids.inspector_close,
                .interactive = true,
                .cursor = .pointer,
                .layout = .{ .padding = .symmetric(8, 2) },
                .decoration = .{ .background = if (ui.hovered(ids.inspector_close)) palette.on_accent.mix(palette.accent, 0.7) else null, .corner_radius = .all(4) },
            });
            frame_shell.labelColored(ui, .body, palette.on_accent, "x");
            ui.close();
            if (ui.clicked(ids.inspector_close)) app.inspector_open = false;
        }

        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = .all(12), .child_gap = 8 } });
        defer ui.close();

        const summary = perf.summarize();
        frame_shell.label(ui, .caption, "LAST 120 ZUI FRAMES (begin + declare + layout)");
        frame_shell.print(ui, .body, "min {d:.0}  avg {d:.0}  p95 {d:.0}  max {d:.0} us", .{ summary.minimum, summary.average, summary.p95, summary.maximum });
        sparkline(ui, frame_shell, perf, 70);

        const latest = perf.latest();
        const total = @max(latest.totalMicroseconds(), 0.001);
        frame_shell.label(ui, .caption, "WHERE THE LAST FRAME WENT");
        {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(14) } }, .decoration = .{ .corner_radius = .all(4) } });
            defer ui.close();
            const parts = [_]struct { f32, zui.Color }{
                .{ latest.begin_frame_us, kit.hueColor(0.55, 0.6, 0.9) },
                .{ latest.declare_us, kit.hueColor(0.3, 0.6, 0.85) },
                .{ latest.end_frame_us, kit.hueColor(0.08, 0.7, 0.95) },
            };
            for (parts) |part| ui.box(.{ .layout = .{ .sizing = .{ .width = .growWeighted(@max(part[0] / total, 0.0001)), .height = .grow } }, .decoration = .{ .background = part[1] } });
        }
        frame_shell.printColored(ui, .caption, palette.muted, "begin {d:.0}%  declare {d:.0}%  layout+emit {d:.0}%", .{ 100 * latest.begin_frame_us / total, 100 * latest.declare_us / total, 100 * latest.end_frame_us / total });

        frame_shell.divider(ui);
        frame_shell.label(ui, .caption, "LIMITS: WHAT THE FRAME NEEDED");
        const limit_rows = [_]struct { zui.Limit, []const u8 }{
            .{ .max_elements, "elements" },
            .{ .max_depth, "depth" },
            .{ .max_text_bytes, "text bytes" },
            .{ .max_render_commands, "commands" },
        };
        for (limit_rows) |row| {
            const needed = perf.diagnostics.needed.get(row[0]);
            const limit = limitValue(row[0]);
            const fraction = @as(f32, @floatFromInt(needed)) / @as(f32, @floatFromInt(limit));
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(110) } } });
            frame_shell.label(ui, .caption, row[1]);
            ui.close();
            frame_shell.meter(ui, fraction, if (fraction > 0.9) palette.bad else if (fraction > 0.6) palette.warn else palette.good, 8);
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(110) }, .child_alignment = .{ .x = .end } } });
            frame_shell.print(ui, .caption, "{d}/{d}", .{ needed, limit });
            ui.close();
            ui.close();
        }

        frame_shell.divider(ui);
        frame_shell.label(ui, .caption, "DIAGNOSTICS");
        const diagnostics = perf.diagnostics;
        if (diagnostics.ok()) {
            frame_shell.labelColored(ui, .body, palette.good, "ok: nothing dropped or refused");
        } else {
            frame_shell.printColored(ui, .body, palette.bad, "{d} limits exceeded, {d} duplicate ids", .{ diagnostics.exceeded.count(), diagnostics.duplicate_ids });
            if (diagnostics.refused_publishes != 0) frame_shell.printColored(ui, .body, palette.bad, "{d} publishes refused, first by .{s}", .{ diagnostics.refused_publishes, diagnostics.first_refusing_source });
        }
        frame_shell.print(ui, .caption, "texts measured since start: {d}", .{perf.measure_calls_total});
        frame_shell.print(ui, .caption, "producer wakes: {d}   dropped input: {d}", .{ perf.wakes, perf.dropped_input_events });
        frame_shell.print(ui, .caption, "layer overflows: {d}   glyph atlas overflows: {d}", .{ perf.layer_overflows, perf.glyph_overflows });

        frame_shell.divider(ui);
        frame_shell.label(ui, .caption, "ENVIRONMENT, AS THE HOST REPORTS IT");
        const environment = ui.environment();
        frame_shell.print(ui, .caption, "theme .{t}  contrast .{t}  reduced motion {}", .{ environment.theme, environment.contrast, environment.reduced_motion });
        frame_shell.print(ui, .caption, "text scale {d:.2}  window focused {}  zoom {d:.1}", .{ environment.text_scale, environment.window_focused, app.zoom });
    }
};

fn limitValue(limit: zui.Limit) u32 {
    return switch (limit) {
        inline else => |tag| @intCast(@field(Ui.limits, @tagName(tag))),
    };
}

fn stat(ui: *Ui, frame_shell: *const Shell, name: []const u8, comptime format: []const u8, arguments: anytype, color: zui.Color) void {
    ui.open(.{ .layout = .{ .child_gap = 5, .child_alignment = .{ .y = .center } } });
    frame_shell.label(ui, .tiny, name);
    frame_shell.printColored(ui, .caption, color, format, arguments);
    ui.close();
}

/// One bar per zui frame, scaled to the tallest: green under 0.5 ms, red over 4 ms.
fn sparkline(ui: *Ui, frame_shell: *const Shell, perf: *const Perf, height: f32) void {
    const palette = frame_shell.palette;
    var tallest: f32 = 50;
    for (perf.history) |sample| tallest = @max(tallest, sample.totalMicroseconds());
    ui.open(.{
        .layout = .{ .sizing = .{ .height = .fixed(height) }, .padding = .all(3), .child_gap = 1, .child_alignment = .{ .y = .end } },
        .decoration = .{ .background = palette.background, .corner_radius = .all(4) },
    });
    defer ui.close();
    for (0..Perf.history_length) |age| {
        const total = perf.sampleAt(age).totalMicroseconds();
        const color = if (total < 500) palette.good else if (total < 4000) palette.warn else palette.bad;
        ui.box(.{
            .layout = .{ .sizing = .{ .width = .fixed(2), .height = .fixed(@max(1, (height - 6) * total / tallest)) } },
            .decoration = .{ .background = color },
        });
    }
}
