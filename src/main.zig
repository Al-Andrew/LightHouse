const std = @import("std");
const lighthouse = @import("LightHouse");

// std.log's policy belongs to the executable, including logs from dependencies.
// A terminal used by the compositor must never receive out-of-band log writes:
// even one newline can scroll it and invalidate the saved frame. Explicit
// startup/runtime errors below are reported after App cleanup restores the console.
// Preserve diagnostics when stderr is redirected (e.g. 2>lighthouse.log).
pub const std_options: std.Options = .{ .logFn = log };

fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (lighthouse.platform.c.isatty(2) == 1) return;
    std.log.defaultLog(level, scope, format, args);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var shell: [:0]const u8 = if (lighthouse.platform.c.getenv("SHELL")) |value| std.mem.span(value) else "/bin/sh";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            try lighthouse.platform.writeAll(1, "LightHouse: dual-pane file browser with an integrated terminal\n" ++
                "Usage: lighthouse [--shell /path/to/shell]\n\n" ++
                "Ctrl+G switches focus; Ctrl+J hides/shows or starts the shell.\n" ++
                "Shell exit leaves browsing usable. Jobs block shell input until dismissed.\n" ++
                "LF Enter is indistinguishable from Ctrl+J; CR Return stays Enter.\n" ++
                "In panes: arrows/PageUp/PageDown navigate, Enter opens directories,\n" ++
                "Backspace goes up, Tab switches pane, Space/Insert marks entries.\n" ++
                "Shift+Up/Down/Home/End toggles marks while moving.\n" ++
                "Ctrl+F inserts the Cursor reference into the shell without Enter.\n" ++
                "Ctrl+L enters a path, Ctrl+R refreshes, . toggles hidden files,\n" ++
                "s cycles sorting, r reverses it, F1 shows help, q/F10 quits.\n" ++
                "F5 copies, F6 moves/renames, F7 creates a directory, F8 deletes.\n" ++
                "+/- resizes the shell, z zooms, Shift+PgUp/PgDn scrolls its history.\n" ++
                "In shell: all keys except Ctrl+G/Ctrl+J go to the child application.\n");
            return;
        } else if (std.mem.eql(u8, args[i], "--shell") and i + 1 < args.len) {
            i += 1;
            shell = args[i];
        } else {
            std.debug.print("Usage: lighthouse [--shell /path/to/shell]\n", .{});
            std.process.exit(2);
        }
    }
    runApplication(init.io, init.gpa, shell) catch |err| {
        std.debug.print("LightHouse: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

// Keep the lifetime inside an error-returning scope so deinit runs before the
// caller reports an error and exits the process.
fn runApplication(io: std.Io, allocator: std.mem.Allocator, shell: [:0]const u8) !void {
    var app = try lighthouse.App.init(io, allocator, shell);
    defer app.deinit();
    try app.run();
}
