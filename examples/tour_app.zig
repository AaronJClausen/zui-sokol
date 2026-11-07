//! The tour's application, for a loop other than sokol_app's to run, as
//! zui-host's Windows demo does: `b.dependency("zui_sokol", .{ .gl = true })
//! .module("zui_sokol_tour")`.

pub const App = @import("app.zig").App;
pub const kit = @import("kit.zig");
pub const FrameReason = @import("perf.zig").FrameReason;
