const std = @import("std");
const zui_sokol = @import("zui_sokol");
const zui = zui_sokol.zui;
const sokol = zui_sokol.sokol;
const sapp = sokol.app;
const sg = sokol.gfx;
const sglue = sokol.glue;
const showcase_module = @import("showcase.zig");

const Ui = zui.Context(zui_sokol.config(.{}), zui_sokol.Platform);
const Showcase = showcase_module.Showcase(Ui);

const State = struct {
    ui: Ui = undefined,
    platform: zui_sokol.Platform = .{},
    renderer: zui_sokol.Renderer = undefined,
    input: zui_sokol.InputCollector = .{},
    showcase: Showcase = .{ .title = "zui + sokol", .widgets = .{ .theme = .{} } },
    /// Quit after this many frames, for smoke tests.
    frame_limit: ?u64 = null,
    frames_drawn: u64 = 0,

    fn from(userdata: ?*anyopaque) *State {
        return @ptrCast(@alignCast(userdata.?));
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
    state.platform.dpi_scale = dpi_scale;
    const viewport: [2]f32 = .{ sapp.widthf() / dpi_scale, sapp.heightf() / dpi_scale };

    state.ui.beginFrame(state.input.take(viewport, @floatCast(sapp.frameDuration())));
    state.showcase.declare(&state.ui);
    const frame = state.ui.endFrame() catch state.ui.lastFrame();
    defer state.ui.release(frame);

    const background = state.showcase.palette.background;
    var clear: sg.PassAction = .{};
    clear.colors[0] = .{ .load_action = .CLEAR, .clear_value = .{
        .r = @as(f32, @floatFromInt(background.r)) / 255,
        .g = @as(f32, @floatFromInt(background.g)) / 255,
        .b = @as(f32, @floatFromInt(background.b)) / 255,
        .a = 1,
    } };
    sg.beginPass(.{ .action = clear, .swapchain = sglue.swapchain() });
    state.renderer.draw(Ui.RenderCommand, &state.platform, frame.commands(), viewport, .{});
    sg.endPass();
    sg.commit();

    state.frames_drawn += 1;
    if (state.frame_limit) |limit| if (state.frames_drawn >= limit) sapp.requestQuit();
}

fn onEvent(event: [*c]const sapp.Event, userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = .from(userdata);
    state.input.handleEvent(event, sapp.dpiScale());
}

fn onCleanup(userdata: ?*anyopaque) callconv(.c) void {
    const state: *State = .from(userdata);
    state.renderer.deinit();
    sg.shutdown();
}

pub fn main(init: std.process.Init) !void {
    var state: State = .{};
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

    state.ui = try Ui.init(init.gpa, init.io, &state.platform);
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
    if (state.frame_limit != null) std.debug.print("drew {d} frames, {d} layer overflows\n", .{ state.frames_drawn, state.renderer.layer_overflows });
}
