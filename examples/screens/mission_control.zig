const std = @import("std");
const kit = @import("../kit.zig");
const zui = kit.zui;
const zui_async = kit.zui_async;
const Ui = kit.Ui;
const Shell = kit.Shell;

pub const Telemetry = struct {
    altitude_km: f32,
    velocity_km_s: f32,
    hull_celsius: f32,
    battery: f32,
    sample: u64,
};

pub const LogLine = struct {
    pub const Level = enum { info, warn, alarm };

    bytes: [80]u8 = undefined,
    len: u8 = 0,
    level: Level = .info,

    pub fn text(self: *const LogLine) []const u8 {
        return self.bytes[0..self.len];
    }

    fn init(level: Level, comptime format: []const u8, arguments: anytype) LogLine {
        var line: LogLine = .{ .level = level };
        const written: []const u8 = std.fmt.bufPrint(&line.bytes, format, arguments) catch "";
        line.len = @intCast(written.len);
        return line;
    }
};

pub const LaunchError = error{ Canceled, EngineFlameout, WeatherScrub };
pub const LaunchReport = struct { apogee_km: f32, seconds: f32 };

pub const TelemetrySource = zui_async.Latest(Telemetry);
/// The steady chatter and a burst publish at once, hence `.many`.
pub const LogSource = zui_async.Stream(LogLine, .{ .capacity = 64, .producers = .many });
pub const LaunchTask = zui_async.Task(LaunchError!LaunchReport, .{ .Progress = f32 });

/// A producer that runs only while the UI reads its source.
const DemandedProducer = struct {
    const Phase = enum(u8) { stopped, running, stopping };

    phase: std.atomic.Value(Phase) = .init(.stopped),

    /// UI thread. Returns true when the caller must start the producer.
    fn demand(self: *DemandedProducer) bool {
        while (true) switch (self.phase.load(.acquire)) {
            .running => return false,
            .stopping => if (self.phase.cmpxchgWeak(.stopping, .running, .acq_rel, .acquire) == null) return false,
            .stopped => {
                self.phase.store(.running, .release);
                return true;
            },
        };
    }

    /// UI thread.
    fn release(self: *DemandedProducer) void {
        _ = self.phase.cmpxchgStrong(.running, .stopping, .acq_rel, .acquire);
    }

    /// Producer thread: false once it should exit, after which it must not publish.
    fn keepGoing(self: *DemandedProducer) bool {
        while (true) switch (self.phase.load(.acquire)) {
            .running => return true,
            .stopping => if (self.phase.cmpxchgStrong(.stopping, .stopped, .acq_rel, .acquire) == null) return false,
            .stopped => return false,
        };
    }
};

const history_length = 120;
const kept_log_lines = 200;

pub const MissionControl = struct {
    tasks: std.Io.Group = .init,
    telemetry_producer: DemandedProducer = .{},
    chatter_producer: DemandedProducer = .{},
    telemetry_hertz: std.atomic.Value(u32) = .init(30),
    chatter_per_second: std.atomic.Value(u32) = .init(4),

    telemetry_samples_seen: u64 = 0,
    altitude_history: [history_length]f32 = @splat(0),
    history_newest: usize = 0,

    log: [kept_log_lines]LogLine = undefined,
    log_newest: usize = 0,
    log_count: usize = 0,
    log_received: u64 = 0,
    follow_log: bool = true,
    bursts: u32 = 0,

    launch_attempts: u32 = 0,
    storm_chance: u32 = 15,
    last_launch_progress: f32 = 0,

    pub fn declare(self: *MissionControl, ui: *Ui, shell: *const Shell) void {
        ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 16 } });
        defer ui.close();
        self.telemetryPanel(ui, shell);
        self.launchPanel(ui, shell);
        self.logPanel(ui, shell);
    }

    fn telemetryPanel(self: *MissionControl, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        const telemetry = ui.source(.telemetry);
        if (telemetry.changed()) if (telemetry.get()) |reading| {
            self.telemetry_samples_seen += 1;
            self.history_newest = (self.history_newest + 1) % history_length;
            self.altitude_history[self.history_newest] = reading.altitude_km;
        };

        shell.openScrollingCard(ui, .of("mission.telemetry"), "Telemetry  (Latest)", .{ .width = .fixed(300), .height = .grow });
        defer ui.close();
        shell.label(ui, .caption, "A thread publishes the newest reading; frames in between that it overwrote are simply skipped. It runs only while this screen reads it.");
        var hertz = self.telemetry_hertz.load(.monotonic);
        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
        if (shell.widgets.slider(ui, .of("mission.hertz"), &hertz, .{ .min = 1, .max = 240 })) self.telemetry_hertz.store(hertz, .monotonic);
        shell.print(ui, .body, "{d} Hz", .{hertz});
        ui.close();

        const reading = telemetry.get() orelse {
            shell.labelColored(ui, .body, palette.muted, "waiting for the first reading...");
            return;
        };
        gauge(ui, shell, "altitude", reading.altitude_km, "{d:.2} km", (reading.altitude_km - 400) / 40 + 0.5, palette.accent);
        gauge(ui, shell, "velocity", reading.velocity_km_s, "{d:.3} km/s", (reading.velocity_km_s - 7.6) * 4 + 0.5, palette.good);
        gauge(ui, shell, "hull", reading.hull_celsius, "{d:.1} C", (reading.hull_celsius + 120) / 240, palette.warn);
        gauge(ui, shell, "battery", reading.battery * 100, "{d:.0}%", reading.battery, if (reading.battery < 0.3) palette.bad else palette.good);

        shell.label(ui, .caption, "ALTITUDE, ONE BAR PER READING THE UI SAW");
        {
            ui.open(.{
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(90) }, .padding = .all(4), .child_gap = 1, .child_alignment = .{ .y = .end } },
                .decoration = .{ .background = palette.sunken, .corner_radius = .all(6) },
                .clip = .both,
            });
            defer ui.close();
            for (0..history_length) |age| {
                const value = self.altitude_history[(self.history_newest + 1 + age) % history_length];
                const fraction = std.math.clamp((value - 380) / 40, 0.02, 1);
                ui.box(.{ .layout = .{ .sizing = .{ .width = .growWeighted(1), .height = .percent(fraction) } }, .decoration = .{ .background = palette.accent.mix(palette.good, fraction) } });
            }
        }
        shell.print(ui, .caption, "sample #{d} published, {d} seen by the UI", .{ reading.sample, self.telemetry_samples_seen });
        shell.print(ui, .caption, "framesSinceRead(.telemetry) = {d}", .{ui.framesSinceRead(.telemetry)});
    }

    fn launchPanel(self: *MissionControl, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        const widgets = shell.widgets;
        const launch = ui.source(.launch);
        const status = launch.status();
        if (status == .running) self.last_launch_progress = status.running;

        shell.openCard(ui, "Launch  (Task)", .{ .width = .grow, .height = .grow });
        defer ui.close();
        {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 10, .child_alignment = .{ .y = .center } } });
            defer ui.close();
            const running = status == .running;
            if (widgets.button(ui, .of("mission.launch"), if (self.launch_attempts == 0) "Launch" else "Again", .{ .disabled = running })) {
                if (shell.sources.launch.begin(shell.waker)) |run| {
                    self.launch_attempts += 1;
                    self.tasks.concurrent(shell.io, runLaunch, .{ shell.io, run, self.storm_chance, self.launch_attempts }) catch run.finish(error.Canceled);
                } else |_| {}
            }
            if (widgets.button(ui, .of("mission.abort"), "Abort", .{ .disabled = !running })) shell.sources.launch.abandon();
            shell.label(ui, .caption, "storms");
            _ = widgets.slider(ui, .of("mission.storm"), &self.storm_chance, .{ .min = 0, .max = 100 });
            shell.print(ui, .caption, "{d}%", .{self.storm_chance});
        }

        const progress: f32 = switch (status) {
            .idle => 0,
            .running => |fraction| fraction,
            .ready => 1,
            .failed, .canceled => self.last_launch_progress,
        };
        launchScene(ui, shell, status, progress);

        switch (status) {
            .idle => shell.labelColored(ui, .body, palette.muted, "On the pad. Press Launch: a thread runs the countdown and reports progress; the UI only reads the task's status."),
            .running => |fraction| shell.printColored(ui, .body, palette.accent, "{s}  ({d:.0}%)", .{ phaseName(fraction), fraction * 100 }),
            .ready => |report| shell.printColored(ui, .body, palette.good, "Orbit reached: apogee {d:.0} km after {d:.1} s.", .{ report.apogee_km, report.seconds }),
            .failed => |err| shell.printColored(ui, .body, palette.bad, "Mission failed at {d:.0}%: {t}", .{ self.last_launch_progress * 100, err }),
            .canceled => shell.printColored(ui, .body, palette.warn, "Aborted by the flight director at {d:.0}%. The thread saw run.abandoned() and stopped.", .{self.last_launch_progress * 100}),
        }
        shell.meter(ui, progress, switch (status) {
            .failed => palette.bad,
            .canceled => palette.warn,
            .ready => palette.good,
            else => palette.accent,
        }, 10);
    }

    fn logPanel(self: *MissionControl, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        const widgets = shell.widgets;
        var items = ui.source(.mission_log).items();
        var received_now: usize = 0;
        while (items.next()) |line| {
            self.keepLine(line.*);
            received_now += 1;
        }

        shell.openCard(ui, "Comms  (Stream)", .{ .width = .fixed(360), .height = .grow });
        defer ui.close();
        shell.label(ui, .caption, "Every line, in order. The ring holds 64; a burst of 300 overflows it, and the frame's diagnostics report the refusals.");
        {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
            defer ui.close();
            var rate = self.chatter_per_second.load(.monotonic);
            if (widgets.slider(ui, .of("mission.chatter"), &rate, .{ .min = 0, .max = 60 })) self.chatter_per_second.store(rate, .monotonic);
            shell.print(ui, .caption, "{d}/s", .{rate});
            if (widgets.button(ui, .of("mission.burst"), "Burst x300", .{})) {
                self.bursts += 1;
                self.tasks.concurrent(shell.io, publishBurst, .{ shell.sources, shell.waker, self.bursts }) catch {};
            }
        }
        _ = widgets.checkbox(ui, .of("mission.follow"), "Follow newest", &self.follow_log, .{});
        shell.print(ui, .caption, "{d} received ({d} this frame), {d} refused so far this frame", .{ self.log_received, received_now, shell.perf.diagnostics.refused_publishes });

        const log_id: zui.Id = .of("mission.log");
        if (self.follow_log and received_now != 0) ui.setScrollOffset(log_id, .{ 0, std.math.floatMax(f32) });
        ui.open(.{
            .id = log_id,
            .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(8), .child_gap = 2 },
            .decoration = .{ .background = palette.sunken, .corner_radius = .all(6) },
            .scroll = .{},
        });
        defer ui.close();
        for (0..self.log_count) |age| {
            const line = &self.log[(self.log_newest + kept_log_lines - self.log_count + 1 + age) % kept_log_lines];
            const color = switch (line.level) {
                .info => palette.muted,
                .warn => palette.warn,
                .alarm => palette.bad,
            };
            ui.text(line.text(), .{ .size = 12 * shell.text_scale, .color = color, .font = 1 });
        }
    }

    fn keepLine(self: *MissionControl, line: LogLine) void {
        self.log_newest = (self.log_newest + 1) % kept_log_lines;
        self.log[self.log_newest] = line;
        self.log_count = @min(self.log_count + 1, kept_log_lines);
        self.log_received += 1;
    }

    /// Starts the producers whose sources this frame read and stops those
    /// it no longer reads, so leaving the screen lets zui sleep again.
    pub fn afterFrame(self: *MissionControl, ui: *Ui, shell: *const Shell) void {
        const unread_frames_before_stopping = 2;
        if (ui.framesSinceRead(.telemetry) <= unread_frames_before_stopping) {
            if (self.telemetry_producer.demand()) self.tasks.concurrent(shell.io, produceTelemetry, .{ shell.io, &self.telemetry_producer, shell.sources, shell.waker, &self.telemetry_hertz }) catch {
                self.telemetry_producer.release();
                _ = self.telemetry_producer.keepGoing();
            };
        } else self.telemetry_producer.release();

        if (ui.framesSinceRead(.mission_log) <= unread_frames_before_stopping) {
            if (self.chatter_producer.demand()) self.tasks.concurrent(shell.io, produceChatter, .{ shell.io, &self.chatter_producer, shell.sources, shell.waker, &self.chatter_per_second }) catch {
                self.chatter_producer.release();
                _ = self.chatter_producer.keepGoing();
            };
        } else self.chatter_producer.release();
    }

    pub fn deinit(self: *MissionControl, io: std.Io) void {
        self.tasks.cancel(io);
    }
};

fn gauge(ui: *Ui, shell: *const Shell, name: []const u8, value: f32, comptime format: []const u8, fraction: f32, color: zui.Color) void {
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .child_gap = 3 } });
    defer ui.close();
    ui.open(.{ .layout = .{ .sizing = .{ .width = .grow } } });
    shell.label(ui, .caption, name);
    shell.spacer(ui);
    shell.printColored(ui, .heading, color, format, .{value});
    ui.close();
    shell.meter(ui, fraction, color, 6);
}

fn phaseName(progress: f32) []const u8 {
    if (progress < 0.25) return "Countdown";
    if (progress < 0.32) return "Ignition";
    if (progress < 0.45) return "Liftoff";
    if (progress < 0.6) return "Max Q";
    if (progress < 0.8) return "Stage separation";
    return "Orbital insertion";
}

/// Sky, pad and a rocket of boxes whose height above the pad follows the
/// task's progress.
fn launchScene(ui: *Ui, shell: *const Shell, status: LaunchTask.Status, progress: f32) void {
    const palette = shell.palette;
    const flight = std.math.clamp((progress - 0.3) / 0.7, 0, 1);
    const sky = kit.hueColor(0.6, 0.6, 0.55 - 0.45 * flight);
    ui.open(.{
        .id = .of("mission.sky"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_alignment = .{ .x = .center } },
        .decoration = .{ .background = sky, .corner_radius = .all(8) },
        .clip = .both,
    });
    defer ui.close();
    const scene_height = (ui.rectOf(.of("mission.sky")) orelse zui.Rect{ .height = 400 }).height;
    const rocket_height: f32 = 120;
    const travel = @max(0, scene_height - rocket_height - 40);
    const rocket_top = travel * (1 - flight * flight);
    ui.box(.{ .layout = .{ .sizing = .{ .height = .fixed(rocket_top) } } });

    const exploded = status == .failed;
    if (exploded) {
        for ([_]f32{ 70, 50, 30 }, 0..) |size, index| {
            ui.box(.{
                .layout = .{ .sizing = .{ .width = .fixed(size), .height = .fixed(size * 0.6) } },
                .decoration = .{ .background = kit.hueColor(0.02 + @as(f32, @floatFromInt(index)) * 0.04, 0.9, 1), .corner_radius = .all(size / 2) },
            });
        }
    } else {
        rocket(ui, shell, status == .running and progress > 0.25);
    }
    shell.spacer(ui);
    ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(18) } }, .decoration = .{ .background = palette.faint } });
}

fn rocket(ui: *Ui, shell: *const Shell, burning: bool) void {
    const white: zui.Color = .rgb(0xf2f2f6);
    const red: zui.Color = .rgb(0xe0453a);
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .child_alignment = .{ .x = .center } } });
    defer ui.close();
    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(20), .height = .fixed(22) } }, .decoration = .{ .background = red, .corner_radius = .{ .top_left = 10, .top_right = 10 } } });
    ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(20), .height = .fixed(52) }, .padding = .{ .top = 10 }, .child_alignment = .{ .x = .center } }, .decoration = .{ .background = white } });
    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(10) } }, .decoration = .{ .background = kit.hueColor(0.55, 0.6, 0.9), .border = .{ .color = .rgb(0x7a7a8a), .widths = .all(2) }, .corner_radius = .all(5) } });
    ui.close();
    ui.open(.{ .layout = .{ .child_gap = 20 } });
    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(14) } }, .decoration = .{ .background = red, .corner_radius = .{ .top_right = 10 } } });
    ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(10), .height = .fixed(14) } }, .decoration = .{ .background = red, .corner_radius = .{ .top_left = 10 } } });
    ui.close();
    if (burning) {
        const flicker = 0.5 + 0.5 * @sin(shell.motionSeconds() * 40);
        ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(14), .height = .fixed(18 + 14 * flicker) } }, .decoration = .{ .background = kit.hueColor(0.08 + 0.05 * flicker, 0.9, 1), .corner_radius = .{ .bottom_left = 7, .bottom_right = 7 } } });
    }
}

fn produceTelemetry(io: std.Io, producer: *DemandedProducer, sources: *kit.Sources, waker: zui.Waker, hertz: *const std.atomic.Value(u32)) std.Io.Cancelable!void {
    var sample: u64 = 0;
    var seconds: f32 = 0;
    var prng: std.Random.DefaultPrng = .init(0xC0FFEE);
    while (producer.keepGoing()) {
        sample += 1;
        const reading: Telemetry = .{
            .altitude_km = 400 + 14 * @sin(seconds * 0.7) + 3 * @sin(seconds * 2.9) + prng.random().floatNorm(f32) * 0.4,
            .velocity_km_s = 7.66 + 0.04 * @cos(seconds * 0.7),
            .hull_celsius = 80 * @sin(seconds * 0.21) + prng.random().floatNorm(f32),
            .battery = 0.55 + 0.4 * @sin(seconds * 0.11),
            .sample = sample,
        };
        waker.wakeIf(sources.telemetry.publish(reading));
        const period_seconds = 1 / @as(f32, @floatFromInt(@max(1, hertz.load(.monotonic))));
        try io.sleep(.fromNanoseconds(@intFromFloat(period_seconds * std.time.ns_per_s)), .awake);
        seconds += period_seconds;
    }
}

const chatter_lines = [_]struct { LogLine.Level, []const u8 }{
    .{ .info, "GNC: attitude hold nominal" },
    .{ .info, "COMMS: downlink margin +6.1 dB" },
    .{ .info, "EECOM: cabin pressure 101.2 kPa" },
    .{ .info, "FIDO: state vector uplinked" },
    .{ .warn, "THERMAL: radiator loop B drifting" },
    .{ .info, "PAO: crew says hi to the zui team" },
    .{ .warn, "POWER: bus 2 ripple above spec" },
    .{ .alarm, "MASTER ALARM: someone microwaved fish" },
    .{ .info, "SURGEON: crew heart rates nominal" },
};

fn produceChatter(io: std.Io, producer: *DemandedProducer, sources: *kit.Sources, waker: zui.Waker, per_second: *const std.atomic.Value(u32)) std.Io.Cancelable!void {
    var prng: std.Random.DefaultPrng = .init(0xBEEF);
    const random = prng.random();
    var sequence: u32 = 0;
    while (producer.keepGoing()) {
        const rate = per_second.load(.monotonic);
        if (rate == 0) {
            try io.sleep(.fromMilliseconds(100), .awake);
            continue;
        }
        sequence += 1;
        const entry = chatter_lines[random.uintLessThan(usize, chatter_lines.len)];
        const line: LogLine = .init(entry[0], "{d:0>5} {s}", .{ sequence, entry[1] });
        waker.wakeIf(sources.mission_log.publish(line) catch .already_pending);
        const mean_gap_milliseconds = 1000 / @as(f32, @floatFromInt(rate));
        const jittered = mean_gap_milliseconds * (0.5 + random.float(f32));
        try io.sleep(.fromMilliseconds(@intFromFloat(jittered)), .awake);
    }
}

fn publishBurst(sources: *kit.Sources, waker: zui.Waker, burst: u32) void {
    for (0..300) |index| {
        const line: LogLine = .init(.warn, "BURST {d}: packet {d:0>3}/300", .{ burst, index + 1 });
        waker.wakeIf(sources.mission_log.publish(line) catch .already_pending);
    }
}

fn runLaunch(io: std.Io, run: LaunchTask.Run, storm_chance: u32, attempt: u32) void {
    run.finish(fly(io, run, storm_chance, attempt));
}

fn fly(io: std.Io, run: LaunchTask.Run, storm_chance: u32, attempt: u32) LaunchError!LaunchReport {
    var prng: std.Random.DefaultPrng = .init(@as(u64, attempt) *% 0x9E3779B97F4A7C15);
    const random = prng.random();
    const flameout_at: f32 = if (random.uintLessThan(u32, 100) < 12) 0.35 + random.float(f32) * 0.5 else 2;
    const steps = 240;
    for (0..steps) |step| {
        if (run.abandoned()) return error.Canceled;
        const progress = @as(f32, @floatFromInt(step)) / steps;
        if (step == 30 and random.uintLessThan(u32, 100) < storm_chance) return error.WeatherScrub;
        if (progress >= flameout_at) return error.EngineFlameout;
        run.progress(progress);
        io.sleep(.fromMilliseconds(30), .awake) catch return error.Canceled;
    }
    return .{ .apogee_km = 380 + random.float(f32) * 60, .seconds = steps * 0.03 };
}
