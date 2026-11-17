//! The tour declaring a frame on `wasm32-freestanding`, as a browser's
//! worker will run it; `zig build check` links it, so the tour keeps
//! building without sokol.

const std = @import("std");
const zui_sokol_ui = @import("zui_sokol_ui");
const tour = @import("zui_sokol_tour");

export fn zuiSokolTourDeclaresAFrame() bool {
    declareFrame(std.heap.wasm_allocator, std.Io.failing) catch return false;
    return true;
}

fn declareFrame(gpa: std.mem.Allocator, io: std.Io) !void {
    var text: zui_sokol_ui.Text = .{};
    try tour.kit.addFonts(&text);
    var ui: tour.kit.Ui = try .init(gpa, io, &text);
    defer ui.deinit(gpa);
    const app = try gpa.create(tour.App);
    defer gpa.destroy(app);
    app.init(io, .zero);
    defer app.deinit();

    ui.beginFrame(&.{ .params = .{ .now = .zero, .viewport = .{ 1440, 900 } } }, &app.sources);
    app.declare(&ui);
    const frame = ui.endFrame();
    app.afterFrame(&ui);
    ui.release(frame);
}
