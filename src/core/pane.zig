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

/// One UI thread owns the pane. Observations borrow storage until the next
/// mutating call or destroy; callers must copy names that need to live longer.
/// Drawing only consumes View values and never normalizes navigation state.
pub const Pane = opaque {
    pub const Config = struct { provider: directory.Provider = directory.local };
    pub const Movement = union(enum) { by: isize, first, last, page_up, page_down };
    pub const ListingChange = enum { toggle_hidden, cycle_sort, reverse };
    pub const Status = union(enum) {
        ready,
        loading,
        failed: struct { err: anyerror, path: ?[]const u8 },
    };
    pub const RowKind = enum { current, parent, entry };
    pub const Row = struct {
        kind: RowKind,
        // Reference rows are never filesystem entries.
        entry: ?*const directory.Entry,
        focused: bool,
        marked: bool,
    };
    pub const View = struct {
        path: []const u8,
        has_parent: bool,
        marks: []const bool,
        entries: []const directory.Entry,
        cursor: usize,
        first_visible: usize,
        visible_rows: usize,
        marked_count: usize,
        requested_options: directory.Options,
        options: directory.Options,
        status: Status,

        pub fn referenceRowCount(self: View) usize {
            return 1 + @as(usize, @intFromBool(self.has_parent));
        }

        fn entryAt(self: View, index: usize) ?*const directory.Entry {
            const reference_offset: usize = self.referenceRowCount();
            if (index < reference_offset or index - reference_offset >= self.entries.len) return null;
            return &self.entries[index - reference_offset];
        }

        pub fn focusedMarked(self: View) bool {
            return self.focused() != null and self.marks[self.cursor - self.referenceRowCount()];
        }

        pub fn focused(self: View) ?*const directory.Entry {
            return self.entryAt(self.cursor);
        }

        /// A viewport-relative row, with reference-row mapping and cursor state resolved.
        pub fn row(self: View, offset: usize) ?Row {
            if (offset >= self.visible_rows) return null;
            const index = self.first_visible +| offset;
            const count = self.entries.len + self.referenceRowCount();
            if (index >= count) return null;
            return .{ .kind = if (index == 0) .current else if (index < self.referenceRowCount()) .parent else .entry, .entry = self.entryAt(index), .focused = index == self.cursor, .marked = if (self.entryAt(index) != null) self.marks[index - self.referenceRowCount()] else false };
        }
    };
    /// Short-lived, read-only iteration in displayed order. Reference rows are never
    /// sources; marks take precedence over the cursor. Consume before mutation.
    pub const Sources = struct {
        entries: []const directory.Entry,
        marked_only: bool,
        marks: []const bool = &.{},
        count: usize,
        offset: usize = 0,

        pub fn next(self: *Sources) ?[]const u8 {
            while (self.offset < self.entries.len) {
                const entry = &self.entries[self.offset];
                self.offset += 1;
                if (!self.marked_only or self.marks[self.offset - 1]) return entry.name;
            }
            return null;
        }
    };

    pub fn create(io: std.Io, allocator: std.mem.Allocator, start_path: []const u8, config: Config) !*Pane {
        const self = try allocator.create(Implementation);
        errdefer allocator.destroy(self);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .initial_path = try allocator.dupe(u8, start_path),
            .provider = config.provider,
        };
        return @ptrCast(self);
    }

    pub fn destroy(pane: *Pane) void {
        const self = pane.implementation();
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn view(pane: *const Pane) View {
        const self = pane.read();
        return .{
            .path = self.provider.display(self.provider.context, self.path()),
            .has_parent = self.hasParent(),
            .marks = self.marks,
            .entries = self.entries(),
            .cursor = self.cursor,
            .first_visible = self.scroll,
            .visible_rows = self.viewport_rows,
            .marked_count = self.marked_count,
            .requested_options = self.options,
            .options = if (self.snapshot) |snapshot| snapshot.options else self.options,
            .status = if (self.failure) |err|
                .{ .failed = .{ .err = err, .path = self.failed_path } }
            else if (self.busy()) .loading else .ready,
        };
    }

    /// Owned Provider representation of the Cursor row, independent of Marks.
    pub fn cursorReference(pane: *const Pane, allocator: std.mem.Allocator) ![]const u8 {
        const self = pane.read();
        if (self.focused()) |entry| {
            const reference = self.provider.reference orelse return error.UnsupportedReference;
            return reference(self.provider.context, allocator, self.path(), entry.*);
        }
        const reference = self.provider.location_reference orelse return error.UnsupportedReference;
        if (self.cursor == 0) return reference(self.provider.context, allocator, self.path());
        const parent_path = try self.provider.resolve(self.provider.context, allocator, self.path(), .parent);
        defer allocator.free(parent_path);
        return reference(self.provider.context, allocator, parent_path);
    }

    pub fn sources(pane: *const Pane) Sources {
        const self = pane.read();
        if (self.marked_count > 0) return .{ .entries = self.entries(), .marked_only = true, .marks = self.marks, .count = self.marked_count };
        if (self.focused() != null) {
            const index = self.cursor - self.referenceRowCount();
            return .{ .entries = self.entries()[index..][0..1], .marked_only = false, .count = 1 };
        }
        return .{ .entries = &.{}, .marked_only = false, .count = 0 };
    }

    /// Relative movement with marking toggles the departing row; first/last
    /// movement with marking toggles the inclusive range. Both skip reference rows.
    pub fn move(pane: *Pane, movement: Movement, mark: bool) void {
        const self = pane.implementation();
        switch (movement) {
            .first, .last => {
                const target = if (movement == .first) 0 else self.count() -| 1;
                if (mark) self.markTo(target) else {
                    self.cursor = target;
                    self.ensureVisible();
                }
            },
            .by, .page_up, .page_down => {
                const page: isize = @intCast(@min(@max(1, self.viewport_rows), std.math.maxInt(isize)));
                const delta = switch (movement) {
                    .by => |value| value,
                    .page_up => -page,
                    .page_down => page,
                    else => unreachable,
                };
                if (mark) self.moveMarked(delta) else self.move(delta);
            },
        }
    }

    pub fn toggleSelection(pane: *Pane) void {
        pane.implementation().toggleSelection();
    }

    pub fn setViewportRows(pane: *Pane, rows: usize) void {
        const self = pane.implementation();
        self.viewport_rows = rows;
        self.ensureVisible();
    }

    /// Requested options survive canceled and failed scans. Displayed options
    /// remain attached to the last published listing until a new scan succeeds.
    pub fn changeListing(pane: *Pane, change: ListingChange) !void {
        const self = pane.implementation();
        switch (change) {
            .toggle_hidden => self.options.hidden = !self.options.hidden,
            .cycle_sort => self.options.sort = switch (self.options.sort) {
                .name => .size,
                .size => .modified,
                .modified => .name,
            },
            .reverse => self.options.reverse = !self.options.reverse,
        }
        try self.refresh();
    }

    pub fn request(pane: *Pane, target: []const u8) !void {
        const self = pane.implementation();
        const resolved = try self.provider.resolve(self.provider.context, self.allocator, self.path(), .{ .user_input = target });
        defer self.allocator.free(resolved);
        try self.request(resolved, null);
    }
    pub fn provider(pane: *const Pane) directory.Provider {
        return pane.read().provider;
    }
    pub fn location(pane: *const Pane) directory.Location {
        return pane.read().provider.location(pane.read().path());
    }
    pub fn rootInput(pane: *const Pane, allocator: std.mem.Allocator) ![]const u8 {
        const self = pane.read();
        return self.provider.resolve(self.provider.context, allocator, self.path(), .root);
    }
    pub fn refresh(pane: *Pane) !void {
        try pane.implementation().refresh();
    }
    pub fn parent(pane: *Pane) !void {
        try pane.implementation().parent();
    }
    pub fn enter(pane: *Pane) !void {
        try pane.implementation().enter();
    }
    pub fn cancelNavigation(pane: *Pane) void {
        pane.implementation().cancelNavigation();
    }
    pub fn poll(pane: *Pane) !bool {
        return pane.implementation().poll();
    }

    fn implementation(pane: *Pane) *Implementation {
        return @ptrCast(@alignCast(pane));
    }
    fn read(pane: *const Pane) *const Implementation {
        return @ptrCast(@alignCast(pane));
    }
};

const Implementation = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: directory.Provider = directory.local,
    initial_path: []const u8,
    snapshot: ?directory.Snapshot = null,
    job: ?*Job = null,
    pending: ?*Job = null,
    options: directory.Options = .{},
    cursor: usize = 0, // Includes the synthetic current and parent rows.
    scroll: usize = 0,
    viewport_rows: usize = 0,
    marked_count: usize = 0,
    marks: []bool = &.{},
    failure: ?anyerror = null,
    failed_path: ?[]const u8 = null,

    fn deinit(self: *Implementation) void {
        if (self.job) |job| {
            job.canceled.store(true, .release);
            job.future.?.cancel(self.io);
            job.destroy(self.allocator);
        }
        if (self.pending) |pending| pending.destroy(self.allocator);
        if (self.snapshot) |*snapshot| snapshot.deinit();
        if (self.failed_path) |failed| self.allocator.free(failed);
        self.allocator.free(self.initial_path);
        self.allocator.free(self.marks);
    }
    fn path(self: *const Implementation) []const u8 {
        return if (self.snapshot) |snapshot| snapshot.locator else self.initial_path;
    }
    fn busy(self: *const Implementation) bool {
        return self.job != null or self.pending != null;
    }
    fn hasParent(self: *const Implementation) bool {
        return self.provider.show_root_parent or self.provider.has_parent(self.provider.context, self.path());
    }
    fn referenceRowCount(self: *const Implementation) usize {
        return 1 + @as(usize, @intFromBool(self.hasParent()));
    }
    fn entries(self: *const Implementation) []directory.Entry {
        return if (self.snapshot) |snapshot| snapshot.entries else &.{};
    }
    fn count(self: *const Implementation) usize {
        return self.entries().len + self.referenceRowCount();
    }
    fn focused(self: *const Implementation) ?*directory.Entry {
        const reference_offset: usize = self.referenceRowCount();
        if (self.cursor < reference_offset or self.cursor - reference_offset >= self.entries().len) return null;
        return &self.entries()[self.cursor - reference_offset];
    }
    fn move(self: *Implementation, delta: isize) void {
        const position = @as(isize, @intCast(self.cursor)) +| delta;
        self.cursor = @intCast(std.math.clamp(position, 0, @as(isize, @intCast(self.count() -| 1))));
        self.ensureVisible();
    }
    /// Toggle the inclusive cursor-to-target range, skipping reference rows.
    fn markTo(self: *Implementation, target: usize) void {
        defer self.ensureVisible();
        const old = @min(self.cursor, self.count() -| 1);
        self.cursor = @min(target, self.count() -| 1);
        const offset: usize = self.referenceRowCount();
        const first = @max(@min(old, self.cursor), offset);
        const end = @min(@max(old, self.cursor) + 1, self.count());
        if (first >= end) return;
        for (self.marks[first - offset .. end - offset]) |*marked| {
            if (marked.*) self.marked_count -= 1 else self.marked_count += 1;
            marked.* = !marked.*;
        }
    }
    fn moveMarked(self: *Implementation, delta: isize) void {
        // Toggle only the departing row so repeated Shift+arrows do not undo
        // the previous event's endpoint while moving in the same direction.
        self.toggleSelection();
        self.move(delta);
    }
    fn ensureVisible(self: *Implementation) void {
        self.cursor = @min(self.cursor, self.count() -| 1);
        // A hidden viewport still maintains a valid anchor and uses one-row
        // paging. Restoring its dimensions reveals the current cursor.
        const rows = @max(1, self.viewport_rows);
        if (self.cursor < self.scroll) self.scroll = self.cursor;
        if (self.cursor - self.scroll >= rows) self.scroll = self.cursor - rows + 1;
        self.scroll = @min(self.scroll, self.count() -| rows);
    }
    fn toggleSelection(self: *Implementation) void {
        if (self.focused() != null) {
            const marked = &self.marks[self.cursor - self.referenceRowCount()];
            if (marked.*) self.marked_count -= 1 else self.marked_count += 1;
            marked.* = !marked.*;
        }
    }
    fn clearError(self: *Implementation) void {
        self.failure = null;
        if (self.failed_path) |p| self.allocator.free(p);
        self.failed_path = null;
    }
    fn cancelNavigation(self: *Implementation) void {
        if (self.job) |job| job.canceled.store(true, .release);
        if (self.pending) |pending| pending.destroy(self.allocator);
        self.pending = null;
        self.clearError();
    }

    fn request(self: *Implementation, target: []const u8, hint: ?[]const u8) !void {
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        const normalized = try self.allocator.dupe(u8, target);
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
    fn launch(self: *Implementation) void {
        if (self.job != null) return;
        const job = self.pending orelse return;
        self.pending = null;
        job.future = self.io.concurrent(Job.work, .{ job, self.io }) catch |err| {
            self.failure = err;
            self.failed_path = self.allocator.dupe(u8, self.provider.display(self.provider.context, job.path)) catch null;
            job.destroy(self.allocator);
            return;
        };
        self.job = job;
    }
    fn poll(self: *Implementation) !bool {
        const job = self.job orelse return false;
        if (!job.done.load(.acquire)) return false;
        job.future.?.await(self.io);
        self.job = null;
        defer self.launch();
        defer job.destroy(self.allocator);
        if (!job.canceled.load(.acquire)) {
            self.clearError();
            if (job.result) |snapshot| {
                const same_path = directory.Location.eql(self.provider.location(self.path()), self.provider.location(snapshot.locator));
                const old_name = if (self.focused()) |entry| entry.name else if (self.cursor == 0) "." else "..";
                const wanted = job.hint orelse if (same_path) old_name else ".";
                // Preserve marked entries by exact name, independent of sorting.
                var selected: std.StringHashMap(void) = .init(self.allocator);
                defer selected.deinit();
                if (same_path) for (self.entries(), self.marks) |entry, marked| {
                    if (marked) try selected.put(entry.name, {});
                };
                const reference_offset: usize = 1 + @as(usize, @intFromBool(self.provider.show_root_parent or self.provider.has_parent(self.provider.context, snapshot.locator)));
                const next_marks = try self.allocator.alloc(bool, snapshot.entries.len);
                var next_cursor: usize = if (same_path) @min(self.cursor, (snapshot.entries.len + reference_offset) -| 1) else 0;
                self.marked_count = 0;
                for (snapshot.entries, 0..) |entry, i| {
                    next_marks[i] = selected.contains(entry.name);
                    if (next_marks[i]) self.marked_count += 1;
                    if (std.mem.eql(u8, entry.name, wanted)) next_cursor = i + reference_offset;
                }
                if (self.snapshot) |*old| old.deinit();
                self.allocator.free(self.marks);
                self.marks = next_marks;
                self.snapshot = snapshot;
                job.result = null;
                self.cursor = next_cursor;
                if (!same_path) self.scroll = 0;
                self.ensureVisible();
            } else {
                self.failure = job.failure orelse error.ReadFailed;
                self.failed_path = try self.allocator.dupe(u8, self.provider.display(self.provider.context, job.path));
                // Retain the last good listing and location on failure.
            }
        }
        return true;
    }
    fn refresh(self: *Implementation) !void {
        try self.request(self.path(), null);
    }
    fn parent(self: *Implementation) !void {
        if (!self.provider.has_parent(self.provider.context, self.path())) return;
        const parent_path = try self.provider.resolve(self.provider.context, self.allocator, self.path(), .parent);
        defer self.allocator.free(parent_path);
        try self.request(parent_path, self.provider.parent_hint(self.provider.context, self.path()));
    }
    fn enter(self: *Implementation) !void {
        if (self.busy()) return;
        if (self.cursor == 0) return;
        if (self.hasParent() and self.cursor == 1) return self.parent();
        if (self.focused()) |entry| {
            if (entry.directory or entry.kind == .sym_link) {
                const child = try self.provider.resolve(self.provider.context, self.allocator, self.path(), .{ .child = entry.name });
                defer self.allocator.free(child);
                try self.request(child, null);
            }
        }
    }
};

fn waitForScan(pane: *Pane) !void {
    for (0..5000) |_| {
        _ = try pane.poll();
        if (pane.view().status != .loading) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
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
    const pane = try Pane.create(io, allocator, base, .{});
    defer pane.destroy();
    try pane.refresh();
    try waitForScan(pane);
    pane.move(.{ .by = 3 }, false);
    pane.toggleSelection();
    try std.testing.expectEqualStrings("a", pane.view().focused().?.name);
    try pane.changeListing(.reverse);
    try waitForScan(pane);
    try std.testing.expectEqualStrings("a", pane.view().focused().?.name);
    try std.testing.expect(pane.view().focusedMarked());
    try pane.request("missing");
    try waitForScan(pane);
    try std.testing.expectEqual(error.FileNotFound, pane.view().status.failed.err);
    try std.testing.expectEqualStrings(base, pane.view().path);
    try std.testing.expectEqualStrings("a", pane.view().focused().?.name);
    try pane.request("child");
    try waitForScan(pane);
    try pane.parent();
    try waitForScan(pane);
    try std.testing.expectEqualStrings("child", pane.view().focused().?.name);
    try std.testing.expectEqualStrings(base, pane.view().path);
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
            return .{ .arena = arena, .locator = try arena.allocator().dupe(u8, target), .entries = &.{}, .options = options };
        }
    };
    var controlled: Controlled = .{};
    const pane = try Pane.create(std.testing.io, std.testing.allocator, "/", .{ .provider = testLocalProvider(&controlled, Controlled.scan) });
    defer pane.destroy();
    defer controlled.release.store(true, .release);
    try pane.request("/slow");
    for (0..5000) |_| {
        if (controlled.started.load(.acquire)) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(controlled.started.load(.acquire));
    try pane.request("/discarded");
    try pane.request("/latest");
    try std.testing.expectEqualStrings("/", pane.view().path);
    controlled.release.store(true, .release);
    try waitForScan(pane);
    try std.testing.expectEqualStrings("/latest", pane.view().path);
}

test "canceling navigation retains the current location and drops a pending request" {
    const io = std.testing.io;
    const pane = try Pane.create(io, std.testing.allocator, "/", .{});
    defer pane.destroy();
    // Even an already-finished worker may not publish after it is canceled.
    try pane.request("/tmp");
    try pane.request("/usr");
    pane.cancelNavigation();
    try waitForScan(pane);
    try std.testing.expectEqualStrings("/", pane.view().path);
    try std.testing.expect(pane.view().entries.len == 0);
    try std.testing.expect(pane.view().status == .ready);
}

test "shift marking toggles traversed entries and preserves counts across refresh" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a", "b", "c", "d" }) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const pane = try Pane.create(io, std.testing.allocator, buffer[0..len], .{});
    defer pane.destroy();
    try pane.refresh();
    try waitForScan(pane);
    pane.move(.{ .by = -1 }, true);
    pane.move(.{ .by = 2 }, true); // Current -> a skips both reference rows.
    try std.testing.expectEqual(@as(usize, 0), pane.view().marked_count);
    pane.move(.{ .by = 1 }, true); // Mark a, move to b.
    pane.move(.{ .by = 1 }, true); // Mark b, move to c; a stays marked.
    try std.testing.expectEqualStrings("c", pane.view().focused().?.name);
    try std.testing.expectEqual(@as(usize, 2), pane.view().marked_count);
    try std.testing.expect(pane.view().marks[0] and pane.view().marks[1]);
    pane.move(.{ .by = -2 }, false); // Return to a without changing marks.
    pane.move(.{ .by = 1 }, true);
    try std.testing.expect(!pane.view().marks[0]);
    try std.testing.expectEqual(@as(usize, 1), pane.view().marked_count);
    pane.move(.{ .by = -1 }, true); // Unmark b and move back to a.
    try std.testing.expectEqual(@as(usize, 0), pane.view().marked_count);
    pane.move(.last, true); // Toggle a..d on.
    try std.testing.expectEqual(@as(usize, 4), pane.view().marked_count);
    pane.move(.{ .by = 1 }, true); // At the bottom, toggle d off without moving.
    try std.testing.expectEqual(@as(usize, 3), pane.view().marked_count);
    pane.move(.first, true); // Mixed range: a/b/c off, d on; reference rows stay excluded.
    try std.testing.expectEqual(@as(usize, 1), pane.view().marked_count);
    try std.testing.expect(pane.view().marks[3]);
    pane.move(.last, true); // Mixed range: a/b/c on, d off.
    try std.testing.expectEqual(@as(usize, 3), pane.view().marked_count);
    try pane.changeListing(.reverse);
    try waitForScan(pane);
    try std.testing.expectEqualStrings("d", pane.view().focused().?.name);
    try std.testing.expect(!pane.view().focusedMarked());
    try std.testing.expectEqual(@as(usize, 3), pane.view().marked_count);
}

test "shift marking empty panes cannot mark synthetic reference rows" {
    for ([_][]const u8{ "/", "/empty" }) |path| {
        const pane = try Pane.create(std.testing.io, std.testing.allocator, path, .{});
        defer pane.destroy();
        pane.move(.{ .by = 1 }, true);
        pane.move(.{ .by = -1 }, true);
        pane.move(.last, true);
        pane.move(.first, true);
        try std.testing.expectEqual(@as(usize, 0), pane.view().marked_count);
        try std.testing.expectEqual(@as(usize, 0), pane.view().cursor);
    }
}

const TestScan = struct {
    blocked: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(bool) = .init(false),
    fail: bool = false,

    fn provider(self: *TestScan) directory.Provider {
        return testLocalProvider(self, scan);
    }
    fn block(self: *TestScan) void {
        self.entered.store(false, .release);
        self.blocked.store(true, .release);
    }
    fn unblock(self: *TestScan) void {
        self.blocked.store(false, .release);
    }
    fn waitUntilEntered(self: *TestScan) !void {
        for (0..5000) |_| {
            if (self.entered.load(.acquire)) return;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        return error.ScanTimeout;
    }
    fn scan(context: ?*anyopaque, io: std.Io, path: []const u8, options: directory.Options, canceled: *const std.atomic.Value(bool)) anyerror!directory.Snapshot {
        const self: *TestScan = @ptrCast(@alignCast(context.?));
        self.entered.store(true, .release);
        while (self.blocked.load(.acquire)) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        if (self.fail) return error.AccessDenied;
        return directory.local.scan(null, io, path, options, canceled);
    }
};

test "requested options survive cancellation and failure while displayed options match the listing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "long" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b", .data = "b" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    var scan: TestScan = .{};
    const pane = try Pane.create(io, std.testing.allocator, buffer[0..len], .{ .provider = scan.provider() });
    defer pane.destroy();
    defer scan.unblock();
    try pane.refresh();
    try waitForScan(pane);
    pane.move(.{ .by = 2 }, false);
    pane.toggleSelection();

    scan.block();
    try pane.changeListing(.cycle_sort);
    try scan.waitUntilEntered();
    try std.testing.expectEqual(Pane.Status.loading, pane.view().status);
    try std.testing.expectEqual(directory.Sort.size, pane.view().requested_options.sort);
    try std.testing.expectEqual(directory.Sort.name, pane.view().options.sort);
    try std.testing.expectEqualStrings("a", pane.view().entries[0].name);
    pane.cancelNavigation();
    scan.unblock();
    try waitForScan(pane);
    try std.testing.expect(pane.view().status == .ready);
    try std.testing.expectEqual(directory.Sort.size, pane.view().requested_options.sort);
    try std.testing.expectEqual(directory.Sort.name, pane.view().options.sort);

    // Cycling continues from the requested setting, even after cancellation.
    try pane.changeListing(.cycle_sort);
    try waitForScan(pane);
    try std.testing.expectEqual(directory.Sort.modified, pane.view().options.sort);
    try std.testing.expectEqualStrings("a", pane.view().focused().?.name);
    try std.testing.expectEqual(@as(usize, 1), pane.view().marked_count);

    scan.fail = true;
    try pane.changeListing(.reverse);
    try waitForScan(pane);
    try std.testing.expectEqual(error.AccessDenied, pane.view().status.failed.err);
    try std.testing.expectEqualStrings(buffer[0..len], pane.view().status.failed.path.?);
    try std.testing.expect(pane.view().requested_options.reverse);
    try std.testing.expect(!pane.view().options.reverse);
    try std.testing.expectEqualStrings("a", pane.view().focused().?.name);
    try std.testing.expectEqual(@as(usize, 1), pane.view().marked_count);

    scan.fail = false;
    try pane.refresh();
    try waitForScan(pane);
    try std.testing.expect(pane.view().status == .ready);
    try std.testing.expectEqualDeep(pane.view().requested_options, pane.view().options);
    try std.testing.expect(pane.view().options.reverse);
    try std.testing.expectEqualStrings("a", pane.view().focused().?.name);
}

test "latest listing options supersede a blocked scan and publish together" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "long" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "x" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    var scan: TestScan = .{};
    const pane = try Pane.create(io, std.testing.allocator, buffer[0..len], .{ .provider = scan.provider() });
    defer pane.destroy();
    defer scan.unblock();
    try pane.refresh();
    try waitForScan(pane);
    scan.block();
    try pane.changeListing(.toggle_hidden);
    try scan.waitUntilEntered();
    try pane.changeListing(.cycle_sort);
    try pane.changeListing(.reverse);
    try std.testing.expectEqual(@as(usize, 1), pane.view().entries.len);
    try std.testing.expect(!pane.view().options.hidden);
    scan.unblock();
    try waitForScan(pane);
    const view = pane.view();
    try std.testing.expectEqualDeep(directory.Options{ .hidden = true, .sort = .size, .reverse = true }, view.options);
    try std.testing.expectEqualDeep(view.requested_options, view.options);
    try std.testing.expectEqual(@as(usize, 2), view.entries.len);
    try std.testing.expectEqualStrings("a", view.entries[0].name);
    try std.testing.expectEqualStrings(".hidden", view.entries[1].name);
}

test "pane viewport follows navigation resizing and listing shrink without painting" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a", "b", "c", "d", "e", "f" }) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const pane = try Pane.create(io, std.testing.allocator, buffer[0..len], .{});
    defer pane.destroy();
    pane.setViewportRows(3);
    try pane.refresh();
    try waitForScan(pane);
    try std.testing.expect(pane.view().row(0).?.entry == null);
    try std.testing.expect(pane.view().row(0).?.focused);
    pane.move(.last, false);
    try std.testing.expectEqualStrings("f", pane.view().row(2).?.entry.?.name);
    try std.testing.expect(pane.view().row(2).?.focused);
    pane.move(.page_up, false);
    try std.testing.expectEqualStrings("c", pane.view().row(0).?.entry.?.name);
    try std.testing.expect(pane.view().row(0).?.focused);
    pane.move(.page_down, false);
    pane.setViewportRows(1);
    try std.testing.expectEqualStrings("f", pane.view().row(0).?.entry.?.name);
    try std.testing.expect(pane.view().row(0).?.focused);
    pane.setViewportRows(4);
    try std.testing.expectEqualStrings("f", pane.view().row(3).?.entry.?.name);
    try std.testing.expect(pane.view().row(3).?.focused);

    // Hidden panes keep valid cursor state and page by one row.
    pane.setViewportRows(0);
    try std.testing.expect(pane.view().row(0) == null);
    pane.move(.page_up, false);
    try std.testing.expectEqualStrings("e", pane.view().focused().?.name);
    pane.setViewportRows(3);
    try std.testing.expectEqualStrings("e", pane.view().row(1).?.entry.?.name);
    try std.testing.expect(pane.view().row(1).?.focused);

    for ([_][]const u8{ "c", "d", "e", "f" }) |name| try tmp.dir.deleteFile(io, name);
    try pane.refresh();
    try waitForScan(pane);
    try std.testing.expectEqualStrings("b", pane.view().row(2).?.entry.?.name);
    try std.testing.expect(pane.view().row(2).?.focused);
    try std.testing.expect(pane.view().row(3) == null);
    pane.move(.first, false);
    try std.testing.expect(pane.view().row(0).?.entry == null);
    try std.testing.expect(pane.view().row(0).?.focused);
}

fn expectSources(pane: *const Pane, expected: []const []const u8) !void {
    var sources = pane.sources();
    try std.testing.expectEqual(expected.len, sources.count);
    for (expected) |name| try std.testing.expectEqualStrings(name, sources.next() orelse return error.MissingSource);
    try std.testing.expect(sources.next() == null);
}

test "file-action sources prefer marks exclude reference rows and follow refreshed visible entries" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ ".hidden", "a", "b" }) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    try tmp.dir.createDir(io, "child", .default_dir);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const pane = try Pane.create(io, std.testing.allocator, buffer[0..len], .{});
    defer pane.destroy();
    try pane.refresh();
    try waitForScan(pane);
    try expectSources(pane, &.{});
    pane.move(.last, false);
    try expectSources(pane, &.{"b"});
    pane.toggleSelection();
    try pane.changeListing(.toggle_hidden);
    try waitForScan(pane);
    pane.move(.first, false);
    pane.move(.{ .by = 3 }, false); // Skip reference rows and child directory.
    try std.testing.expectEqualStrings(".hidden", pane.view().focused().?.name);
    pane.toggleSelection();
    pane.move(.first, false);
    try expectSources(pane, &.{ ".hidden", "b" });
    try pane.changeListing(.reverse);
    try waitForScan(pane);
    try expectSources(pane, &.{ "b", ".hidden" });
    try pane.changeListing(.toggle_hidden);
    try waitForScan(pane);
    try expectSources(pane, &.{"b"});
    try std.testing.expectEqual(@as(usize, 1), pane.view().marked_count);
    try tmp.dir.deleteFile(io, "b");
    try pane.refresh();
    try waitForScan(pane);
    try expectSources(pane, &.{}); // Cursor still on Current row; the mark disappeared.
    try std.testing.expectEqual(@as(usize, 0), pane.view().marked_count);
    pane.move(.last, false);
    pane.toggleSelection();
    try expectSources(pane, &.{"a"});
    try pane.request("child");
    try waitForScan(pane);
    try std.testing.expectEqual(@as(usize, 0), pane.view().marked_count);
    try expectSources(pane, &.{});
}

fn testLocalProvider(context: ?*anyopaque, scan: @TypeOf(directory.local.scan)) directory.Provider {
    var result = directory.local;
    result.context = context;
    result.scan = scan;
    return result;
}

test "opaque provider owns navigation and display never determines root or location identity" {
    const Fixture = @import("testing_provider.zig").Opaque;
    var fixture: Fixture = .{};
    var other: Fixture = .{};
    const pane = try Pane.create(std.testing.io, std.testing.allocator, Fixture.root, .{ .provider = fixture.provider() });
    defer pane.destroy();
    try std.testing.expect(!directory.Location.eql(pane.location(), other.provider().location(Fixture.root)));
    try std.testing.expect(directory.Location.eql(pane.location(), fixture.provider().location(Fixture.root)));
    try pane.refresh();
    try waitForScan(pane);
    pane.setViewportRows(5);
    try std.testing.expect(!pane.view().has_parent);
    pane.move(.{ .by = 1 }, false);
    try std.testing.expectEqualStrings("folder", pane.view().focused().?.name);
    try pane.parent(); // Root's parent is a no-op, despite its non-filesystem locator.
    try std.testing.expect(pane.view().status == .ready);
    try pane.enter();
    try waitForScan(pane);
    try std.testing.expectEqualStrings(Fixture.child, pane.location().locator);
    try std.testing.expectEqualStrings("/", pane.view().path);
    try std.testing.expect(pane.view().has_parent);
    try std.testing.expect(pane.view().row(0).?.entry == null);
    pane.toggleSelection();
    try expectSources(pane, &.{});
    try pane.parent();
    try waitForScan(pane);
    try std.testing.expectEqualStrings("folder", pane.view().focused().?.name);
    try pane.request("folder"); // Provider relative syntax, not a path join.
    try waitForScan(pane);
    try pane.request("up");
    try waitForScan(pane);
    try std.testing.expectEqualStrings(Fixture.root, pane.location().locator);
    const root_input = try pane.rootInput(std.testing.allocator);
    defer std.testing.allocator.free(root_input);
    try pane.request(root_input);
    try waitForScan(pane);
    try std.testing.expectError(error.UnknownLocation, pane.request("../folder"));
    try pane.request("bad-scan");
    try waitForScan(pane);
    try std.testing.expectEqual(error.AccessDenied, pane.view().status.failed.err);
    try std.testing.expectEqualStrings("/", pane.view().status.failed.path.?);
    try std.testing.expectEqualStrings(Fixture.root, pane.location().locator);
}

test "opaque scans preserve visible pane marks by exact name and discard stale or canceled results" {
    const Fixture = @import("testing_provider.zig").Opaque;
    var fixture: Fixture = .{};
    const pane = try Pane.create(std.testing.io, std.testing.allocator, Fixture.root, .{ .provider = fixture.provider() });
    defer pane.destroy();
    defer fixture.release.store(true, .release);
    try pane.refresh();
    try waitForScan(pane);
    pane.move(.{ .by = 2 }, false);
    pane.toggleSelection();
    try pane.changeListing(.reverse);
    try waitForScan(pane);
    try std.testing.expectEqualStrings("a", pane.view().focused().?.name);
    try std.testing.expect(pane.view().focusedMarked());
    try pane.request(Fixture.slow);
    try fixture.waitStarted();
    try pane.request(Fixture.child);
    try pane.request(Fixture.latest);
    fixture.release.store(true, .release);
    try waitForScan(pane);
    try std.testing.expect(fixture.canceled_seen.load(.acquire));
    try std.testing.expectEqualStrings(Fixture.latest, pane.location().locator);
    try std.testing.expectEqual(@as(usize, 0), pane.view().marked_count); // Same display, different identity.
    try pane.request(Fixture.root);
    try waitForScan(pane);
    pane.move(.last, false);
    pane.toggleSelection();
    fixture.missing_a = true;
    try pane.refresh();
    try waitForScan(pane);
    try std.testing.expectEqual(@as(usize, 0), pane.view().marked_count);
    fixture.started.store(false, .release);
    fixture.release.store(false, .release);
    try pane.request(Fixture.slow);
    try fixture.waitStarted();
    try pane.request(Fixture.child);
    pane.cancelNavigation();
    fixture.release.store(true, .release);
    try waitForScan(pane);
    try std.testing.expectEqualStrings(Fixture.root, pane.location().locator);
}

test "current and parent reference rows stay first and resolve local root" {
    const allocator = std.testing.allocator;
    const pane = try Pane.create(std.testing.io, allocator, "/", .{});
    defer pane.destroy();
    pane.setViewportRows(3);
    try std.testing.expect(pane.view().row(0) != null);
    try std.testing.expect(pane.view().row(1) != null);
    try std.testing.expect(pane.view().row(2) == null);
    try pane.enter();
    try std.testing.expect(pane.view().status == .ready);
    pane.move(.{ .by = 1 }, true);
    try pane.enter();
    try std.testing.expect(pane.view().status == .ready);
    try std.testing.expectEqual(@as(usize, 0), pane.sources().count);
}

test "reference rows insert resolved Provider locations and never become file-action sources" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "/", "/home/user/a 'link" }, [_][]const u8{ "/", "/home/user" }) |path, parent_path| {
        const pane = try Pane.create(std.testing.io, allocator, path, .{});
        defer pane.destroy();
        const current = try pane.cursorReference(allocator);
        defer allocator.free(current);
        try std.testing.expectEqualStrings(path, current);
        pane.toggleSelection();
        pane.move(.{ .by = 1 }, true);
        const parent_reference = try pane.cursorReference(allocator);
        defer allocator.free(parent_reference);
        try std.testing.expectEqualStrings(parent_path, parent_reference);
        pane.toggleSelection();
        try std.testing.expectEqual(@as(usize, 0), pane.view().marked_count);
        try expectSources(pane, &.{});
    }
    var fixture: @import("testing_provider.zig").Opaque = .{};
    const remote = try Pane.create(std.testing.io, allocator, @import("testing_provider.zig").Opaque.root, .{ .provider = fixture.provider() });
    defer remote.destroy();
    try std.testing.expectError(error.UnsupportedReference, remote.cursorReference(allocator));
}

test "reference rows retain Cursor identity across listing changes and scroll with entries" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const pane = try Pane.create(io, allocator, buffer[0..len], .{});
    defer pane.destroy();
    pane.setViewportRows(3);
    try pane.refresh();
    try waitForScan(pane);
    for ([_]Pane.ListingChange{ .reverse, .cycle_sort, .toggle_hidden }) |change| {
        try pane.changeListing(change);
        try waitForScan(pane);
        try std.testing.expectEqual(@as(usize, 0), pane.view().cursor);
        try std.testing.expectEqual(Pane.RowKind.current, pane.view().row(0).?.kind);
        try std.testing.expectEqual(Pane.RowKind.parent, pane.view().row(1).?.kind);
    }
    pane.move(.last, false);
    pane.toggleSelection();
    pane.move(.first, false);
    try expectSources(pane, &.{".hidden"});
    const current = try pane.cursorReference(allocator);
    defer allocator.free(current);
    try std.testing.expectEqualStrings(buffer[0..len], current);
    pane.move(.{ .by = 1 }, false);
    try pane.refresh();
    try waitForScan(pane);
    try std.testing.expectEqual(@as(usize, 1), pane.view().cursor);
    try expectSources(pane, &.{".hidden"});
    pane.setViewportRows(1);
    try std.testing.expectEqual(Pane.RowKind.parent, pane.view().row(0).?.kind);
    pane.move(.{ .by = 1 }, false);
    try std.testing.expectEqual(Pane.RowKind.entry, pane.view().row(0).?.kind);
    pane.move(.first, false);
    try std.testing.expectEqual(Pane.RowKind.current, pane.view().row(0).?.kind);
    try pane.enter();
    try std.testing.expect(pane.view().status == .ready);
}
