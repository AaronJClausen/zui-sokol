const std = @import("std");
const kit = @import("../kit.zig");
const zui = kit.zui;
const Ui = kit.Ui;
const Shell = kit.Shell;
const Material = @import("zui_sokol").Material;

const patterns = std.enums.values(Material.Pattern);

pub const Materials = struct {
    pattern: Material.Pattern = .aurora,
    first_hue: f32 = 0.6,
    second_hue: f32 = 0.42,
    turns_per_second: f32 = 0.08,
    scale: f32 = 48,
    corner_radius: f32 = 20,
    animate: bool = true,
    show_fallback: bool = false,

    pub fn declare(self: *Materials, ui: *Ui, shell: *const Shell) void {
        const moving = self.animate and !shell.reduced_motion;
        if (moving) ui.requestFrame();
        const seconds: f32 = if (moving) shell.motionSeconds() else 0;

        ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 16 } });
        defer ui.close();
        self.controls(ui, shell);
        {
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 16 } });
            defer ui.close();
            self.specimen(ui, shell, seconds);
            {
                ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(212) }, .child_gap = 16 } });
                defer ui.close();
                self.everyPattern(ui, shell, seconds);
                self.drawnAndLowered(ui, shell, seconds);
                self.underAndOver(ui, shell, seconds);
            }
        }
    }

    fn material(self: *const Materials, pattern: Material.Pattern, seconds: f32) Material {
        return .{
            .pattern = pattern,
            .first = kit.hueColor(self.first_hue, 0.75, 0.35),
            .second = kit.hueColor(self.second_hue, 0.7, 0.95),
            .phase = seconds * self.turns_per_second,
            .scale = self.scale,
        };
    }

    /// What a renderer without `.material` draws: the first color.
    fn fallback(self: *const Materials) zui.Color {
        return kit.hueColor(self.first_hue, 0.75, 0.35);
    }

    fn decoration(self: *const Materials, pattern: Material.Pattern, seconds: f32, corner_radius: f32) Ui.Decoration {
        return .{
            .background = self.fallback(),
            .material = if (self.show_fallback) null else self.material(pattern, seconds),
            .corner_radius = .all(corner_radius),
        };
    }

    fn controls(self: *Materials, ui: *Ui, shell: *const Shell) void {
        const widgets = shell.widgets;
        shell.openScrollingCard(ui, .of("materials.controls"), "zui_sokol.Material", .{ .width = .fixed(340), .height = .grow });
        defer ui.close();
        shell.print(ui, .body, "pattern: .{t}", .{self.pattern});
        {
            ui.open(.{ .layout = .{ .child_gap = 8 } });
            defer ui.close();
            for (patterns, 0..) |pattern, index| {
                if (widgets.button(ui, .indexed("materials.pattern", index), @tagName(pattern), .{})) self.pattern = pattern;
            }
        }
        shell.sliderRow(ui, .of("materials.first"), "first hue", &self.first_hue, 0, 1, 0.01, "{d:.2}");
        shell.sliderRow(ui, .of("materials.second"), "second hue", &self.second_hue, 0, 1, 0.01, "{d:.2}");
        shell.sliderRow(ui, .of("materials.speed"), "turns / s", &self.turns_per_second, 0, 0.5, 0.01, "{d:.2}");
        shell.sliderRow(ui, .of("materials.scale"), "wave", &self.scale, 8, 160, 1, "{d:.0}");
        shell.sliderRow(ui, .of("materials.radius"), "corner radius", &self.corner_radius, 0, 80, 1, "{d:.0}");
        _ = widgets.checkbox(ui, .of("materials.animate"), "turn the phase", &self.animate, .{});
        _ = widgets.checkbox(ui, .of("materials.fallback"), "draw the fallback: material = null", &self.show_fallback, .{});
        shell.divider(ui);
        shell.label(ui, .caption, "A material is the renderer's own shader, drawn in place of the background, in the element's corners. zui_sokol's patterns move with their phase, which the application turns. A renderer that does not declare .material draws the background instead, so the background is the material's fallback.");
        if (widgets.button(ui, .of("materials.reset"), "Reset", .{})) self.* = .{};
    }

    fn specimen(self: *const Materials, ui: *Ui, shell: *const Shell, seconds: f32) void {
        const palette = shell.palette;
        const material_now = self.material(self.pattern, seconds);
        ui.open(.{
            .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(24), .child_gap = 24, .child_alignment = .{ .x = .center, .y = .center } },
            .decoration = .{ .background = palette.sunken, .corner_radius = .all(10) },
            .clip = .both,
        });
        defer ui.close();
        ui.open(.{
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(380), .height = .fixed(200) }, .padding = .all(24), .child_gap = 6, .child_alignment = .{ .y = .end } },
            .decoration = self.decoration(self.pattern, seconds, self.corner_radius),
        });
        ui.text("Materials", shell.style(.title, .rgb(0xffffff)));
        ui.text(if (self.show_fallback) "the fallback background, as lowered" else "drawn by zui_sokol's shader", shell.style(.caption, .rgb(0xffffff)));
        ui.close();

        var code_buffer: [400]u8 = undefined;
        const code = std.fmt.bufPrint(&code_buffer,
            \\.decoration = .{{
            \\    .background = .rgb(0x{x:0>6}),
            \\    .material = .{{
            \\        .pattern = .{t},
            \\        .first = .rgb(0x{x:0>6}),
            \\        .second = .rgb(0x{x:0>6}),
            \\        .phase = {d:.2}, .scale = {d:.0},
            \\    }},
            \\    .corner_radius = .all({d:.0}),
            \\}},
        , .{
            rgbOf(self.fallback()),      material_now.pattern,
            rgbOf(material_now.first),   rgbOf(material_now.second),
            @mod(material_now.phase, 1), material_now.scale,
            self.corner_radius,
        }) catch "";
        ui.text(code, .{ .font = kit.mono_font, .size = 13 * shell.text_scale, .color = palette.muted, .wrap = .newlines });
    }

    fn everyPattern(self: *const Materials, ui: *Ui, shell: *const Shell, seconds: f32) void {
        shell.openCard(ui, "Patterns", .{ .width = .grow, .height = .grow });
        defer ui.close();
        shell.label(ui, .caption, "Each of the shader's patterns, in the same two colors.");
        ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 10 } });
        defer ui.close();
        for (patterns) |pattern| {
            ui.open(.{
                .layout = .{ .sizing = .grow_both, .padding = .all(8), .child_alignment = .{ .y = .end } },
                .decoration = self.decoration(pattern, seconds, 8),
            });
            shell.labelColored(ui, .caption, .rgb(0xffffff), @tagName(pattern));
            ui.close();
        }
    }

    fn drawnAndLowered(self: *const Materials, ui: *Ui, shell: *const Shell, seconds: f32) void {
        shell.openCard(ui, "Drawn and lowered", .{ .width = .grow, .height = .grow });
        defer ui.close();
        shell.label(ui, .caption, "The same decoration, and what a renderer without .material draws.");
        ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 10 } });
        defer ui.close();
        const sides = [_]struct { []const u8, ?Material }{
            .{ "material", self.material(self.pattern, seconds) },
            .{ "its fallback", null },
        };
        for (sides) |side| {
            const name, const drawn = side;
            ui.open(.{
                .layout = .{ .sizing = .grow_both, .padding = .all(8), .child_alignment = .{ .y = .end } },
                .decoration = .{ .background = self.fallback(), .material = drawn, .corner_radius = .all(8) },
            });
            shell.labelColored(ui, .caption, .rgb(0xffffff), name);
            ui.close();
        }
    }

    /// The shadow is drawn beneath the material, and the border and
    /// children over it.
    fn underAndOver(self: *const Materials, ui: *Ui, shell: *const Shell, seconds: f32) void {
        const palette = shell.palette;
        shell.openCard(ui, "Under and over", .{ .width = .grow, .height = .grow });
        defer ui.close();
        shell.label(ui, .caption, "A shadow beneath the material, a border and a button over it.");
        ui.open(.{ .layout = .{ .sizing = .grow_both, .padding = .all(12), .child_alignment = .{ .x = .center, .y = .center } } });
        defer ui.close();
        var decorated = self.decoration(self.pattern, seconds, 14);
        decorated.border = .{ .color = palette.text, .widths = .all(2) };
        ui.open(.{
            .layout = .{ .sizing = .{ .width = .fixed(200), .height = .fixed(100) }, .child_alignment = .{ .x = .center, .y = .center } },
            .decoration = decorated,
            .effects = &.{ .shadow = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = 160 }, .offset = .{ 0, 10 }, .blur = 22 } },
        });
        _ = shell.widgets.button(ui, .of("materials.over"), "over the material", .{});
        ui.close();
    }
};

fn rgbOf(color: zui.Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}
