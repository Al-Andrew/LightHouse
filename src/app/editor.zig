//! Editor configuration and literal argv preparation; no shell evaluation.
const std = @import("std");
const c = @import("../platform/linux.zig").c;

pub const Command = struct {
    arena: std.heap.ArenaAllocator,
    argv: []const [:0]const u8,

    pub fn deinit(self: *Command) void {
        self.arena.deinit();
    }

    pub fn load(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8, file: []const u8) !Command {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const config_root = environment("XDG_CONFIG_HOME");
        const home = environment("HOME");
        const config = if (config_root) |root|
            try std.fs.path.join(a, &.{ root, "lighthouse/config.json" })
        else if (home) |root|
            try std.fs.path.join(a, &.{ root, ".config/lighthouse/config.json" })
        else
            null;
        const bytes = if (config) |path| std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return error.InvalidEditorConfiguration,
        } else null;
        var args: std.ArrayList([:0]const u8) = .empty;
        var configured = false;
        if (bytes) |json| {
            const value = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch return error.InvalidEditorConfiguration;
            if (value != .object) return error.InvalidEditorConfiguration;
            if (value.object.get("editor")) |editor| {
                configured = true;
                if (editor != .array or editor.array.items.len == 0) return error.InvalidEditorConfiguration;
                for (editor.array.items) |arg| {
                    if (arg != .string or std.mem.indexOfScalar(u8, arg.string, 0) != null) return error.InvalidEditorConfiguration;
                    try args.append(a, try a.dupeZ(u8, arg.string));
                }
            }
        }
        if (!configured) {
            const value = environment("EDITOR") orelse return error.EditorNotConfigured;
            try tokenize(a, value, &args);
        }
        if (args.items.len == 0 or args.items[0].len == 0) return error.InvalidEditorConfiguration;
        args.items[0] = try executable(a, cwd, args.items[0]);
        try args.append(a, try a.dupeZ(u8, file));
        return .{ .arena = arena, .argv = args.items };
    }
};

fn environment(name: [:0]const u8) ?[]const u8 {
    const value = c.getenv(name.ptr) orelse return null;
    const bytes = std.mem.span(value);
    return if (bytes.len == 0) null else bytes;
}

fn executable(a: std.mem.Allocator, cwd: []const u8, name: []const u8) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const absolute = try std.fs.path.resolve(a, &.{ cwd, name });
        const path = try a.dupeZ(u8, absolute);
        if (c.access(path.ptr, c.X_OK) != 0) return error.EditorNotExecutable;
        return path;
    }
    var paths = std.mem.splitScalar(u8, environment("PATH") orelse "/bin:/usr/bin", ':');
    while (paths.next()) |directory| {
        const absolute = try std.fs.path.resolve(a, &.{ cwd, directory, name });
        const path = try a.dupeZ(u8, absolute);
        if (c.access(path.ptr, c.X_OK) == 0) return path;
    }
    return error.EditorNotExecutable;
}

fn tokenize(a: std.mem.Allocator, value: []const u8, args: *std.ArrayList([:0]const u8)) !void {
    var token: std.ArrayList(u8) = .empty;
    var quote: ?u8 = null;
    var started = false;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const byte = value[i];
        if (byte == 0) return error.InvalidEditorArguments;
        if (quote == null and std.ascii.isWhitespace(byte)) {
            if (started) {
                try args.append(a, try a.dupeZ(u8, token.items));
                token.clearRetainingCapacity();
                started = false;
            }
            continue;
        }
        started = true;
        if (byte == '\\' and quote != '\'') {
            i += 1;
            if (i == value.len) return error.InvalidEditorArguments;
            if (quote == '"' and std.mem.indexOfScalar(u8, "\\\"$`", value[i]) == null) try token.append(a, '\\');
            try token.append(a, value[i]);
        } else if (byte == '\'' or byte == '"') {
            if (quote == byte) quote = null else if (quote == null) quote = byte else try token.append(a, byte);
        } else try token.append(a, byte);
    }
    if (quote != null) return error.InvalidEditorArguments;
    if (started) try args.append(a, try a.dupeZ(u8, token.items));
}
