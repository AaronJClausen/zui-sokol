const std = @import("std");
const kit = @import("../kit.zig");
const zui = kit.zui;
const Ui = kit.Ui;
const Shell = kit.Shell;
const Screen = kit.Screen;

const scroll_id: zui.Id = .of("welcome.scroll");
const card_width = 300;

const strip_legend = [_][2][]const u8{
    .{ "zui frames / display frames", "sokol redraws at every display refresh; zui declares a frame only when something changed. Leave the mouse still and watch the first number stop." },
    .{ "this frame because", "why the host asked zui for a new frame: input, a resize, ui.requestFrame(), a requestFrameAt() deadline, or a source a thread published into." },
    .{ "next", "what ui.nextFrame() told the host: immediately, at a deadline, or on input. 'on input' means the UI is asleep." },
    .{ "beginFrame / declare / layout+emit", "microseconds for applying input and swapping sources, for your declaration code, and for zui's layout and command emission." },
    .{ "texts measured", "calls into the text contract. Warm frames hit the whole-string cache, so this is 0 unless new text appeared." },
};

pub const Welcome = struct {
    pub fn declare(_: *Welcome, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        ui.open(.{ .id = scroll_id, .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 18 }, .scroll = .{} });
        defer ui.close();

        {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 24, .child_alignment = .{ .y = .center } } });
            defer ui.close();
            {
                ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 10 } });
                defer ui.close();
                heroTitle(ui, shell);
                shell.label(ui, .heading, "An immediate-mode layout library for Zig, drawn here by sokol.");
                shell.labelColored(ui, .body, palette.muted, "Every screen of this tour is declared from scratch whenever something changes, laid out by zui, and handed to a renderer as a flat list of commands. Nothing is retained but your own state. The strip at the bottom times every frame.");
                uptime(ui, shell);
            }
            legend(ui, shell);
        }

        shell.label(ui, .title, "Pick a screen");
        cardGrid(ui, shell);
    }
};

fn heroTitle(ui: *Ui, shell: *const Shell) void {
    ui.open(.{ .layout = .{ .child_gap = 4, .child_alignment = .{ .y = .end } } });
    defer ui.close();
    const letters = "zui";
    const seconds = shell.motionSeconds();
    for (letters, 0..) |letter, index| {
        const hue = 0.6 + @as(f32, @floatFromInt(index)) * 0.12 + seconds * 0.05;
        ui.text(&.{letter}, .{ .size = 96 * shell.text_scale, .font = 4, .color = kit.hueColor(hue, 0.55, 1) });
    }
    ui.open(.{ .layout = .{ .padding = .{ .left = 12, .bottom = 12 } } });
    shell.labelColored(ui, .heading, shell.palette.muted, "the tour");
    ui.close();
}

/// Ticks once a second: the frame after this one is scheduled with
/// `requestFrameAt`, and none is declared in between.
fn uptime(ui: *Ui, shell: *const Shell) void {
    const whole_seconds: u64 = @intFromFloat(@floor(shell.seconds));
    ui.requestFrameAt(ui.now().addSeconds(@as(f64, @floatFromInt(whole_seconds + 1)) - shell.seconds));
    ui.open(.{ .layout = .{ .child_gap = 10, .child_alignment = .{ .y = .center } } });
    defer ui.close();
    shell.chip(ui, "requestFrameAt", shell.palette.warn);
    shell.print(ui, .body, "open for {d:0>2}:{d:0>2}:{d:0>2}, ticking once a second without a frame in between", .{ whole_seconds / 3600, (whole_seconds / 60) % 60, whole_seconds % 60 });
}

fn legend(ui: *Ui, shell: *const Shell) void {
    shell.openCard(ui, "Reading the strip", .{ .width = .fixed(460) });
    defer ui.close();
    for (strip_legend) |entry| {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 3 } });
        shell.labelColored(ui, .body, shell.palette.accent, entry[0]);
        shell.label(ui, .caption, entry[1]);
        ui.close();
    }
}

/// zui has no wrapping rows, so the grid is rows of as many cards as fit
/// the width the stage had in the previous frame.
fn cardGrid(ui: *Ui, shell: *const Shell) void {
    const stage_width = if (ui.rectOf(scroll_id)) |rect| rect.width else ui.viewport()[0] - 280;
    const columns: usize = @max(1, @as(usize, @intFromFloat(stage_width / card_width)));
    const screens = std.enums.values(Screen)[1..];
    var row_start: usize = 0;
    while (row_start < screens.len) : (row_start += columns) {
        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 14 } });
        defer ui.close();
        for (row_start..row_start + columns) |index| {
            if (index < screens.len) card(ui, shell, screens[index]) else ui.box(.{ .layout = .{ .sizing = .{ .width = .grow } } });
        }
    }
}

fn card(ui: *Ui, shell: *const Shell, screen: Screen) void {
    const palette = shell.palette;
    const info = screen.info();
    const id: zui.Id = .indexed("welcome.card", @intFromEnum(screen));
    const state = ui.widgetState(id);
    const lit = state == .hovered or state == .pressed or ui.focused(id);
    const color = kit.hueColor(info.hue, 0.55, 0.95);
    if (ui.clicked(id)) shell.requested_screen.* = screen;

    ui.open(.{
        .id = id,
        .focusable = true,
        .cursor = .pointer,
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow, .height = .fixed(176) } },
        .decoration = .{
            .background = if (lit) palette.raised else palette.surface,
            .border = .{ .color = if (lit) color else palette.border, .widths = .all(if (lit) 2 else 1) },
            .corner_radius = .all(12),
        },
    });
    defer ui.close();
    ui.box(.{
        .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(if (state == .pressed) 14 else 8) } },
        .decoration = .{ .background = color, .corner_radius = .{ .top_left = 11, .top_right = 11 } },
    });
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(14), .child_gap = 8 } });
    defer ui.close();
    {
        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_alignment = .{ .y = .center } } });
        defer ui.close();
        shell.label(ui, .heading, info.title);
        shell.spacer(ui);
        shell.printColored(ui, .caption, palette.faint, "Ctrl+{d}", .{(@intFromEnum(screen) + 1) % 10});
    }
    shell.label(ui, .caption, info.tagline);
    shell.spacer(ui);
    var features_buffer: [128]u8 = undefined;
    var features: std.Io.Writer = .fixed(&features_buffer);
    for (info.features, 0..) |feature, index| features.print("{s}{s}", .{ if (index == 0) "" else "  /  ", feature }) catch {};
    shell.labelColored(ui, .caption, color, features.buffered());

    if (lit) {
        ui.open(.{
            .floating = .{ .anchor = .bottom_center, .attach_point = .top_center, .offset = .{ 0, -6 }, .z = 50 },
            .layout = .{ .padding = .symmetric(10, 5) },
            .decoration = .{ .background = color, .corner_radius = .all(6) },
        });
        shell.labelColored(ui, .caption, palette.on_accent, "click, Enter or Space to open");
        ui.close();
    }
}
