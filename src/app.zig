const std = @import("std");
const platform = @import("platform/linux.zig");
const c = platform.c;
const ui = @import("ui/screen.zig");
const input = @import("ui/input.zig");
const Emulator = @import("terminal/emulator.zig").Emulator;
const Pane = @import("core/pane.zig").Pane;
const file_pane = @import("ui/file_pane.zig");
const PathInput = @import("ui/path_input.zig").PathInput;
const key_bar = @import("ui/key_bar.zig");
const operations = @import("core/operations.zig");
const dialog = @import("ui/dialog.zig");
const theme = @import("ui/theme.zig");

// Poll often enough to service workers and disambiguate a standalone Escape.
const poll_interval_ms = 40;
const read_buffer_bytes = 4 * 1024;
const pty_reads_per_turn = 4; // At most 16 KiB before handling input/repainting.
const path_dialog_width = 84;
const job_dialog_width = 90;
const help_dialog_width = 66;
const delete_preview_items = 4;

pub const Layout = struct {
    terminal: ui.Rect,
    panes_height: usize,
    compact: bool,

    const min_columns = 32;
    const min_rows = 10;
    const footer_rows = 1;
    const min_pane_rows = 5;
    const min_terminal_rows = 2;
    const terminal_height_divisor = 3;
    const max_adjustment = platform.Console.max_rows;

    pub fn calculate(size: platform.Size, adjustment: i32, zoom: bool) Layout {
        if (zoom or size.cols < min_columns or size.rows < min_rows) return .{
            .terminal = .{ .x = 0, .y = 0, .width = size.cols, .height = @max(1, size.rows -| footer_rows) },
            .panes_height = 0,
            .compact = true,
        };
        const height: usize = @intCast(std.math.clamp(@as(i32, size.rows / terminal_height_divisor) + adjustment, min_terminal_rows, @as(i32, size.rows) - min_pane_rows - footer_rows));
        const panes_height = size.rows - height - footer_rows;
        return .{
            .terminal = .{ .x = 0, .y = panes_height, .width = size.cols, .height = height },
            .panes_height = panes_height,
            .compact = false,
        };
    }
};

const Focus = enum { left, right, terminal };
// A tagged state owns exactly one modal payload. An action cannot outlive its
// editor, and help/path/delete dialogs cannot accidentally overlap.
const Modal = union(enum) {
    none,
    help,
    editor: struct { input: PathInput, action: ?operations.Kind = null },
    confirm_delete: *operations.Job,

    fn deinit(self: *Modal) void {
        switch (self.*) {
            .editor => |*editor| editor.input.deinit(),
            .confirm_delete => |job| job.destroy(),
            .none, .help => {},
        }
        self.* = .none;
    }
};

const State = struct {
    focus: Focus = .left,
    last_pane: Focus = .left,
    adjustment: i32 = 0,
    zoom: bool = false,
    quit: bool = false,
    force_redraw: bool = true,
    paste_to_terminal: bool = false,
    paste_bracketed: bool = false,
    panes: ?*[2]Pane = null,
    page_rows: usize = 1,
    modal: Modal = .none,
    operation: ?*operations.Job = null,

    fn activePane(self: *State) ?*Pane {
        const panes = self.panes orelse return null;
        return &panes[if (self.focus == .right) @as(usize, 1) else 0];
    }

    fn openPath(self: *State, absolute: bool) !void {
        const pane = self.activePane() orelse return;
        self.modal = .{ .editor = .{ .input = try PathInput.init(pane.allocator, if (absolute) "/" else pane.path()) } };
        // Keep the base location stable while editing a relative path. A slow
        // earlier navigation must not change its meaning underneath the dialog.
        pane.cancelNavigation();
        if (absolute) self.modal.editor.input.select_all = false;
    }

    fn openAction(self: *State, kind: operations.Kind) !void {
        const pane = self.activePane() orelse return;
        if (kind != .mkdir and pane.selectedCount() == 0 and pane.focused() == null) return;
        const other = &self.panes.?[if (self.focus == .left) @as(usize, 1) else 0];
        self.modal = .{ .editor = .{
            .input = try PathInput.init(pane.allocator, if (kind == .mkdir) "" else other.path()),
            .action = kind,
        } };
        pane.cancelNavigation();
        other.cancelNavigation();
    }

    fn submitEditor(self: *State, value: []const u8, action: ?operations.Kind) !void {
        const pane = self.activePane().?;
        const target = if (value[0] == '~' and (value.len == 1 or value[1] == '/')) target: {
            const home = c.getenv("HOME") orelse break :target try pane.allocator.dupe(u8, value);
            break :target try std.fs.path.join(pane.allocator, &.{ std.mem.span(home), if (value.len > 1) value[2..] else "" });
        } else try pane.allocator.dupe(u8, value);
        defer pane.allocator.free(target);
        if (action) |kind| {
            self.startOperation(try self.createOperation(kind, target));
        } else try pane.request(target, null);
    }

    fn createOperation(self: *State, kind: operations.Kind, target: []const u8) !*operations.Job {
        const pane = self.activePane().?;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(pane.allocator);
        if (kind != .mkdir) {
            if (pane.selectedCount() > 0) {
                for (pane.entries()) |entry| if (entry.selected) try names.append(pane.allocator, entry.name);
            } else if (pane.focused()) |entry| try names.append(pane.allocator, entry.name);
        }
        return operations.Job.create(pane.io, pane.allocator, kind, pane.path(), names.items, target);
    }

    fn startOperation(self: *State, job: *operations.Job) void {
        job.start() catch |err| {
            job.failure = err;
            job.done.store(true, .release);
        };
        self.operation = job;
    }

    fn openDelete(self: *State) !void {
        const pane = self.activePane() orelse return;
        if (pane.selectedCount() == 0 and pane.focused() == null) return;
        // Own the exact names shown in the confirmation, independent of scans.
        self.modal = .{ .confirm_delete = try self.createOperation(.delete, "") };
        pane.cancelNavigation();
    }

    fn event(self: *State, emulator: *Emulator, ev: *const input.Event) !void {
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
        switch (ev.kind) {
            .paste_start => {
                self.paste_to_terminal = self.focus == .terminal;
                self.paste_bracketed = self.paste_to_terminal and emulator.bracketedPaste();
                if (self.paste_to_terminal) emulator.bottom();
                if (self.paste_bracketed) try emulator.queue(input.paste_start);
                return;
            },
            .paste_end => {
                if (self.paste_bracketed) try emulator.queue(input.paste_end);
                self.paste_to_terminal = false;
                self.paste_bracketed = false;
                return;
            },
            .paste_byte => {
                if (self.paste_to_terminal) try emulator.queue(ev.text());
                return;
            },
            .key => {},
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
            try emulator.key(ev);
            return;
        }
        if (self.operation) |job| {
            if (ev.key == .f10 or (ev.key == .text and ev.len == 1 and ev.bytes[0] == 'q')) {
                self.quit = true;
            } else if (ev.key == .escape or (ev.key == .enter and job.collected)) {
                if (job.collected) {
                    job.destroy();
                    self.operation = null;
                } else job.canceled.store(true, .release);
            }
            return;
        }
        const pane = self.activePane();
        switch (ev.key) {
            .up => if (pane) |p| {
                if (ev.shift) p.moveMarked(-1) else p.move(-1);
            },
            .down => if (pane) |p| {
                if (ev.shift) p.moveMarked(1) else p.move(1);
            },
            .home => if (pane) |p| {
                if (ev.shift) p.markTo(0) else p.cursor = 0;
            },
            .end => if (pane) |p| {
                if (ev.shift) p.markTo(p.count() -| 1) else p.cursor = p.count() -| 1;
            },
            .enter, .right => if (pane) |p| try p.enter(),
            .backspace, .left => if (pane) |p| try p.parent(),
            .insert => if (pane) |p| {
                p.toggleSelection();
                p.move(1);
            },
            .f1 => self.modal = .help,
            .f5 => try self.openAction(.copy),
            .f6 => try self.openAction(.move),
            .f7 => try self.openAction(.mkdir),
            .f8 => try self.openDelete(),
            .escape => if (pane) |p| p.cancelNavigation(),
            .tab => {
                self.focus = if (self.focus == .left) .right else .left;
                self.last_pane = self.focus;
            },
            .f10 => self.quit = true,
            .page_up => if (ev.shift) emulator.scroll(-@as(isize, emulator.terminal.rows)) else if (pane) |p| p.move(-@as(isize, @intCast(self.page_rows))),
            .page_down => if (ev.shift) emulator.scroll(emulator.terminal.rows) else if (pane) |p| p.move(@intCast(self.page_rows)),
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
                    ' ' => if (pane) |p| p.toggleSelection(),
                    '.' => if (pane) |p| {
                        p.options.hidden = !p.options.hidden;
                        try p.refresh();
                    },
                    's' => if (pane) |p| {
                        p.options.sort = switch (p.options.sort) {
                            .name => .size,
                            .size => .modified,
                            .modified => .name,
                        };
                        try p.refresh();
                    },
                    'r' => if (pane) |p| {
                        p.options.reverse = !p.options.reverse;
                        try p.refresh();
                    },
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

pub fn run(io: std.Io, allocator: std.mem.Allocator, shell: [:0]const u8) !void {
    var console = try platform.Console.init();
    defer console.deinit();
    var state: State = .{};
    var size = platform.Console.size();
    var layout = Layout.calculate(size, state.adjustment, state.zoom);
    var pty = try platform.Pty.spawn(shell, terminalSize(layout), &console.saved);
    defer pty.deinit();
    const emulator = try Emulator.create(io, allocator, @intCast(layout.terminal.width), @intCast(layout.terminal.height));
    defer emulator.destroy();
    // Spawn the shell before starting directory workers (forkpty boundary).
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    var panes: [2]Pane = undefined;
    panes[0] = try Pane.init(io, allocator, cwd);
    defer panes[0].deinit();
    panes[1] = try Pane.init(io, allocator, cwd);
    defer panes[1].deinit();
    state.panes = &panes;
    defer state.modal.deinit();
    defer if (state.operation) |job| job.destroy();
    try panes[0].refresh();
    try panes[1].refresh();
    var current = ui.Frame.init(allocator);
    defer current.deinit();
    var previous = ui.Frame.init(allocator);
    defer previous.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var decoder: input.Decoder = .{};
    var last_input = std.Io.Clock.awake.now(io);
    var dirty = true;
    var pty_eof = false;

    while (!state.quit and !platform.shouldStop()) {
        if (state.operation) |job| {
            if (job.poll()) {
                for (&panes) |*pane| try pane.refresh();
                dirty = true;
            } else if (!job.collected and state.focus != .terminal) dirty = true;
        }
        for (&panes) |*pane| if (try pane.poll()) {
            dirty = true;
        };
        // Escape must time out even while the PTY is continuously readable.
        if (last_input.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >= input.escape_timeout_ms) {
            if (decoder.timeout()) |ev| {
                try state.event(emulator, &ev);
                dirty = true;
            }
        }
        const new_size = platform.Console.size();
        const new_layout = Layout.calculate(new_size, state.adjustment, state.zoom);
        if (!std.meta.eql(size, new_size) or !std.meta.eql(layout, new_layout)) {
            size = new_size;
            layout = new_layout;
            const dimensions = terminalSize(layout);
            try emulator.resize(dimensions.cols, dimensions.rows);
            try pty.resize(dimensions);
            state.force_redraw = true;
            dirty = true;
        }
        if (dirty) {
            state.page_rows = @max(1, file_pane.visibleRows(layout.panes_height));
            try draw(&current, emulator, size, layout, state);
            output.clearRetainingCapacity();
            try ui.encode(&output.writer, &current, if (state.force_redraw) null else &previous);
            platform.writeAll(1, output.written()) catch |err| {
                if (platform.shouldStop()) break;
                return err;
            };
            std.mem.swap(ui.Frame, &current, &previous);
            state.force_redraw = false;
            dirty = false;
        }
        // Drain through EOF before exiting, preserving the child's final output.
        if (pty_eof) break;
        var fds = [_]c.pollfd{
            .{ .fd = 0, .events = if (emulator.acceptsInput()) c.POLLIN else 0, .revents = 0 },
            .{ .fd = pty.fd, .events = @as(c_short, c.POLLIN) | (if (emulator.queued().len > 0) @as(c_short, c.POLLOUT) else 0), .revents = 0 },
        };
        const ready = c.poll(&fds, fds.len, poll_interval_ms);
        if (ready < 0) {
            if (platform.errno() == c.EINTR) continue;
            return error.PollFailed;
        }
        if (fds[0].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) break;
        if (fds[0].revents & c.POLLIN != 0) {
            var bytes: [read_buffer_bytes]u8 = undefined;
            const count = c.read(0, &bytes, bytes.len);
            if (count == 0) break;
            if (count < 0) {
                if (platform.errno() != c.EINTR) return error.InputFailed;
            } else {
                last_input = std.Io.Clock.awake.now(io);
                for (bytes[0..@intCast(count)]) |byte| {
                    if (decoder.feed(byte)) |ev| try state.event(emulator, &ev);
                }
                dirty = true;
            }
        }
        if (fds[1].revents & c.POLLOUT != 0 and emulator.queued().len > 0) {
            const pending = emulator.queued();
            const count = c.write(pty.fd, pending.ptr, pending.len);
            if (count > 0) emulator.consumed(@intCast(count)) else if (count < 0 and platform.errno() != c.EAGAIN and platform.errno() != c.EINTR) return error.PtyWriteFailed;
        }
        if (fds[1].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) {
            // Bound each batch so a noisy child cannot starve input or repaint.
            var bytes: [read_buffer_bytes]u8 = undefined;
            for (0..pty_reads_per_turn) |_| {
                if (platform.shouldStop()) break;
                const count = c.read(pty.fd, &bytes, bytes.len);
                if (count > 0) {
                    try emulator.feed(bytes[0..@intCast(count)]);
                    dirty = true;
                } else {
                    if (count == 0 or platform.errno() == c.EIO) {
                        pty_eof = true;
                        break;
                    }
                    if (platform.errno() == c.EAGAIN or platform.errno() == c.EINTR) break;
                    return error.PtyReadFailed;
                }
            }
        }
    }
}

fn terminalSize(layout: Layout) platform.Size {
    return .{ .cols = @intCast(layout.terminal.width), .rows = @intCast(layout.terminal.height) };
}

fn draw(frame: *ui.Frame, emulator: *Emulator, size: platform.Size, layout: Layout, state: State) !void {
    try frame.begin(size.cols, size.rows);
    if (!layout.compact) {
        const split = size.cols / 2;
        for ([_]Focus{ .left, .right }, 0..) |focus, i| {
            const pane = frame.painter(.{ .x = if (i == 0) 0 else split, .y = 0, .width = if (i == 0) split else size.cols - split, .height = layout.panes_height });
            if (state.panes) |panes| try file_pane.paint(pane, &panes[i], state.focus == focus);
        }
    }
    try emulator.paint(frame.painter(layout.terminal), state.focus == .terminal);
    if (size.rows > 1) {
        const footer = frame.painter(.{ .x = 0, .y = size.rows - 1, .width = size.cols, .height = 1 });
        key_bar.paint(footer, state.focus != .terminal and state.modal == .none and state.operation == null);
    }
    switch (state.modal) {
        .editor => |editor| try paintPathInput(frame, &editor.input, editor.action, if (state.panes) |panes| &panes[if (state.focus == .right) @as(usize, 1) else 0] else null),
        .help => paintHelp(frame),
        .confirm_delete => |job| try paintDeleteConfirmation(frame, job),
        .none => {},
    }
    if (state.operation) |job| if (state.focus != .terminal) try paintOperation(frame, job);
}

fn paintPathInput(frame: *ui.Frame, editor: *const PathInput, action: ?operations.Kind, pane: ?*Pane) !void {
    const style = theme.dialog;
    const box = dialog.begin(frame, path_dialog_width, if (action != null) 6 else 4, style);
    const width = box.rect.width;
    const height = box.rect.height;
    if (width < 5 or height < 3) return;
    box.child(.{ .x = 2, .y = 0, .width = width - 4, .height = 1 }).label(0, 0, if (action) |kind| kind.title() else " Go to directory ", style);
    const field = box.child(.{ .x = 1, .y = 1, .width = width - 2, .height = 1 });
    try editor.paint(field, .{ .bg = if (editor.select_all) theme.selection else theme.base.bg });
    const allocator = frame.arena.allocator();
    if (action) |kind| {
        if (height > 3) if (pane) |p| {
            const summary = if (kind == .mkdir) "Create one folder; its parent must exist." else if (p.selectedCount() > 0)
                try std.fmt.allocPrint(allocator, "{d} marked items. Existing destinations are refused.", .{p.selectedCount()})
            else if (p.focused()) |entry|
                try std.fmt.allocPrint(allocator, "Source: {s}", .{entry.name})
            else
                "";
            try box.child(.{ .x = 1, .y = 2, .width = width - 2, .height = 1 }).text(0, 0, summary, style);
        };
        if (height > 4) box.child(.{ .x = 1, .y = 3, .width = width - 2, .height = 1 }).label(0, 0, "Enter start  |  Esc cancel  |  Ctrl+U clear", style);
        if (height > 5 and kind != .mkdir) box.child(.{ .x = 1, .y = 4, .width = width - 2, .height = 1 }).label(0, 0, "Existing folder: place inside. New path: rename destination.", style);
    } else if (height > 3) box.child(.{ .x = 1, .y = 2, .width = width - 2, .height = 1 }).label(0, 0, "Enter open  |  Esc cancel  |  Ctrl+U clear", style);
}

fn paintDeleteConfirmation(frame: *ui.Frame, job: *const operations.Job) !void {
    const shown: usize = @min(delete_preview_items, job.sources.len);
    const style = theme.destructive_dialog;
    // Two warning rows, source previews, overflow hint, controls, and borders.
    const box = dialog.begin(frame, job_dialog_width, shown + 6, style);
    const inside = box.inset(1);
    const summary = try std.fmt.allocPrint(frame.arena.allocator(), "Permanently delete {d} item(s)?", .{job.sources.len});
    inside.label(0, 0, summary, style);
    inside.label(0, 1, "Folders include all contents. This cannot be undone.", style);
    for (job.sources[0..shown], 0..) |source, i| try inside.child(.{ .x = 0, .y = i + 2, .width = inside.rect.width, .height = 1 }).textEnd(source, style);
    if (job.sources.len > shown) inside.label(0, shown + 2, "...and the other marked entries", style);
    inside.label(0, shown + 3, "Enter delete  |  Esc / n cancel", style);
}

fn paintOperation(frame: *ui.Frame, job: *const operations.Job) !void {
    const style = theme.dialog;
    const box = dialog.begin(frame, job_dialog_width, 8, style);
    const inside = box.inset(1);
    const allocator = frame.arena.allocator();
    inside.label(0, 0, job.kind.title(), style);
    const progress = try std.fmt.allocPrint(allocator, "{d}/{d} items complete | {d} {s}", .{
        job.completed.load(.acquire),
        if (job.kind == .mkdir) @as(usize, 1) else job.sources.len,
        if (job.kind == .delete) job.removed.load(.acquire) else job.bytes.load(.acquire),
        if (job.kind == .delete) "entries deleted" else "bytes copied",
    });
    inside.label(0, 1, progress, style);
    if (job.collected) {
        inside.label(0, 2, if (job.failure) |err| operationError(err) else "Completed", style);
        if (job.failure != null) {
            try inside.text(0, 3, job.failed_path[0..job.failed_path_len], style);
            inside.label(0, 4, if (job.kind == .copy) "Completed copies remain; unfinished folders may be partial." else if (job.kind == .delete) "Deleted entries stay deleted; folders may be partly removed." else "Completed actions remain; remaining items were not processed.", style);
        }
        inside.label(0, 5, "Enter / Esc close  |  Ctrl+G shell", style);
    } else {
        inside.label(0, 2, if (job.canceled.load(.acquire)) "Canceling..." else if (job.kind == .delete) "Deleting..." else "Working... Existing destinations are never replaced.", style);
        inside.label(0, 5, "Esc cancel  |  Ctrl+G shell  |  F10 quit", style);
    }
}

fn operationError(err: anyerror) []const u8 {
    return switch (err) {
        error.PathAlreadyExists => "Destination already exists; nothing overwritten.",
        error.DestinationInsideSource => "Destination is inside the source directory.",
        error.DestinationMustBeDirectory => "Destination must be an existing directory.",
        error.CrossDevice => "Moves between filesystems are not supported yet; source retained.",
        error.Canceled => "Canceled",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.FileNotFound => "Not found",
        error.SourceChanged => "Source changed during copying; file was not published.",
        error.UnsupportedFileType => "Unsupported file type (only files, folders and symlinks can be copied).",
        else => @errorName(err),
    };
}

fn paintHelp(frame: *ui.Frame) void {
    const lines = [_][]const u8{
        "Arrows / PgUp / PgDn / Home / End   Move cursor",
        "Enter / Right                      Enter directory",
        "Backspace / Left                   Parent directory",
        "Tab                                Switch pane",
        "Space / Insert                     Mark / mark and advance",
        "Shift+Up/Down/Home/End               Toggle marks while moving",
        "Ctrl+L / /                         Enter path / absolute path",
        "F5 / F6 / F7                       Copy / move or rename / mkdir",
        "F8                                 Delete (with confirmation)",
        "Ctrl+R                             Refresh current directory",
        "Esc                                Cancel read / clear error",
        ".                                  Toggle hidden files",
        "s / r                              Sort field / reverse order",
        "Ctrl+G / t                         Focus shell",
        "+ / - / z                          Terminal height / zoom",
        "Shift+PgUp / Shift+PgDn             Terminal history",
        "q / F10                            Quit",
        "Any key closes help. Shell keys pass through when focused.",
    };
    const style = theme.dialog;
    const box = dialog.begin(frame, help_dialog_width, lines.len + 2, style);
    const inside = box.inset(1);
    for (lines, 0..) |line, i| inside.label(0, i, line, style);
}

test "layout remains nonempty and inside every small terminal" {
    for (1..120) |cols| for (1..50) |rows| {
        for ([_]i32{ -Layout.max_adjustment, 0, Layout.max_adjustment }) |adjustment| {
            const layout = Layout.calculate(.{ .cols = @intCast(cols), .rows = @intCast(rows) }, adjustment, false);
            try std.testing.expect(layout.terminal.width > 0 and layout.terminal.height > 0);
            try std.testing.expect(layout.terminal.x + layout.terminal.width <= cols);
            try std.testing.expect(layout.terminal.y + layout.terminal.height <= rows);
        }
    };
}

test "terminal focus forwards quit text and Ctrl+C but intercepts Ctrl+G" {
    const emulator = try Emulator.create(std.testing.io, std.testing.allocator, 20, 4);
    defer emulator.destroy();
    var state: State = .{ .focus = .terminal };
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
    var state: State = .{ .modal = .{ .editor = .{
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
        try paintPathInput(&frame, &editor, .copy, null);
        if (frame.cursor) |cursor| try std.testing.expect(cursor.x < cols and cursor.y < rows);
        try paintOperation(&frame, job);
        try std.testing.expect(frame.cursor == null);
    };
}

test "delete confirmation ignores paste, cancels without starting, and fits tiny windows" {
    const allocator = std.testing.allocator;
    const emulator = try Emulator.create(std.testing.io, allocator, 20, 4);
    defer emulator.destroy();
    var state: State = .{};
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
        try paintDeleteConfirmation(&frame, state.modal.confirm_delete);
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
        try paintDeleteConfirmation(&frame, job);
    }
}
