const std = @import("std");
const zui_sokol = @import("zui_sokol");
const zui = zui_sokol.zui;
const sokol = zui_sokol.sokol;
const sapp = sokol.app;
const sg = sokol.gfx;
const sglue = sokol.glue;
const showcase_module = @import("showcase.zig");

const Ui = zui.Context(zui_sokol.config(.{}));
const Showcase = showcase_module.Showcase(Ui);

const State = struct {
    io: std.Io,
    ui: Ui = undefined,
    text: zui_sokol.Text = .{},
    renderer: zui_sokol.Renderer = undefined,
    input: zui_sokol.InputCollector = .{},
    host_requests: zui_sokol.HostRequestApplier = .{},
    showcase: Showcase = .{ .title = "zui + sokol", .widgets = .{ .theme = .{} } },
    /// The frame drawn at every display refresh until zui needs a new one.
    shown_frame: ?*const Ui.Frame = null,
    shown_params: zui.FrameParams = .{ .now = .zero, .viewport = .{ 0, 0 } },
    next_frame: zui.NextFrame = .immediately,
    /// Quit after this many frames, for smoke tests.
    frame_limit: ?u64 = null,
    frames_drawn: u64 = 0,
    frames_declared: u64 = 0,

    fn from(userdata: ?*anyopaque) *State {
        return @ptrCast(@alignCast(userdata.?));
    }

    fn now(self: *const State) zui.Instant {
        return .fromTimestamp(std.Io.Timestamp.now(self.io, .awake));
    }

    /// sokol_app draws at every display refresh, but zui declares a frame
    /// only when one is due; the rest redraw the frame already shown.
    fn frameDue(self: *const State, params: zui.FrameParams) bool {
        if (self.shown_frame == null or self.input.event_count != 0) return true;
        if (!std.meta.eql(params.viewport, self.shown_params.viewport) or params.scale != self.shown_params.scale) return true;
        return switch (self.next_frame) {
            .immediately => true,
            .at => |deadline| !params.now.isBefore(deadline),
            .on_event => false,
        };
    }
};

fn onInit(userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = .from(userdata);
    sg.setup(.{ .environment = sglue.environment(), .logger = .{ .func = sokol.log.func } });
    state.renderer = .init();
}

fn onFrame(userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = .from(userdata);
    const dpi_scale = sapp.dpiScale();
    const params: zui.FrameParams = .{
        .now = state.now(),
        .viewport = .{ sapp.widthf() / dpi_scale, sapp.heightf() / dpi_scale },
        .scale = dpi_scale,
    };

    if (state.frameDue(params)) {
        state.ui.beginFrame(&.{ .params = params, .events = state.input.take() });
        state.showcase.declare(&state.ui);
        const frame = state.ui.endFrame();
        if (state.shown_frame) |previous| state.ui.release(previous);
        state.shown_frame = frame;
        state.shown_params = params;
        state.host_requests.apply(frame.requests());
        state.next_frame = state.ui.nextFrame();
        state.frames_declared += 1;
    }

    const background = state.showcase.palette.background;
    var clear: sg.PassAction = .{};
    clear.colors[0] = .{ .load_action = .CLEAR, .clear_value = .{
        .r = @as(f32, @floatFromInt(background.r)) / 255,
        .g = @as(f32, @floatFromInt(background.g)) / 255,
        .b = @as(f32, @floatFromInt(background.b)) / 255,
        .a = 1,
    } };
    sg.beginPass(.{ .action = clear, .swapchain = sglue.swapchain() });
    state.renderer.draw(Ui.RenderCommand, &state.text, state.shown_frame.?.commands(), state.shown_params, .{});
    sg.endPass();
    sg.commit();

    state.frames_drawn += 1;
    if (state.frame_limit) |limit| if (state.frames_drawn >= limit) sapp.requestQuit();
}

fn onEvent(event: [*c]const sapp.Event, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = .from(userdata);
    state.input.handleEvent(event, sapp.dpiScale(), state.now());
}

fn onCleanup(userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = .from(userdata);
    if (state.shown_frame) |frame| state.ui.release(frame);
    state.renderer.deinit();
    sg.shutdown();
}

pub fn main(init: std.process.Init) !void {
    var state: State = .{ .io = init.io };
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        if (std.mem.eql(u8, arguments[index], "--frames") and index + 1 < arguments.len) {
            index += 1;
            state.frame_limit = try std.fmt.parseInt(u64, arguments[index], 10);
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --frames <count>\n", .{arguments[index]});
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
        .width = 1100,
        .height = 700,
        .high_dpi = true,
        .sample_count = 4,
        .window_title = "zui + sokol",
        .logger = .{ .func = sokol.log.func },
    });
    if (state.frame_limit != null) std.debug.print("drew {d} frames, declared {d}, {d} layer overflows\n", .{ state.frames_drawn, state.frames_declared, state.renderer.layer_overflows });
}
