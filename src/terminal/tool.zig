//! Owns the one temporary full-area External tool session.
const std = @import("std");
const platform = @import("../platform/linux.zig");
const Session = @import("session.zig").Session;
const Emulator = @import("emulator.zig").Emulator;

pub const Tool = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    termios: platform.c.termios,
    dimensions: platform.Size,
    session: ?*Session = null,

    pub fn start(context: *anyopaque, argv: []const [:0]const u8, cwd: []const u8) !*Emulator {
        const self: *Tool = @ptrCast(@alignCast(context));
        if (self.session) |session| {
            if (session.pty != null) return error.ToolBusy;
            self.release();
        }
        const session = try Session.create(self.io, self.allocator, argv[0], cwd, self.dimensions, self.termios);
        errdefer session.destroy();
        try session.startCommand(argv, cwd);
        self.session = session;
        return session.emulator;
    }

    pub fn release(self: *Tool) void {
        if (self.session) |session| session.destroy();
        self.session = null;
    }
};
