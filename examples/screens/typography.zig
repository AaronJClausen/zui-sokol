const std = @import("std");
const kit = @import("../kit.zig");
const zui = kit.zui;
const Ui = kit.Ui;
const Shell = kit.Shell;

const font_names = [_][]const u8{ "KC85/3", "KC85/4", "Z1013", "Amstrad CPC", "Commodore 64", "Oric Atmos" };
const handle_id: zui.Id = .of("type.handle");
const column_id: zui.Id = .of("type.column");
const marquee_id: zui.Id = .of("type.marquee");

const sample =
    \\Immediate mode means the UI is a function of your state.
    \\
    \\Every frame, zui walks what you declare, wraps text between words to fit its box, and hands back a flat list of rectangles, borders and lines of text. Drag the handle on the right edge to change this column's width and watch every line re-wrap; no line is cached between widths except by the measurements of its words.
;

const marquee_text = "  *** zui: layout in microseconds  ***  sources: threads publish, the UI never waits  ***  sokol draws it all with sokol_gl and sokol_debugtext  ***  ";

pub const Typography = struct {
    font: usize = 0,
    size: f32 = 18,
    letter_spacing: f32 = 0,
    line_height: f32 = 0,
    wrap: zui.TextWrap = .words,
    alignment: zui.Alignment = .start,
    column_width: f32 = 520,
    marquee_speed: f32 = 80,

    pub fn declare(self: *Typography, ui: *Ui, shell: *const Shell) void {
        ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 16 } });
        defer ui.close();
        self.controls(ui, shell);
        {
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 16 } });
            defer ui.close();
            self.marquee(ui, shell);
            self.column(ui, shell);
            self.specimens(ui, shell);
        }
    }

    fn style(self: *const Typography, shell: *const Shell) Ui.TextStyle {
        return .{
            .font = @intCast(self.font),
            .size = self.size * shell.text_scale,
            .letter_spacing = self.letter_spacing,
            .line_height = self.line_height,
            .wrap = self.wrap,
            .alignment = self.alignment,
            .color = shell.palette.text,
        };
    }

    fn controls(self: *Typography, ui: *Ui, shell: *const Shell) void {
        const widgets = shell.widgets;
        shell.openScrollingCard(ui, .of("type.controls"), "TextStyle", .{ .width = .fixed(340), .height = .grow });
        defer ui.close();
        widgets.labeledRow(ui, "font");
        _ = widgets.dropdown(ui, .of("type.font"), &self.font, &font_names, .{ .width = .grow });
        ui.close();
        sliderRow(ui, shell, .of("type.size"), "size", &self.size, 8, 72, 1, "{d:.0}");
        sliderRow(ui, shell, .of("type.spacing"), "letter spacing", &self.letter_spacing, -3, 16, 0.5, "{d:.1}");
        sliderRow(ui, shell, .of("type.line_height"), "line height", &self.line_height, 0, 96, 1, "{d:.0}");
        widgets.labeledRow(ui, "wrap");
        _ = widgets.dropdownEnum(ui, .of("type.wrap"), &self.wrap, .{ .width = .grow });
        ui.close();
        widgets.labeledRow(ui, "alignment");
        _ = widgets.dropdownEnum(ui, .of("type.alignment"), &self.alignment, .{ .width = .grow });
        ui.close();
        sliderRow(ui, shell, .of("type.marquee_speed"), "marquee speed", &self.marquee_speed, 0, 400, 10, "{d:.0}");
        shell.divider(ui);
        shell.label(ui, .caption, "line height 0 means whatever the text contract measures. Letter spacing goes through the measure key, so differently spaced runs never share a cache entry.");
        const measured = ui.measureText("zui", self.style(shell));
        shell.print(ui, .caption, "ui.measureText(\"zui\") = {d:.1} x {d:.1}", .{ measured[0], measured[1] });
        shell.print(ui, .caption, "glyph advance = size x {d:.2} + spacing", .{0.75});
        if (widgets.button(ui, .of("type.reset"), "Reset", .{})) self.* = .{};
    }

    fn column(self: *Typography, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        const dragging = ui.pressed(handle_id);
        if (dragging) if (ui.primaryPointer()) |pointer| if (ui.rectOf(column_id)) |rect| {
            self.column_width = std.math.clamp(pointer.position[0] - rect.x, 120, 1400);
        };
        ui.open(.{ .id = .of("type.column_viewport"), .layout = .{ .sizing = .{ .width = .grow, .height = .grow }, .child_alignment = .{ .y = .start } }, .scroll = .both });
        defer ui.close();
        ui.open(.{
            .id = column_id,
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(self.column_width) }, .padding = .all(16), .child_gap = 8 },
            .decoration = .{ .background = palette.surface, .border = .{ .color = palette.border, .widths = .all(1) }, .corner_radius = .{ .top_left = 10, .bottom_left = 10 } },
        });
        ui.text(sample, self.style(shell));
        ui.close();
        ui.open(.{
            .id = handle_id,
            .interactive = true,
            .cursor = .resize_horizontal,
            .layout = .{ .sizing = .{ .width = .fixed(14), .height = .fixed(if (ui.rectOf(column_id)) |rect| rect.height else 200) }, .child_alignment = .{ .x = .center, .y = .center } },
            .decoration = .{ .background = if (dragging) palette.accent else if (ui.hovered(handle_id)) palette.hovered else palette.raised, .corner_radius = .{ .top_right = 10, .bottom_right = 10 } },
        });
        ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(2), .height = .fixed(28) } }, .decoration = .{ .background = palette.muted } });
        ui.close();
        ui.open(.{ .layout = .{ .padding = .{ .left = 8 } } });
        shell.print(ui, .caption, "{d:.0} wide", .{self.column_width});
        ui.close();
    }

    /// A horizontal scroll container driven by `setScrollOffset` instead of
    /// the wheel. The text is declared twice, so wrapping the offset at one
    /// copy's measured width loops without a seam.
    fn marquee(self: *Typography, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        const marquee_style: Ui.TextStyle = .{ .size = 22, .font = 4, .color = palette.warn, .wrap = .none };
        const loop_width = ui.measureText(marquee_text, marquee_style)[0];
        if (!shell.reduced_motion and self.marquee_speed > 0 and loop_width > 0) {
            const offset: f32 = @floatCast(@mod(shell.seconds * self.marquee_speed, loop_width));
            ui.setScrollOffset(marquee_id, .{ offset, 0 });
            ui.requestFrame();
        }
        ui.open(.{
            .id = marquee_id,
            .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(44) }, .padding = .symmetric(0, 10) },
            .decoration = .{ .background = palette.sunken, .border = .{ .color = palette.warn, .widths = .{ .top = 2, .bottom = 2 } } },
            .scroll = .{ .horizontal = true, .vertical = false },
        });
        defer ui.close();
        ui.text(marquee_text, marquee_style);
        ui.text(marquee_text, marquee_style);
    }

    fn specimens(self: *Typography, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        shell.openScrollingCard(ui, .of("type.specimens"), "Six fonts, one text contract", .{ .width = .grow });
        defer ui.close();
        for (font_names, 0..) |name, index| {
            const id: zui.Id = .indexed("type.specimen", index);
            if (ui.clicked(id)) self.font = index;
            const selected = self.font == index;
            ui.open(.{
                .id = id,
                .interactive = true,
                .cursor = .pointer,
                .layout = .{ .sizing = .{ .width = .grow }, .padding = .symmetric(8, 4), .child_gap = 16, .child_alignment = .{ .y = .center } },
                .decoration = .{ .background = if (selected) palette.hovered else if (ui.hovered(id)) palette.raised else null, .corner_radius = .all(6) },
            });
            defer ui.close();
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(150) } } });
            shell.labelColored(ui, .caption, if (selected) palette.accent else palette.muted, name);
            ui.close();
            ui.text("The quick brown fox jumps over the lazy dog. 0123456789 {}[]<>!?", .{ .font = @intCast(index), .size = 16 * shell.text_scale, .color = kit.hueColor(@as(f32, @floatFromInt(index)) / 6, 0.45, 1) });
        }
    }
};

fn sliderRow(ui: *Ui, shell: *const Shell, id: zui.Id, name: []const u8, value: *f32, minimum: f64, maximum: f64, step: f64, comptime format: []const u8) void {
    shell.widgets.labeledRow(ui, name);
    defer ui.close();
    _ = shell.widgets.slider(ui, id, value, .{ .min = minimum, .max = maximum, .step = step });
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(40) }, .child_alignment = .{ .x = .end } } });
    shell.print(ui, .caption, format, .{value.*});
    ui.close();
}
