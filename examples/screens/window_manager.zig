const std = @import("std");
const kit = @import("../kit.zig");
const zui = kit.zui;
const zui_widgets = kit.zui_widgets;
const Ui = kit.Ui;
const Shell = kit.Shell;

const desktop_id: zui.Id = .of("wm.desktop");
const anchor_target_id: zui.Id = .of("wm.anchor_target");
const modal_first_field_id: zui.Id = .of("wm.modal.callsign");

const Kind = enum { notes, mixer, anchors, focus };

const Window = struct {
    kind: Kind,
    title: []const u8,
    width: f32,
    /// Relative to the desktop's top-left corner.
    position: [2]f32,
    open: bool = true,
};

const Channel = struct { name: []const u8, level: f32, muted: bool = false };

const anchor_names = [_][]const u8{ "top left", "top center", "top right", "center left", "center", "center right", "bottom left", "bottom center", "bottom right" };

pub const WindowManager = struct {
    windows: [4]Window = .{
        .{ .kind = .notes, .title = "Sticky notes", .width = 300, .position = .{ 24, 24 } },
        .{ .kind = .mixer, .title = "Mixer", .width = 320, .position = .{ 360, 60 } },
        .{ .kind = .anchors, .title = "Anchor playground", .width = 380, .position = .{ 120, 300 } },
        .{ .kind = .focus, .title = "Focus scopes", .width = 300, .position = .{ 720, 220 } },
    },
    /// Back to front: the last index paints on top.
    stacking: [4]u8 = .{ 0, 1, 2, 3 },

    note_bytes: [64]u8 = undefined,
    note_input: zui_widgets.EditableText = undefined,
    notes: [6][64]u8 = undefined,
    note_lengths: [6]usize = @splat(0),
    note_count: usize = 0,

    channels: [4]Channel = .{
        .{ .name = "drums", .level = 0.8 },
        .{ .name = "bass", .level = 0.65 },
        .{ .name = "synth", .level = 0.5 },
        .{ .name = "vocals", .level = 0.9 },
    },
    preset: enum { studio, live_room, cathedral, telephone } = .studio,

    floating_anchor: zui.AnchorPoint = .bottom_left,
    attach_point: zui.AnchorPoint = .top_right,
    float_offset: f32 = 6,

    modal_open: bool = false,
    callsign_bytes: [32]u8 = undefined,
    callsign: zui_widgets.EditableText = undefined,
    passphrase_bytes: [32]u8 = undefined,
    passphrase: zui_widgets.EditableText = undefined,
    modal_result: []const u8 = "nothing yet",

    pub fn init(self: *WindowManager) void {
        self.note_input = .init(&self.note_bytes, "");
        self.callsign = .init(&self.callsign_bytes, "Maverick");
        self.passphrase = .init(&self.passphrase_bytes, "");
        self.addNote("Drag me by the title bar");
        self.addNote("Click a window to raise it");
    }

    fn addNote(self: *WindowManager, content: []const u8) void {
        if (content.len == 0) return;
        if (self.note_count == self.notes.len) {
            std.mem.copyForwards([64]u8, self.notes[0 .. self.notes.len - 1], self.notes[1..]);
            std.mem.copyForwards(usize, self.note_lengths[0 .. self.notes.len - 1], self.note_lengths[1..]);
            self.note_count -= 1;
        }
        const length = @min(content.len, 64);
        @memcpy(self.notes[self.note_count][0..length], content[0..length]);
        self.note_lengths[self.note_count] = length;
        self.note_count += 1;
    }

    fn raise(self: *WindowManager, window_index: u8) void {
        const rank = std.mem.indexOfScalar(u8, &self.stacking, window_index) orelse return;
        std.mem.copyForwards(u8, self.stacking[rank .. self.stacking.len - 1], self.stacking[rank + 1 ..]);
        self.stacking[self.stacking.len - 1] = window_index;
    }

    pub fn declare(self: *WindowManager, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        ui.open(.{
            .id = desktop_id,
            .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both },
            .decoration = .{ .background = palette.sunken, .corner_radius = .all(10) },
            .clip = .both,
        });
        wallpaper(ui, shell);
        self.taskbar(ui, shell);
        ui.close();

        const desktop = ui.rectOf(desktop_id) orelse zui.Rect{ .width = 1000, .height = 600 };
        for (self.stacking, 0..) |window_index, rank| {
            if (self.windows[window_index].open) self.window(ui, shell, window_index, @intCast(rank), desktop);
        }
        if (self.modal_open) self.modal(ui, shell, desktop);
    }

    fn taskbar(self: *WindowManager, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        ui.open(.{
            .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(48) }, .padding = .symmetric(12, 0), .child_gap = 8, .child_alignment = .{ .y = .center } },
            .decoration = .{ .background = palette.surface, .border = .{ .color = palette.border, .widths = .{ .top = 1 } }, .corner_radius = .{ .bottom_left = 10, .bottom_right = 10 } },
        });
        defer ui.close();
        for (&self.windows, 0..) |*task, index| {
            const id: zui.Id = .indexed("wm.task", index);
            const on_top = self.stacking[self.stacking.len - 1] == index and task.open;
            if (ui.clicked(id)) {
                if (on_top) task.open = false else {
                    task.open = true;
                    self.raise(@intCast(index));
                }
            }
            const state = ui.widgetState(id);
            ui.open(.{
                .id = id,
                .focusable = true,
                .cursor = .pointer,
                .layout = .{ .sizing = .{ .height = .fixed(34) }, .padding = .symmetric(12, 0), .child_gap = 8, .child_alignment = .{ .y = .center } },
                .decoration = .{
                    .background = if (state == .hovered or state == .pressed) palette.hovered else if (on_top) palette.raised else null,
                    .border = if (ui.focused(id)) .{ .color = palette.focus, .widths = .all(1) } else .{ .color = if (task.open) palette.accent else palette.border, .widths = .{ .bottom = 2 } },
                    .corner_radius = .all(6),
                },
            });
            shell.labelColored(ui, .body, if (task.open) palette.text else palette.faint, task.title);
            if (state == .hovered) {
                ui.open(.{
                    .floating = .{ .anchor = .bottom_center, .attach_point = .top_center, .offset = .{ 0, -8 }, .z = 400 },
                    .layout = .{ .padding = .symmetric(8, 4) },
                    .decoration = .{ .background = palette.text, .corner_radius = .all(4) },
                });
                shell.labelColored(ui, .caption, palette.background, if (on_top) "click to minimize" else if (task.open) "click to raise" else "click to open");
                ui.close();
            }
            ui.close();
        }
        shell.spacer(ui);
        shell.label(ui, .caption, "z order:");
        for (self.stacking) |window_index| shell.printColored(ui, .caption, palette.muted, " {d}", .{window_index + 1});
    }

    fn window(self: *WindowManager, ui: *Ui, shell: *const Shell, window_index: u8, rank: i16, desktop: zui.Rect) void {
        const palette = shell.palette;
        const window_state = &self.windows[window_index];
        const window_id: zui.Id = .indexed("wm.window", window_index);
        const title_id = window_id.child("title");
        const close_id = window_id.child("close");
        const on_top = rank == self.stacking.len - 1;

        var absolute: [2]f32 = .{ desktop.x + window_state.position[0], desktop.y + window_state.position[1] };
        const dragging = kit.drag(ui, title_id, &absolute);
        window_state.position = .{
            std.math.clamp(absolute[0] - desktop.x, 0, @max(0, desktop.width - window_state.width)),
            std.math.clamp(absolute[1] - desktop.y, 0, @max(0, desktop.height - 90)),
        };
        if (!on_top and (ui.pressed(window_id) or ui.pressed(title_id))) self.raise(window_index);
        if (ui.clicked(close_id)) window_state.open = false;

        const accent = kit.hueColor(0.45 + @as(f32, @floatFromInt(window_index)) * 0.15, 0.55, 0.9);
        ui.open(.{
            .id = window_id,
            .interactive = true,
            .floating = .{ .attach_to = .{ .element = desktop_id }, .offset = window_state.position, .z = 20 + rank },
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(window_state.width) } },
            .decoration = .{ .background = palette.surface, .border = .{ .color = if (on_top) accent else palette.border, .widths = .all(if (on_top) 2 else 1) }, .corner_radius = .all(10) },
        });
        defer ui.close();
        {
            ui.open(.{
                .id = title_id,
                .interactive = true,
                .cursor = if (dragging) .grabbing else .grab,
                .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(32) }, .padding = .{ .left = 12, .right = 6 }, .child_gap = 8, .child_alignment = .{ .y = .center } },
                .decoration = .{ .background = if (on_top) accent else palette.raised, .corner_radius = .{ .top_left = 9, .top_right = 9 } },
            });
            defer ui.close();
            shell.labelColored(ui, .body, if (on_top) palette.on_accent else palette.muted, window_state.title);
            shell.spacer(ui);
            ui.open(.{
                .id = close_id,
                .interactive = true,
                .cursor = .pointer,
                .layout = .{ .sizing = .{ .width = .fixed(22), .height = .fixed(22) }, .child_alignment = .{ .x = .center, .y = .center } },
                .decoration = .{ .background = if (ui.hovered(close_id)) palette.bad else null, .corner_radius = .all(11) },
            });
            shell.labelColored(ui, .body, if (on_top) palette.on_accent else palette.muted, "x");
            ui.close();
        }
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .grow }, .padding = .all(12), .child_gap = 8 } });
        defer ui.close();
        switch (window_state.kind) {
            .notes => self.notesContent(ui, shell),
            .mixer => self.mixerContent(ui, shell),
            .anchors => self.anchorsContent(ui, shell),
            .focus => self.focusContent(ui, shell),
        }
    }

    fn notesContent(self: *WindowManager, ui: *Ui, shell: *const Shell) void {
        for (0..self.note_count) |index| {
            ui.open(.{
                .layout = .{ .sizing = .{ .width = .grow }, .padding = .all(8) },
                .decoration = .{ .background = kit.hueColor(0.12 + @as(f32, @floatFromInt(index)) * 0.09, 0.45, 1), .corner_radius = .{ .top_left = 2, .top_right = 2, .bottom_left = 2, .bottom_right = 12 } },
            });
            ui.text(self.notes[index][0..self.note_lengths[index]], .{ .size = 14 * shell.text_scale, .color = .rgb(0x1b1d2a) });
            ui.close();
        }
        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 6 } });
        defer ui.close();
        const result = shell.widgets.textField(ui, .of("wm.note_input"), &self.note_input, .{ .placeholder = "new note" });
        if (shell.widgets.button(ui, .of("wm.note_add"), "Pin", .{}) or result.submitted) {
            self.addNote(self.note_input.slice());
            self.note_input.set("");
        }
    }

    fn mixerContent(self: *WindowManager, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        shell.widgets.labeledRow(ui, "Room");
        _ = shell.widgets.dropdownEnum(ui, .of("wm.preset"), &self.preset, .{ .width = .grow });
        ui.close();
        shell.label(ui, .caption, "Its list floats in layer popup_z, above every window.");
        for (&self.channels, 0..) |*channel, index| {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
            defer ui.close();
            _ = shell.widgets.checkbox(ui, .indexed("wm.mute", index), "", &channel.muted, .{});
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(56) } } });
            shell.label(ui, .caption, channel.name);
            ui.close();
            _ = shell.widgets.slider(ui, .indexed("wm.level", index), &channel.level, .{ .disabled = channel.muted });
            const level = if (channel.muted) 0 else channel.level;
            ui.open(.{ .layout = .{ .sizing = .{ .width = .fixed(40), .height = .fixed(12) }, .child_gap = 1 } });
            for (0..8) |segment| {
                const lit = @as(f32, @floatFromInt(segment)) < level * 8;
                const color = if (segment > 5) palette.bad else if (segment > 3) palette.warn else palette.good;
                ui.box(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .grow } }, .decoration = .{ .background = if (lit) color else palette.sunken } });
            }
            ui.close();
        }
    }

    fn anchorsContent(self: *WindowManager, ui: *Ui, shell: *const Shell) void {
        const palette = shell.palette;
        shell.label(ui, .caption, "Pick the badge's anchor and the target point it attaches to.");
        {
            ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 18 } });
            defer ui.close();
            anchorPicker(ui, shell, "badge anchor", "wm.anchor", &self.floating_anchor);
            anchorPicker(ui, shell, "attach point", "wm.attach", &self.attach_point);
        }
        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8, .child_alignment = .{ .y = .center } } });
        shell.label(ui, .caption, "offset");
        _ = shell.widgets.slider(ui, .of("wm.offset"), &self.float_offset, .{ .min = -20, .max = 30, .step = 1 });
        ui.close();
        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(150) }, .child_alignment = .{ .x = .center, .y = .center } } });
        defer ui.close();
        ui.open(.{
            .id = anchor_target_id,
            .layout = .{ .sizing = .{ .width = .fixed(120), .height = .fixed(64) }, .child_alignment = .{ .x = .center, .y = .center } },
            .decoration = .{ .background = palette.raised, .border = .{ .color = palette.accent, .widths = .all(2) }, .corner_radius = .all(6) },
        });
        shell.label(ui, .caption, "target");
        ui.close();
        const direction: [2]f32 = .{ self.attach_point.fractions()[0] * 2 - 1, self.attach_point.fractions()[1] * 2 - 1 };
        ui.open(.{
            .floating = .{
                .attach_to = .{ .element = anchor_target_id },
                .anchor = self.floating_anchor,
                .attach_point = self.attach_point,
                .offset = .{ direction[0] * self.float_offset, direction[1] * self.float_offset },
                .z = 45,
            },
            .layout = .{ .padding = .symmetric(8, 4) },
            .decoration = .{ .background = palette.warn, .corner_radius = .all(10) },
        });
        shell.labelColored(ui, .caption, palette.on_accent, "badge");
        ui.close();
    }

    fn focusContent(self: *WindowManager, ui: *Ui, shell: *const Shell) void {
        shell.label(ui, .caption, "Tab walks every focusable element on screen. A focus scope keeps it inside a dialog until the dialog closes.");
        if (shell.widgets.button(ui, .of("wm.open_modal"), "Open a modal dialog", .{})) {
            self.modal_open = true;
            ui.requestFocus(modal_first_field_id);
        }
        shell.print(ui, .body, "Last answer: {s}", .{self.modal_result});
    }

    fn modal(self: *WindowManager, ui: *Ui, shell: *const Shell, desktop: zui.Rect) void {
        const palette = shell.palette;
        if (ui.keyPressed(.escape)) {
            self.modal_open = false;
            self.modal_result = "dismissed with Escape";
        }
        ui.open(.{
            .interactive = true,
            .floating = .{ .attach_to = .{ .element = desktop_id }, .z = 300 },
            .layout = .{ .sizing = .{ .width = .fixed(desktop.width), .height = .fixed(desktop.height) }, .child_alignment = .{ .x = .center, .y = .center } },
            .decoration = .{ .background = palette.overlay, .corner_radius = .all(10) },
        });
        defer ui.close();
        ui.open(.{
            .focus_scope = true,
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(380) }, .padding = .all(18), .child_gap = 10 },
            .decoration = .{ .background = palette.surface, .border = .{ .color = palette.focus, .widths = .all(2) }, .corner_radius = .all(12) },
        });
        defer ui.close();
        shell.label(ui, .title, "Identify");
        shell.label(ui, .caption, "Tab and Shift+Tab stay inside this box. Escape closes it.");
        shell.widgets.labeledRow(ui, "Callsign");
        _ = shell.widgets.textField(ui, modal_first_field_id, &self.callsign, .{});
        ui.close();
        shell.widgets.labeledRow(ui, "Passphrase");
        _ = shell.widgets.textField(ui, .of("wm.modal.passphrase"), &self.passphrase, .{ .placeholder = "swordfish" });
        ui.close();
        ui.open(.{ .layout = .{ .sizing = .{ .width = .grow }, .child_gap = 8 } });
        defer ui.close();
        shell.spacer(ui);
        if (shell.widgets.button(ui, .of("wm.modal.cancel"), "Cancel", .{})) {
            self.modal_open = false;
            self.modal_result = "canceled";
        }
        if (shell.widgets.button(ui, .of("wm.modal.ok"), "Engage", .{})) {
            self.modal_open = false;
            self.modal_result = if (std.mem.eql(u8, self.passphrase.slice(), "swordfish")) "access granted" else "wrong passphrase";
        }
    }
};

fn anchorPicker(ui: *Ui, shell: *const Shell, title: []const u8, comptime id_name: []const u8, value: *zui.AnchorPoint) void {
    const palette = shell.palette;
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .child_gap = 4 } });
    defer ui.close();
    shell.label(ui, .caption, title);
    for (0..3) |row| {
        ui.open(.{ .layout = .{ .child_gap = 4 } });
        defer ui.close();
        for (0..3) |column| {
            const index = row * 3 + column;
            const id: zui.Id = .indexed(id_name, index);
            const point: zui.AnchorPoint = @enumFromInt(index);
            if (ui.clicked(id)) value.* = point;
            const selected = value.* == point;
            ui.box(.{
                .id = id,
                .interactive = true,
                .cursor = .pointer,
                .layout = .{ .sizing = .{ .width = .fixed(18), .height = .fixed(18) } },
                .decoration = .{ .background = if (selected) palette.accent else if (ui.hovered(id)) palette.hovered else palette.sunken, .corner_radius = .all(9) },
            });
        }
    }
    shell.labelColored(ui, .tiny, palette.accent, anchor_names[@intFromEnum(value.*)]);
}

/// Faint bands, so dragged windows have something to move over.
fn wallpaper(ui: *Ui, shell: *const Shell) void {
    ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(24), .child_gap = 18 } });
    defer ui.close();
    for (0..12) |band| {
        ui.box(.{
            .layout = .{ .sizing = .{ .width = .percent(0.3 + 0.05 * @as(f32, @floatFromInt(band % 7))), .height = .fixed(10) } },
            .decoration = .{ .background = kit.hueColor(0.5 + @as(f32, @floatFromInt(band)) * 0.04, 0.3, 0.6).mix(shell.palette.sunken, 0.75), .corner_radius = .all(5) },
        });
    }
}
