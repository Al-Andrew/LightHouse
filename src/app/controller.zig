const std = @import("std");
const c = @import("../platform/linux.zig").c;
const toolkit = @import("lighthouse-ui");
const input = toolkit.input;
const ui = toolkit.screen;
const PathInput = toolkit.TextInput;
const Emulator = @import("../terminal/emulator.zig").Emulator;
const Pane = @import("../core/pane.zig").Pane;
const operations = @import("../core/operations.zig");
const file_pane = @import("widgets/file_pane.zig");
const TerminalInput = @import("widgets/terminal.zig").Input;
const Layout = @import("layout.zig").Layout;
const dialogs = @import("widgets/dialogs.zig");
const paintPathInput = dialogs.paintPathInput;
const paintOperation = dialogs.paintOperation;
const paintDeleteConfirmation = dialogs.paintDeleteConfirmation;

pub const Focus = enum { left, right, terminal };
// A tagged state owns exactly one modal payload. An action cannot outlive its
// editor, and help/path/delete dialogs cannot accidentally overlap.
pub const Modal = union(enum) {
    none,
    help,
    editor: struct { input: PathInput, action: ?operations.Kind = null },
    confirm_delete: *operations.Job,

    pub fn deinit(self: *Modal) void {
        switch (self.*) {
            .editor => |*editor| editor.input.deinit(),
            .confirm_delete => |job| job.destroy(),
            .none, .help => {},
        }
        self.* = .none;
    }
};

pub const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    focus: Focus = .left,
    last_pane: Focus = .left,
    adjustment: i32 = 0,
    zoom: bool = false,
    quit: bool = false,
    force_redraw: bool = true,
    terminal_input: TerminalInput = .{},
    panes: ?[2]*Pane = null,
    modal: Modal = .none,
    operation: ?*operations.Job = null,

    pub fn activePane(self: *State) ?*Pane {
        const panes = self.panes orelse return null;
        return panes[if (self.focus == .right) @as(usize, 1) else 0];
    }

    fn openPath(self: *State, absolute: bool) !void {
        const pane = self.activePane() orelse return;
        self.modal = .{ .editor = .{ .input = try PathInput.init(self.allocator, if (absolute) "/" else pane.view().path) } };
        // Keep the base location stable while editing a relative path. A slow
        // earlier navigation must not change its meaning underneath the dialog.
        pane.cancelNavigation();
        if (absolute) self.modal.editor.input.select_all = false;
    }

    fn openAction(self: *State, kind: operations.Kind) !void {
        const pane = self.activePane() orelse return;
        if (kind != .mkdir and pane.sources().count == 0) return;
        const other = self.panes.?[if (self.focus == .left) @as(usize, 1) else 0];
        self.modal = .{ .editor = .{
            .input = try PathInput.init(self.allocator, if (kind == .mkdir) "" else other.view().path),
            .action = kind,
        } };
        pane.cancelNavigation();
        other.cancelNavigation();
    }

    fn submitEditor(self: *State, value: []const u8, action: ?operations.Kind) !void {
        const pane = self.activePane().?;
        const target = if (value[0] == '~' and (value.len == 1 or value[1] == '/')) target: {
            const home = c.getenv("HOME") orelse break :target try self.allocator.dupe(u8, value);
            break :target try std.fs.path.join(self.allocator, &.{ std.mem.span(home), if (value.len > 1) value[2..] else "" });
        } else try self.allocator.dupe(u8, value);
        defer self.allocator.free(target);
        if (action) |kind| {
            self.startOperation(try self.createOperation(kind, target));
        } else try pane.request(target);
    }

    fn createOperation(self: *State, kind: operations.Kind, target: []const u8) !*operations.Job {
        const pane = self.activePane().?;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        if (kind != .mkdir) {
            var sources = pane.sources();
            while (sources.next()) |name| try names.append(self.allocator, name);
        }
        return operations.Job.create(self.io, self.allocator, kind, pane.view().path, names.items, target);
    }

    fn startOperation(self: *State, job: *operations.Job) void {
        // This ownership transfer happens once; launch failures stay in the job.
        job.start() catch unreachable;
        self.operation = job;
    }

    fn openDelete(self: *State) !void {
        const pane = self.activePane() orelse return;
        if (pane.sources().count == 0) return;
        // Own the exact names shown in the confirmation, independent of scans.
        self.modal = .{ .confirm_delete = try self.createOperation(.delete, "") };
        pane.cancelNavigation();
    }

    pub fn event(self: *State, emulator: *Emulator, ev: *const input.Event) !void {
        switch (self.modal) {
            .confirm_delete => |job| {
                // Paste contents cannot confirm or dismiss a destructive action.
                if (ev.kind != .key) return;
                if (ev.key == .escape or (ev.key == .text and ev.len == 1 and ev.bytes[0] == 'n')) {
                    self.modal.deinit();
                } else if (ev.key == .enter) {
                    // Transfer ownership to the running operation before closing.
                    self.modal = .none;
                    self.startOperation(job);
                }
                return;
            },
            .editor => |*editor| {
                switch (try editor.input.event(ev)) {
                    .editing => {},
                    .cancel => self.modal.deinit(),
                    .accept => {
                        const value = editor.input.text();
                        if (value.len == 0) return;
                        try self.submitEditor(value, editor.action);
                        self.modal.deinit();
                    },
                }
                return;
            },
            .help => {
                if (ev.kind == .key) self.modal.deinit();
                return;
            },
            .none => {},
        }
        if (ev.kind != .key) {
            if (self.focus == .terminal) try self.terminal_input.event(emulator, ev);
            return;
        }
        if (ev.len == 1 and ev.bytes[0] == input.control('g')) {
            if (self.focus == .terminal) {
                self.focus = self.last_pane;
                self.zoom = false;
            } else {
                self.last_pane = self.focus;
                self.focus = .terminal;
            }
            return;
        }
        if (self.focus == .terminal) {
            try self.terminal_input.event(emulator, ev);
            return;
        }
        if (self.operation) |job| {
            const finished = job.status() == .finished;
            if (ev.key == .f10 or (ev.key == .text and ev.len == 1 and ev.bytes[0] == 'q')) {
                self.quit = true;
            } else if (ev.key == .escape or (ev.key == .enter and finished)) {
                if (finished) {
                    job.destroy();
                    self.operation = null;
                } else job.cancel();
            }
            return;
        }
        const pane = self.activePane();
        if (pane) |p| if (try file_pane.handleEvent(p, ev)) return;
        switch (ev.key) {
            .f1 => self.modal = .help,
            .f5 => try self.openAction(.copy),
            .f6 => try self.openAction(.move),
            .f7 => try self.openAction(.mkdir),
            .f8 => try self.openDelete(),
            .tab => {
                self.focus = if (self.focus == .left) .right else .left;
                self.last_pane = self.focus;
            },
            .f10 => self.quit = true,
            .page_up => if (ev.shift) emulator.scroll(-@as(isize, emulator.terminal.rows)),
            .page_down => if (ev.shift) emulator.scroll(emulator.terminal.rows),
            .text => if (ev.len == 1) {
                switch (ev.bytes[0]) {
                    'q' => self.quit = true,
                    't' => {
                        self.last_pane = self.focus;
                        self.focus = .terminal;
                    },
                    'z' => {
                        self.zoom = true;
                        self.last_pane = self.focus;
                        self.focus = .terminal;
                    },
                    '+' => self.adjustment = @min(self.adjustment + 1, Layout.max_adjustment),
                    '-' => self.adjustment = @max(self.adjustment - 1, -Layout.max_adjustment),
                    input.control('l') => try self.openPath(false),
                    '/' => try self.openPath(true),
                    input.control('r') => {
                        self.force_redraw = true;
                        if (pane) |p| try p.refresh();
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
};

test "terminal focus forwards quit text and Ctrl+C but intercepts Ctrl+G" {
    const emulator = try Emulator.create(std.testing.io, std.testing.allocator, 20, 4);
    defer emulator.destroy();
    var state: State = .{ .io = std.testing.io, .allocator = std.testing.allocator, .focus = .terminal };
    var decoder: input.Decoder = .{};
    const q = decoder.feed('q').?;
    try state.event(emulator, &q);
    const interrupt = decoder.feed(3).?;
    try state.event(emulator, &interrupt);
    try std.testing.expectEqualStrings("q\x03", emulator.queued());
    const focus = decoder.feed(7).?;
    try state.event(emulator, &focus);
    try std.testing.expectEqual(Focus.left, state.focus);
    try state.event(emulator, &q);
    try std.testing.expect(state.quit);
}

test "closing an action editor releases its payload before opening help" {
    const allocator = std.testing.allocator;
    const emulator = try Emulator.create(std.testing.io, allocator, 20, 4);
    defer emulator.destroy();
    var state: State = .{ .io = std.testing.io, .allocator = std.testing.allocator, .modal = .{ .editor = .{
        .input = try PathInput.init(allocator, "/destination"),
        .action = .copy,
    } } };
    defer state.modal.deinit();
    // Empty input keeps the dialog open; Escape frees both editor and action.
    var decoder: input.Decoder = .{};
    const clear = decoder.feed(input.control('u')).?;
    try state.event(emulator, &clear);
    try state.event(emulator, &.{ .key = .enter });
    try std.testing.expect(state.modal == .editor);
    try state.event(emulator, &.{ .key = .escape });
    try std.testing.expect(state.modal == .none);
    try state.event(emulator, &.{ .key = .f1 });
    try std.testing.expect(state.modal == .help);
    try state.event(emulator, &.{ .kind = .paste_byte });
    try std.testing.expect(state.modal == .help);
    try state.event(emulator, &.{ .key = .escape });
    try std.testing.expect(state.modal == .none);
    try std.testing.expectEqual(@as(usize, 0), emulator.queued().len);
}

test "file action dialogs fit tiny windows with Unicode input" {
    const allocator = std.testing.allocator;
    var frame = ui.Frame.init(allocator);
    defer frame.deinit();
    var editor = try PathInput.init(allocator, "/dest/界");
    defer editor.deinit();
    const job = try operations.Job.create(std.testing.io, allocator, .copy, "/source", &.{"file"}, "/target");
    defer job.destroy();
    for (1..95) |cols| for (1..10) |rows| {
        try frame.begin(cols, rows);
        try paintPathInput(frame.painter(.{ .x = 0, .y = 0, .width = frame.cols, .height = frame.rows }), &editor, .copy, null);
        if (frame.cursor) |cursor| try std.testing.expect(cursor.x < cols and cursor.y < rows);
        try paintOperation(frame.painter(.{ .x = 0, .y = 0, .width = frame.cols, .height = frame.rows }), job);
        try std.testing.expect(frame.cursor == null);
    };
}

test "delete confirmation ignores paste, cancels without starting, and fits tiny windows" {
    const allocator = std.testing.allocator;
    const emulator = try Emulator.create(std.testing.io, allocator, 20, 4);
    defer emulator.destroy();
    var state: State = .{
        .io = std.testing.io,
        .allocator = std.testing.allocator,
    };
    state.modal = .{ .confirm_delete = try operations.Job.create(std.testing.io, allocator, .delete, "/unused", &.{"file"}, "") };
    defer state.modal.deinit();
    var decoder: input.Decoder = .{};
    for ("\x1b[200~\r\nn\x1b[201~") |byte| if (decoder.feed(byte)) |ev| try state.event(emulator, &ev);
    try std.testing.expect(state.modal == .confirm_delete);
    try std.testing.expect(state.operation == null);
    try std.testing.expectEqual(@as(usize, 0), emulator.queued().len);
    var frame = ui.Frame.init(allocator);
    defer frame.deinit();
    for (1..95) |cols| for (1..12) |rows| {
        try frame.begin(cols, rows);
        try paintDeleteConfirmation(frame.painter(.{ .x = 0, .y = 0, .width = frame.cols, .height = frame.rows }), state.modal.confirm_delete);
        try std.testing.expect(frame.cursor == null);
    };
    try state.event(emulator, &.{ .key = .escape });
    try std.testing.expect(state.modal == .none);
    try std.testing.expect(state.operation == null);
}

test "delete confirmation handles multiple selections" {
    const allocator = std.testing.allocator;
    var frame = ui.Frame.init(allocator);
    defer frame.deinit();
    const names = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (2..names.len + 1) |count| {
        const job = try operations.Job.create(std.testing.io, allocator, .delete, "/unused", names[0..count], "");
        defer job.destroy();
        try frame.begin(100, 30);
        try paintDeleteConfirmation(frame.painter(.{ .x = 0, .y = 0, .width = frame.cols, .height = frame.rows }), job);
    }
}

test "confirmed job retains ownership through launch failure and result dismissal" {
    const allocator = std.testing.allocator;
    const emulator = try Emulator.create(std.testing.io, allocator, 20, 4);
    defer emulator.destroy();
    const job = try operations.Job.create(std.Io.failing, allocator, .delete, "/unused", &.{"file"}, "");
    var state: State = .{ .io = std.testing.io, .allocator = std.testing.allocator, .modal = .{ .confirm_delete = job } };
    defer state.modal.deinit();
    defer if (state.operation) |operation| operation.destroy();
    try state.event(emulator, &.{ .key = .enter });
    try std.testing.expect(state.modal == .none);
    try std.testing.expectEqual(job, state.operation.?);
    // Neither rendering nor Enter can collect or dismiss a pending completion.
    var frame = ui.Frame.init(allocator);
    defer frame.deinit();
    try frame.begin(100, 30);
    try paintOperation(frame.painter(.{ .x = 0, .y = 0, .width = frame.cols, .height = frame.rows }), job);
    try state.event(emulator, &.{ .key = .enter });
    try std.testing.expectEqual(job, state.operation.?);
    try std.testing.expect(job.status() == .running);
    try std.testing.expect(job.poll());
    try std.testing.expectEqual(error.ConcurrencyUnavailable, job.status().finished.failure.?.err);
    try paintOperation(frame.painter(.{ .x = 0, .y = 0, .width = frame.cols, .height = frame.rows }), job);
    try std.testing.expect(!job.poll());
    // The finished result survives a visit to the shell, where Enter is input.
    var toggle: input.Event = .{ .key = .text, .len = 1 };
    toggle.bytes[0] = input.control('g');
    try state.event(emulator, &toggle);
    try state.event(emulator, &.{ .key = .enter });
    try std.testing.expectEqual(job, state.operation.?);
    try state.event(emulator, &toggle);
    try state.event(emulator, &.{ .key = .enter });
    try std.testing.expect(state.operation == null);
}
