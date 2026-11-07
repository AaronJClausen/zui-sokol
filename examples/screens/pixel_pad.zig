const std = @import("std");
const kit = @import("../kit.zig");
const zui = kit.zui;
const Ui = kit.Ui;
const Shell = kit.Shell;

const columns = 40;
const rows = 28;
const Canvas = [rows][columns]u8;
const canvas_id: zui.Id = .of("pad.canvas");
const empty: u8 = 0;

const palette_colors = [_]zui.Color{
    .rgb(0x000000), .rgb(0x1d2b53), .rgb(0x7e2553), .rgb(0x008751),
    .rgb(0xab5236), .rgb(0x5f574f), .rgb(0xc2c3c7), .rgb(0xfff1e8),
    .rgb(0xff004d), .rgb(0xffa300), .rgb(0xffec27), .rgb(0x00e436),
    .rgb(0x29adff), .rgb(0x83769c), .rgb(0xff77a8), .rgb(0xffccaa),
};

const Tool = enum {
    pencil,
    eraser,
    fill,

    fn key(tool: Tool) []const u8 {
        return switch (tool) {
            .pencil => "B",
            .eraser => "E",
            .fill => "F",
        };
    }
};

const KeyLogEntry = struct { event: zui.KeyEvent };

/// A zui heart, so the canvas never starts blank.
const starter_art = [_][]const u8{
    "..XX...XX..",
    ".XXXX.XXXX.",
    "XXXXXXXXXXX",
    "XXXXXXXXXXX",
    ".XXXXXXXXX.",
    "..XXXXXXX..",
    "...XXXXX...",
    "....XXX....",
    ".....X.....",
};

pub const PixelPad = struct {
    canvas: Canvas = @splat(@splat(empty)),
    undo_stack: [32]Canvas = undefined,
    undo_count: usize = 0,
    redo_stack: [32]Canvas = undefined,
    redo_count: usize = 0,
    color: u8 = 9,
    tool: Tool = .pencil,
    mirror: bool = false,
    grid_lines: bool = true,
    stroke_active: bool = false,
    last_cell: ?[2]i32 = null,
    strokes: u32 = 0,
    key_log: [14]KeyLogEntry = undefined,
    key_log_count: usize = 0,
    key_log_newest: usize = 0,
    typed: [96]u8 = undefined,
    typed_length: usize = 0,
    last_chord: []const u8 = "none yet",

    pub fn init(self: *PixelPad) void {
        for (starter_art, 0..) |art_row, row| for (art_row, 0..) |cell, column| {
            if (cell == 'X') self.canvas[row + 9][column + 14] = 9;
        };
    }

    pub fn declare(self: *PixelPad, ui: *Ui, shell: *const Shell) void {
        self.recordInput(ui);
        self.handleShortcuts(ui);
        self.paint(ui);

        ui.open(.{ .layout = .{ .sizing = .grow_both, .child_gap = 16 } });
        defer ui.close();
        self.toolbox(ui, shell);
        {
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 10, .child_alignment = .{ .x = .center, .y = .center } } });
            defer ui.close();
            self.canvasView(ui, shell);
            shell.print(ui, .caption, "{d}x{d} cells, one interactive element: the cell under the pointer comes from ui.pointerLocal(), not from {d} hit boxes.", .{ columns, rows, columns * rows });
        }
        self.inputInspector(ui, shell);
    }

    fn recordInput(self: *PixelPad, ui: *Ui) void {
        for (ui.keyEvents()) |event| {
            self.key_log_newest = (self.key_log_newest + 1) % self.key_log.len;
            self.key_log[self.key_log_newest] = .{ .event = event };
            self.key_log_count = @min(self.key_log_count + 1, self.key_log.len);
        }
        const typed = ui.typedText();
        if (typed.len != 0) {
            const keep = self.typed.len / 2;
            if (self.typed_length + typed.len > self.typed.len) {
                std.mem.copyForwards(u8, self.typed[0..keep], self.typed[self.typed_length - keep .. self.typed_length]);
                self.typed_length = keep;
            }
            const length = @min(typed.len, self.typed.len - self.typed_length);
            @memcpy(self.typed[self.typed_length..][0..length], typed[0..length]);
            self.typed_length += length;
        }
    }

    fn handleShortcuts(self: *PixelPad, ui: *Ui) void {
        const control: zui.Modifiers = .{ .control = true };
        const control_shift: zui.Modifiers = .{ .control = true, .shift = true };
        if (ui.chordPressed(.{ .key = .z, .modifiers = control })) {
            self.undo();
            self.last_chord = "Ctrl+Z  undo";
        }
        if (ui.chordPressed(.{ .key = .y, .modifiers = control }) or ui.chordPressed(.{ .key = .z, .modifiers = control_shift })) {
            self.redo();
            self.last_chord = "Ctrl+Y  redo";
        }
        if (ui.chordPressed(.{ .key = .delete, .modifiers = control })) {
            self.clear();
            self.last_chord = "Ctrl+Delete  clear";
        }
        if (ui.keyPressed(.b)) self.tool = .pencil;
        if (ui.keyPressed(.e)) self.tool = .eraser;
        if (ui.keyPressed(.f)) self.tool = .fill;
        if (ui.keyPressed(.m)) self.mirror = !self.mirror;
        if (ui.keyPressed(.g)) self.grid_lines = !self.grid_lines;
        if (ui.keyPressed(.left_bracket)) self.color = @intCast((self.color + palette_colors.len - 1) % palette_colors.len);
        if (ui.keyPressed(.right_bracket)) self.color = @intCast((self.color + 1) % palette_colors.len);
    }

    fn checkpoint(self: *PixelPad) void {
        if (self.undo_count == self.undo_stack.len) {
            std.mem.copyForwards(Canvas, self.undo_stack[0 .. self.undo_stack.len - 1], self.undo_stack[1..]);
            self.undo_count -= 1;
        }
        self.undo_stack[self.undo_count] = self.canvas;
        self.undo_count += 1;
        self.redo_count = 0;
    }

    fn undo(self: *PixelPad) void {
        if (self.undo_count == 0) return;
        self.undo_count -= 1;
        if (self.redo_count < self.redo_stack.len) {
            self.redo_stack[self.redo_count] = self.canvas;
            self.redo_count += 1;
        }
        self.canvas = self.undo_stack[self.undo_count];
    }

    fn redo(self: *PixelPad) void {
        if (self.redo_count == 0) return;
        self.redo_count -= 1;
        self.undo_stack[self.undo_count] = self.canvas;
        self.undo_count = @min(self.undo_count + 1, self.undo_stack.len);
        self.canvas = self.redo_stack[self.redo_count];
    }

    fn clear(self: *PixelPad) void {
        self.checkpoint();
        self.canvas = @splat(@splat(empty));
    }

    /// Strokes join the previous cell to this one, so a fast drag between
    /// two frames leaves no gaps.
    fn paint(self: *PixelPad, ui: *Ui) void {
        if (!ui.pressed(canvas_id)) {
            self.stroke_active = false;
            self.last_cell = null;
            return;
        }
        const cell = self.cellUnderPointer(ui) orelse return;
        if (!self.stroke_active) {
            self.stroke_active = true;
            self.strokes += 1;
            self.checkpoint();
        }
        const ink: u8 = if (self.tool == .eraser) empty else self.color + 1;
        if (self.tool == .fill) {
            self.floodFill(cell, ink);
        } else {
            self.line(self.last_cell orelse cell, cell, ink);
        }
        self.last_cell = cell;
    }

    fn cellUnderPointer(_: *PixelPad, ui: *Ui) ?[2]i32 {
        const local = ui.pointerLocal(canvas_id) orelse return null;
        const rect = ui.rectOf(canvas_id) orelse return null;
        const column: i32 = @intFromFloat(@floor(local[0] / rect.width * columns));
        const row: i32 = @intFromFloat(@floor(local[1] / rect.height * rows));
        return .{ std.math.clamp(column, 0, columns - 1), std.math.clamp(row, 0, rows - 1) };
    }

    fn line(self: *PixelPad, from: [2]i32, to: [2]i32, ink: u8) void {
        const delta_x: i32 = @intCast(@abs(to[0] - from[0]));
        const delta_y: i32 = -@as(i32, @intCast(@abs(to[1] - from[1])));
        const step_x: i32 = if (from[0] < to[0]) 1 else -1;
        const step_y: i32 = if (from[1] < to[1]) 1 else -1;
        var error_term = delta_x + delta_y;
        var point = from;
        while (true) {
            self.plot(point, ink);
            if (point[0] == to[0] and point[1] == to[1]) break;
            const doubled = 2 * error_term;
            if (doubled >= delta_y) {
                error_term += delta_y;
                point[0] += step_x;
            }
            if (doubled <= delta_x) {
                error_term += delta_x;
                point[1] += step_y;
            }
        }
    }

    fn plot(self: *PixelPad, cell: [2]i32, ink: u8) void {
        const column: usize = @intCast(cell[0]);
        const row: usize = @intCast(cell[1]);
        self.canvas[row][column] = ink;
        if (self.mirror) self.canvas[row][columns - 1 - column] = ink;
    }

    fn floodFill(self: *PixelPad, start: [2]i32, ink: u8) void {
        const target = self.canvas[@intCast(start[1])][@intCast(start[0])];
        if (target == ink) return;
        var stack: [columns * rows][2]i32 = undefined;
        var depth: usize = 1;
        stack[0] = start;
        while (depth > 0) {
            depth -= 1;
            const cell = stack[depth];
            if (cell[0] < 0 or cell[1] < 0 or cell[0] >= columns or cell[1] >= rows) continue;
            const value = &self.canvas[@intCast(cell[1])][@intCast(cell[0])];
            if (value.* != target) continue;
            value.* = ink;
            for ([_][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |offset| {
                if (depth < stack.len) {
                    stack[depth] = .{ cell[0] + offset[0], cell[1] + offset[1] };
                    depth += 1;
                }
            }
        }
    }

    fn toolbox(self: *PixelPad, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        shell.openScrollingCard(ui, .of("pad.tools"), "Tools", .{ .width = .fixed(200), .height = .grow });
        defer ui.close();
        for (std.enums.values(Tool)) |tool| {
            const id: zui.Id = .indexed("pad.tool", @intFromEnum(tool));
            if (ui.clicked(id)) self.tool = tool;
            const selected = self.tool == tool;
            ui.open(.{
                .id = id,
                .focusable = true,
                .cursor = .pointer,
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(32) }, .padding = .symmetric(10, 0), .child_alignment = .{ .y = .center } },
                .decoration = .{
                    .background = if (selected) palette.accent else if (ui.hovered(id)) palette.hovered else palette.raised,
                    .border = if (ui.focused(id)) .{ .color = palette.focus, .widths = .all(1) } else null,
                    .corner_radius = .all(6),
                },
            });
            shell.labelColored(ui, .body, if (selected) palette.on_accent else palette.text, @tagName(tool));
            shell.spacer(ui);
            shell.labelColored(ui, .caption, if (selected) palette.on_accent else palette.faint, tool.key());
            ui.close();
        }
        _ = shell.widgets.checkbox(ui, .of("pad.mirror"), "Mirror  (M)", &self.mirror, .{});
        _ = shell.widgets.checkbox(ui, .of("pad.grid"), "Grid lines  (G)", &self.grid_lines, .{});
        shell.label(ui, .caption, "COLOR  ([ and ])");
        for (0..4) |swatch_row| {
            ui.open(.{ .layout = .{ .child_gap = 6 } });
            defer ui.close();
            for (0..4) |swatch_column| {
                const index = swatch_row * 4 + swatch_column;
                const id: zui.Id = .indexed("pad.swatch", index);
                if (ui.clicked(id)) self.color = @intCast(index);
                const selected = self.color == index;
                ui.box(.{
                    .id = id,
                    .interactive = true,
                    .cursor = .pointer,
                    .layout = .{ .sizing = .{ .width = .fixed(38), .height = .fixed(30) } },
                    .decoration = .{
                        .background = palette_colors[index],
                        .border = .{ .color = if (selected) palette.focus else palette.border, .widths = .all(if (selected) 3 else 1) },
                        .corner_radius = .all(if (selected) 10 else 4),
                    },
                });
            }
        }
        shell.spacer(ui);
        ui.open(.{ .layout = .{ .child_gap = 6 } });
        if (shell.widgets.button(ui, .of("pad.undo"), "Undo", .{ .disabled = self.undo_count == 0 })) self.undo();
        if (shell.widgets.button(ui, .of("pad.redo"), "Redo", .{ .disabled = self.redo_count == 0 })) self.redo();
        if (shell.widgets.button(ui, .of("pad.clear"), "Clear", .{})) self.clear();
        ui.close();
        shell.print(ui, .caption, "{d} strokes, {d} undo steps", .{ self.strokes, self.undo_count });
    }

    fn canvasView(self: *PixelPad, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        const hover_cell = if (ui.hovered(canvas_id)) self.cellUnderPointer(ui) else null;
        const gap: f32 = if (self.grid_lines) 1 else 0;
        const cell_size = cellSizeFitting(ui.viewport(), gap);
        const background = palette.sunken.mix(palette.surface, 0.5);
        ui.open(.{
            .id = canvas_id,
            .interactive = true,
            .cursor = .crosshair,
            .layout = .{ .direction = .top_to_bottom, .padding = .all(gap), .child_gap = gap },
            .decoration = .{ .background = if (self.grid_lines) palette.border else background, .corner_radius = .all(4) },
        });
        defer ui.close();
        for (self.canvas, 0..) |cells, row| {
            ui.open(.{ .layout = .{ .child_gap = gap } });
            defer ui.close();
            for (cells, 0..) |cell, column| {
                const hovered = if (hover_cell) |hover| hover[0] == column and hover[1] == row else false;
                const mirrored_hover = if (hover_cell) |hover| self.mirror and columns - 1 - @as(usize, @intCast(hover[0])) == column and hover[1] == row else false;
                var color = if (cell == empty) background else palette_colors[cell - 1];
                if (hovered or mirrored_hover) color = color.mix(if (self.tool == .eraser) background else palette_colors[self.color], 0.6);
                ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(cell_size), .height = .fixed(cell_size) } }, .decoration = .{ .background = color } });
            }
        }
    }

    /// The largest whole cell that fits beside the two side cards, from the
    /// viewport rather than the canvas's own rectangle, which the cells
    /// themselves size.
    fn cellSizeFitting(viewport: [2]f32, gap: f32) f32 {
        const chrome_width = 236 + 32 + 200 + 310 + 32 + 16;
        const chrome_height = 60 + 78 + 32 + 60;
        const width_per_cell = (viewport[0] - chrome_width) / columns - gap;
        const height_per_cell = (viewport[1] - chrome_height) / rows - gap;
        return std.math.clamp(@floor(@min(width_per_cell, height_per_cell)), 6, 24);
    }

    fn inputInspector(self: *PixelPad, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        shell.openScrollingCard(ui, .of("pad.input"), "Input, as zui sees it", .{ .width = .fixed(310), .height = .grow });
        defer ui.close();
        if (ui.primaryPointer()) |pointer| {
            shell.print(ui, .body, "pointer .{t} at {d:.0}, {d:.0}", .{ pointer.kind, pointer.position[0], pointer.position[1] });
            if (ui.pointerLocal(canvas_id)) |local| shell.print(ui, .caption, "canvas-local {d:.1}, {d:.1}  pressure {d:.2}", .{ local[0], local[1], pointer.pressure });
        } else shell.labelColored(ui, .body, palette.muted, "no pointer over the window");
        shell.print(ui, .caption, "canvas: .{t}", .{ui.widgetState(canvas_id)});
        shell.printColored(ui, .body, palette.accent, "last chord: {s}", .{self.last_chord});
        shell.divider(ui);
        shell.label(ui, .caption, "KEY EVENTS, NEWEST FIRST (ui.keyEvents)");
        for (0..self.key_log_count) |age| {
            const entry = self.key_log[(self.key_log_newest + self.key_log.len - age) % self.key_log.len];
            const modifiers = entry.event.modifiers;
            shell.printColored(ui, .caption, if (age == 0) palette.text else palette.muted, "{s}{s}{s}{s}{t}{s}  scancode {d}", .{
                if (modifiers.control) "Ctrl+" else "",
                if (modifiers.shift) "Shift+" else "",
                if (modifiers.alt) "Alt+" else "",
                if (modifiers.super) "Super+" else "",
                entry.event.key,
                if (entry.event.repeat) " (repeat)" else "",
                entry.event.scancode,
            });
        }
        shell.divider(ui);
        shell.label(ui, .caption, "TYPED TEXT (ui.typedText)");
        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .padding = .all(8) }, .decoration = .{ .background = palette.sunken, .corner_radius = .all(6) } });
        shell.labelColored(ui, .body, palette.good, if (self.typed_length == 0) "type anything..." else self.typed[0..self.typed_length]);
        ui.close();
    }
};
