//! Process lifetime and emulator ownership for one terminal session.
const std = @import("std");
const platform = @import("../platform/linux.zig");
const Emulator = @import("emulator.zig").Emulator;

pub const Session = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    shell: [:0]const u8,
    launch_directory: [:0]const u8,
    termios: platform.c.termios,
    dimensions: platform.Size,
    pty: ?platform.Pty = null,
    emulator: *Emulator,
    successful_exit: bool = false,

    pub fn create(io: std.Io, allocator: std.mem.Allocator, shell: [:0]const u8, cwd: []const u8, dimensions: platform.Size, termios: platform.c.termios) !*Session {
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        const absolute_shell = try std.fs.path.resolve(allocator, &.{ cwd, shell });
        defer allocator.free(absolute_shell);
        const owned_shell = try allocator.dupeZ(u8, absolute_shell);
        errdefer allocator.free(owned_shell);
        const owned_cwd = try allocator.dupeZ(u8, cwd);
        errdefer allocator.free(owned_cwd);
        self.* = .{ .io = io, .allocator = allocator, .shell = owned_shell, .launch_directory = owned_cwd, .termios = termios, .dimensions = dimensions, .emulator = try Emulator.create(io, allocator, dimensions.cols, dimensions.rows) };
        return self;
    }

    pub fn destroy(self: *Session) void {
        self.end();
        self.emulator.destroy();
        self.allocator.free(self.shell);
        self.allocator.free(self.launch_directory);
        self.allocator.destroy(self);
    }

    pub fn start(self: *Session, cwd: ?[]const u8) !void {
        try self.startCommand(&.{ self.shell, "-i" }, cwd orelse self.launch_directory);
    }

    pub fn startCommand(self: *Session, argv: []const [:0]const u8, cwd: []const u8) !void {
        if (self.pty != null) return;
        const path = try self.allocator.dupeZ(u8, cwd);
        defer self.allocator.free(path);
        var pty = try platform.Pty.spawn(self.allocator, argv, path, self.dimensions, &self.termios);
        errdefer pty.deinit();
        try self.emulator.reset(self.io, self.dimensions.cols, self.dimensions.rows);
        self.pty = pty;
        self.successful_exit = false;
    }

    pub fn end(self: *Session) void {
        if (self.pty) |*pty| {
            pty.deinit();
            self.successful_exit = if (pty.exit_status) |status| status == 0 else false;
        }
        self.pty = null;
        self.emulator.consumed(self.emulator.queued().len);
        self.emulator.paste = .inactive;
    }

    pub fn resize(self: *Session, dimensions: platform.Size) !void {
        self.dimensions = dimensions;
        try self.emulator.resize(dimensions.cols, dimensions.rows);
        if (self.pty) |*pty| try pty.resize(dimensions);
    }

    pub const Drain = enum { idle, output, ended };

    /// Bound each batch so a noisy child cannot starve host input or repaint.
    pub fn drain(self: *Session) !Drain {
        const pty = self.pty orelse return .ended;
        var result: Drain = .idle;
        var bytes: [4096]u8 = undefined;
        for (0..4) |_| {
            const count = platform.c.read(pty.fd, &bytes, bytes.len);
            if (count > 0) {
                try self.emulator.feed(bytes[0..@intCast(count)]);
                result = .output;
            } else {
                if (count == 0 or platform.errno() == platform.c.EIO) return .ended;
                if (platform.errno() == platform.c.EAGAIN or platform.errno() == platform.c.EINTR) break;
                return error.PtyReadFailed;
            }
        }
        return result;
    }

    /// False reports child EOF, including writes after the child has closed.
    pub fn flush(self: *Session) !bool {
        const pty = self.pty orelse return false;
        const pending = self.emulator.queued();
        if (pending.len == 0) return true;
        const count = platform.c.write(pty.fd, pending.ptr, pending.len);
        if (count > 0) self.emulator.consumed(@intCast(count)) else if (count < 0) switch (platform.errno()) {
            platform.c.EAGAIN, platform.c.EINTR => {},
            platform.c.EIO, platform.c.EPIPE => return false,
            else => return error.PtyWriteFailed,
        };
        return true;
    }
};
