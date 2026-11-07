const std = @import("std");
const kit = @import("../kit.zig");
const zui = kit.zui;
const Ui = kit.Ui;
const Shell = kit.Shell;

const arena_id: zui.Id = .of("storm.arena");

const Mode = enum {
    ripple_grid,
    golden_spiral,
    warm_text,
    churning_text,

    fn explanation(mode: Mode) []const u8 {
        return switch (mode) {
            .ripple_grid => "Every box is re-declared each frame with a new size and color; zui lays out and emits all of them.",
            .golden_spiral => "Containers nested inside containers, alternating direction: each level is a percent() of its parent.",
            .warm_text => "The same strings every frame: the whole-string cache answers, so 'texts measured' stays at 0.",
            .churning_text => "Every string changes every frame, so each one goes through the text contract: watch 'texts measured'.",
        };
    }
};

pub const BoxStorm = struct {
    mode: Mode = .ripple_grid,
    box_count: u32 = 4096,
    depth: u32 = 40,
    text_count: u32 = 900,
    animate: bool = true,
    frame_counter: u64 = 0,

    pub fn declare(self: *BoxStorm, ui: *Ui, shell: *const Shell) void {
        self.frame_counter +%= 1;
        if (self.animate) ui.requestFrame();
        self.controls(ui, shell);
        {
            ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 16 } });
            defer ui.close();
            ui.open(.{
                .id = arena_id,
                .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(8), .child_alignment = .{ .x = .center, .y = .center } },
                .decoration = .{ .background = shell.palette.sunken, .corner_radius = .all(10) },
                .clip = .both,
            });
            switch (self.mode) {
                .ripple_grid => self.rippleGrid(ui, shell),
                .golden_spiral => self.goldenSpiral(ui, shell),
                .warm_text, .churning_text => self.textWall(ui, shell),
            }
            ui.close();
            readout(ui, shell);
        }
    }

    fn controls(self: *BoxStorm, ui: *Ui, shell: *const Shell) void {
        const widgets = shell.widgets;
        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 14, .child_alignment = .{ .y = .center } } });
        defer ui.close();
        _ = widgets.dropdownEnum(ui, .of("storm.mode"), &self.mode, .{});
        ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(320) }, .child_gap = 10, .child_alignment = .{ .y = .center } } });
        switch (self.mode) {
            .ripple_grid => {
                _ = widgets.slider(ui, .of("storm.boxes"), &self.box_count, .{ .min = 64, .max = 14000, .step = 64 });
                shell.print(ui, .body, "{d} boxes", .{self.box_count});
            },
            .golden_spiral => {
                _ = widgets.slider(ui, .of("storm.depth"), &self.depth, .{ .min = 1, .max = 90 });
                shell.print(ui, .body, "depth {d}", .{self.depth});
            },
            .warm_text, .churning_text => {
                _ = widgets.slider(ui, .of("storm.texts"), &self.text_count, .{ .min = 50, .max = 3000, .step = 50 });
                shell.print(ui, .body, "{d} texts", .{self.text_count});
            },
        }
        ui.close();
        _ = widgets.checkbox(ui, .of("storm.animate"), "Animate", &self.animate, .{});
        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow } } });
        shell.label(ui, .caption, self.mode.explanation());
        ui.close();
    }

    /// Cells sized so the whole grid fits the arena the frame before had.
    fn rippleGrid(self: *BoxStorm, ui: *Ui, shell: *const Shell) void {
        const arena = ui.rectOf(arena_id) orelse zui.Rect{ .width = 800, .height = 500 };
        const usable_width = @max(arena.width - 16, 50);
        const usable_height = @max(arena.height - 16, 50);
        const count: f32 = @floatFromInt(self.box_count);
        const cell = @max(3, @floor(@sqrt(usable_width * usable_height / count)));
        const columns: u32 = @max(1, @as(u32, @intFromFloat(usable_width / cell)));
        const rows = (self.box_count + columns - 1) / columns;
        const seconds = shell.motionSeconds();
        const center: [2]f32 = .{ @as(f32, @floatFromInt(columns)) / 2, @as(f32, @floatFromInt(rows)) / 2 };

        for (0..rows) |row| {
            ui.open(.{ .layout = .{ .sizing = .{ .height = .fixed(cell) }, .child_alignment = .{ .y = .center } } });
            defer ui.close();
            const first = row * columns;
            const last = @min(first + columns, self.box_count);
            for (first..last) |index| {
                const column: f32 = @floatFromInt(index - first);
                const row_float: f32 = @floatFromInt(row);
                const distance = std.math.hypot(column - center[0], row_float - center[1]);
                const wave = 0.5 + 0.5 * @sin(seconds * 3 - distance * 0.35);
                const size = @max(1, (cell - 1) * (0.35 + 0.65 * wave));
                ui.box(.{
                    .layout = .{ .sizing = .{ .width = .fixed(cell), .height = .fixed(size) } },
                    .decoration = .{ .background = kit.hueColor(distance * 0.015 + seconds * 0.08, 0.65, 0.35 + 0.65 * wave) },
                });
            }
        }
    }

    /// Each level splits into a block and the next level, turning a quarter
    /// each time. The block goes first for two turns and last for two, so a
    /// trailing block is declared on the way back out, once the deeper
    /// levels have closed.
    fn goldenSpiral(self: *BoxStorm, ui: *Ui, shell: *const Shell) void {
        for (0..self.depth) |level| {
            const spiral_level = spiralLevel(level, shell);
            ui.open(.{
                .layout = .{ .direction = spiral_level.direction, .sizing = .grow_both, .padding = .all(2), .child_gap = 3 },
                .decoration = .{ .border = .{ .color = spiral_level.block.decoration.?.background.?.mix(shell.palette.sunken, 0.5), .widths = .all(1) }, .corner_radius = .all(4) },
            });
            if (spiral_level.block_first) ui.box(spiral_level.block);
        }
        shell.printColored(ui, .caption, shell.palette.text, "depth {d}", .{self.depth});
        var level = self.depth;
        while (level > 0) {
            level -= 1;
            const spiral_level = spiralLevel(level, shell);
            if (!spiral_level.block_first) ui.box(spiral_level.block);
            ui.close();
        }
    }

    const SpiralLevel = struct { direction: zui.Direction, block: zui.Element, block_first: bool };

    fn spiralLevel(level: usize, shell: *const Shell) SpiralLevel {
        const turn = level % 4;
        const level_float: f32 = @floatFromInt(level);
        const seconds = shell.motionSeconds();
        const block_fraction = 0.382 + 0.06 * @sin(seconds * 1.5 + level_float * 0.5);
        const direction: zui.Direction = if (turn % 2 == 0) .left_to_right else .top_to_bottom;
        const block_sizing: zui.Sizing2 = if (direction == .left_to_right)
            .{ .width = .percent(block_fraction), .height = .grow }
        else
            .{ .width = .grow, .height = .percent(block_fraction) };
        return .{
            .direction = direction,
            .block_first = turn < 2,
            .block = .{
                .layout = .{ .sizing = block_sizing },
                .decoration = .{ .background = kit.hueColor(level_float * 0.035 + seconds * 0.05, 0.6, 0.95), .corner_radius = .all(@max(1, 14 - level_float * 0.3)) },
            },
        };
    }

    fn textWall(self: *BoxStorm, ui: *Ui, shell: *const Shell) void {
        const arena = ui.rectOf(arena_id) orelse zui.Rect{ .width = 800, .height = 500 };
        const churn = self.mode == .churning_text;
        const cell_width: f32 = if (churn) 104 else 72;
        const columns: usize = @max(1, @as(usize, @intFromFloat((arena.width - 16) / cell_width)));
        const seconds = shell.motionSeconds();
        var index: usize = 0;
        while (index < self.text_count) {
            ui.open(.{ .layout = .{ .child_gap = 0 } });
            defer ui.close();
            const row_end = @min(index + columns, self.text_count);
            while (index < row_end) : (index += 1) {
                var buffer: [32]u8 = undefined;
                const content = if (churn)
                    std.fmt.bufPrint(&buffer, "{d:0>4}:{d:0>6}", .{ index, self.frame_counter % 1_000_000 }) catch "?"
                else
                    std.fmt.bufPrint(&buffer, "item{d:0>4}", .{index}) catch "?";
                const hue = @as(f32, @floatFromInt(index)) * 0.003 + seconds * 0.1;
                ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(cell_width) } } });
                ui.text(content, .{ .size = 11, .color = kit.hueColor(hue, 0.5, 1), .wrap = .none });
                ui.close();
            }
        }
    }
};

fn readout(ui: *Ui, shell: *const Shell) void {
    const palette = shell.palette;
    const latest = shell.perf.latest();
    const summary = shell.perf.summarize();
    shell.openScrollingCard(ui, .of("storm.stopwatch"), "Stopwatch", .{ .width = .fixed(280), .height = .grow });
    defer ui.close();
    big(ui, shell, "declare", latest.declare_us, palette.accent);
    big(ui, shell, "layout + emit", latest.end_frame_us, palette.warn);
    const nanoseconds_per_element = if (latest.elements == 0) 0 else 1000 * (latest.declare_us + latest.end_frame_us) / @as(f32, @floatFromInt(latest.elements));
    shell.print(ui, .body, "{d} elements", .{latest.elements});
    shell.print(ui, .body, "{d} render commands", .{latest.commands});
    shell.printColored(ui, .body, palette.good, "{d:.1} ns per element", .{nanoseconds_per_element});
    shell.divider(ui);
    shell.label(ui, .caption, "LAST 120 FRAMES, ALL PHASES");
    shell.print(ui, .body, "avg {d:.0} us   p95 {d:.0} us", .{ summary.average, summary.p95 });
    const budget_fraction = summary.p95 / 16_667;
    shell.meter(ui, budget_fraction, if (budget_fraction < 0.25) palette.good else if (budget_fraction < 0.75) palette.warn else palette.bad, 10);
    shell.printColored(ui, .caption, palette.muted, "{d:.1}% of a 60 Hz frame", .{100 * budget_fraction});
    shell.divider(ui);
    shell.label(ui, .caption, "SPEC 20.2 budget: 4,096 boxes laid out and emitted in under 100 us, on a 2020 desktop core. Build with -Doptimize=ReleaseFast to compare.");
}

fn big(ui: *Ui, shell: *const Shell, name: []const u8, microseconds: f32, color: zui.Color) void {
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .child_gap = 2 } });
    defer ui.close();
    shell.label(ui, .caption, name);
    shell.printColored(ui, .title, color, "{d:.0} us", .{microseconds});
}
