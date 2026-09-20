const std = @import("std");
const platform = @import("platform/linux.zig");
const c = platform.c;
const toolkit = @import("lighthouse-ui");
const ui = toolkit.screen;
const input = toolkit.input;
const Session = @import("terminal/session.zig").Session;
const Pane = @import("core/pane.zig").Pane;
const State = @import("app/controller.zig").State;
const Layout = @import("app/layout.zig").Layout;
const View = @import("app/view.zig").View;
const poll_interval_ms = 40;
const read_buffer_bytes = 4 * 1024;
const pty_reads_per_turn = 4;

/// Owns one interactive application session. After a successful init, call
/// deinit exactly once, including when run fails. The view borrows heap-owned
/// controller state, so returning App by value does not invalidate widget pointers.
pub const App = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    console: platform.Console,
    session: *Session,
    panes: [2]*Pane,
    state: *State,
    view: *View,
    size: toolkit.Size,
    layout: Layout,
    current: ui.Frame,
    previous: ui.Frame,
    output: std.Io.Writer.Allocating,
    decoder: input.Decoder = .{},
    last_input: std.Io.Timestamp,
    dirty: bool = true,

    /// Acquires the console, shell, panes, and widgets. Failure releases all
    /// resources acquired so far and restores the outer terminal.
    pub fn init(io: std.Io, allocator: std.mem.Allocator, shell: [:0]const u8) !App {
        var console = try platform.Console.init();
        errdefer console.deinit();
        const size = screenSize(platform.Console.size());
        const layout = Layout.calculate(size, 0, false);
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        const session = try Session.create(io, allocator, shell, cwd, terminalSize(layout), console.saved);
        errdefer session.destroy();
        try session.start(cwd);
        const left = try Pane.create(io, allocator, cwd, .{});
        errdefer left.destroy();
        const right = try Pane.create(io, allocator, cwd, .{});
        errdefer right.destroy();
        const panes: [2]*Pane = .{ left, right };
        const state = try State.create(io, allocator, panes);
        errdefer state.destroy();
        state.attachTerminal(.{ .context = session, .start = startTerminal });
        const view = try View.create(allocator, state, session.emulator);
        errdefer view.destroy();
        try view.resize(size);
        for (panes) |pane| try pane.refresh();

        return .{
            .io = io,
            .allocator = allocator,
            .console = console,
            .session = session,
            .panes = panes,
            .state = state,
            .view = view,
            .size = size,
            .layout = layout,
            .current = ui.Frame.init(allocator),
            .previous = ui.Frame.init(allocator),
            .output = .init(allocator),
            .last_input = std.Io.Clock.awake.now(io),
        };
    }

    pub fn deinit(self: *App) void {
        self.output.deinit();
        self.previous.deinit();
        self.current.deinit();
        // Release borrowers first, then cancel/join workers before their owners.
        self.view.destroy();
        self.state.destroy();
        self.panes[1].destroy();
        self.panes[0].destroy();
        self.session.destroy();
        // Restore the outer terminal only after the embedded session has ended.
        self.console.deinit();
        self.* = undefined;
    }

    pub fn run(self: *App) !void {
        while (!self.state.view().quit and !platform.shouldStop()) {
            try self.pollWorkers();
            try self.expireInput();
            try self.resize();
            self.render() catch |err| {
                if (platform.shouldStop()) break;
                return err;
            };
            if (!try self.pollIo()) break;
        }
    }

    fn pollWorkers(self: *App) !void {
        if (try self.state.poll()) self.dirty = true;
    }

    fn expireInput(self: *App) !void {
        // Escape must time out even while the PTY is continuously readable.
        if (self.last_input.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() >= input.escape_timeout_ms) {
            if (self.decoder.timeout()) |ev| {
                try self.view.event(&ev);
                self.dirty = true;
            }
        }
    }

    fn resize(self: *App) !void {
        const size = screenSize(platform.Console.size());
        const layout = Layout.forState(size, self.state.view().adjustment, self.state.view().zoom, self.state.view().terminal_visible);
        if (std.meta.eql(self.size, size) and std.meta.eql(self.layout, layout)) return;
        self.size = size;
        self.layout = layout;
        try self.view.resize(size);
        // Hidden sessions retain the chosen split geometry and keep draining.
        const dimensions = terminalSize(Layout.calculate(size, self.state.view().adjustment, self.state.view().zoom));
        try self.session.resize(dimensions);
        self.state.requestRedraw();
        self.dirty = true;
    }

    fn render(self: *App) !void {
        if (!self.dirty and !self.view.tree.needsPaint()) return;
        try self.view.paint(&self.current, self.size);
        self.output.clearRetainingCapacity();
        try ui.encode(&self.output.writer, &self.current, if (self.state.view().force_redraw) null else &self.previous);
        try platform.writeAll(1, self.output.written());
        std.mem.swap(ui.Frame, &self.current, &self.previous);
        self.state.rendered();
        self.dirty = false;
    }

    /// False means host input closed. Child EOF is handled after its final paint.
    fn pollIo(self: *App) !bool {
        var fds = [_]c.pollfd{
            .{ .fd = 0, .events = if (self.state.view().focus != .terminal or self.session.emulator.acceptsInput()) c.POLLIN else 0, .revents = 0 },
            .{ .fd = if (self.session.pty) |pty| pty.fd else -1, .events = @as(c_short, c.POLLIN) | (if (self.session.emulator.queued().len > 0) @as(c_short, c.POLLOUT) else 0), .revents = 0 },
        };
        const ready = c.poll(&fds, fds.len, poll_interval_ms);
        if (ready < 0) {
            if (platform.errno() == c.EINTR) return true;
            return error.PollFailed;
        }
        if (fds[0].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return false;
        // Drain/retire the old child before accepting input that could start a
        // replacement. A full ended-session queue cannot block host input.
        if (fds[1].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0 and self.session.pty != null) try self.readPty();
        if (self.session.pty != null and fds[1].revents & c.POLLOUT != 0) {
            if (!try self.session.flush()) self.endTerminal();
        }
        if (fds[0].revents & c.POLLIN != 0 and !try self.readInput()) return false;
        return true;
    }

    fn readInput(self: *App) !bool {
        var bytes: [read_buffer_bytes]u8 = undefined;
        const count = c.read(0, &bytes, bytes.len);
        if (count == 0) return false;
        if (count < 0) {
            if (platform.errno() == c.EINTR) return true;
            return error.InputFailed;
        }
        self.last_input = std.Io.Clock.awake.now(self.io);
        for (bytes[0..@intCast(count)]) |byte| {
            if (self.decoder.feed(byte)) |ev| try self.view.event(&ev);
        }
        self.dirty = true;
        return true;
    }

    fn endTerminal(self: *App) void {
        self.session.end();
        self.state.terminalEnded();
        self.dirty = true;
    }

    fn readPty(self: *App) !void {
        // Bound each batch so a noisy child cannot starve input or repaint.
        var bytes: [read_buffer_bytes]u8 = undefined;
        for (0..pty_reads_per_turn) |_| {
            if (platform.shouldStop()) break;
            const count = c.read(self.session.pty.?.fd, &bytes, bytes.len);
            if (count > 0) {
                try self.session.emulator.feed(bytes[0..@intCast(count)]);
                self.dirty = true;
            } else {
                if (count == 0 or platform.errno() == c.EIO) {
                    self.endTerminal();
                    break;
                }
                if (platform.errno() == c.EAGAIN or platform.errno() == c.EINTR) break;
                return error.PtyReadFailed;
            }
        }
    }
};

fn terminalSize(layout: Layout) platform.Size {
    return .{ .cols = @intCast(layout.terminal.width), .rows = @intCast(layout.terminal.height) };
}

// Convert the host's geometry once at the event-loop boundary. Both the view
// and PTY/emulator layout use this same nonzero, allocation-bounded size.
fn screenSize(size: platform.Size) toolkit.Size {
    return Layout.boundedSize(.{ .width = size.cols, .height = size.rows });
}

fn startTerminal(context: *anyopaque, cwd: ?[]const u8) !void {
    const session: *Session = @ptrCast(@alignCast(context));
    try session.start(cwd);
}
