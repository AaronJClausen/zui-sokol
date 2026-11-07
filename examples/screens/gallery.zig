const std = @import("std");
const kit = @import("../kit.zig");
const zui = kit.zui;
const Ui = kit.Ui;
const Shell = kit.Shell;

pub const Tile = struct {
    background: zui.Color,
    accent: zui.Color,
    corners: zui.CornerRadius,
    shape_fraction: f32,
    initials: [2]u8,
};

pub const TileError = error{
    /// Demand lapsed: the tile scrolled away before it finished.
    Canceled,
    /// The made-up failure the "failure rate" knob injects.
    Glitched,
    /// The `Io` had no thread to spare, and loading inline would block the UI.
    NoThreadAvailable,
};

pub const tile_count = 10_000;

/// Enough slots for a screenful plus what is waiting to be released after
/// a fast scroll; a key that finds every slot taken stays `.idle` and the
/// refusal shows up in the frame's diagnostics.
pub const TileLoads = kit.zui_async.KeyedLoads(u32, TileError!Tile, .{ .capacity = 512, .unread_frames_before_release = 20, .Progress = f32 });

const scroll_id: zui.Id = .of("gallery.scroll");
const track_id: zui.Id = .of("gallery.track");
const gap = 8;

/// What a load needs to know, copied when it starts so producers never
/// read the UI's knobs while they change.
const LoadSettings = struct {
    minimum_milliseconds: u32,
    maximum_milliseconds: u32,
    failure_percent: u32,
};

const Counters = struct {
    completed: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(u32) = .init(0),
    canceled: std.atomic.Value(u32) = .init(0),
};

pub const Gallery = struct {
    tasks: std.Io.Group = .init,
    counters: Counters = .{},
    started: u32 = 0,
    minimum_milliseconds: u32 = 150,
    maximum_milliseconds: u32 = 900,
    failure_percent: u32 = 4,
    tile_size: f32 = 96,
    jumps: u32 = 0,

    pub fn declare(self: *Gallery, ui: *Ui, shell: *const Shell) void {
        const tiles = ui.source(.tiles);
        self.controls(ui, shell);
        ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 6 } });
        defer ui.close();

        const pitch = self.tile_size + gap;
        const viewport = ui.rectOf(scroll_id) orelse zui.Rect{ .width = 900, .height = 600 };
        const columns: u32 = @max(1, @as(u32, @intFromFloat((viewport.width + gap) / pitch)));
        const total_rows = (tile_count + columns - 1) / columns;
        const content_height = @as(f32, @floatFromInt(total_rows)) * pitch;
        const offset = ui.scrollOffset(scroll_id)[1];
        const first_row: u32 = @intFromFloat(@max(0, @floor(offset / pitch) - 1));
        const last_row: u32 = @min(total_rows, @as(u32, @intFromFloat(@ceil((offset + viewport.height) / pitch))) + 1);

        var on_screen: std.EnumArray(std.meta.Tag(TileLoads.Status), u32) = .initFill(0);
        {
            ui.open(.{ .id = scroll_id, .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both }, .scroll = .{}, .decoration = .{ .background = shell.palette.sunken, .corner_radius = .all(8) } });
            defer ui.close();
            ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(@as(f32, @floatFromInt(first_row)) * pitch) } } });
            for (first_row..last_row) |row| {
                ui.open(.{ .layout = .{ .sizing = .{ .height = .fixed(pitch) }, .padding = .{ .left = gap, .top = gap }, .child_gap = gap } });
                defer ui.close();
                const first_key = row * columns;
                for (first_key..@min(first_key + columns, tile_count)) |key| {
                    const status = tiles.get(@intCast(key));
                    on_screen.getPtr(std.meta.activeTag(status)).* += 1;
                    self.tile(ui, shell, @intCast(key), status);
                }
            }
            ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(@as(f32, @floatFromInt(total_rows - last_row)) * pitch) } } });
        }
        scrollTrack(ui, shell, offset, viewport.height, content_height);

        shell.openScrollingCard(ui, .of("gallery.loads"), "Loads", .{ .width = .fixed(250), .height = .grow });
        defer ui.close();
        shell.print(ui, .body, "rows {d}-{d} of {d}", .{ first_row + 1, last_row, total_rows });
        shell.print(ui, .caption, "{d} tiles declared of {d}", .{ (last_row - first_row) * columns, tile_count });
        shell.divider(ui);
        shell.label(ui, .caption, "ON SCREEN");
        legendRow(ui, shell, "ready", on_screen.get(.ready), shell.palette.good);
        legendRow(ui, shell, "loading", on_screen.get(.running), shell.palette.accent);
        legendRow(ui, shell, "wanted", on_screen.get(.idle), shell.palette.muted);
        legendRow(ui, shell, "failed", on_screen.get(.failed), shell.palette.bad);
        legendRow(ui, shell, "canceled", on_screen.get(.canceled), shell.palette.warn);
        shell.divider(ui);
        shell.label(ui, .caption, "SINCE START");
        legendRow(ui, shell, "started", self.started, shell.palette.text);
        legendRow(ui, shell, "completed", self.counters.completed.load(.monotonic), shell.palette.good);
        legendRow(ui, shell, "glitched", self.counters.failed.load(.monotonic), shell.palette.bad);
        legendRow(ui, shell, "abandoned", self.counters.canceled.load(.monotonic), shell.palette.warn);
        shell.divider(ui);
        shell.label(ui, .caption, "The grid only asks: tiles.get(key). It never starts or waits for work. After endFrame the loader starts what was asked for on other threads, and a key nobody reads for 20 frames is abandoned, so a fast jump cancels what scrolled away.");
    }

    fn controls(self: *Gallery, ui: *Ui, shell: *const Shell) void {
        const widgets = shell.widgets;
        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 12, .child_alignment = .{ .y = .center } } });
        defer ui.close();
        slider(ui, shell, .of("gallery.size"), "tile", &self.tile_size, 48, 200, "{d:.0} px");
        slider(ui, shell, .of("gallery.slowest"), "slowest load", &self.maximum_milliseconds, 0, 4000, "{d} ms");
        slider(ui, shell, .of("gallery.failures"), "failure rate", &self.failure_percent, 0, 50, "{d}%");
        self.minimum_milliseconds = @min(self.minimum_milliseconds, self.maximum_milliseconds);
        shell.spacer(ui);
        if (widgets.button(ui, .of("gallery.top"), "Top", .{})) ui.setScrollOffset(scroll_id, .{ 0, 0 });
        if (widgets.button(ui, .of("gallery.jump"), "Warp", .{})) {
            self.jumps += 1;
            var prng: std.Random.DefaultPrng = .init(@as(u64, self.jumps) *% 0x9E3779B97F4A7C15);
            ui.setScrollOffset(scroll_id, .{ 0, prng.random().float(f32) * 100_000 });
        }
        if (widgets.button(ui, .of("gallery.bottom"), "Bottom", .{})) ui.setScrollOffset(scroll_id, .{ 0, std.math.floatMax(f32) });
    }

    fn tile(self: *Gallery, ui: *Ui, shell: *const Shell, key: u32, status: TileLoads.Status) void {
        const palette = shell.palette;
        const size = self.tile_size;
        const frame: zui.Element = .{
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(size), .height = .fixed(size) }, .padding = .all(6), .child_gap = 4, .child_alignment = .{ .x = .center, .y = .center } },
            .decoration = .{ .background = palette.surface, .border = .{ .color = palette.border, .widths = .all(1) }, .corner_radius = .all(8) },
        };
        var number_buffer: [8]u8 = undefined;
        const number = std.fmt.bufPrint(&number_buffer, "#{d}", .{key}) catch "#";
        switch (status) {
            .idle => {
                ui.open(frame);
                shell.labelColored(ui, .tiny, palette.faint, number);
                shell.labelColored(ui, .tiny, palette.faint, "wanted");
                ui.close();
            },
            .running => |progress| {
                ui.open(frame);
                shell.labelColored(ui, .tiny, palette.muted, number);
                shell.meter(ui, progress, palette.accent, 6);
                shell.printColored(ui, .tiny, palette.accent, "{d:.0}%", .{progress * 100});
                ui.close();
            },
            .ready => |art| {
                ui.open(.{
                    .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(size), .height = .fixed(size) }, .padding = .all(6), .child_alignment = .{ .x = .center, .y = .center } },
                    .decoration = .{ .background = art.background, .corner_radius = art.corners },
                });
                const shape_size = size * art.shape_fraction;
                ui.open(.{
                    .layout = .{ .sizing = .{ .width = .fixed(shape_size), .height = .fixed(shape_size) }, .child_alignment = .{ .x = .center, .y = .center } },
                    .decoration = .{ .background = art.accent, .corner_radius = .{ .top_left = art.corners.bottom_right, .top_right = art.corners.bottom_left, .bottom_left = art.corners.top_right, .bottom_right = art.corners.top_left } },
                });
                ui.text(&art.initials, .{ .size = @max(10, shape_size * 0.35), .font = 4, .color = art.background });
                ui.close();
                ui.close();
            },
            .failed => {
                var failed = frame;
                failed.decoration.?.border = .{ .color = palette.bad, .widths = .all(2) };
                ui.open(failed);
                shell.labelColored(ui, .tiny, palette.bad, number);
                shell.labelColored(ui, .tiny, palette.bad, "glitched");
                ui.close();
            },
            .canceled => {
                ui.open(frame);
                shell.labelColored(ui, .tiny, palette.warn, "canceled");
                ui.close();
            },
        }
    }

    /// The loader. Runs after every frame, on whichever screen, so loads
    /// finish and release even when the gallery is not shown.
    pub fn afterFrame(self: *Gallery, _: *Ui, shell: *const Shell) void {
        const settings: LoadSettings = .{
            .minimum_milliseconds = self.minimum_milliseconds,
            .maximum_milliseconds = self.maximum_milliseconds,
            .failure_percent = self.failure_percent,
        };
        var to_start = shell.sources.tiles.toStart(shell.waker);
        while (to_start.next()) |load| {
            self.started += 1;
            self.tasks.concurrent(shell.io, runLoad, .{ &self.counters, shell.io, load, settings }) catch load.finish(error.NoThreadAvailable);
        }
    }

    pub fn deinit(self: *Gallery, io: std.Io) void {
        self.tasks.cancel(io);
    }
};

fn runLoad(counters: *Counters, io: std.Io, load: TileLoads.Load, settings: LoadSettings) void {
    const result = produceTile(io, load, settings);
    if (result) |_| {
        _ = counters.completed.fetchAdd(1, .monotonic);
    } else |err| switch (err) {
        error.Canceled => _ = counters.canceled.fetchAdd(1, .monotonic),
        error.Glitched => _ = counters.failed.fetchAdd(1, .monotonic),
        error.NoThreadAvailable => {},
    }
    load.finish(result);
}

/// A slow, made-up load: sleeps in steps, reporting progress and stopping
/// early once nobody reads the tile, then derives the art from the key.
fn produceTile(io: std.Io, load: TileLoads.Load, settings: LoadSettings) TileError!Tile {
    var prng: std.Random.DefaultPrng = .init(@as(u64, load.key) *% 0x9E3779B97F4A7C15 +% 7);
    const random = prng.random();
    const total_milliseconds = random.intRangeAtMost(u32, @min(settings.minimum_milliseconds, settings.maximum_milliseconds), settings.maximum_milliseconds);
    const step_milliseconds = 30;
    var elapsed_milliseconds: u32 = 0;
    while (elapsed_milliseconds < total_milliseconds) {
        if (load.abandoned()) return error.Canceled;
        const step = @min(step_milliseconds, total_milliseconds - elapsed_milliseconds);
        try io.sleep(.fromMilliseconds(step), .awake);
        elapsed_milliseconds += step;
        load.progress(@as(f32, @floatFromInt(elapsed_milliseconds)) / @as(f32, @floatFromInt(total_milliseconds)));
    }
    if (random.uintLessThan(u32, 100) < settings.failure_percent) return error.Glitched;

    const radii = [_]f32{ 0, 6, 16, 32, 60 };
    const hue = random.float(f32);
    return .{
        .background = kit.hueColor(hue, 0.5, 0.3 + random.float(f32) * 0.2),
        .accent = kit.hueColor(hue + 0.35 + random.float(f32) * 0.3, 0.6, 0.95),
        .corners = .{
            .top_left = radii[random.uintLessThan(usize, radii.len)],
            .top_right = radii[random.uintLessThan(usize, radii.len)],
            .bottom_left = radii[random.uintLessThan(usize, radii.len)],
            .bottom_right = radii[random.uintLessThan(usize, radii.len)],
        },
        .shape_fraction = 0.35 + random.float(f32) * 0.35,
        .initials = .{ 'A' + random.uintLessThan(u8, 26), 'A' + random.uintLessThan(u8, 26) },
    };
}

/// A scrollbar zui does not draw for you: the thumb follows the offset, and
/// pressing or dragging on the track sets it.
fn scrollTrack(ui: *Ui, shell: *const Shell, offset: f32, visible_height: f32, content_height: f32) void {
    const palette = shell.palette;
    const maximum_offset = @max(1, content_height - visible_height);
    const track_height = (ui.rectOf(track_id) orelse zui.Rect{ .height = visible_height }).height;
    const thumb_height = std.math.clamp(track_height * visible_height / content_height, 24, track_height);
    const thumb_top = (track_height - thumb_height) * std.math.clamp(offset / maximum_offset, 0, 1);
    if (ui.pressed(track_id)) if (ui.pointerLocal(track_id)) |local| {
        const fraction = std.math.clamp((local[1] - thumb_height / 2) / @max(1, track_height - thumb_height), 0, 1);
        ui.setScrollOffset(scroll_id, .{ 0, fraction * maximum_offset });
    };
    ui.open(.{
        .id = track_id,
        .interactive = true,
        .cursor = .resize_vertical,
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(12), .height = .grow } },
        .decoration = .{ .background = palette.sunken, .corner_radius = .all(6) },
    });
    defer ui.close();
    ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(thumb_top) } } });
    ui.box(.{
        .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(thumb_height) } },
        .decoration = .{ .background = if (ui.hovered(track_id) or ui.pressed(track_id)) palette.accent else palette.faint, .corner_radius = .all(6) },
    });
}

fn slider(ui: *Ui, shell: *const Shell, id: zui.Id, name: []const u8, value: anytype, minimum: f64, maximum: f64, comptime format: []const u8) void {
    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
    defer ui.close();
    shell.label(ui, .caption, name);
    _ = shell.widgets.slider(ui, id, value, .{ .min = minimum, .max = maximum });
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(64) } } });
    shell.print(ui, .caption, format, .{value.*});
    ui.close();
}

fn legendRow(ui: *Ui, shell: *const Shell, name: []const u8, count: u32, color: zui.Color) void {
    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
    defer ui.close();
    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } }, .decoration = .{ .background = color, .corner_radius = .all(5) } });
    shell.label(ui, .body, name);
    shell.spacer(ui);
    shell.printColored(ui, .body, color, "{d}", .{count});
}
