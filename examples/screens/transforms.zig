const std = @import("std");
const kit = @import("../kit.zig");
const zui = kit.zui;
const Ui = kit.Ui;
const Shell = kit.Shell;

const tile_angles_degrees = [_]f32{ -18, 8, 30 };
const bitmap_font_names = [_][]const u8{ "KC85/3", "KC85/4", "Z1013", "CPC", "C64", "Oric" };

pub const Transforms = struct {
    translation: [2]f32 = .{ 0, 0 },
    scale: [2]f32 = .{ 1, 1 },
    rotation_degrees: f32 = -8,
    origin: [2]f32 = .{ 0.5, 0.5 },
    animate: bool = true,
    card_presses: u32 = 0,
    tile_presses: [tile_angles_degrees.len]u32 = @splat(0),

    pub fn declare(self: *Transforms, ui: *Ui, shell: *const Shell) void {
        const moving = self.animate and !shell.reduced_motion;
        if (moving) ui.requestFrame();
        const seconds: f32 = if (moving) shell.motionSeconds() else 0;

        ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 16 } });
        defer ui.close();
        self.controls(ui, shell);
        {
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 16 } });
            defer ui.close();
            self.specimen(ui, shell);
            {
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(232) }, .child_gap = 16 } });
                defer ui.close();
                self.tiles(ui, shell, seconds);
                dial(ui, shell, seconds);
                turnedBitmapText(ui, shell, seconds);
            }
        }
    }

    fn transform(self: *const Transforms) zui.Transform {
        return .{ .translation = self.translation, .scale = self.scale, .rotation = std.math.degreesToRadians(self.rotation_degrees), .origin = self.origin };
    }

    fn controls(self: *Transforms, ui: *Ui, shell: *const Shell) void {
        const widgets = shell.widgets;
        shell.openScrollingCard(ui, .of("transforms.controls"), "zui.Transform", .{ .width = .fixed(340), .height = .grow });
        defer ui.close();
        shell.sliderRow(ui, .of("transforms.move_x"), "move x", &self.translation[0], -160, 160, 1, "{d:.0}");
        shell.sliderRow(ui, .of("transforms.move_y"), "move y", &self.translation[1], -80, 80, 1, "{d:.0}");
        shell.sliderRow(ui, .of("transforms.scale_x"), "scale x", &self.scale[0], 0, 2, 0.05, "{d:.2}");
        shell.sliderRow(ui, .of("transforms.scale_y"), "scale y", &self.scale[1], 0, 2, 0.05, "{d:.2}");
        shell.sliderRow(ui, .of("transforms.turn"), "turn", &self.rotation_degrees, -180, 180, 1, "{d:.0}");
        shell.sliderRow(ui, .of("transforms.origin_x"), "origin x", &self.origin[0], 0, 1, 0.05, "{d:.2}");
        shell.sliderRow(ui, .of("transforms.origin_y"), "origin y", &self.origin[1], 0, 1, 0.05, "{d:.2}");
        _ = widgets.checkbox(ui, .of("transforms.animate"), "sway the tiles, run the clock, turn the text", &self.animate, .{});
        shell.divider(ui);
        shell.label(ui, .caption, "A transform moves an element and its subtree as painted: layout, rectOf and the neighbours stay where they were, and a pointer hits it where it is drawn. The renderer declares .transform; one that does not draws and hits the element as laid out.");
        shell.label(ui, .caption, "Scale to 0 and the card is neither drawn nor hit.");
        if (widgets.button(ui, .of("transforms.reset"), "Reset", .{})) {
            const presses = self.card_presses;
            const tile_presses = self.tile_presses;
            self.* = .{ .card_presses = presses, .tile_presses = tile_presses };
        }
    }

    fn specimen(self: *Transforms, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        const transform_now = self.transform();
        ui.open(.{
            .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(24), .child_gap = 20, .child_alignment = .{ .x = .center, .y = .center } },
            .decoration = .{ .background = palette.sunken, .corner_radius = .all(10) },
            .clip = .both,
        });
        defer ui.close();
        {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(320), .height = .fixed(170) } }, .decoration = .{ .border = .{ .color = palette.border, .widths = .all(1) }, .corner_radius = .all(14) } });
            defer ui.close();
            ui.open(.{
                .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(20), .child_gap = 8 },
                .decoration = .{ .corner_radius = .all(14) },
                .effects = &.{
                    .gradient = .{ .from = kit.hueColor(0.58, 0.7, 0.9), .to = kit.hueColor(0.8, 0.7, 0.85), .angle = std.math.pi / 4.0 },
                    .shadow = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 150 }, .offset = .{ 0, 10 }, .blur = 24 },
                    .transform = transform_now,
                },
            });
            defer ui.close();
            ui.text("Turned, not laid out again", shell.style(.title, .rgb(0xffffff)));
            ui.text("the outline is where layout put the card", shell.style(.caption, .rgb(0xffffff)));
            shell.spacer(ui);
            if (shell.widgets.button(ui, .of("transforms.card_button"), "Press me where I am drawn", .{})) self.card_presses += 1;
        }
        shell.print(ui, .caption, "pressed {d} times", .{self.card_presses});

        var code_buffer: [320]u8 = undefined;
        const code = std.fmt.bufPrint(&code_buffer,
            \\.effects = &.{{ .transform = .{{
            \\    .translation = .{{ {d:.0}, {d:.0} }},
            \\    .scale = .{{ {d:.2}, {d:.2} }},
            \\    .rotation = {d:.3},
            \\    .origin = .{{ {d:.2}, {d:.2} }},
            \\}} }},
        , .{
            transform_now.translation[0], transform_now.translation[1],
            transform_now.scale[0],       transform_now.scale[1],
            transform_now.rotation,       transform_now.origin[0],
            transform_now.origin[1],
        }) catch "";
        ui.text(code, .{ .font = kit.mono_font, .size = 13 * shell.text_scale, .color = palette.muted, .wrap = .newlines });
    }

    fn tiles(self: *Transforms, ui: *Ui, shell: *const Shell, seconds: f32) void {
        const palette = shell.palette;
        shell.openCard(ui, "Hit where drawn", .{ .width = .grow, .height = .grow });
        defer ui.close();
        shell.label(ui, .caption, "Each tile is a button, turned; hover and press its corners.");
        ui.open(.{ .layout = .{ .sizing = .grow_both, .padding = .symmetric(8, 4), .child_gap = 22, .child_alignment = .{ .x = .center, .y = .center } } });
        defer ui.close();
        for (tile_angles_degrees, &self.tile_presses, 0..) |angle_degrees, *presses, index| {
            const id: zui.Id = .indexed("transforms.tile", index);
            const sway = 10 * @sin(seconds * 1.3 + @as(f32, @floatFromInt(index)));
            const hovered = ui.hovered(id);
            if (ui.clicked(id)) presses.* += 1;
            const color = kit.hueColor(0.08 + 0.3 * @as(f32, @floatFromInt(index)), 0.6, 0.9);
            ui.open(.{
                .id = id,
                .interactive = true,
                .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(78), .height = .fixed(78) }, .child_alignment = .{ .x = .center, .y = .center } },
                .decoration = .{ .background = if (hovered) color else color.mix(palette.surface, 0.35), .border = .{ .color = if (hovered) palette.text else color, .widths = .all(2) }, .corner_radius = .all(10) },
                .effects = &.{ .transform = .{ .rotation = std.math.degreesToRadians(angle_degrees + sway), .scale = @splat(if (ui.pressed(id)) 0.92 else 1) } },
            });
            shell.print(ui, .heading, "{d}", .{presses.*});
            ui.close();
        }
    }
};

/// Each hand is laid out pointing up from the dial's center and turned
/// about its foot.
fn dial(ui: *Ui, shell: *const Shell, seconds: f32) void {
    const palette = shell.palette;
    const face = 150;
    shell.openCard(ui, "Origin", .{ .width = .grow, .height = .grow });
    defer ui.close();
    shell.label(ui, .caption, "Hands turned about their foot: origin .{ 0.5, 1 }.");
    ui.open(.{ .layout = .{ .sizing = .grow_both, .child_alignment = .{ .x = .center, .y = .center } } });
    defer ui.close();
    ui.open(.{
        .layout = .{ .sizing = .{ .width = .fixed(face), .height = .fixed(face) }, .child_alignment = .{ .x = .center } },
        .decoration = .{ .background = palette.raised, .border = .{ .color = palette.border, .widths = .all(2) }, .corner_radius = .all(face / 2) },
    });
    defer ui.close();
    const hands = [_]struct { length: f32, width: f32, turns: f32, color: zui.Color }{
        .{ .length = 40, .width = 6, .turns = seconds / 600, .color = palette.text },
        .{ .length = 58, .width = 4, .turns = seconds / 60, .color = palette.text },
        .{ .length = 64, .width = 2, .turns = @floor(seconds) / 60, .color = palette.accent },
    };
    for (hands) |hand| {
        ui.box(.{
            .floating = .{ .offset = .{ (face - hand.width) / 2, face / 2 - hand.length } },
            .layout = .{ .sizing = .{ .width = .fixed(hand.width), .height = .fixed(hand.length) } },
            .decoration = .{ .background = hand.color, .corner_radius = .all(hand.width / 2) },
            .effects = &.{ .transform = .{ .rotation = hand.turns * 2 * std.math.pi, .origin = .{ 0.5, 1 } } },
        });
    }
}

fn turnedBitmapText(ui: *Ui, shell: *const Shell, seconds: f32) void {
    shell.openCard(ui, "Bitmap text, turned", .{ .width = .grow, .height = .grow });
    defer ui.close();
    shell.label(ui, .caption, "The six bitmap fonts, each turned a little further.");
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .symmetric(16, 4), .child_gap = 6, .child_alignment = .{ .x = .center } } });
    defer ui.close();
    for (bitmap_font_names, 0..) |name, font| {
        const step: f32 = @floatFromInt(font);
        ui.open(.{ .effects = &.{ .transform = .{ .rotation = std.math.degreesToRadians((step - 2.5) * 4 + 6 * @sin(seconds + step)) } } });
        ui.text(name, .{ .font = @intCast(font), .size = 16 * shell.text_scale, .color = kit.hueColor(step / bitmap_font_names.len, 0.45, 1) });
        ui.close();
    }
}
