const std = @import("std");
const zui = @import("zui_sokol").zui;

/// Why the host declared a zui frame instead of redrawing the one it holds.
pub const FrameReason = enum {
    first,
    input,
    resize,
    requested,
    timer,
    source,

    pub fn describe(reason: FrameReason) []const u8 {
        return switch (reason) {
            .first => "first frame",
            .input => "input arrived",
            .resize => "window resized",
            .requested => "ui.requestFrame()",
            .timer => "requestFrameAt() came due",
            .source => "a source published",
        };
    }
};

/// What the host measured of each zui frame, kept for the HUD. The HUD
/// shows the frame before the one being declared, since a frame cannot
/// time its own declaration.
pub const Perf = struct {
    pub const history_length = 120;

    pub const Sample = struct {
        begin_frame_us: f32 = 0,
        declare_us: f32 = 0,
        end_frame_us: f32 = 0,
        elements: u32 = 0,
        commands: u32 = 0,
        measure_calls: u32 = 0,
        reason: FrameReason = .first,

        pub fn totalMicroseconds(sample: Sample) f32 {
            return sample.begin_frame_us + sample.declare_us + sample.end_frame_us;
        }
    };

    history: [history_length]Sample = @splat(.{}),
    newest: usize = history_length - 1,
    recorded: usize = 0,

    zui_frames: u64 = 0,
    display_frames: u64 = 0,
    submit_us: f32 = 0,
    display_fps: f32 = 0,
    measure_calls_total: u64 = 0,
    layer_overflows: u32 = 0,
    glyph_overflows: u32 = 0,
    wakes: u32 = 0,
    dropped_input_events: u32 = 0,
    diagnostics: zui.Diagnostics = .{},
    next_frame: zui.NextFrame = .immediately,
    next_frame_seconds: f32 = 0,

    pub fn record(self: *Perf, sample: Sample) void {
        self.newest = (self.newest + 1) % history_length;
        self.history[self.newest] = sample;
        self.recorded = @min(self.recorded + 1, history_length);
    }

    pub fn latest(self: *const Perf) Sample {
        return self.history[self.newest];
    }

    /// Oldest first, `history_length` long; unrecorded samples are zero.
    pub fn sampleAt(self: *const Perf, age_from_oldest: usize) Sample {
        return self.history[(self.newest + 1 + age_from_oldest) % history_length];
    }

    pub const Summary = struct { minimum: f32, average: f32, p95: f32, maximum: f32 };

    pub fn summarize(self: *const Perf) Summary {
        if (self.recorded == 0) return .{ .minimum = 0, .average = 0, .p95 = 0, .maximum = 0 };
        var totals: [history_length]f32 = undefined;
        var sum: f32 = 0;
        for (0..self.recorded) |age| {
            const total = self.history[(self.newest + history_length - age) % history_length].totalMicroseconds();
            totals[age] = total;
            sum += total;
        }
        const recorded_totals = totals[0..self.recorded];
        std.mem.sort(f32, recorded_totals, {}, std.sort.asc(f32));
        const p95_index = (self.recorded * 95) / 100;
        return .{
            .minimum = recorded_totals[0],
            .average = sum / @as(f32, @floatFromInt(self.recorded)),
            .p95 = recorded_totals[@min(p95_index, self.recorded - 1)],
            .maximum = recorded_totals[self.recorded - 1],
        };
    }
};
