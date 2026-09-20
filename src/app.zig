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

pub fn run(io: std.Io, allocator: std.mem.Allocator, shell: [:0]const u8) !void {
    var console = try platform.Console.init();
    defer console.deinit();
    var state: State = .{ .io = io, .allocator = allocator };
    var size = platform.Console.size();
    var layout = Layout.calculate(size, state.adjustment, state.zoom);
    var pty = try platform.Pty.spawn(shell, terminalSize(layout), &console.saved);
    defer pty.deinit();
    const emulator = try Emulator.create(io, allocator, @intCast(layout.terminal.width), @intCast(layout.terminal.height));
    defer emulator.destroy();
    // Spawn the shell before starting directory workers (forkpty boundary).
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const left = try Pane.create(io, allocator, cwd, .{});
    defer left.destroy();
    const right = try Pane.create(io, allocator, cwd, .{});
    defer right.destroy();
    const panes: [2]*Pane = .{ left, right };
    state.panes = panes;
    defer state.modal.deinit();
    defer if (state.operation) |job| job.destroy();
    const view = try View.create(allocator, &state, emulator);
    defer view.destroy();
    try view.resize(size);
    for (panes) |pane| {
        try pane.refresh();
    }
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
                for (panes) |pane| try pane.refresh();
                dirty = true;
            } else if (job.status() != .finished and state.focus != .terminal) dirty = true;
        }
        for (panes) |pane| if (try pane.poll()) {
            dirty = true;
        };
        // Escape must time out even while the PTY is continuously readable.
        if (last_input.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() >= input.escape_timeout_ms) {
            if (decoder.timeout()) |ev| {
                try view.event(&ev);
                dirty = true;
            }
        }
        const new_size = platform.Console.size();
        const new_layout = Layout.calculate(new_size, state.adjustment, state.zoom);
        if (!std.meta.eql(size, new_size) or !std.meta.eql(layout, new_layout)) {
            size = new_size;
            layout = new_layout;
            try view.resize(size);
            const dimensions = terminalSize(layout);
            try emulator.resize(dimensions.cols, dimensions.rows);
            try pty.resize(dimensions);
            state.force_redraw = true;
            dirty = true;
        }
        if (dirty or view.tree.dirty) {
            try view.paint(&current, size);
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
                    if (decoder.feed(byte)) |ev| try view.event(&ev);
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
