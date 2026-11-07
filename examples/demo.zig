//! The zui tour, hosted by sokol_app.
//!
//! ```sh
//! zig build demo                                # interactive window
//! zig build demo -- --screen box_storm          # start on one screen
//! zig build demo -- --frames 600 --cycle 40     # visit every screen, 40 zui frames each, then quit
//! ```

const std = @import("std");
const zui_sokol = @import("zui_sokol");
const kit = @import("kit.zig");
const zui = kit.zui;
const Ui = kit.Ui;
const App = @import("app.zig").App;
const FrameReason = @import("perf.zig").FrameReason;
const sokol = zui_sokol.sokol;
const sapp = sokol.app;
const sg = sokol.gfx;
const sglue = sokol.glue;

const State = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    ui: Ui = undefined,
    text: zui_sokol.Text = .{},
    renderer: zui_sokol.Renderer = undefined,
    input: zui_sokol.InputCollector = .{},
    host_requests: zui_sokol.HostRequestApplier = .{},
    app: *App = undefined,
    /// The frame drawn at every display refresh until zui needs a new one.
    shown_frame: ?*const Ui.Frame = null,
    /// Quit after this many display frames, for smoke tests.
    frame_limit: ?u64 = null,
    events: [zui_sokol.InputCollector.event_capacity + 16]zui.Event = undefined,

    fn from(userdata: ?*anyopaque) *State {
        return @ptrCast(@alignCast(userdata.?));
    }

    fn now(self: *const State) zui.Instant {
        return kit.instantNow(self.io);
    }

    /// sokol_app draws at every display refresh, but zui declares a frame
    /// only when one is due; the rest redraw the frame already shown.
    fn frameReason(self: *State, params: zui.FrameParams) ?FrameReason {
        const shown_frame = self.shown_frame orelse return .first;
        if (self.input.event_count != 0 or self.app.environment_changes.count != 0) return .input;
        const shown = shown_frame.params;
        if (!std.meta.eql(params.viewport, shown.viewport) or params.scale != shown.scale or params.zoom != shown.zoom) return .resize;
        if (sourcesPending(&self.app.sources)) return .source;
        return switch (self.ui.nextFrame(&self.app.sources)) {
            .immediately => .requested,
            .at => |deadline| if (params.now.isBefore(deadline)) null else .timer,
            .on_event => null,
        };
    }

    /// The input since the last frame, then the environment changes the
    /// tour made up, as if the OS had reported them.
    fn takeEvents(self: *State) []const zui.Event {
        self.app.perf.dropped_input_events = self.input.dropped_events;
        const input_events = self.input.take();
        @memcpy(self.events[0..input_events.len], input_events);
        var count = input_events.len;
        for (self.app.environment_changes.drain()) |change| {
            if (count == self.events.len) break;
            self.events[count] = .{ .environment = change };
            count += 1;
        }
        return self.events[0..count];
    }

    fn declareFrame(self: *State, params: zui.FrameParams, reason: FrameReason) void {
        const perf = &self.app.perf;
        const measure_calls_before = self.ui.measureCalls();
        const events = self.takeEvents();

        const started = self.now();
        self.ui.beginFrame(&.{ .params = params, .events = events }, &self.app.sources);
        const began = self.now();
        self.app.declare(&self.ui);
        const declared = self.now();
        const frame = self.ui.endFrame();
        const ended = self.now();

        if (self.shown_frame) |previous| self.ui.release(previous);
        self.shown_frame = frame;
        self.host_requests.apply(frame.requests());
        self.app.afterFrame(&self.ui);

        const measure_calls = self.ui.measureCalls() - measure_calls_before;
        perf.record(.{
            .begin_frame_us = microsecondsBetween(started, began),
            .declare_us = microsecondsBetween(began, declared),
            .end_frame_us = microsecondsBetween(declared, ended),
            .elements = frame.elementCount(),
            .commands = @intCast(frame.commands().len),
            .measure_calls = @intCast(measure_calls),
            .reason = reason,
        });
        perf.zui_frames += 1;
        perf.measure_calls_total += measure_calls;
        perf.diagnostics = frame.diagnostics;
        perf.wakes = self.app.wakes.load(.monotonic);
        perf.next_frame = self.ui.nextFrame(&self.app.sources);
        perf.next_frame_seconds = switch (perf.next_frame) {
            .at => |deadline| deadline.secondsSince(ended),
            else => 0,
        };
    }
};

fn sourcesPending(sources: *const kit.Sources) bool {
    inline for (@typeInfo(kit.Sources).@"struct".fields) |field| {
        if (@field(sources, field.name).zuiPending()) return true;
    }
    return false;
}

fn microsecondsBetween(earlier: zui.Instant, later: zui.Instant) f32 {
    return later.secondsSince(earlier) * std.time.us_per_s;
}

fn onInit(userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = .from(userdata);
    sg.setup(.{ .environment = sglue.environment(), .logger = .{ .func = sokol.log.func } });
    state.renderer = .init(&state.text);
    state.renderer.clear_color = kit.Palette.dark.background;
}

fn onFrame(userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = .from(userdata);
    const perf = &state.app.perf;
    const dpi_scale = sapp.dpiScale();
    const zoom = state.app.zoom;
    const params: zui.FrameParams = .{
        .now = state.now(),
        .viewport = .{ sapp.widthf() / (dpi_scale * zoom), sapp.heightf() / (dpi_scale * zoom) },
        .scale = dpi_scale,
        .zoom = zoom,
    };

    if (state.frameReason(params)) |reason| state.declareFrame(params, reason);

    state.renderer.clear_color = kit.Palette.forEnvironment(state.ui.environment()).background;
    const submit_started = state.now();
    state.renderer.zuiSubmit(.library, state.shown_frame.?) catch unreachable;
    const submit_microseconds = microsecondsBetween(submit_started, state.now());
    perf.submit_us = if (perf.display_frames == 0) submit_microseconds else perf.submit_us * 0.95 + submit_microseconds * 0.05;
    perf.layer_overflows = state.renderer.layer_overflows;

    const frame_duration: f32 = @floatCast(sapp.frameDuration());
    if (frame_duration > 0) perf.display_fps = 1 / frame_duration;
    perf.display_frames += 1;
    if (state.frame_limit) |limit| if (perf.display_frames >= limit) sapp.requestQuit();
}

fn onEvent(event: [*c]const sapp.Event, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = .from(userdata);
    state.input.handleEvent(event, sapp.dpiScale() * state.app.zoom, state.now());
}

fn onCleanup(userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = .from(userdata);
    state.app.deinit();
    if (state.shown_frame) |frame| state.ui.release(frame);
    state.renderer.deinit();
    sg.shutdown();
}

fn parseScreen(name: []const u8) !kit.Screen {
    return std.meta.stringToEnum(kit.Screen, name) orelse {
        std.debug.print("unknown screen \"{s}\"; expected one of:", .{name});
        for (std.meta.fieldNames(kit.Screen)) |screen_name| std.debug.print(" {s}", .{screen_name});
        std.debug.print("\n", .{});
        return error.UnknownScreen;
    };
}

pub fn main(init: std.process.Init) !void {
    var state: State = .{ .io = init.io, .gpa = init.gpa };
    state.app = try init.gpa.create(App);
    defer init.gpa.destroy(state.app);
    state.app.init(init.io, state.now());

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        const has_value = index + 1 < arguments.len;
        if (std.mem.eql(u8, argument, "--frames") and has_value) {
            index += 1;
            state.frame_limit = try std.fmt.parseInt(u64, arguments[index], 10);
        } else if (std.mem.eql(u8, argument, "--screen") and has_value) {
            index += 1;
            state.app.current = try parseScreen(arguments[index]);
        } else if (std.mem.eql(u8, argument, "--cycle") and has_value) {
            index += 1;
            state.app.cycle_every = try std.fmt.parseInt(u32, arguments[index], 10);
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --frames <count>, --screen <name> or --cycle <zui frames>\n", .{argument});
            return error.UnknownArgument;
        }
    }

    state.ui = try Ui.init(init.gpa, init.io, &state.text);
    defer state.ui.deinit(init.gpa);

    sapp.run(.{
        .init_userdata_cb = onInit,
        .frame_userdata_cb = onFrame,
        .event_userdata_cb = onEvent,
        .cleanup_userdata_cb = onCleanup,
        .user_data = &state,
        .width = 1440,
        .height = 900,
        .high_dpi = true,
        .sample_count = 4,
        .window_title = "zui tour (sokol)",
        .logger = .{ .func = sokol.log.func },
    });
    if (state.frame_limit != null) {
        const perf = &state.app.perf;
        std.debug.print("drew {d} frames, declared {d}, {d} layer overflows, diagnostics ok: {}\n", .{ perf.display_frames, perf.zui_frames, perf.layer_overflows, perf.diagnostics.ok() });
    }
}
