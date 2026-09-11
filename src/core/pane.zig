//! UI-owned navigation state with one concurrent scan per pane. New requests
//! supersede pending work; the UI never waits for a scan during navigation.
const std = @import("std");
const directory = @import("directory.zig");

const Job = struct {
    path: []const u8,
    hint: ?[]const u8,
    options: directory.Options,
    provider: directory.Provider,
    canceled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    result: ?directory.Snapshot = null,
    failure: ?anyerror = null,
    future: ?std.Io.Future(void) = null,

    fn work(self: *Job, io: std.Io) void {
        self.result = self.provider.scan(self.provider.context, io, self.path, self.options, &self.canceled) catch |err| result: {
            self.failure = err;
            break :result null;
        };
        self.done.store(true, .release);
    }
    fn destroy(self: *Job, allocator: std.mem.Allocator) void {
        if (self.result) |*result| result.deinit();
        allocator.free(self.path);
        if (self.hint) |hint| allocator.free(hint);
        allocator.destroy(self);
    }
};

pub const Pane = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: directory.Provider = directory.local,
    initial_path: []const u8,
    snapshot: ?directory.Snapshot = null,
    job: ?*Job = null,
    pending: ?*Job = null,
    options: directory.Options = .{},
    cursor: usize = 0, // Includes a synthetic parent entry, if not at root.
    scroll: usize = 0,
    marked_count: usize = 0,
    failure: ?anyerror = null,
    failed_path: ?[]const u8 = null,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, start_path: []const u8) !Pane {
        return .{ .io = io, .allocator = allocator, .initial_path = try allocator.dupe(u8, start_path) };
    }
    pub fn deinit(self: *Pane) void {
        if (self.job) |job| {
            job.canceled.store(true, .release);
            job.future.?.cancel(self.io);
            job.destroy(self.allocator);
        }
        if (self.pending) |pending| pending.destroy(self.allocator);
        if (self.snapshot) |*snapshot| snapshot.deinit();
        if (self.failed_path) |failed| self.allocator.free(failed);
        self.allocator.free(self.initial_path);
    }
    pub fn path(self: *const Pane) []const u8 {
        return if (self.snapshot) |snapshot| snapshot.path else self.initial_path;
    }
    pub fn busy(self: *const Pane) bool {
        return self.job != null or self.pending != null;
    }
    pub fn hasParent(self: *const Pane) bool {
        return !std.mem.eql(u8, self.path(), "/");
    }
    pub fn entries(self: *const Pane) []directory.Entry {
        return if (self.snapshot) |snapshot| snapshot.entries else &.{};
    }
    pub fn count(self: *const Pane) usize {
        return self.entries().len + @intFromBool(self.hasParent());
    }
    pub fn focused(self: *const Pane) ?*directory.Entry {
        const parent_offset: usize = @intFromBool(self.hasParent());
        if (self.cursor < parent_offset or self.cursor - parent_offset >= self.entries().len) return null;
        return &self.entries()[self.cursor - parent_offset];
    }
    pub fn selectedCount(self: *const Pane) usize {
        return self.marked_count;
    }
    pub fn move(self: *Pane, delta: isize) void {
        const position = @as(isize, @intCast(self.cursor)) + delta;
        self.cursor = @intCast(std.math.clamp(position, 0, @as(isize, @intCast(self.count() -| 1))));
    }
    /// Toggle the inclusive cursor-to-target range, skipping the parent row.
    pub fn markTo(self: *Pane, target: usize) void {
        const old = @min(self.cursor, self.count() -| 1);
        self.cursor = @min(target, self.count() -| 1);
        const offset: usize = @intFromBool(self.hasParent());
        const first = @max(@min(old, self.cursor), offset);
        const end = @min(@max(old, self.cursor) + 1, self.count());
        if (first >= end) return;
        for (self.entries()[first - offset .. end - offset]) |*entry| {
            if (entry.selected) self.marked_count -= 1 else self.marked_count += 1;
            entry.selected = !entry.selected;
        }
    }
    pub fn moveMarked(self: *Pane, delta: isize) void {
        // Toggle only the departing row so repeated Shift+arrows do not undo
        // the previous event's endpoint while moving in the same direction.
        self.toggleSelection();
        self.move(delta);
    }
    pub fn ensureVisible(self: *Pane, rows: usize) void {
        self.cursor = @min(self.cursor, self.count() -| 1);
        if (rows == 0) return;
        if (self.cursor < self.scroll) self.scroll = self.cursor;
        if (self.cursor >= self.scroll + rows) self.scroll = self.cursor - rows + 1;
        self.scroll = @min(self.scroll, self.count() -| rows);
    }
    pub fn toggleSelection(self: *Pane) void {
        if (self.focused()) |entry| {
            if (entry.selected) self.marked_count -= 1 else self.marked_count += 1;
            entry.selected = !entry.selected;
        }
    }
    pub fn clearError(self: *Pane) void {
        self.failure = null;
        if (self.failed_path) |p| self.allocator.free(p);
        self.failed_path = null;
    }
    pub fn cancelNavigation(self: *Pane) void {
        if (self.job) |job| job.canceled.store(true, .release);
        if (self.pending) |pending| pending.destroy(self.allocator);
        self.pending = null;
        self.clearError();
    }

    pub fn request(self: *Pane, target: []const u8, hint: ?[]const u8) !void {
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        const normalized = try std.fs.path.resolve(self.allocator, &.{ self.path(), target });
        errdefer self.allocator.free(normalized);
        job.* = .{
            .path = normalized,
            .hint = if (hint) |h| try self.allocator.dupe(u8, h) else null,
            .options = self.options,
            .provider = self.provider,
        };
        if (self.pending) |pending| pending.destroy(self.allocator);
        self.pending = job;
        if (self.job) |current| current.canceled.store(true, .release);
        self.clearError();
        self.launch();
    }
    fn launch(self: *Pane) void {
        if (self.job != null) return;
        const job = self.pending orelse return;
        self.pending = null;
        job.future = self.io.concurrent(Job.work, .{ job, self.io }) catch |err| {
            self.failure = err;
            self.failed_path = self.allocator.dupe(u8, job.path) catch null;
            job.destroy(self.allocator);
            return;
        };
        self.job = job;
    }
    pub fn poll(self: *Pane) !bool {
        const job = self.job orelse return false;
        if (!job.done.load(.acquire)) return false;
        job.future.?.await(self.io);
        self.job = null;
        defer job.destroy(self.allocator);
        if (!job.canceled.load(.acquire)) {
            self.clearError();
            if (job.result) |snapshot| {
                const same_path = std.mem.eql(u8, self.path(), snapshot.path);
                const old_name = if (self.focused()) |entry| entry.name else "..";
                const wanted = job.hint orelse if (same_path) old_name else "..";
                // Preserve marked entries by exact name, independent of sorting.
                var selected: std.StringHashMap(void) = .init(self.allocator);
                defer selected.deinit();
                if (same_path) for (self.entries()) |entry| {
                    if (entry.selected) try selected.put(entry.name, {});
                };
                const parent_offset: usize = @intFromBool(!std.mem.eql(u8, snapshot.path, "/"));
                var next_cursor: usize = if (same_path) @min(self.cursor, (snapshot.entries.len + parent_offset) -| 1) else 0;
                self.marked_count = 0;
                for (snapshot.entries, 0..) |*entry, i| {
                    entry.selected = selected.contains(entry.name);
                    if (entry.selected) self.marked_count += 1;
                    if (std.mem.eql(u8, entry.name, wanted)) next_cursor = i + parent_offset;
                }
                if (self.snapshot) |*old| old.deinit();
                self.snapshot = snapshot;
                job.result = null;
                self.cursor = next_cursor;
                if (!same_path) self.scroll = 0;
            } else {
                self.failure = job.failure orelse error.ReadFailed;
                self.failed_path = try self.allocator.dupe(u8, job.path);
                // Retain the last good listing and location on failure.
            }
        }
        self.launch();
        return true;
    }
    pub fn refresh(self: *Pane) !void {
        try self.request(self.path(), null);
    }
    pub fn parent(self: *Pane) !void {
        if (!self.hasParent()) return;
        try self.request(std.fs.path.dirname(self.path()) orelse "/", std.fs.path.basename(self.path()));
    }
    pub fn enter(self: *Pane) !void {
        if (self.busy()) return;
        if (self.hasParent() and self.cursor == 0) return self.parent();
        if (self.focused()) |entry| {
            if (entry.directory or entry.kind == .sym_link) try self.request(entry.name, null);
        }
    }
};

fn waitForScan(pane: *Pane) !void {
    for (0..5000) |_| {
        _ = try pane.poll();
        if (!pane.busy()) return;
        try std.Io.sleep(pane.io, .fromMilliseconds(1), .awake);
    }
    return error.ScanTimeout;
}

test "navigation preserves names across sorting and keeps the old listing after failure" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "child", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b", .data = "bb" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const base = buffer[0..len];
    var pane = try Pane.init(io, allocator, base);
    defer pane.deinit();
    try pane.refresh();
    try waitForScan(&pane);
    pane.cursor = 2;
    pane.toggleSelection();
    try std.testing.expectEqualStrings("a", pane.focused().?.name);
    pane.options.reverse = true;
    try pane.refresh();
    try waitForScan(&pane);
    try std.testing.expectEqualStrings("a", pane.focused().?.name);
    try std.testing.expect(pane.focused().?.selected);
    try pane.request("missing", null);
    try waitForScan(&pane);
    try std.testing.expectEqual(error.FileNotFound, pane.failure.?);
    try std.testing.expectEqualStrings(base, pane.path());
    try std.testing.expectEqualStrings("a", pane.focused().?.name);
    try pane.request("child", null);
    try waitForScan(&pane);
    try pane.parent();
    try waitForScan(&pane);
    try std.testing.expectEqualStrings("child", pane.focused().?.name);
    try std.testing.expectEqualStrings(base, pane.path());
}

test "superseded scans cannot replace the most recent location" {
    const Controlled = struct {
        started: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        fn scan(context: ?*anyopaque, io: std.Io, target: []const u8, options: directory.Options, _: *const std.atomic.Value(bool)) anyerror!directory.Snapshot {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (std.mem.eql(u8, target, "/slow")) {
                self.started.store(true, .release);
                while (!self.release.load(.acquire)) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            }
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            errdefer arena.deinit();
            return .{ .arena = arena, .path = try arena.allocator().dupe(u8, target), .entries = &.{}, .options = options };
        }
    };
    var controlled: Controlled = .{};
    var pane = try Pane.init(std.testing.io, std.testing.allocator, "/");
    defer pane.deinit();
    pane.provider = .{ .context = &controlled, .scan = Controlled.scan };
    try pane.request("/slow", null);
    for (0..5000) |_| {
        if (controlled.started.load(.acquire)) break;
        try std.Io.sleep(pane.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(controlled.started.load(.acquire));
    try pane.request("/discarded", null);
    try pane.request("/latest", null);
    try std.testing.expectEqualStrings("/", pane.path());
    controlled.release.store(true, .release);
    try waitForScan(&pane);
    try std.testing.expectEqualStrings("/latest", pane.path());
}

test "canceling navigation retains the current location and drops a pending request" {
    const io = std.testing.io;
    var pane = try Pane.init(io, std.testing.allocator, "/");
    defer pane.deinit();
    // Even an already-finished worker may not publish after it is canceled.
    try pane.request("/tmp", null);
    try pane.request("/usr", null);
    pane.cancelNavigation();
    try waitForScan(&pane);
    try std.testing.expectEqualStrings("/", pane.path());
    try std.testing.expect(pane.snapshot == null);
    try std.testing.expect(pane.failure == null);
}

test "shift marking toggles traversed entries and preserves counts across refresh" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a", "b", "c", "d" }) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    var pane = try Pane.init(io, std.testing.allocator, buffer[0..len]);
    defer pane.deinit();
    try pane.refresh();
    try waitForScan(&pane);
    pane.moveMarked(-1);
    pane.moveMarked(1); // Parent -> a does not mark the synthetic parent.
    try std.testing.expectEqual(@as(usize, 0), pane.selectedCount());
    pane.moveMarked(1); // Mark a, move to b.
    pane.moveMarked(1); // Mark b, move to c; a stays marked.
    try std.testing.expectEqualStrings("c", pane.focused().?.name);
    try std.testing.expectEqual(@as(usize, 2), pane.selectedCount());
    try std.testing.expect(pane.entries()[0].selected and pane.entries()[1].selected);
    pane.move(-2); // Return to a without changing marks.
    pane.moveMarked(1);
    try std.testing.expect(!pane.entries()[0].selected);
    try std.testing.expectEqual(@as(usize, 1), pane.selectedCount());
    pane.moveMarked(-1); // Unmark b and move back to a.
    try std.testing.expectEqual(@as(usize, 0), pane.selectedCount());
    pane.markTo(std.math.maxInt(usize)); // Toggle a..d on.
    try std.testing.expectEqual(@as(usize, 4), pane.selectedCount());
    pane.moveMarked(1); // At the bottom, toggle d off without moving.
    try std.testing.expectEqual(@as(usize, 3), pane.selectedCount());
    pane.markTo(0); // Mixed range: a/b/c off, d on; parent stays excluded.
    try std.testing.expectEqual(@as(usize, 1), pane.selectedCount());
    try std.testing.expect(pane.entries()[3].selected);
    pane.markTo(4); // Mixed range: a/b/c on, d off.
    try std.testing.expectEqual(@as(usize, 3), pane.selectedCount());
    pane.options.reverse = true;
    try pane.refresh();
    try waitForScan(&pane);
    try std.testing.expectEqualStrings("d", pane.focused().?.name);
    try std.testing.expect(!pane.focused().?.selected);
    try std.testing.expectEqual(@as(usize, 3), pane.selectedCount());
}

test "shift marking empty panes cannot select a synthetic parent" {
    for ([_][]const u8{ "/", "/empty" }) |path| {
        var pane = try Pane.init(std.testing.io, std.testing.allocator, path);
        defer pane.deinit();
        pane.moveMarked(1);
        pane.moveMarked(-1);
        pane.markTo(std.math.maxInt(usize));
        pane.markTo(0);
        try std.testing.expectEqual(@as(usize, 0), pane.selectedCount());
        try std.testing.expectEqual(@as(usize, 0), pane.cursor);
    }
}
