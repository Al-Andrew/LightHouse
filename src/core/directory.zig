//! Provider-neutral listing data. A completed snapshot owns its names and path.
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
    selected: bool = false,
};
pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    entries: []Entry,
    options: Options,
    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }
};

pub const Provider = struct {
    // Called on a worker. Context must outlive its pane; ownership of a returned
    // snapshot transfers to the UI only after the scan completes. This is an
    // internal interface, not the future native-plugin ABI.
    context: ?*anyopaque = null,
    scan: *const fn (?*anyopaque, std.Io, []const u8, Options, *const std.atomic.Value(bool)) anyerror!Snapshot,
};
pub const local: Provider = .{ .scan = scanLocal };

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
    return .{ .arena = arena, .path = try allocator.dupe(u8, path), .entries = entries.items, .options = options };
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
