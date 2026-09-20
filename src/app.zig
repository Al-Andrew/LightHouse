const std = @import("std");
const platform = @import("platform/linux.zig");
const c = platform.c;
const toolkit = @import("lighthouse-ui");
const ui = toolkit.screen;
const input = toolkit.input;
const Emulator = @import("terminal/emulator.zig").Emulator;
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
    pty: platform.Pty,
    emulator: *Emulator,
    panes: [2]*Pane,
    state: *State,
    view: *View,
    size: platform.Size,
    layout: Layout,
    current: ui.Frame,
    previous: ui.Frame,
    output: std.Io.Writer.Allocating,
    decoder: input.Decoder = .{},
    last_input: std.Io.Timestamp,
    dirty: bool = true,
    pty_eof: bool = false,

    /// Acquires the console, shell, panes, and widgets. Failure releases all
    /// resources acquired so far and restores the outer terminal.
    pub fn init(io: std.Io, allocator: std.mem.Allocator, shell: [:0]const u8) !App {
        var console = try platform.Console.init();
        errdefer console.deinit();
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .io = io, .allocator = allocator };
        const size = platform.Console.size();
        const layout = Layout.calculate(size, state.adjustment, state.zoom);
        var pty = try platform.Pty.spawn(shell, terminalSize(layout), &console.saved);
        errdefer pty.deinit();
        const emulator = try Emulator.create(io, allocator, @intCast(layout.terminal.width), @intCast(layout.terminal.height));
        errdefer emulator.destroy();
        // Spawn the shell before starting directory workers (forkpty boundary).
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        const left = try Pane.create(io, allocator, cwd, .{});
        errdefer left.destroy();
        const right = try Pane.create(io, allocator, cwd, .{});
        errdefer right.destroy();
        const panes: [2]*Pane = .{ left, right };
        state.panes = panes;
        const view = try View.create(allocator, state, emulator);
        errdefer view.destroy();
        try view.resize(size);
        for (panes) |pane| try pane.refresh();

        return .{
            .io = io,
            .allocator = allocator,
            .console = console,
            .pty = pty,
            .emulator = emulator,
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
        if (self.state.operation) |job| job.destroy();
        self.state.modal.deinit();
        self.panes[1].destroy();
        self.panes[0].destroy();
        self.emulator.destroy();
        self.pty.deinit();
        self.allocator.destroy(self.state);
        // Restore the outer terminal only after the embedded session has ended.
        self.console.deinit();
        self.* = undefined;
    }

    pub fn run(self: *App) !void {
        while (!self.state.quit and !platform.shouldStop()) {
            try self.pollWorkers();
            try self.expireInput();
            try self.resize();
            self.render() catch |err| {
                if (platform.shouldStop()) break;
                return err;
            };
            // Render the child's final output before leaving on EOF.
            if (self.pty_eof) break;
            if (!try self.pollIo()) break;
        }
    }

    fn pollWorkers(self: *App) !void {
        if (self.state.operation) |job| {
            if (job.poll()) {
                for (self.panes) |pane| try pane.refresh();
                self.dirty = true;
            } else if (job.status() != .finished and self.state.focus != .terminal) self.dirty = true;
        }
        for (self.panes) |pane| if (try pane.poll()) {
            self.dirty = true;
        };
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
        const size = platform.Console.size();
        const layout = Layout.calculate(size, self.state.adjustment, self.state.zoom);
        if (std.meta.eql(self.size, size) and std.meta.eql(self.layout, layout)) return;
        self.size = size;
        self.layout = layout;
        try self.view.resize(size);
        const dimensions = terminalSize(layout);
        try self.emulator.resize(dimensions.cols, dimensions.rows);
        try self.pty.resize(dimensions);
        self.state.force_redraw = true;
        self.dirty = true;
    }

    fn render(self: *App) !void {
        if (!self.dirty and !self.view.tree.needsPaint()) return;
        try self.view.paint(&self.current, self.size);
        self.output.clearRetainingCapacity();
        try ui.encode(&self.output.writer, &self.current, if (self.state.force_redraw) null else &self.previous);
        try platform.writeAll(1, self.output.written());
        std.mem.swap(ui.Frame, &self.current, &self.previous);
        self.state.force_redraw = false;
        self.dirty = false;
    }

    /// False means host input closed. Child EOF is handled after its final paint.
    fn pollIo(self: *App) !bool {
        var fds = [_]c.pollfd{
            .{ .fd = 0, .events = if (self.emulator.acceptsInput()) c.POLLIN else 0, .revents = 0 },
            .{ .fd = self.pty.fd, .events = @as(c_short, c.POLLIN) | (if (self.emulator.queued().len > 0) @as(c_short, c.POLLOUT) else 0), .revents = 0 },
        };
        const ready = c.poll(&fds, fds.len, poll_interval_ms);
        if (ready < 0) {
            if (platform.errno() == c.EINTR) return true;
            return error.PollFailed;
        }
        if (fds[0].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return false;
        if (fds[0].revents & c.POLLIN != 0 and !try self.readInput()) return false;
        if (fds[1].revents & c.POLLOUT != 0) try self.flushPty();
        if (fds[1].revents & (c.POLLIN | c.POLLHUP | c.POLLERR) != 0) try self.readPty();
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

    fn flushPty(self: *App) !void {
        const pending = self.emulator.queued();
        if (pending.len == 0) return;
        const count = c.write(self.pty.fd, pending.ptr, pending.len);
        if (count > 0) {
            self.emulator.consumed(@intCast(count));
        } else if (count < 0 and platform.errno() != c.EAGAIN and platform.errno() != c.EINTR) return error.PtyWriteFailed;
    }

    fn readPty(self: *App) !void {
        // Bound each batch so a noisy child cannot starve input or repaint.
        var bytes: [read_buffer_bytes]u8 = undefined;
        for (0..pty_reads_per_turn) |_| {
            if (platform.shouldStop()) break;
            const count = c.read(self.pty.fd, &bytes, bytes.len);
            if (count > 0) {
                try self.emulator.feed(bytes[0..@intCast(count)]);
                self.dirty = true;
            } else {
                if (count == 0 or platform.errno() == c.EIO) {
                    self.pty_eof = true;
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
