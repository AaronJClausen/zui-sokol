const std = @import("std");
const kit = @import("../kit.zig");
const zui = kit.zui;
const Ui = kit.Ui;
const Shell = kit.Shell;

const elevation_levels = 5;
const srgb_steps = 24;
const glow_names = [_][]const u8{ "Online", "Syncing", "Recording" };

pub const LightAndDepth = struct {
    offset: [2]f32 = .{ 0, 14 },
    blur: f32 = 32,
    spread: f32 = 0,
    shadow_opacity: f32 = 0.7,
    glow: bool = false,
    corner_radius: f32 = 20,
    angle_degrees: f32 = 30,
    from_hue: f32 = 0.92,
    to_hue: f32 = 0.58,
    animate: bool = true,

    pub fn declare(self: *LightAndDepth, ui: *Ui, shell: *const Shell) void {
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
                elevation(ui, shell);
                glows(ui, shell, seconds);
                self.blends(ui, shell);
            }
        }
    }

    fn gradient(self: *const LightAndDepth, seconds: f32) zui.Gradient {
        const turns = (self.angle_degrees + seconds * 24) / 360;
        return .{
            .from = kit.hueColor(self.from_hue, 0.75, 0.95),
            .to = kit.hueColor(self.to_hue, 0.75, 0.95),
            .angle = turns * 2 * std.math.pi,
        };
    }

    fn shadow(self: *const LightAndDepth, shell: *const Shell) zui.Shadow {
        const alpha: u8 = @intFromFloat(@round(std.math.clamp(self.shadow_opacity, 0, 1) * 255));
        if (self.glow) {
            var glow_color = shell.palette.accent;
            glow_color.a = alpha;
            var glow: zui.Shadow = .glow(glow_color, self.blur);
            glow.spread = self.spread;
            return glow;
        }
        return .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = alpha }, .offset = self.offset, .blur = self.blur, .spread = self.spread };
    }

    fn controls(self: *LightAndDepth, ui: *Ui, shell: *const Shell) void {
        const widgets = shell.widgets;
        shell.openScrollingCard(ui, .of("depth.controls"), "zui.Effects", .{ .width = .fixed(340), .height = .grow });
        defer ui.close();
        shell.labelColored(ui, .body, shell.palette.accent, "shadow");
        _ = widgets.checkbox(ui, .of("depth.glow"), "glow: no offset, the accent color", &self.glow, .{});
        if (!self.glow) {
            sliderRow(ui, shell, .of("depth.offset_x"), "offset x", &self.offset[0], -40, 40, 1, "{d:.0}");
            sliderRow(ui, shell, .of("depth.offset_y"), "offset y", &self.offset[1], -40, 40, 1, "{d:.0}");
        }
        sliderRow(ui, shell, .of("depth.blur"), "blur", &self.blur, 0, 80, 1, "{d:.0}");
        sliderRow(ui, shell, .of("depth.spread"), "spread", &self.spread, -20, 30, 1, "{d:.0}");
        sliderRow(ui, shell, .of("depth.opacity"), "opacity", &self.shadow_opacity, 0, 1, 0.05, "{d:.2}");
        shell.divider(ui);
        shell.labelColored(ui, .body, shell.palette.accent, "gradient");
        sliderRow(ui, shell, .of("depth.angle"), "angle", &self.angle_degrees, 0, 360, 1, "{d:.0}");
        sliderRow(ui, shell, .of("depth.from"), "from hue", &self.from_hue, 0, 1, 0.01, "{d:.2}");
        sliderRow(ui, shell, .of("depth.to"), "to hue", &self.to_hue, 0, 1, 0.01, "{d:.2}");
        _ = widgets.checkbox(ui, .of("depth.animate"), "turn the gradient, pulse the glows", &self.animate, .{});
        shell.divider(ui);
        sliderRow(ui, shell, .of("depth.radius"), "corner radius", &self.corner_radius, 0, 80, 1, "{d:.0}");
        shell.label(ui, .caption, "Both effects take the element's corner radius. The renderer declares .gradient and .shadow; one that does not gets the gradient as its middle color and no shadow.");
        if (widgets.button(ui, .of("depth.reset"), "Reset", .{})) self.* = .{};
    }

    fn specimen(self: *const LightAndDepth, ui: *Ui, shell: *const Shell, seconds: f32) void {
        const palette = shell.palette;
        const gradient_now = self.gradient(seconds);
        const shadow_now = self.shadow(shell);
        ui.open(.{
            .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(24), .child_gap = 28, .child_alignment = .{ .x = .center, .y = .center } },
            .decoration = .{ .background = palette.sunken, .corner_radius = .all(10) },
            .clip = .both,
        });
        defer ui.close();
        ui.open(.{
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(360), .height = .fixed(200) }, .padding = .all(24), .child_gap = 6, .child_alignment = .{ .y = .end } },
            .decoration = .{ .corner_radius = .all(self.corner_radius) },
            .effects = &.{ .gradient = gradient_now, .shadow = shadow_now },
        });
        ui.text("Light & Depth", shell.style(.title, .rgb(0xffffff)));
        ui.text("a gradient in OKLab over a soft shadow", shell.style(.caption, .rgb(0xffffff)));
        ui.close();

        var code_buffer: [512]u8 = undefined;
        const code = std.fmt.bufPrint(&code_buffer,
            \\.effects = &.{{
            \\    .gradient = .{{
            \\        .from = .rgb(0x{x:0>6}), .to = .rgb(0x{x:0>6}),
            \\        .angle = {d:.2},
            \\    }},
            \\    .shadow = .{{
            \\        .color = .rgba(0x{x:0>8}), .offset = .{{ {d:.0}, {d:.0} }},
            \\        .blur = {d:.0}, .spread = {d:.0},
            \\    }},
            \\}},
        , .{
            rgbOf(gradient_now.from), rgbOf(gradient_now.to), @mod(gradient_now.angle, 2 * std.math.pi),
            rgbaOf(shadow_now.color), shadow_now.offset[0],   shadow_now.offset[1],
            shadow_now.blur,          shadow_now.spread,
        }) catch "";
        ui.text(code, .{ .font = kit.mono_font, .size = 13 * shell.text_scale, .color = palette.muted, .wrap = .newlines });
    }

    fn blends(self: *const LightAndDepth, ui: *Ui, shell: *const Shell) void {
        const across = self.gradient(0);
        const straight: zui.Gradient = .{ .from = across.from, .to = across.to };
        shell.openCard(ui, "OKLab against sRGB", .{ .width = .grow, .height = .grow });
        defer ui.close();
        shell.label(ui, .caption, "drawn by the renderer, in OKLab");
        ui.box(.{
            .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(30) } },
            .decoration = .{ .corner_radius = .all(6) },
            .effects = &.{ .gradient = straight },
        });
        shell.label(ui, .caption, "the same two colors through Color.mix");
        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(30) } } });
        for (0..srgb_steps) |step| {
            const amount = @as(f32, @floatFromInt(step)) / (srgb_steps - 1);
            ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .grow } }, .decoration = .{ .background = across.from.mix(across.to, amount) } });
        }
        ui.close();
    }
};

fn elevation(ui: *Ui, shell: *const Shell) void {
    const palette = shell.palette;
    shell.openCard(ui, "Elevation", .{ .width = .grow, .height = .grow });
    defer ui.close();
    shell.label(ui, .caption, "One shadow per level: further off the page, softer and further down.");
    ui.open(.{ .layout = .{ .sizing = .grow_both, .padding = .symmetric(4, 10), .child_gap = 14, .child_alignment = .{ .y = .center } } });
    defer ui.close();
    for (1..elevation_levels + 1) |level| {
        const height: f32 = @floatFromInt(level);
        ui.open(.{
            .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(56) }, .child_alignment = .{ .x = .center, .y = .center } },
            .decoration = .{ .background = palette.raised, .corner_radius = .all(8) },
            .effects = &.{ .shadow = .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = @intCast(40 + 14 * level) }, .offset = .{ 0, height * 2 }, .blur = height * 5 } },
        });
        shell.print(ui, .heading, "{d}", .{level});
        ui.close();
    }
}

fn glows(ui: *Ui, shell: *const Shell, seconds: f32) void {
    const palette = shell.palette;
    shell.openCard(ui, "Glow", .{ .width = .grow, .height = .grow });
    defer ui.close();
    shell.label(ui, .caption, "Shadow.glow: a shadow with no offset, here pulsing.");
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .symmetric(16, 8), .child_gap = 12 } });
    defer ui.close();
    const colors = [_]zui.Color{ palette.good, palette.warn, palette.bad };
    for (glow_names, colors, 0..) |name, color, index| {
        const phase = seconds * 2.4 + @as(f32, @floatFromInt(index)) * 2.1;
        var glow_color = color;
        glow_color.a = 150;
        ui.open(.{
            .layout = .{ .sizing = .{ .width = .grow }, .padding = .symmetric(12, 4), .child_gap = 8, .child_alignment = .{ .y = .center } },
            .decoration = .{ .background = palette.surface, .border = .{ .color = color, .widths = .all(1) }, .corner_radius = .all(12) },
            .effects = &.{ .shadow = .glow(glow_color, 9 + 5 * @sin(phase)) },
        });
        ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } }, .decoration = .{ .background = color, .corner_radius = .all(5) } });
        shell.labelColored(ui, .caption, color, name);
        ui.close();
    }
}

fn rgbOf(color: zui.Color) u32 {
    return @as(u32, color.r) << 16 | @as(u32, color.g) << 8 | color.b;
}

fn rgbaOf(color: zui.Color) u32 {
    return rgbOf(color) << 8 | color.a;
}

fn sliderRow(ui: *Ui, shell: *const Shell, id: zui.Id, name: []const u8, value: *f32, minimum: f64, maximum: f64, step: f64, comptime format: []const u8) void {
    shell.widgets.labeledRow(ui, name);
    defer ui.close();
    _ = shell.widgets.slider(ui, id, value, .{ .min = minimum, .max = maximum, .step = step });
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(40) }, .child_alignment = .{ .x = .end } } });
    shell.print(ui, .caption, format, .{value.*});
    ui.close();
}
