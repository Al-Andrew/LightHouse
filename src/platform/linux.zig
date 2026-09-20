//! Linux-only terminal/process boundary. No UI or Ghostty dependencies.
const std = @import("std");
pub const c = @cImport({
    // Import libc declarations without optimizer-dependent inline fortify
    // wrappers, which Zig 0.16's C translator cannot translate on glibc 2.43.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("pty.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("errno.h");
});

pub const Size = struct { cols: u16, rows: u16 };
var stopping = std.atomic.Value(bool).init(false);

fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    stopping.store(true, .monotonic);
}

pub fn shouldStop() bool {
    return stopping.load(.monotonic);
}

pub fn errno() c_int {
    return c.__errno_location().*;
}

pub fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0) {
            if (errno() == c.EINTR and !shouldStop()) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

pub const Console = struct {
    const fallback_size: Size = .{ .cols = 80, .rows = 24 };
    saved: c.termios,
    old_signals: [signals.len]std.posix.Sigaction,
    const signals = [_]std.posix.SIG{ .TERM, .HUP, .INT, .PIPE };
    const enter = "\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[?2004h";
    pub const leave = "\x1b[0m\x1b[0 q\x1b[?2004l\x1b[?7h\x1b[?25h\x1b[?1049l";

    pub fn init() !Console {
        if (c.isatty(0) != 1 or c.isatty(1) != 1) return error.InteractiveTerminalRequired;
        var self: Console = undefined;
        if (c.tcgetattr(0, &self.saved) != 0) return error.TerminalSetupFailed;
        var raw = self.saved;
        c.cfmakeraw(&raw);
        if (c.tcsetattr(0, c.TCSAFLUSH, &raw) != 0) return error.TerminalSetupFailed;
        errdefer _ = c.tcsetattr(0, c.TCSAFLUSH, &self.saved);
        stopping.store(false, .monotonic);
        for (signals, 0..) |sig, i| {
            const action: std.posix.Sigaction = .{
                .handler = if (sig == .PIPE) .{ .handler = std.posix.SIG.IGN } else .{ .handler = signalHandler },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(sig, &action, &self.old_signals[i]);
        }
        errdefer for (signals, 0..) |sig, i| std.posix.sigaction(sig, &self.old_signals[i], null);
        errdefer _ = c.write(1, leave.ptr, leave.len);
        try writeAll(1, enter);
        return self;
    }

    pub fn deinit(self: *Console) void {
        // Best effort even if a signal interrupted the output write.
        _ = c.write(1, leave.ptr, leave.len);
        _ = c.tcsetattr(0, c.TCSAFLUSH, &self.saved);
        for (signals, 0..) |sig, i| std.posix.sigaction(sig, &self.old_signals[i], null);
    }

    pub fn size() Size {
        var ws: c.winsize = std.mem.zeroes(c.winsize);
        if (c.ioctl(1, c.TIOCGWINSZ, &ws) != 0) return fallback_size;
        return .{ .cols = ws.ws_col, .rows = ws.ws_row };
    }
};

pub const Pty = struct {
    const shutdown_grace_ms = 200;
    const shutdown_poll_ms = 10;
    fd: c_int,
    pid: c.pid_t,
    reaped: bool = false,
    exit_status: ?c_int = null,

    /// All allocations/environment preparation happen in the parent. The forked
    /// child uses only async-signal-safe operations before execve, so runtime
    /// launch is safe after directory and file-job workers have started.
    pub fn spawn(allocator: std.mem.Allocator, argv: []const [:0]const u8, cwd: [:0]const u8, dimensions: Size, termios: *const c.termios) !Pty {
        if (argv.len == 0 or c.access(argv[0].ptr, c.X_OK) != 0) return error.ShellNotExecutable;
        const directory = c.open(cwd.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
        if (directory < 0) return error.WorkingDirectoryUnavailable;
        defer _ = c.close(directory);
        var arguments: std.ArrayList(?[*:0]const u8) = .empty;
        defer arguments.deinit(allocator);
        for (argv) |arg| try arguments.append(allocator, arg.ptr);
        try arguments.append(allocator, null);
        var environment: std.ArrayList(?[*:0]const u8) = .empty;
        defer environment.deinit(allocator);
        var i: usize = 0;
        while (c.environ[i]) |entry| : (i += 1) {
            const value = std.mem.span(entry);
            if (std.mem.startsWith(u8, value, "TERM=") or std.mem.startsWith(u8, value, "COLORTERM=") or std.mem.startsWith(u8, value, "TERM_PROGRAM=")) continue;
            try environment.append(allocator, entry);
        }
        try environment.appendSlice(allocator, &.{ "TERM=xterm-256color", "COLORTERM=truecolor", null });
        var pipe: [2]c_int = undefined;
        if (c.pipe2(&pipe, c.O_CLOEXEC) != 0) return error.SpawnFailed;
        defer _ = c.close(pipe[0]);
        defer if (pipe[1] >= 0) {
            _ = c.close(pipe[1]);
        };
        var master: c_int = -1;
        var slave: c_int = -1;
        var ws = std.mem.zeroes(c.winsize);
        ws.ws_col = dimensions.cols;
        ws.ws_row = dimensions.rows;
        if (c.openpty(&master, &slave, null, termios, &ws) != 0) {
            return error.SpawnFailed;
        }
        defer _ = c.close(slave);
        errdefer _ = c.close(master);
        if (c.fcntl(master, c.F_SETFD, c.FD_CLOEXEC) < 0) return error.PtySetupFailed;
        const pid = c.fork();
        if (pid == 0) {
            _ = c.close(pipe[0]);
            _ = c.close(master);
            for ([_]c_int{ c.SIGINT, c.SIGTERM, c.SIGHUP, c.SIGPIPE, c.SIGQUIT }) |sig| _ = c.signal(sig, c.SIG_DFL);
            const ready = c.setsid() >= 0 and c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0)) == 0 and
                c.dup2(slave, 0) >= 0 and c.dup2(slave, 1) >= 0 and c.dup2(slave, 2) >= 0 and c.fchdir(directory) == 0;
            if (slave > 2) _ = c.close(slave);
            if (ready) _ = c.execve(argv[0].ptr, @ptrCast(arguments.items.ptr), @ptrCast(environment.items.ptr));
            const failure: u8 = 1;
            _ = c.write(pipe[1], &failure, 1);
            c._exit(127);
        }
        _ = c.close(pipe[1]);
        pipe[1] = -1;
        if (pid < 0) return error.SpawnFailed;
        const self: Pty = .{ .fd = master, .pid = pid };
        // self now owns master; cleanup on subsequent failure closes it once.
        var failure: u8 = 0;
        var count: isize = undefined;
        while (true) {
            count = c.read(pipe[0], &failure, 1);
            if (count >= 0 or errno() != c.EINTR) break;
        }
        if (count != 0 or c.fcntl(master, c.F_SETFL, c.O_NONBLOCK) < 0) {
            // Outer errdefer owns the descriptor; reap the failed child here.
            _ = c.kill(pid, c.SIGKILL);
            while (c.waitpid(pid, null, 0) < 0 and errno() == c.EINTR) {}
            return error.SpawnFailed;
        }
        return self;
    }

    pub fn resize(self: *Pty, dimensions: Size) !void {
        var ws = std.mem.zeroes(c.winsize);
        ws.ws_col = dimensions.cols;
        ws.ws_row = dimensions.rows;
        if (c.ioctl(self.fd, c.TIOCSWINSZ, &ws) != 0) return error.ResizeFailed;
    }

    pub fn exited(self: *Pty) bool {
        if (!self.reaped) {
            var status: c_int = 0;
            self.reaped = c.waitpid(self.pid, &status, c.WNOHANG) == self.pid;
            if (self.reaped) self.exit_status = status;
        }
        return self.reaped;
    }

    pub fn deinit(self: *Pty) void {
        // Hang up the controlling terminal and explicitly terminate the shell
        // and foreground group. Reap with a bounded grace period.
        const foreground = c.tcgetpgrp(self.fd);
        if (foreground > 0) _ = c.kill(-foreground, c.SIGHUP);
        _ = c.close(self.fd);
        if (!self.reaped) {
            _ = c.kill(-self.pid, c.SIGHUP);
            _ = c.kill(self.pid, c.SIGHUP);
        }
        for (0..shutdown_grace_ms / shutdown_poll_ms) |_| {
            const shell_exited = self.exited();
            const foreground_alive = foreground > 0 and c.kill(-foreground, 0) == 0;
            if (shell_exited and !foreground_alive) return;
            _ = c.usleep(shutdown_poll_ms * std.time.us_per_ms);
        }
        if (foreground > 0) _ = c.kill(-foreground, c.SIGKILL);
        if (self.reaped) return;
        _ = c.kill(-self.pid, c.SIGKILL);
        _ = c.kill(self.pid, c.SIGKILL);
        var status: c_int = 0;
        while (c.waitpid(self.pid, &status, 0) < 0 and errno() == c.EINTR) {}
        self.reaped = true;
        self.exit_status = status;
    }
};
