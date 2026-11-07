const std = @import("std");
const kit = @import("../kit.zig");
const zui = kit.zui;
const zui_reflect = kit.zui_reflect;
const zui_widgets = kit.zui_widgets;
const Ui = kit.Ui;
const Shell = kit.Shell;

const Paint = enum {
    steel,
    tangerine,
    mint,
    grape,
    bubblegum,
    gold,
    midnight,

    fn color(paint: Paint) zui.Color {
        return switch (paint) {
            .steel => .rgb(0xa7b4c6),
            .tangerine => .rgb(0xff9446),
            .mint => .rgb(0x5ee6b0),
            .grape => .rgb(0x9b6cff),
            .bubblegum => .rgb(0xff7ac6),
            .gold => .rgb(0xf5c542),
            .midnight => .rgb(0x3a4a7a),
        };
    }
};

const Mood = enum { cheerful, grumpy, sleepy, suspicious };

const Head = struct {
    width: f32 = 140,
    height: f32 = 104,
    roundness: f32 = 26,
    paint: Paint = .steel,
    eyes: u8 = 2,
    eye_size: f32 = 24,
    antenna: bool = true,

    pub const zui_inspector: zui_reflect.Options(@This()) = .{ .fields = .{
        .width = .{ .min = 70, .max = 220, .step = 1 },
        .height = .{ .min = 60, .max = 170, .step = 1 },
        .roundness = .{ .min = 0, .max = 85, .step = 1 },
        .eyes = .{ .min = 1, .max = 5 },
        .eye_size = .{ .min = 8, .max = 40, .step = 1 },
    } };
};

const Body = struct {
    width: f32 = 170,
    height: f32 = 130,
    paint: Paint = .tangerine,
    chest_lights: u8 = 4,
    arm_length: f32 = 70,

    pub const zui_inspector: zui_reflect.Options(@This()) = .{ .fields = .{
        .width = .{ .min = 90, .max = 240, .step = 1 },
        .height = .{ .min = 70, .max = 200, .step = 1 },
        .chest_lights = .{ .min = 0, .max = 8 },
        .arm_length = .{ .min = 20, .max = 130, .step = 1 },
    } };
};

const Personality = struct {
    mood: Mood = .cheerful,
    blinks: bool = true,
    dances: bool = false,
};

const Robot = struct {
    name: zui_widgets.EditableText,
    serial: []const u8 = "ZUI-0042",
    head: Head = .{},
    body: Body = .{},
    personality: Personality = .{},
    power_level: u16 = 4200,

    pub const zui_inspector: zui_reflect.Options(@This()) = .{ .fields = .{
        .name = .{ .placeholder = "name your robot" },
        .power_level = .{ .min = 0, .max = 10000, .step = 100 },
    } };
};

const blink_period_seconds = 3.2;
const blink_closed_seconds = 0.16;
const chest_light_period_seconds = 0.5;

pub const RobotWorkshop = struct {
    name_bytes: [24]u8 = undefined,
    robot: Robot = undefined,
    edits: u32 = 0,
    randomizations: u64 = 0,
    text_scale: f32 = 1,

    pub fn init(self: *RobotWorkshop) void {
        self.robot = .{ .name = .init(&self.name_bytes, "Bolt") };
    }

    pub fn declare(self: *RobotWorkshop, ui: *Ui, shell: *const Shell) void {
        ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 16 } });
        defer ui.close();
        self.editor(ui, shell);
        self.stage(ui, shell);
        self.environmentPanel(ui, shell);
    }

    fn editor(self: *RobotWorkshop, ui: *Ui, shell: *const Shell) void {
        ui.open(.{
            .id = .of("robot.editor"),
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(400), .height = .grow }, .padding = .all(14), .child_gap = 8 },
            .decoration = .{ .background = shell.palette.surface, .border = .{ .color = shell.palette.border, .widths = .all(1) }, .corner_radius = .all(10) },
            .scroll = .{},
        });
        defer ui.close();
        shell.label(ui, .heading, "Blueprint");
        shell.label(ui, .caption, "Not one widget below is written by hand: zui_reflect.inspector walks the Robot struct and picks a text field, slider, stepper, dropdown, checkbox or collapsible section per field.");
        if (zui_reflect.inspector(shell.widgets, ui, .of("robot.blueprint"), &self.robot)) self.edits += 1;
        ui.open(.{ .layout = .{ .child_gap = 8 } });
        defer ui.close();
        if (shell.widgets.button(ui, .of("robot.randomize"), "Randomize", .{})) self.randomize();
        if (shell.widgets.button(ui, .of("robot.reset"), "Reset", .{})) {
            const name = self.robot.name;
            self.robot = .{ .name = name };
        }
        shell.print(ui, .caption, "{d} edits", .{self.edits});
    }

    fn randomize(self: *RobotWorkshop) void {
        self.randomizations += 1;
        var prng: std.Random.DefaultPrng = .init(self.randomizations *% 0x2545F4914F6CDD1D);
        const random = prng.random();
        const robot = &self.robot;
        robot.head = .{
            .width = 80 + random.float(f32) * 130,
            .height = 60 + random.float(f32) * 100,
            .roundness = random.float(f32) * 70,
            .paint = random.enumValue(Paint),
            .eyes = random.intRangeAtMost(u8, 1, 5),
            .eye_size = 10 + random.float(f32) * 26,
            .antenna = random.boolean(),
        };
        robot.body = .{
            .width = 100 + random.float(f32) * 130,
            .height = 80 + random.float(f32) * 110,
            .paint = random.enumValue(Paint),
            .chest_lights = random.intRangeAtMost(u8, 0, 8),
            .arm_length = 20 + random.float(f32) * 100,
        };
        robot.personality.mood = random.enumValue(Mood);
        robot.power_level = random.intRangeAtMost(u16, 0, 100) * 100;
    }

    fn stage(self: *RobotWorkshop, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        const robot = &self.robot;
        const seconds = shell.motionSeconds();
        self.scheduleNextChange(ui, shell);

        ui.open(.{
            .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(16), .child_gap = 0, .child_alignment = .{ .x = .center } },
            .decoration = .{ .background = palette.sunken, .corner_radius = .all(10) },
            .clip = .both,
        });
        defer ui.close();
        {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
            defer ui.close();
            if (robot.power_level > 9000) shell.chip(ui, "IT'S OVER 9000", palette.bad);
            shell.spacer(ui);
            shell.chip(ui, @tagName(robot.personality.mood), Paint.color(robot.head.paint));
        }
        shell.spacer(ui);

        const sway = if (robot.personality.dances) 40 * @sin(seconds * 5) else 0;
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .padding = .{ .left = @max(0, sway), .right = @max(0, -sway) }, .child_alignment = .{ .x = .center } } });
        if (robot.head.antenna) antenna(ui, robot.head.paint, seconds);
        self.head(ui, shell);
        ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(36), .height = .fixed(14) } }, .decoration = .{ .background = palette.faint } });
        self.torso(ui, shell);
        legs(ui, robot.body);
        ui.close();

        shell.spacer(ui);
        ui.text(robot.name.slice(), .{ .size = 38 * shell.text_scale, .font = kit.bold_font, .letter_spacing = 3, .color = Paint.color(robot.body.paint) });
        shell.printColored(ui, .caption, palette.muted, "serial {s}   power {d}", .{ robot.serial, robot.power_level });
    }

    /// Asks for a frame only when the picture changes: the next blink edge
    /// and the next chest-light toggle, or every frame while dancing.
    fn scheduleNextChange(self: *RobotWorkshop, ui: *Ui, shell: *const Shell) void {
        if (shell.reduced_motion) return;
        const personality = self.robot.personality;
        if (personality.dances) return ui.requestFrame();
        const seconds = shell.seconds;
        const now = ui.now();
        if (personality.blinks) {
            const phase = @mod(seconds, blink_period_seconds);
            const until_edge = if (phase < blink_closed_seconds) blink_closed_seconds - phase else blink_period_seconds - phase;
            ui.requestFrameAt(now.addSeconds(until_edge));
        }
        if (self.robot.body.chest_lights != 0) {
            ui.requestFrameAt(now.addSeconds(chest_light_period_seconds - @mod(seconds, chest_light_period_seconds)));
        }
    }

    fn head(self: *RobotWorkshop, ui: *Ui, shell: *const Shell) void {
        const head_spec = self.robot.head;
        const personality = self.robot.personality;
        const blinking = personality.blinks and !shell.reduced_motion and @mod(shell.seconds, blink_period_seconds) < blink_closed_seconds;
        const paint = Paint.color(head_spec.paint);
        ui.open(.{
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(head_spec.width), .height = .fixed(head_spec.height) }, .padding = .all(12), .child_gap = 10, .child_alignment = .{ .x = .center, .y = .center } },
            .decoration = .{ .background = paint, .border = .{ .color = paint.mix(.black, 0.35), .widths = .all(3) }, .corner_radius = .all(head_spec.roundness) },
        });
        defer ui.close();
        {
            ui.open(.{ .layout = .{ .child_gap = head_spec.eye_size * 0.5, .child_alignment = .{ .y = .center } } });
            defer ui.close();
            for (0..head_spec.eyes) |eye_index| eye(ui, head_spec.eye_size, personality.mood, blinking, eye_index);
        }
        mouth(ui, personality.mood, head_spec.width, paint);
    }

    fn torso(self: *RobotWorkshop, ui: *Ui, shell: *const Shell) void {
        const body = self.robot.body;
        const paint = Paint.color(body.paint);
        ui.open(.{ .layout = .{ .child_alignment = .{ .y = .start } } });
        defer ui.close();
        arm(ui, body, .left);
        ui.open(.{
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(body.width), .height = .fixed(body.height) }, .padding = .all(14), .child_gap = 10, .child_alignment = .{ .x = .center } },
            .decoration = .{ .background = paint, .border = .{ .color = paint.mix(.black, 0.35), .widths = .all(3) }, .corner_radius = .{ .top_left = 18, .top_right = 18, .bottom_left = 8, .bottom_right = 8 } },
        });
        if (body.chest_lights != 0) {
            const tick: u64 = @intFromFloat(@floor(shell.motionSeconds() / chest_light_period_seconds));
            ui.open(.{
                .layout = .{ .padding = .all(6), .child_gap = 5 },
                .decoration = .{ .background = paint.mix(.black, 0.55), .corner_radius = .all(6) },
            });
            for (0..body.chest_lights) |light| {
                const lit = (light + tick) % 2 == 0;
                ui.box(.{
                    .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } },
                    .decoration = .{ .background = if (lit) kit.hueColor(@as(f32, @floatFromInt(light)) / 8, 0.7, 1) else .rgb(0x303040), .corner_radius = .all(5) },
                });
            }
            ui.close();
        }
        ui.box(.{ .layout = .{ .sizing = .{ .width = .percent(0.5), .height = .fixed(6) } }, .decoration = .{ .background = paint.mix(.black, 0.3), .corner_radius = .all(3) } });
        ui.box(.{ .layout = .{ .sizing = .{ .width = .percent(0.5), .height = .fixed(6) } }, .decoration = .{ .background = paint.mix(.black, 0.3), .corner_radius = .all(3) } });
        ui.close();
        arm(ui, body, .right);
    }

    fn environmentPanel(self: *RobotWorkshop, ui: *Ui, shell: *const Shell) void {
        const widgets = shell.widgets;
        const environment = ui.environment();
        shell.openScrollingCard(ui, .of("robot.environment"), "Environment", .{ .width = .fixed(270), .height = .grow });
        defer ui.close();
        shell.label(ui, .caption, "These would come from the OS. Here they are made-up environment events in the next frame record; the palette, widgets, text scale and every animation follow ui.environment().");
        const dark = environment.theme == .dark;
        if (widgets.button(ui, .of("robot.theme"), if (dark) "Switch to light" else "Switch to dark", .{ .width = .grow })) shell.changeEnvironment(.{ .theme = if (dark) .light else .dark });
        var high_contrast = environment.contrast == .high;
        if (widgets.checkbox(ui, .of("robot.contrast"), "High contrast", &high_contrast, .{})) shell.changeEnvironment(.{ .contrast = if (high_contrast) .high else .normal });
        var reduced_motion = environment.reduced_motion;
        if (widgets.checkbox(ui, .of("robot.motion"), "Reduce motion", &reduced_motion, .{})) shell.changeEnvironment(.{ .reduced_motion = reduced_motion });
        shell.print(ui, .body, "Text scale {d:.2}", .{environment.text_scale});
        self.text_scale = environment.text_scale;
        if (widgets.slider(ui, .of("robot.text_scale"), &self.text_scale, .{ .min = 0.75, .max = 1.5, .step = 0.05 })) shell.changeEnvironment(.{ .text_scale = self.text_scale });
        shell.divider(ui);
        shell.label(ui, .caption, "With reduced motion the robot stops blinking and dancing, and this screen stops asking for frames at all.");
    }
};

fn antenna(ui: *Ui, paint: Paint, seconds: f32) void {
    const glow = 0.6 + 0.4 * @sin(seconds * 4);
    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(18), .height = .fixed(18) } }, .decoration = .{ .background = kit.hueColor(0.0, 0.8, glow), .corner_radius = .all(9) } });
    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(4), .height = .fixed(22) } }, .decoration = .{ .background = Paint.color(paint).mix(.black, 0.4) } });
}

fn eye(ui: *Ui, size: f32, mood: Mood, blinking: bool, eye_index: usize) void {
    const white: zui.Color = .rgb(0xf6f6fa);
    const lid_fraction: f32 = if (blinking) 0.12 else switch (mood) {
        .cheerful => 1,
        .grumpy => 0.55,
        .sleepy => 0.3,
        .suspicious => if (eye_index % 2 == 0) 0.4 else 1,
    };
    const height = @max(2, size * lid_fraction);
    const corners: zui.CornerRadius = switch (mood) {
        .grumpy => .{ .bottom_left = size / 2, .bottom_right = size / 2 },
        else => .all(@min(size, height) / 2),
    };
    ui.open(.{
        .layout = .{ .sizing = .{ .width = .fixed(size), .height = .fixed(height) }, .child_alignment = .{ .x = .center, .y = .center } },
        .decoration = .{ .background = white, .corner_radius = corners },
    });
    if (!blinking) ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(size * 0.4), .height = .fixed(@min(size * 0.4, height)) } }, .decoration = .{ .background = .rgb(0x1b1d2a), .corner_radius = .all(size * 0.2) } });
    ui.close();
}

fn mouth(ui: *Ui, mood: Mood, head_width: f32, paint: zui.Color) void {
    const dark = paint.mix(.black, 0.6);
    const width = head_width * 0.4;
    switch (mood) {
        .cheerful => ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(width), .height = .fixed(width * 0.35) } }, .decoration = .{ .background = dark, .corner_radius = .{ .bottom_left = width / 2, .bottom_right = width / 2, .top_left = 3, .top_right = 3 } } }),
        .grumpy => ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(width), .height = .fixed(width * 0.3) } }, .decoration = .{ .background = dark, .corner_radius = .{ .top_left = width / 2, .top_right = width / 2 } } }),
        .sleepy => ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(width * 0.3), .height = .fixed(width * 0.3) } }, .decoration = .{ .background = dark, .corner_radius = .all(width) } }),
        .suspicious => {
            ui.open(.{ .layout = .{ .padding = .{ .left = width * 0.4 } } });
            ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(width * 0.6), .height = .fixed(5) } }, .decoration = .{ .background = dark, .corner_radius = .all(2) } });
            ui.close();
        },
    }
}

fn arm(ui: *Ui, body: Body, side: enum { left, right }) void {
    const paint = Paint.color(body.paint).mix(.black, 0.2);
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .padding = .{ .top = 16 }, .child_alignment = .{ .x = if (side == .left) .end else .start } } });
    defer ui.close();
    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(16), .height = .fixed(body.arm_length) } }, .decoration = .{ .background = paint, .corner_radius = .all(8) } });
    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(24), .height = .fixed(16) } }, .decoration = .{ .border = .{ .color = paint, .widths = .{ .left = 5, .right = 5, .bottom = 5 } }, .corner_radius = .{ .bottom_left = 8, .bottom_right = 8 } } });
}

fn legs(ui: *Ui, body: Body) void {
    const paint = Paint.color(body.paint).mix(.black, 0.3);
    ui.open(.{ .layout = .{ .child_gap = body.width * 0.3 } });
    defer ui.close();
    for (0..2) |_| {
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .child_alignment = .{ .x = .center } } });
        ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(18), .height = .fixed(36) } }, .decoration = .{ .background = paint } });
        ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(40), .height = .fixed(14) } }, .decoration = .{ .background = paint.mix(.black, 0.3), .corner_radius = .{ .top_left = 10, .top_right = 10, .bottom_left = 3, .bottom_right = 3 } } });
        ui.close();
    }
}
