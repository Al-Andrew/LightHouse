//! Provider-neutral listing metadata and provisional location operations.
const std = @import("std");

pub const Sort = enum { name, size, modified };
pub const Options = struct {
    hidden: bool = false,
    sort: Sort = .name,
    reverse: bool = false,
};
pub const Entry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
    directory: bool,
    size: ?u64,
    modified: ?i64,
};
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    locator: []const u8,
    entries: []Entry,
    options: Options,
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }
};

/// Equality uses adapter identity and canonical opaque locator, never display text.
pub const Location = struct {
    provider: *const anyopaque,
    locator: []const u8,
    pub fn eql(a: Location, b: Location) bool {
        return a.provider == b.provider and std.mem.eql(u8, a.locator, b.locator);
    }
};
pub const Resolution = union(enum) { user_input: []const u8, child: []const u8, parent, root };
pub const Capabilities = struct { source_read: bool = false, destination_write: bool = false };

/// Provisional internal interface; see docs/PROVIDERS.md for ownership/threading.
pub const Provider = struct {
    identity: *const anyopaque,
    context: ?*anyopaque = null,
    resolve: *const fn (?*anyopaque, std.mem.Allocator, []const u8, Resolution) anyerror![]const u8,
    has_parent: *const fn (?*anyopaque, []const u8) bool,
    display: *const fn (?*anyopaque, []const u8) []const u8,
    parent_hint: *const fn (?*anyopaque, []const u8) ?[]const u8,
    capabilities: *const fn (?*anyopaque, []const u8) Capabilities,
    /// Returns one owned, unquoted Cursor entry reference; no local executor
    /// capability is implied. Called on the UI thread with original name bytes.
    reference: ?*const fn (?*anyopaque, std.mem.Allocator, []const u8, Entry) anyerror![]const u8 = null,
    scan: *const fn (?*anyopaque, std.Io, []const u8, Options, *const std.atomic.Value(bool)) anyerror!Snapshot,

    pub fn location(self: Provider, locator: []const u8) Location {
        return .{ .provider = self.identity, .locator = locator };
    }
    /// Explicit bridge into the sole supported file-job executor.
    /// Local file-action targets retain OS path traversal (including symlink/..).
    /// Navigation normalization must not redirect a file job's destination.
    pub fn localTarget(self: Provider, allocator: std.mem.Allocator, base: []const u8, input: []const u8) ![]const u8 {
        _ = try self.localPath(base);
        const expanded = try expandLocalInput(allocator, input);
        defer allocator.free(expanded);
        return if (std.fs.path.isAbsolute(expanded)) allocator.dupe(u8, expanded) else std.fs.path.join(allocator, &.{ base, expanded });
    }
    pub fn localPath(self: Provider, locator: []const u8) ![]const u8 {
        if (self.identity != local.identity) return error.UnsupportedOperation;
        return locator;
    }
};
const local_identity: u8 = 0;
pub const local: Provider = .{
    .identity = &local_identity,
    .resolve = resolveLocal,
    .has_parent = localHasParent,
    .display = localDisplay,
    .parent_hint = localParentHint,
    .capabilities = localCapabilities,
    .scan = scanLocal,
    .reference = localReference,
};
fn localReference(_: ?*anyopaque, allocator: std.mem.Allocator, base: []const u8, entry: Entry) ![]const u8 {
    return std.fs.path.join(allocator, &.{ base, entry.name });
}
fn localHasParent(_: ?*anyopaque, path: []const u8) bool {
    return !std.mem.eql(u8, path, "/");
}
fn localDisplay(_: ?*anyopaque, path: []const u8) []const u8 {
    return path;
}
fn localParentHint(_: ?*anyopaque, path: []const u8) ?[]const u8 {
    return std.fs.path.basename(path);
}
fn localCapabilities(_: ?*anyopaque, _: []const u8) Capabilities {
    return .{ .source_read = true, .destination_write = true };
}

/// Home expansion belongs to the local adapter, including file-action input.
pub fn expandLocalInput(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len > 0 and value[0] == '~' and (value.len == 1 or value[1] == '/')) {
        const c = @import("../platform/linux.zig").c;
        if (c.getenv("HOME")) |home| return std.fs.path.join(allocator, &.{ std.mem.span(home), if (value.len > 1) value[2..] else "" });
    }
    return allocator.dupe(u8, value);
}
fn resolveLocal(_: ?*anyopaque, allocator: std.mem.Allocator, base: []const u8, resolution: Resolution) ![]const u8 {
    return switch (resolution) {
        .root => allocator.dupe(u8, "/"),
        .parent => allocator.dupe(u8, std.fs.path.dirname(base) orelse "/"),
        .child => |name| std.fs.path.resolve(allocator, &.{ base, name }),
        .user_input => |input| blk: {
            const expanded = try expandLocalInput(allocator, input);
            defer allocator.free(expanded);
            break :blk std.fs.path.resolve(allocator, &.{ base, expanded });
        },
    };
}

fn scanLocal(_: ?*anyopaque, io: std.Io, path: []const u8, options: Options, canceled: *const std.atomic.Value(bool)) !Snapshot {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var entries: std.ArrayList(Entry) = .empty;
    while (try iterator.next(io)) |entry| {
        if (canceled.load(.acquire)) return error.Canceled;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (!options.hidden and std.mem.startsWith(u8, entry.name, ".")) continue;
        // A disappearing or inaccessible entry remains visible with unknown
        // metadata. Cancellation, unlike a per-entry stat failure, ends the job.
        const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.Canceled => return err,
            else => null,
        };
        const kind = if (stat) |s| s.kind else entry.kind;
        var directory = kind == .directory;
        if (kind == .sym_link) {
            const target = dir.statFile(io, entry.name, .{}) catch |err| switch (err) {
                error.Canceled => return err,
                else => null,
            };
            directory = if (target) |s| s.kind == .directory else false;
        }
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .kind = kind,
            .directory = directory,
            .size = if (stat) |s| s.size else null,
            .modified = if (stat) |s| s.mtime.toSeconds() else null,
        });
    }
    if (canceled.load(.acquire)) return error.Canceled;
    std.mem.sort(Entry, entries.items, options, lessThan);
    return .{ .arena = arena, .locator = try allocator.dupe(u8, path), .entries = entries.items, .options = options };
}

fn lessThan(options: Options, a: Entry, b: Entry) bool {
    // Directories always come first; reverse only changes order within a group.
    if (a.directory != b.directory) return a.directory;
    var order: std.math.Order = switch (options.sort) {
        .name => .eq,
        .size => std.math.order(a.size orelse 0, b.size orelse 0),
        .modified => std.math.order(a.modified orelse 0, b.modified orelse 0),
    };
    if (order == .eq) order = std.ascii.orderIgnoreCase(a.name, b.name);
    if (order == .eq) order = std.mem.order(u8, a.name, b.name);
    return order == (if (options.reverse) std.math.Order.gt else .lt);
}

test "sorting keeps folders first and has a deterministic name tie break" {
    var entries = [_]Entry{
        .{ .name = "b", .kind = .file, .directory = false, .size = 20, .modified = 2 },
        .{ .name = "z", .kind = .directory, .directory = true, .size = 0, .modified = 0 },
        .{ .name = "a", .kind = .file, .directory = false, .size = 10, .modified = 1 },
        .{ .name = "A", .kind = .file, .directory = false, .size = 10, .modified = 1 },
    };
    std.mem.sort(Entry, &entries, Options{}, lessThan);
    try std.testing.expectEqualStrings("z", entries[0].name);
    try std.testing.expectEqualStrings("A", entries[1].name);
    std.mem.sort(Entry, &entries, Options{ .sort = .size, .reverse = true }, lessThan);
    try std.testing.expectEqualStrings("z", entries[0].name);
    try std.testing.expectEqualStrings("b", entries[1].name);
}

test "local provider keeps raw names, follows directory links, and tolerates broken links" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "folder", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "name\n\xff", .data = "1234" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "" });
    try tmp.dir.symLink(io, "folder", "link", .{});
    try tmp.dir.symLink(io, "missing", "broken", .{});
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buffer);
    var canceled: std.atomic.Value(bool) = .init(false);
    var snapshot = try local.scan(null, io, path_buffer[0..len], .{}, &canceled);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 4), snapshot.entries.len);
    try std.testing.expect(snapshot.entries[0].directory);
    try std.testing.expect(snapshot.entries[1].directory);
    for (snapshot.entries) |entry| {
        if (std.mem.eql(u8, entry.name, "link")) try std.testing.expect(entry.kind == .sym_link and entry.directory);
        if (std.mem.eql(u8, entry.name, "broken")) try std.testing.expect(entry.kind == .sym_link and !entry.directory);
        if (std.mem.eql(u8, entry.name, "name\n\xff")) try std.testing.expectEqual(@as(?u64, 4), entry.size);
    }
    var with_hidden = try local.scan(null, io, path_buffer[0..len], .{ .hidden = true }, &canceled);
    defer with_hidden.deinit();
    try std.testing.expectEqual(@as(usize, 5), with_hidden.entries.len);
    canceled.store(true, .release);
    try std.testing.expectError(error.Canceled, local.scan(null, io, path_buffer[0..len], .{}, &canceled));
}

test "local resolution owns absolute relative home child parent and root semantics" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { base: []const u8, resolution: Resolution, expected: []const u8 }{
        .{ .base = "/tmp/a", .resolution = .{ .user_input = "../b" }, .expected = "/tmp/b" },
        .{ .base = "/tmp/a", .resolution = .{ .user_input = "/usr/../var" }, .expected = "/var" },
        .{ .base = "/tmp", .resolution = .{ .child = "~literal" }, .expected = "/tmp/~literal" },
        .{ .base = "/tmp/a", .resolution = .parent, .expected = "/tmp" },
        .{ .base = "/tmp/a", .resolution = .root, .expected = "/" },
    };
    for (cases) |case| {
        const resolved = try local.resolve(null, allocator, case.base, case.resolution);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings(case.expected, resolved);
    }
    const c = @import("../platform/linux.zig").c;
    if (c.getenv("HOME")) |home| {
        const resolved = try local.resolve(null, allocator, "/tmp", .{ .user_input = "~/folder" });
        defer allocator.free(resolved);
        const expected = try std.fs.path.resolve(allocator, &.{ std.mem.span(home), "folder" });
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, resolved);
    }
}

test "local Provider references preserve file directory and symlink name bytes" {
    const allocator = std.testing.allocator;
    for ([_]std.Io.File.Kind{ .file, .directory, .sym_link }) |kind| {
        const raw = try local.reference.?(null, allocator, "/somewhere", .{ .name = "raw\xff' link", .kind = kind, .directory = kind == .directory, .size = null, .modified = null });
        defer allocator.free(raw);
        try std.testing.expectEqualStrings("/somewhere/raw\xff' link", raw);
    }
}
