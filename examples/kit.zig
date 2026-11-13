//! What every screen of the tour shares: the `Ui` type, its sources, the
//! palettes, and the `Shell` each screen declares through.

const std = @import("std");
const zui_sokol = @import("zui_sokol");
pub const zui = zui_sokol.zui;
pub const zui_widgets = zui_sokol.zui_widgets;
pub const zui_reflect = zui_sokol.zui_reflect;
pub const zui_async = @import("zui_async");
pub const Perf = @import("perf.zig").Perf;
const mission = @import("screens/mission_control.zig");
const gallery = @import("screens/gallery.zig");

pub const Sources = struct {
    telemetry: mission.TelemetrySource = .{},
    mission_log: mission.LogSource = .{},
    launch: mission.LaunchTask = .{},
    tiles: gallery.TileLoads = .{},
    tile_outcomes: gallery.TileOutcomesSource = .{},
};

pub const Ui = zui.Context(zui_sokol.config(.{
    .Sources = Sources,
    .limits = .{
        .max_elements = 16384,
        .max_depth = 128,
        .max_text_bytes = 256 * 1024,
        .max_render_commands = 32768,
        .state_slots = 4096,
        .measure_cache_entries = 8192,
        .string_cache_entries = 4096,
    },
}));

pub const Widgets = zui_widgets.Widgets(Ui);
pub const TextStyle = Ui.TextStyle;

/// Atkinson Hyperlegible, from the Braille Institute, under the SIL Open
/// Font License (fonts/OFL.txt).
pub const body_font: u16 = zui_sokol.Text.bitmap_font_count;
pub const bold_font: u16 = body_font + 1;
/// One of sokol_debugtext's bitmap fonts, for code and logs: the Amstrad
/// CPC's, since the KC85 fonts draw `{` and `}` as umlauts.
pub const mono_font: u16 = 3;

/// Call once, before the first frame, so `body_font` and `bold_font` name
/// the fonts they say.
pub fn addFonts(text: *zui_sokol.Text) error{ InvalidFont, TooManyFonts }!void {
    const regular = try text.addTrueTypeFont(@embedFile("fonts/AtkinsonHyperlegible-Regular.ttf"));
    const bold = try text.addTrueTypeFont(@embedFile("fonts/AtkinsonHyperlegible-Bold.ttf"));
    std.debug.assert(regular == body_font and bold == bold_font);
}

pub const Screen = enum {
    welcome,
    layout_lab,
    box_storm,
    gallery,
    mission_control,
    window_manager,
    robot_workshop,
    pixel_pad,
    typography,
    light_and_depth,
    classic,

    pub const Info = struct {
        title: []const u8,
        tagline: []const u8,
        features: []const []const u8,
        hue: f32,
    };

    /// Ctrl+1 to Ctrl+9, then Ctrl+0, reach the first ten screens; the rest
    /// have no digit.
    pub fn shortcutDigit(screen: Screen) ?u8 {
        const index = @intFromEnum(screen);
        return if (index < 10) (index + 1) % 10 else null;
    }

    pub fn info(screen: Screen) Info {
        return switch (screen) {
            .welcome => .{ .title = "Welcome", .tagline = "A guided tour of zui, drawn by sokol", .features = &.{ "requestFrameAt", "floating", "focus" }, .hue = 0.62 },
            .layout_lab => .{ .title = "Layout Lab", .tagline = "Every sizing rule, alignment and gap, live", .features = &.{ "fit/grow/fixed/percent", "zui_reflect", "rectOf" }, .hue = 0.55 },
            .box_storm => .{ .title = "Box Storm", .tagline = "Thousands of elements, timed every frame", .features = &.{ "16k elements", "string cache", "depth 90" }, .hue = 0.0 },
            .gallery => .{ .title = "Infinite Gallery", .tagline = "10,000 tiles loaded only when seen", .features = &.{ "KeyedLoads", "virtual scroll", "cancellation" }, .hue = 0.8 },
            .mission_control => .{ .title = "Mission Control", .tagline = "Threads publish; the UI never waits", .features = &.{ "Latest", "Stream", "Task" }, .hue = 0.08 },
            .window_manager => .{ .title = "Window Manager", .tagline = "Floating layers, anchors and focus scopes", .features = &.{ "floating z", "anchors", "focus scope" }, .hue = 0.45 },
            .robot_workshop => .{ .title = "Robot Workshop", .tagline = "An editor generated from a struct", .features = &.{ "zui_reflect", "widgets", "environment" }, .hue = 0.3 },
            .pixel_pad => .{ .title = "Pixel Pad", .tagline = "Pointer, keys, chords and typed text", .features = &.{ "pointerLocal", "chords", "keyEvents" }, .hue = 0.92 },
            .typography => .{ .title = "Typography", .tagline = "Six bitmap fonts, wrapping and spacing", .features = &.{ "wrap modes", "letter spacing", "zoom" }, .hue = 0.15 },
            .light_and_depth => .{ .title = "Light & Depth", .tagline = "Gradients in OKLab, shadows and glow", .features = &.{ "Gradient", "Shadow", "glow" }, .hue = 0.75 },
            .classic => .{ .title = "Classic", .tagline = "The showcase every zui backend shares", .features = &.{ "shared demo", "compare renderers" }, .hue = 0.7 },
        };
    }
};

/// Where a dragged handle grabbed what it moves, kept under the handle's id.
const DragGrip = struct {
    active: bool = false,
    grab_offset: [2]f32 = .{ 0, 0 },
};

/// Moves `position` with the pointer while `handle` is pressed, keeping the
/// point that was grabbed under the pointer. Returns whether it is dragging.
pub fn drag(ui: *Ui, handle: zui.Id, position: *[2]f32) bool {
    const grip = ui.state(handle, DragGrip);
    if (!ui.pressed(handle)) {
        grip.active = false;
        return false;
    }
    const pointer = ui.primaryPointer() orelse return false;
    if (!grip.active) {
        grip.active = true;
        grip.grab_offset = .{ pointer.position[0] - position[0], pointer.position[1] - position[1] };
    }
    position.* = .{ pointer.position[0] - grip.grab_offset[0], pointer.position[1] - grip.grab_offset[1] };
    return true;
}

pub const Palette = struct {
    background: zui.Color,
    surface: zui.Color,
    sunken: zui.Color,
    raised: zui.Color,
    hovered: zui.Color,
    border: zui.Color,
    text: zui.Color,
    muted: zui.Color,
    faint: zui.Color,
    accent: zui.Color,
    on_accent: zui.Color,
    good: zui.Color,
    warn: zui.Color,
    bad: zui.Color,
    focus: zui.Color,
    overlay: zui.Color,

    pub const dark: Palette = .{
        .background = .rgb(0x111118),
        .surface = .rgb(0x1a1a24),
        .sunken = .rgb(0x0c0c12),
        .raised = .rgb(0x232332),
        .hovered = .rgb(0x2f2f44),
        .border = .rgb(0x33334a),
        .text = .rgb(0xeaeaf4),
        .muted = .rgb(0x9a9ab4),
        .faint = .rgb(0x5a5a74),
        .accent = .rgb(0x6c8cff),
        .on_accent = .rgb(0x0b0b14),
        .good = .rgb(0x4ade80),
        .warn = .rgb(0xfbbf24),
        .bad = .rgb(0xf87171),
        .focus = .rgb(0xffc65c),
        .overlay = .rgba(0x000000aa),
    };

    pub const light: Palette = .{
        .background = .rgb(0xeef0f6),
        .surface = .rgb(0xffffff),
        .sunken = .rgb(0xdde1ec),
        .raised = .rgb(0xf6f7fb),
        .hovered = .rgb(0xe2e7f8),
        .border = .rgb(0xc4c9d8),
        .text = .rgb(0x1b1d2a),
        .muted = .rgb(0x5b6077),
        .faint = .rgb(0x9aa0b4),
        .accent = .rgb(0x3355dd),
        .on_accent = .rgb(0xffffff),
        .good = .rgb(0x168a4a),
        .warn = .rgb(0xb7790b),
        .bad = .rgb(0xc93030),
        .focus = .rgb(0xe08a00),
        .overlay = .rgba(0x1b1d2a66),
    };

    pub fn forEnvironment(environment: *const zui.Environment) Palette {
        var palette = if (environment.theme == .dark) dark else light;
        if (environment.contrast == .high) {
            palette.border = palette.text;
            palette.muted = palette.text;
            palette.faint = palette.muted.mix(palette.text, 0.5);
        }
        return palette;
    }
};

fn widgetTheme(palette: Palette, text_scale: f32) Widgets.Theme {
    return .{
        .text = .{ .size = 16 * text_scale, .color = palette.text, .font = body_font },
        .muted_text_color = palette.muted,
        .disabled_text_color = palette.faint,
        .control = .init(.{
            .idle = palette.raised,
            .hovered = palette.hovered,
            .pressed = palette.accent,
            .focused = palette.raised,
            .disabled = palette.sunken,
        }),
        .field_background = palette.sunken,
        .border_color = palette.border,
        .accent = palette.accent,
        .check_mark = palette.on_accent,
        .track = palette.border,
        .thumb = palette.text,
        .caret = palette.text,
        .focus_ring = palette.focus,
        .popup_background = palette.surface,
        .option_highlight = palette.hovered,
        .selected_option = palette.accent.mix(palette.surface, 0.6),
        .corner_radius = 5,
        .control_height = @round(30 * text_scale),
        .label_width = 150,
    };
}

pub const Tone = enum {
    hero,
    title,
    heading,
    body,
    caption,
    tiny,

    fn size(tone: Tone) f32 {
        return switch (tone) {
            .hero => 88,
            .title => 34,
            .heading => 22,
            .body => 16,
            .caption => 13,
            .tiny => 11,
        };
    }
};

/// Everything a screen needs besides its own state, rebuilt each frame
/// from the environment the host last reported.
pub const Shell = struct {
    io: std.Io,
    palette: Palette,
    widgets: Widgets,
    text_scale: f32,
    reduced_motion: bool,
    /// Seconds since the tour started, from the frame record's clock.
    seconds: f64,
    perf: *const Perf,
    sources: *Sources,
    waker: zui.Waker,
    environment_changes: *EnvironmentQueue,
    requested_screen: *?Screen,

    pub fn init(ui: *const Ui, io: std.Io, seconds: f64, perf: *const Perf, sources: *Sources, waker: zui.Waker, environment_changes: *EnvironmentQueue, requested_screen: *?Screen) Shell {
        const environment = ui.environment();
        const palette: Palette = .forEnvironment(environment);
        const text_scale = std.math.clamp(environment.text_scale, 0.5, 2);
        const theme = widgetTheme(palette, text_scale);
        return .{
            .io = io,
            .palette = palette,
            .widgets = .{ .theme = theme, .dark_theme = theme },
            .text_scale = text_scale,
            .reduced_motion = environment.reduced_motion,
            .seconds = seconds,
            .perf = perf,
            .sources = sources,
            .waker = waker,
            .environment_changes = environment_changes,
            .requested_screen = requested_screen,
        };
    }

    pub fn style(self: *const Shell, tone: Tone, color: zui.Color) TextStyle {
        return .{
            .size = tone.size() * self.text_scale,
            .color = color,
            .font = switch (tone) {
                .hero, .title, .heading => bold_font,
                .body, .caption, .tiny => body_font,
            },
            .letter_spacing = if (tone == .hero) 2 else 0,
        };
    }

    pub fn defaultColor(self: *const Shell, tone: Tone) zui.Color {
        return switch (tone) {
            .caption, .tiny => self.palette.muted,
            else => self.palette.text,
        };
    }

    pub fn label(self: *const Shell, ui: *Ui, tone: Tone, content: []const u8) void {
        ui.text(content, self.style(tone, self.defaultColor(tone)));
    }

    pub fn labelColored(self: *const Shell, ui: *Ui, tone: Tone, color: zui.Color, content: []const u8) void {
        ui.text(content, self.style(tone, color));
    }

    /// The formatted text is copied by `ui.text`, so the stack buffer may die here.
    pub fn print(self: *const Shell, ui: *Ui, tone: Tone, comptime format: []const u8, arguments: anytype) void {
        self.printColored(ui, tone, self.defaultColor(tone), format, arguments);
    }

    pub fn printColored(self: *const Shell, ui: *Ui, tone: Tone, color: zui.Color, comptime format: []const u8, arguments: anytype) void {
        var buffer: [512]u8 = undefined;
        ui.text(std.fmt.bufPrint(&buffer, format, arguments) catch format, self.style(tone, color));
    }

    /// Opens a titled panel; declare its contents, then `ui.close()`.
    pub fn openCard(self: *const Shell, ui: *Ui, title: []const u8, sizing: zui.Sizing2) void {
        self.openCardWith(ui, .{ .layout = .{ .sizing = sizing } }, title);
    }

    /// `openCard` that scrolls its contents vertically when the window is
    /// too short, instead of making the whole screen taller.
    pub fn openScrollingCard(self: *const Shell, ui: *Ui, id: zui.Id, title: []const u8, sizing: zui.Sizing2) void {
        self.openCardWith(ui, .{ .id = id, .layout = .{ .sizing = sizing }, .scroll = .{} }, title);
    }

    fn openCardWith(self: *const Shell, ui: *Ui, element: zui.Element, title: []const u8) void {
        var card = element;
        card.layout = .{ .direction = .top_to_bottom, .sizing = element.layout.?.sizing, .padding = .all(14), .child_gap = 10 };
        card.decoration = .{ .background = self.palette.surface, .border = .{ .color = self.palette.border, .widths = .all(1) }, .corner_radius = .all(10) };
        ui.open(card);
        if (title.len != 0) self.label(ui, .heading, title);
    }

    pub fn chip(self: *const Shell, ui: *Ui, content: []const u8, color: zui.Color) void {
        ui.open(.{
            .layout = .{ .padding = .symmetric(8, 3) },
            .decoration = .{ .background = color.mix(self.palette.surface, 0.8), .border = .{ .color = color, .widths = .all(1) }, .corner_radius = .all(10) },
        });
        self.labelColored(ui, .caption, color, content);
        ui.close();
    }

    pub fn spacer(_: *const Shell, ui: *Ui) void {
        ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .grow } } });
    }

    pub fn divider(self: *const Shell, ui: *Ui) void {
        ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(1) } }, .decoration = .{ .background = self.palette.border } });
    }

    pub fn meter(self: *const Shell, ui: *Ui, fraction: f32, color: zui.Color, height: f32) void {
        const clamped = std.math.clamp(fraction, 0, 1);
        ui.open(.{
            .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(height) } },
            .decoration = .{ .background = self.palette.sunken, .corner_radius = .all(height / 2) },
        });
        if (clamped > 0) ui.box(.{
            .layout = .{ .sizing = .{ .width = .percent(clamped), .height = .grow } },
            .decoration = .{ .background = color, .corner_radius = .all(height / 2) },
        });
        ui.close();
    }

    /// Asks the next frame for an environment change, as an OS would
    /// report one; widgets and the palette follow it.
    pub fn changeEnvironment(self: *const Shell, change: zui.EnvironmentChange) void {
        self.environment_changes.push(change);
    }

    /// 0 under reduced motion, so animations hold still.
    pub fn motionSeconds(self: *const Shell) f32 {
        return if (self.reduced_motion) 0 else @floatCast(self.seconds);
    }
};

/// Environment changes the application makes up, for the host to append to
/// the next frame record's events as if the OS had reported them.
pub const EnvironmentQueue = struct {
    changes: [16]zui.EnvironmentChange = undefined,
    count: usize = 0,

    pub fn push(self: *EnvironmentQueue, change: zui.EnvironmentChange) void {
        if (self.count == self.changes.len) return;
        self.changes[self.count] = change;
        self.count += 1;
    }

    pub fn drain(self: *EnvironmentQueue) []const zui.EnvironmentChange {
        const pending = self.changes[0..self.count];
        self.count = 0;
        return pending;
    }
};

/// A color around the hue wheel, for things that should look different
/// from their neighbours. `hue` wraps at 1.
pub fn hueColor(hue: f32, saturation: f32, value: f32) zui.Color {
    const wrapped = hue - @floor(hue);
    const sector = wrapped * 6;
    const chroma = value * saturation;
    const secondary = chroma * (1 - @abs(@mod(sector, 2) - 1));
    const lightness_offset = value - chroma;
    const rgb: [3]f32 = switch (@as(u3, @intFromFloat(@min(sector, 5.999)))) {
        0 => .{ chroma, secondary, 0 },
        1 => .{ secondary, chroma, 0 },
        2 => .{ 0, chroma, secondary },
        3 => .{ 0, secondary, chroma },
        4 => .{ secondary, 0, chroma },
        else => .{ chroma, 0, secondary },
    };
    return .{
        .r = @intFromFloat((rgb[0] + lightness_offset) * 255),
        .g = @intFromFloat((rgb[1] + lightness_offset) * 255),
        .b = @intFromFloat((rgb[2] + lightness_offset) * 255),
    };
}

pub fn instantNow(io: std.Io) zui.Instant {
    return .fromTimestamp(std.Io.Timestamp.now(io, .awake));
}
