//! Provider-aware file-action preparation and local execution.
//! Requests own their paths; only atomic counters cross threads.
//! Never replace an existing destination. Completed items remain after failure.
const std = @import("std");
const Dir = std.Io.Dir;
const Pane = @import("pane.zig").Pane;
const listing = @import("directory.zig");

// Bound recursive stack/handle use, and check cancellation between copy chunks.
const max_recursion_depth = 128;
const copy_buffer_bytes = 64 * 1024;

pub const Kind = enum {
    copy,
    move,
    mkdir,
    delete,

    pub fn title(self: Kind) []const u8 {
        return switch (self) {
            .copy => "Copy",
            .move => "Move / Rename",
            .mkdir => "Create directory",
            .delete => "Delete",
        };
    }
};

/// Borrows the active and other pane for synchronous observation/preparation.
/// No pane or provider storage escapes prepare: the caller owns the returned,
/// unstarted Job, including all request paths, until Job.destroy.
/// The other pane supplies transfer destination identity/context; relative input
/// always uses the source location. Mkdir and delete use the source provider.
pub const Context = struct {
    source: *const Pane,
    other: *const Pane,

    /// Cheap, fresh observation shared by presentation and workflow entry points.
    pub fn available(self: Context, kind: Kind) bool {
        const destination_pane = self.destination(kind);
        return supported(kind, self.source.provider(), self.source.location(), destination_pane.provider(), destination_pane.location(), self.source.sources().count);
    }

    /// Rechecks default and edited destinations before constructing local work.
    /// Unsupported combinations return UnsupportedOperation without creating a
    /// Job; preparation never starts work or changes either pane.
    pub fn prepare(self: Context, io: std.Io, allocator: std.mem.Allocator, kind: Kind, target: []const u8) !*Job {
        if (!self.available(kind)) return error.UnsupportedOperation;
        if (kind != .delete and target.len == 0) return error.EmptyDestination;
        const provider = self.source.provider();
        const base = try provider.localPath(self.source.location().locator);
        const destination_provider = self.destination(kind).provider();
        const local_target = if (kind == .delete) try allocator.dupe(u8, base) else try destination_provider.localTarget(allocator, base, target);
        defer allocator.free(local_target);
        if (!supported(kind, provider, self.source.location(), destination_provider, destination_provider.location(local_target), self.source.sources().count)) return error.UnsupportedOperation;
        _ = try destination_provider.localPath(local_target);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(allocator);
        if (kind != .mkdir) {
            var sources = self.source.sources();
            while (sources.next()) |name| try names.append(allocator, name);
        }
        return Job.create(io, allocator, kind, base, names.items, local_target);
    }

    fn destination(self: Context, kind: Kind) *const Pane {
        return if (kind == .copy or kind == .move) self.other else self.source;
    }
};

/// Structural capability checks are cheap observations, never permission probes.
/// Read/write capability does not imply an executor exists for that combination.
fn supported(kind: Kind, source_provider: listing.Provider, source: listing.Location, destination_provider: listing.Provider, destination: listing.Location, source_count: usize) bool {
    if (source.provider != source_provider.identity or destination.provider != destination_provider.identity) return false;
    if (kind != .mkdir and source_count == 0) return false;
    const from = source_provider.capabilities(source_provider.context, source.locator);
    const to = destination_provider.capabilities(destination_provider.context, destination.locator);
    switch (kind) {
        .copy => if (!from.source_read or !to.destination_write) return false,
        .move => if (!from.source_read or !from.destination_write or !to.destination_write) return false,
        .delete => if (!from.destination_write) return false,
        .mkdir => if (!to.destination_write) return false,
    }
    _ = source_provider.localPath(source.locator) catch return false;
    if (kind != .delete) _ = destination_provider.localPath(destination.locator) catch return false;
    return true;
}

/// Owned request metadata. All slices are borrowed until Job.destroy.
pub const Request = struct {
    kind: Kind,
    sources: []const []const u8,
    destination: []const u8,
};

pub const Progress = struct {
    completed: usize = 0,
    removed: usize = 0,
    bytes: u64 = 0,
};

pub const Failure = struct {
    err: anyerror,
    // Launch failures have no filesystem path.
    path: ?[]const u8,
};

pub const Result = struct {
    progress: Progress,
    failure: ?Failure,
};

pub const Status = union(enum) {
    prepared,
    running: Progress,
    canceling: Progress,
    finished: Result,

    pub fn progress(self: Status) Progress {
        return switch (self) {
            .prepared => .{},
            .running, .canceling => |value| value,
            .finished => |result| result.progress,
        };
    }
};

/// One UI thread owns this job from preparation through result dismissal.
/// Only poll publishes a finished result; status never collects completion.
/// Request and failure-path slices remain valid until destroy. Opaque storage
/// keeps worker synchronization out of the caller's interface.
pub const Job = opaque {
    pub fn create(io: std.Io, allocator: std.mem.Allocator, kind: Kind, base: []const u8, names: []const []const u8, target: []const u8) !*Job {
        if (kind != .delete and target.len == 0) return error.EmptyDestination;
        if (kind != .mkdir and names.len == 0) return error.NoSelection;
        const self = try allocator.create(Implementation);
        errdefer allocator.destroy(self);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const sources = try owned.alloc([]const u8, names.len);
        for (names, sources) |name, *source| {
            // Sources are directory-entry names, never paths or synthetic parents.
            if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
                std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidSource;
            source.* = try std.fs.path.join(owned, &.{ base, name });
        }
        // Preserve trailing slashes: a missing destination ending in '/' must
        // not silently become a filename. Relative input is based on the source pane.
        const destination = if (std.fs.path.isAbsolute(target)) try owned.dupe(u8, target) else try std.fs.path.join(owned, &.{ base, target });
        self.* = .{ .allocator = allocator, .arena = arena, .io = io, .kind = kind, .sources = sources, .destination = destination };
        return @ptrCast(self);
    }

    /// Starts once. Worker-launch errors become results at the next poll;
    /// AlreadyStarted denotes a caller error and never launches another worker.
    pub fn start(job: *Job) error{AlreadyStarted}!void {
        const self: *Implementation = @ptrCast(@alignCast(job));
        if (self.phase != .prepared) return error.AlreadyStarted;
        self.phase = .running;
        self.future = self.io.concurrent(Implementation.work, .{self}) catch |err| {
            self.failure = err;
            self.done.store(true, .release);
            return;
        };
    }

    /// Cooperative request, not an outcome. Prepared and finished jobs ignore it.
    pub fn cancel(job: *Job) void {
        const self: *Implementation = @ptrCast(@alignCast(job));
        if (self.phase != .running) return;
        self.phase = .canceling;
        self.canceled.store(true, .release);
    }

    /// Reports completion exactly once, including launch failure. A running
    /// worker is never awaited until it has published completion.
    pub fn poll(job: *Job) bool {
        const self: *Implementation = @ptrCast(@alignCast(job));
        if (self.phase == .prepared or self.phase == .finished or !self.done.load(.acquire)) return false;
        if (self.future) |*future| future.await(self.io);
        self.future = null;
        self.phase = .finished;
        return true;
    }

    pub fn request(job: *const Job) Request {
        const self: *const Implementation = @ptrCast(@alignCast(job));
        return .{ .kind = self.kind, .sources = self.sources, .destination = self.destination };
    }

    /// Live counters are individually safe, not a simultaneous snapshot.
    /// Finished totals and failure data are stable after poll has joined work.
    pub fn status(job: *const Job) Status {
        const self: *const Implementation = @ptrCast(@alignCast(job));
        const progress: Progress = .{
            .completed = self.completed.load(.acquire),
            .removed = self.removed.load(.acquire),
            .bytes = self.bytes.load(.acquire),
        };
        return switch (self.phase) {
            .prepared => .prepared,
            .running => .{ .running = progress },
            .canceling => .{ .canceling = progress },
            .finished => .{ .finished = .{
                .progress = progress,
                .failure = if (self.failure) |err| .{
                    .err = err,
                    .path = if (self.failed_path_len > 0) self.failed_path[0..self.failed_path_len] else null,
                } else null,
            } },
        };
    }

    /// Valid in every state. Cancels and joins outstanding work before freeing
    /// any storage, so callers do not need to poll during shutdown.
    pub fn destroy(job: *Job) void {
        const self: *Implementation = @ptrCast(@alignCast(job));
        if (self.future) |*future| {
            self.canceled.store(true, .release);
            future.cancel(self.io);
        }
        const allocator = self.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
};

const Implementation = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    kind: Kind,
    sources: []const []const u8,
    destination: []const u8,
    canceled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    completed: std.atomic.Value(usize) = .init(0),
    removed: std.atomic.Value(usize) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),
    failure: ?anyerror = null,
    // Worker-owned until done; fixed storage also reports allocation failures.
    failed_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    failed_path_len: usize = 0,
    future: ?std.Io.Future(void) = null,
    phase: enum { prepared, running, canceling, finished } = .prepared,

    fn check(self: *Implementation) !void {
        if (self.canceled.load(.acquire)) return error.Canceled;
    }

    fn pathError(self: *Implementation, path: []const u8) void {
        self.failed_path_len = @min(path.len, self.failed_path.len);
        @memcpy(self.failed_path[0..self.failed_path_len], path[0..self.failed_path_len]);
    }

    fn work(self: *Implementation) void {
        self.execute() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }

    fn execute(self: *Implementation) !void {
        self.pathError(self.destination);
        try self.check();
        if (self.kind == .mkdir) {
            try Dir.cwd().createDir(self.io, self.destination, .default_dir);
            self.completed.store(1, .release);
            return;
        }
        if (self.kind == .delete) {
            for (self.sources) |source| {
                try self.check();
                self.pathError(source);
                const parent = try Dir.openDirAbsolute(self.io, std.fs.path.dirname(source).?, .{});
                defer parent.close(self.io);
                try self.deleteNode(parent, std.fs.path.basename(source), source, 0);
                _ = self.completed.fetchAdd(1, .release);
            }
            return;
        }
        const destination_stat = Dir.cwd().statFile(self.io, self.destination, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        const into_directory = if (destination_stat) |s| s.kind == .directory else false;
        if (!into_directory and (self.sources.len > 1 or std.mem.endsWith(u8, self.destination, "/"))) return error.DestinationMustBeDirectory;
        for (self.sources) |source| {
            try self.check();
            const target = if (into_directory) try std.fs.path.join(self.allocator, &.{ self.destination, std.fs.path.basename(source) }) else try self.allocator.dupe(u8, self.destination);
            defer self.allocator.free(target);
            self.pathError(source);
            const stat = try Dir.cwd().statFile(self.io, source, .{ .follow_symlinks = false });
            self.pathError(target);
            try self.validateTarget(source, target, stat.kind == .directory);
            if (self.kind == .move) {
                // Atomic no-replace rename. Cross-device moves deliberately fail
                // without touching either tree until a safe copy/delete stage exists.
                try Dir.cwd().renamePreserve(source, .cwd(), target, self.io);
            } else try self.copyNode(source, target, 0);
            _ = self.completed.fetchAdd(1, .release);
        }
    }

    fn deleteNode(self: *Implementation, parent: Dir, name: []const u8, display_path: []const u8, depth: usize) anyerror!void {
        self.pathError(display_path);
        try self.check();
        if (depth >= max_recursion_depth) return error.DirectoryTooDeep;
        const stat = try parent.statFile(self.io, name, .{ .follow_symlinks = false });
        if (stat.kind == .directory) {
            // Traverse by open parent handles and refuse symlinks even if an
            // entry changes between stat and open. Links are only ever unlinked.
            const dir = try parent.openDir(self.io, name, .{ .iterate = true, .follow_symlinks = false });
            defer dir.close(self.io);
            var iterator = dir.iterate();
            while (try iterator.next(self.io)) |entry| {
                const child_path = try std.fs.path.join(self.allocator, &.{ display_path, entry.name });
                defer self.allocator.free(child_path);
                try self.deleteNode(dir, entry.name, child_path, depth + 1);
            }
            self.pathError(display_path);
            try self.check();
            try parent.deleteDir(self.io, name);
        } else {
            try self.check();
            try parent.deleteFile(self.io, name);
        }
        _ = self.removed.fetchAdd(1, .release);
    }

    fn validateTarget(self: *Implementation, source: []const u8, target: []const u8, directory: bool) !void {
        // Refuse aliases too: resolving the destination parent catches a symlink
        // back into the source directory, not just lexical descendants.
        const parent = std.fs.path.dirname(target) orelse return error.InvalidDestination;
        const dir = try Dir.openDirAbsolute(self.io, parent, .{});
        defer dir.close(self.io);
        var parent_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try dir.realPath(self.io, &parent_buffer);
        if (directory) {
            const src = try Dir.openDirAbsolute(self.io, source, .{ .follow_symlinks = false });
            defer src.close(self.io);
            var source_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const source_len = try src.realPath(self.io, &source_buffer);
            const canonical = source_buffer[0..source_len];
            const dest_parent = parent_buffer[0..len];
            if (std.mem.eql(u8, canonical, dest_parent) or
                (std.mem.startsWith(u8, dest_parent, canonical) and dest_parent.len > canonical.len and dest_parent[canonical.len] == '/')) return error.DestinationInsideSource;
        }
        // lstat rejects dangling links as well as files and directories.
        _ = Dir.cwd().statFile(self.io, target, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        return error.PathAlreadyExists;
    }

    fn copyNode(self: *Implementation, source: []const u8, target: []const u8, depth: usize) anyerror!void {
        try self.check();
        if (depth >= max_recursion_depth) return error.DirectoryTooDeep;
        self.pathError(source);
        const stat = try Dir.cwd().statFile(self.io, source, .{ .follow_symlinks = false });
        switch (stat.kind) {
            .file => {
                const file = try Dir.openFileAbsolute(self.io, source, .{ .follow_symlinks = false });
                defer file.close(self.io);
                const before = try file.stat(self.io);
                if (before.kind != .file) return error.SourceChanged;
                self.pathError(target);
                var output = try Dir.cwd().createFileAtomic(self.io, target, .{ .permissions = before.permissions });
                defer output.deinit(self.io);
                var buffer: [copy_buffer_bytes]u8 = undefined;
                var offset: u64 = 0;
                while (offset < before.size) {
                    try self.check();
                    const n = try file.readPositional(self.io, &.{buffer[0..@intCast(@min(buffer.len, before.size - offset))]}, offset);
                    if (n == 0) return error.SourceChanged;
                    try output.file.writePositionalAll(self.io, buffer[0..n], offset);
                    offset += n;
                    _ = self.bytes.fetchAdd(n, .release);
                }
                const after = try file.stat(self.io);
                if (before.size != after.size or before.mtime.nanoseconds != after.mtime.nanoseconds or before.ctime.nanoseconds != after.ctime.nanoseconds) return error.SourceChanged;
                try output.file.setTimestamps(self.io, .{ .modify_timestamp = .init(before.mtime) });
                try self.check();
                try output.link(self.io);
            },
            .sym_link => {
                var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const len = try Dir.cwd().readLink(self.io, source, &buffer);
                if (len == buffer.len) return error.NameTooLong;
                self.pathError(target);
                try Dir.cwd().symLink(self.io, buffer[0..len], target, .{});
            },
            .directory => {
                const src = try Dir.openDirAbsolute(self.io, source, .{ .iterate = true, .follow_symlinks = false });
                defer src.close(self.io);
                self.pathError(target);
                try Dir.cwd().createDir(self.io, target, .default_dir);
                const dest = try Dir.openDirAbsolute(self.io, target, .{ .iterate = true, .follow_symlinks = false });
                defer dest.close(self.io);
                var iterator = src.iterate();
                while (try iterator.next(self.io)) |entry| {
                    try self.check();
                    const child_source = try std.fs.path.join(self.allocator, &.{ source, entry.name });
                    defer self.allocator.free(child_source);
                    const child_target = try std.fs.path.join(self.allocator, &.{ target, entry.name });
                    defer self.allocator.free(child_target);
                    try self.copyNode(child_source, child_target, depth + 1);
                }
                try dest.setPermissions(self.io, stat.permissions);
            },
            else => return error.UnsupportedFileType,
        }
    }
};

fn testJob(kind: Kind, base: []const u8, names: []const []const u8, target: []const u8) !*Job {
    const job = try Job.create(std.testing.io, std.testing.allocator, kind, base, names, target);
    errdefer job.destroy();
    try job.start();
    try waitForJob(job);
    return job;
}

fn testBase(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

test "recursive copy includes hidden and raw names and preserves symlinks without following them" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    try tmp.dir.createDirPath(io, "source/nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "source/nested/raw\n\xff", .data = "payload" });
    try tmp.dir.writeFile(io, .{ .sub_path = "source/.hidden", .data = "hidden" });
    try tmp.dir.symLink(io, "missing", "source/broken", .{});
    try tmp.dir.symLink(io, ".", "source/loop", .{});
    const job = try testJob(.copy, base, &.{"source"}, "copied");
    defer job.destroy();
    try std.testing.expectEqual(null, job.status().finished.failure);
    try std.testing.expectEqual(@as(usize, 1), job.status().progress().completed);
    var data: [32]u8 = undefined;
    try std.testing.expectEqualStrings("payload", try tmp.dir.readFile(io, "copied/nested/raw\n\xff", &data));
    try std.testing.expectEqualStrings("hidden", try tmp.dir.readFile(io, "copied/.hidden", &data));
    const len = try tmp.dir.readLink(io, "copied/loop", &data);
    try std.testing.expectEqualStrings(".", data[0..len]);
    const broken = try tmp.dir.statFile(io, "copied/broken", .{ .follow_symlinks = false });
    try std.testing.expectEqual(.sym_link, broken.kind);
}

test "copy and move conflicts preserve existing files and dangling links" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "original" });
    try tmp.dir.writeFile(io, .{ .sub_path = "existing", .data = "keep" });
    try tmp.dir.symLink(io, "absent", "broken", .{});
    for ([_]Kind{ .copy, .move }) |kind| {
        for ([_][]const u8{ "existing", "broken", "source" }) |target| {
            const job = try testJob(kind, base, &.{"source"}, target);
            defer job.destroy();
            try std.testing.expectEqual(error.PathAlreadyExists, job.status().finished.failure.?.err);
        }
    }
    var data: [32]u8 = undefined;
    try std.testing.expectEqualStrings("original", try tmp.dir.readFile(io, "source", &data));
    try std.testing.expectEqualStrings("keep", try tmp.dir.readFile(io, "existing", &data));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "absent", .{}));
}

test "move supports rename and multi-source destination directories" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    try tmp.dir.createDir(io, "dest", .default_dir);
    try tmp.dir.createDir(io, "folder", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "a" });
    try tmp.dir.symLink(io, "missing", "b", .{});
    const renamed = try testJob(.move, base, &.{"a"}, "renamed");
    defer renamed.destroy();
    try std.testing.expectEqual(null, renamed.status().finished.failure);
    const moved = try testJob(.move, base, &.{ "renamed", "b", "folder" }, "dest");
    defer moved.destroy();
    try std.testing.expectEqual(null, moved.status().finished.failure);
    try std.testing.expectEqual(@as(usize, 3), moved.status().progress().completed);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "renamed", .{}));
    try std.testing.expectEqual(.sym_link, (try tmp.dir.statFile(io, "dest/b", .{ .follow_symlinks = false })).kind);
    try std.testing.expectEqual(.directory, (try tmp.dir.statFile(io, "dest/folder", .{})).kind);
}

test "reject descendants including symlink aliases and ambiguous multi-source destinations" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    try tmp.dir.createDirPath(io, "source/child");
    try tmp.dir.symLink(io, "source/child", "alias", .{});
    for ([_]Kind{ .copy, .move }) |kind| {
        for ([_][]const u8{ "source/child/new", "alias/new" }) |target| {
            const job = try testJob(kind, base, &.{"source"}, target);
            defer job.destroy();
            try std.testing.expectEqual(error.DestinationInsideSource, job.status().finished.failure.?.err);
        }
        const multiple = try testJob(kind, base, &.{ "source", "alias" }, "missing");
        defer multiple.destroy();
        try std.testing.expectEqual(error.DestinationMustBeDirectory, multiple.status().finished.failure.?.err);
        const slash = try testJob(kind, base, &.{"source"}, "missing/");
        defer slash.destroy();
        try std.testing.expectEqual(error.DestinationMustBeDirectory, slash.status().finished.failure.?.err);
    }
}

test "mkdir refuses existing paths and reports missing parents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    const first = try testJob(.mkdir, base, &.{}, "new folder");
    defer first.destroy();
    try std.testing.expectEqual(null, first.status().finished.failure);
    const again = try testJob(.mkdir, base, &.{}, "new folder");
    defer again.destroy();
    try std.testing.expectEqual(error.PathAlreadyExists, again.status().finished.failure.?.err);
    const missing = try testJob(.mkdir, base, &.{}, "missing/child");
    defer missing.destroy();
    try std.testing.expectEqual(error.FileNotFound, missing.status().finished.failure.?.err);
}

test "partial batch failure reports completed items and preserves unprocessed sources" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    try tmp.dir.createDir(io, "dest", .default_dir);
    for ([_][]const u8{ "a", "b", "c", "dest/b" }) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = name });
    const job = try testJob(.move, base, &.{ "a", "b", "c" }, "dest");
    defer job.destroy();
    try std.testing.expectEqual(error.PathAlreadyExists, job.status().finished.failure.?.err);
    try std.testing.expectEqual(@as(usize, 1), job.status().progress().completed);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "a", .{}));
    _ = try tmp.dir.statFile(io, "dest/a", .{});
    _ = try tmp.dir.statFile(io, "b", .{});
    _ = try tmp.dir.statFile(io, "c", .{});
}

test "canceling an active copy never publishes a partial destination" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    const source = try tmp.dir.createFile(io, "source", .{});
    defer source.close(io);
    const size = 2 * copy_buffer_bytes;
    try source.setLength(io, size);
    var gate = TestIoGate.init(.copy);
    defer gate.threaded.deinit();
    const job = try Job.create(gate.io(), std.testing.allocator, .copy, base, &.{"source"}, "destination");
    defer job.destroy();
    defer gate.unblock();
    try job.start();
    try gate.waitUntilEntered();
    try std.testing.expect(job.status() == .running);
    try std.testing.expect(job.status().progress().bytes > 0);
    try std.testing.expect(!job.poll());
    try std.testing.expectError(error.AlreadyStarted, job.start());
    job.cancel();
    job.cancel();
    try std.testing.expect(job.status() == .canceling);
    gate.unblock();
    try waitForJob(job);
    const result = job.status().finished;
    try std.testing.expectEqual(error.Canceled, result.failure.?.err);
    try std.testing.expectEqual(@as(usize, 0), result.progress.completed);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "destination", .{}));
    try std.testing.expectEqual(@as(u64, size), (try source.stat(io)).size);
}

test "recursive delete removes raw names and links without touching link targets" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    try tmp.dir.createDirPath(io, "tree/nested");
    try tmp.dir.createDir(io, "outside", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/keep", .data = "keep" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/nested/raw\n\xff", .data = "remove" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/.hidden", .data = "remove" });
    try tmp.dir.symLink(io, "../outside", "tree/link", .{});
    try tmp.dir.symLink(io, "missing", "tree/broken", .{});
    try tmp.dir.symLink(io, "outside", "dirlink", .{});
    const job = try testJob(.delete, base, &.{ "tree", "dirlink" }, "");
    defer job.destroy();
    try std.testing.expectEqual(null, job.status().finished.failure);
    try std.testing.expectEqual(@as(usize, 2), job.status().progress().completed);
    try std.testing.expectEqual(@as(usize, 7), job.status().progress().removed);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "tree", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "dirlink", .{ .follow_symlinks = false }));
    var data: [16]u8 = undefined;
    try std.testing.expectEqualStrings("keep", try tmp.dir.readFile(io, "outside/keep", &data));
}

test "delete rejects synthetic parents and path-shaped source names" {
    for ([_][]const u8{ "", ".", "..", "/", "a/b", "bad\x00name" }) |name| {
        try std.testing.expectError(error.InvalidSource, Job.create(std.testing.io, std.testing.allocator, .delete, "/", &.{name}, ""));
    }
    try std.testing.expectError(error.NoSelection, Job.create(std.testing.io, std.testing.allocator, .delete, "/", &.{}, ""));
}

test "delete stops on failure and reports prior removals" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    try tmp.dir.writeFile(io, .{ .sub_path = "first", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "last", .data = "" });
    const job = try testJob(.delete, base, &.{ "first", "missing", "last" }, "");
    defer job.destroy();
    try std.testing.expectEqual(error.FileNotFound, job.status().finished.failure.?.err);
    try std.testing.expectEqual(@as(usize, 1), job.status().progress().completed);
    try std.testing.expectEqual(@as(usize, 1), job.status().progress().removed);
    try std.testing.expect(std.mem.endsWith(u8, job.status().finished.failure.?.path.?, "/missing"));
    _ = try tmp.dir.statFile(io, "last", .{});
}

test "cancellation interrupts recursive deletion and retains remaining children" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    try tmp.dir.createDir(io, "tree", .default_dir);
    for ([_][]const u8{ "tree/a", "tree/b", "tree/c" }) |name| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    }
    var gate = TestIoGate.init(.delete);
    defer gate.threaded.deinit();
    const job = try Job.create(gate.io(), std.testing.allocator, .delete, base, &.{"tree"}, "");
    defer job.destroy();
    defer gate.unblock();
    try job.start();
    try gate.waitUntilEntered();
    try std.testing.expectEqual(@as(usize, 1), job.status().progress().removed);
    job.cancel();
    gate.unblock();
    try waitForJob(job);
    const result = job.status().finished;
    try std.testing.expectEqual(error.Canceled, result.failure.?.err);
    try std.testing.expectEqual(@as(usize, 0), result.progress.completed);
    // The deletion already in flight may finish after cancellation is requested.
    try std.testing.expect(result.progress.removed >= 1 and result.progress.removed < 3);
    const tree = try tmp.dir.openDir(io, "tree", .{ .iterate = true });
    defer tree.close(io);
    var iterator = tree.iterate();
    try std.testing.expect(try iterator.next(io) != null);
}

fn waitForJob(job: *Job) !void {
    for (0..5000) |_| {
        if (job.poll()) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.JobTimeout;
}

// A real filesystem adapter with a gate at a selected I/O call. The copied
// vtable keeps the Threaded userdata expected by all unchanged callbacks.
// Construct in stable storage before io(); release the gate before job cleanup.
const TestIoGate = struct {
    threaded: std.Io.Threaded,
    vtable: std.Io.VTable = undefined,
    mode: enum { copy, delete, mkdir },
    deletions: usize = 0,
    entered: std.Io.Event = .unset,
    released: std.Io.Event = .unset,

    fn init(mode: @FieldType(TestIoGate, "mode")) TestIoGate {
        return .{ .threaded = .init(std.testing.allocator, .{}), .mode = mode };
    }

    fn io(self: *TestIoGate) std.Io {
        const base = self.threaded.io();
        self.vtable = base.vtable.*;
        self.vtable.fileReadPositional = read;
        self.vtable.dirDeleteFile = delete;
        self.vtable.dirCreateDir = mkdir;
        return .{ .userdata = base.userdata, .vtable = &self.vtable };
    }

    fn fromUserdata(userdata: ?*anyopaque) *TestIoGate {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata.?));
        return @fieldParentPtr("threaded", threaded);
    }

    fn pause(self: *TestIoGate) std.Io.Cancelable!void {
        self.entered.set(self.threaded.io());
        try self.released.wait(self.threaded.io());
    }

    fn unblock(self: *TestIoGate) void {
        self.released.set(self.threaded.io());
    }

    fn waitUntilEntered(self: *TestIoGate) !void {
        // Time bounds diagnose hangs; the event, not elapsed time, orders work.
        for (0..5000) |_| {
            if (self.entered.isSet()) return;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        return error.GateTimeout;
    }

    fn read(userdata: ?*anyopaque, file: std.Io.File, data: []const []u8, offset: u64) std.Io.File.ReadPositionalError!usize {
        const self = fromUserdata(userdata);
        if (self.mode == .copy and offset > 0) try self.pause();
        const base = self.threaded.io();
        return base.vtable.fileReadPositional(base.userdata, file, data, offset);
    }

    fn delete(userdata: ?*anyopaque, dir: Dir, path: []const u8) Dir.DeleteFileError!void {
        const self = fromUserdata(userdata);
        self.deletions += 1;
        if (self.mode == .delete and self.deletions == 2) try self.pause();
        const base = self.threaded.io();
        return base.vtable.dirDeleteFile(base.userdata, dir, path);
    }

    fn mkdir(userdata: ?*anyopaque, dir: Dir, path: []const u8, permissions: Dir.Permissions) Dir.CreateDirError!void {
        const self = fromUserdata(userdata);
        const base = self.threaded.io();
        try base.vtable.dirCreateDir(base.userdata, dir, path, permissions);
        // Let cancellation race with an operation which has already succeeded.
        if (self.mode == .mkdir) try self.pause();
    }
};

test "prepared deletion owns its request and can be dismissed without work" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    try tmp.dir.writeFile(io, .{ .sub_path = "keep", .data = "keep" });
    var name = "keep".*;
    {
        const job = try Job.create(io, std.testing.allocator, .delete, base, &.{&name}, "");
        defer job.destroy();
        name[0] = 'X';
        // Prove ownership after the caller also reuses its base-path buffer.
        @memset(buffer[0..base.len], 0);
        const request = job.request();
        try std.testing.expectEqual(Kind.delete, request.kind);
        try std.testing.expect(std.mem.endsWith(u8, request.sources[0], "/keep"));
        job.cancel();
        try std.testing.expect(job.status() == .prepared);
        try std.testing.expect(!job.poll());
    }
    var data: [4]u8 = undefined;
    try std.testing.expectEqualStrings("keep", try tmp.dir.readFile(io, "keep", &data));
}

test "launch failure is collected once and status never consumes completion" {
    const job = try Job.create(std.Io.failing, std.testing.allocator, .mkdir, "/", &.{}, "unused");
    defer job.destroy();
    try job.start();
    try std.testing.expect(job.status() == .running);
    try std.testing.expect(job.status() == .running);
    try std.testing.expectError(error.AlreadyStarted, job.start());
    job.cancel();
    try std.testing.expect(job.status() == .canceling);
    try std.testing.expect(job.poll());
    const result = job.status().finished;
    try std.testing.expectEqual(error.ConcurrencyUnavailable, result.failure.?.err);
    try std.testing.expectEqual(null, result.failure.?.path);
    try std.testing.expectEqual(Progress{}, result.progress);
    job.cancel();
    try std.testing.expectEqualDeep(result, job.status().finished);
    try std.testing.expect(!job.poll());
    try std.testing.expectError(error.AlreadyStarted, job.start());
}

test "late cancellation preserves success and finished results remain stable" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    var gate = TestIoGate.init(.mkdir);
    defer gate.threaded.deinit();
    const job = try Job.create(gate.io(), std.testing.allocator, .mkdir, base, &.{}, "created");
    defer job.destroy();
    defer gate.unblock();
    try job.start();
    try gate.waitUntilEntered();
    _ = try tmp.dir.statFile(io, "created", .{});
    job.cancel();
    try std.testing.expect(job.status() == .canceling);
    gate.unblock();
    try waitForJob(job);
    const result = job.status().finished;
    try std.testing.expectEqual(null, result.failure);
    try std.testing.expectEqual(@as(usize, 1), result.progress.completed);
    job.cancel();
    try std.testing.expectEqualDeep(result, job.status().finished);
    try std.testing.expect(!job.poll());
}

test "destroy joins an active copy and removes its unpublished destination" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    const source = try tmp.dir.createFile(io, "source", .{});
    defer source.close(io);
    try source.setLength(io, 2 * copy_buffer_bytes);
    var gate = TestIoGate.init(.copy);
    defer gate.threaded.deinit();
    const job = try Job.create(gate.io(), std.testing.allocator, .copy, base, &.{"source"}, "destination");
    var destroyed = false;
    defer if (!destroyed) job.destroy();
    defer gate.unblock();
    try job.start();
    try gate.waitUntilEntered();
    // destroy's Future.cancel must wake the cancelable gate and join the worker.
    job.destroy();
    destroyed = true;
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "destination", .{}));
    try std.testing.expectEqual(@as(u64, 2 * copy_buffer_bytes), (try source.stat(io)).size);
    const dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    try std.testing.expectEqualStrings("source", (try iterator.next(io)).?.name);
    try std.testing.expect(try iterator.next(io) == null);
}

// Local identity with independently mutable capability contexts models support
// changes without adding another production executor.
const PreparationCapabilities = struct {
    readable: bool = true,
    writable: bool = true,
    blocked: ?[]const u8 = null,

    fn provider(self: *PreparationCapabilities, local_identity: bool) listing.Provider {
        var result = listing.local;
        result.context = self;
        result.capabilities = capabilities;
        if (!local_identity) result.identity = self;
        return result;
    }

    fn capabilities(context: ?*anyopaque, locator: []const u8) listing.Capabilities {
        const self: *PreparationCapabilities = @ptrCast(@alignCast(context.?));
        return .{
            .source_read = self.readable,
            .destination_write = self.writable and !(if (self.blocked) |blocked| std.mem.startsWith(u8, locator, blocked) else false),
        };
    }
};

const PreparationPanes = struct {
    source: *Pane,
    other: *Pane,

    fn init(base: []const u8, destination: []const u8, source_provider: listing.Provider, destination_provider: listing.Provider) !PreparationPanes {
        const source = try Pane.create(std.testing.io, std.testing.allocator, base, .{ .provider = source_provider });
        errdefer source.destroy();
        const other = try Pane.create(std.testing.io, std.testing.allocator, destination, .{ .provider = destination_provider });
        errdefer other.destroy();
        try source.refresh();
        for (0..5000) |_| {
            if (try source.poll()) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        } else return error.ScanTimeout;
        source.move(.last, false);
        return .{ .source = source, .other = other };
    }

    fn deinit(self: PreparationPanes) void {
        self.source.destroy();
        self.other.destroy();
    }

    fn context(self: PreparationPanes) Context {
        return .{ .source = self.source, .other = self.other };
    }
};

test "preparation uses destination context for edited absolute and source-relative input" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "safe" });
    try tmp.dir.createDir(io, "destination", .default_dir);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    const blocked = try std.fs.path.join(std.testing.allocator, &.{ base, "blocked" });
    defer std.testing.allocator.free(blocked);
    const destination = try std.fs.path.join(std.testing.allocator, &.{ base, "destination" });
    defer std.testing.allocator.free(destination);
    var source_capabilities: PreparationCapabilities = .{};
    var destination_capabilities: PreparationCapabilities = .{ .blocked = blocked };
    const panes = try PreparationPanes.init(base, destination, source_capabilities.provider(true), destination_capabilities.provider(true));
    defer panes.deinit();
    const context = panes.context();
    for ([_]Kind{ .copy, .move }) |kind| {
        for ([_][]const u8{ blocked, "blocked" }) |target| {
            try std.testing.expect(context.available(kind));
            try std.testing.expectError(error.UnsupportedOperation, context.prepare(io, std.testing.allocator, kind, target));
        }
    }
    // Source context must not veto destination writing for copy.
    source_capabilities.blocked = blocked;
    destination_capabilities.blocked = null;
    const job = try context.prepare(io, std.testing.allocator, .copy, "blocked");
    defer job.destroy();
    try std.testing.expectEqualStrings(blocked, job.request().destination);
    try job.start();
    try waitForJob(job);
    try std.testing.expectEqual(null, job.status().finished.failure);
    _ = try tmp.dir.statFile(io, "blocked", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "destination/blocked", .{}));
}

test "preparation freshly checks default context and source capabilities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "source", .data = "" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    var source: PreparationCapabilities = .{};
    var destination: PreparationCapabilities = .{};
    const panes = try PreparationPanes.init(base, "/default-destination", source.provider(true), destination.provider(true));
    defer panes.deinit();
    const context = panes.context();
    for ([_]Kind{ .copy, .move }) |kind| {
        try std.testing.expect(context.available(kind));
        destination.blocked = "/default-destination";
        // An edited target cannot bypass support lost at the default location.
        try std.testing.expectError(error.UnsupportedOperation, context.prepare(std.testing.io, std.testing.allocator, kind, "edited"));
        destination.blocked = null;
        source.readable = false;
        try std.testing.expectError(error.UnsupportedOperation, context.prepare(std.testing.io, std.testing.allocator, kind, "edited"));
        source.readable = true;
    }
    source.writable = false;
    for ([_]Kind{ .move, .mkdir, .delete }) |kind| {
        try std.testing.expectError(error.UnsupportedOperation, context.prepare(std.testing.io, std.testing.allocator, kind, "edited"));
    }
    try std.testing.expect(context.available(.copy));
    source.writable = true;
    panes.source.move(.first, false); // Parent row is never a file-action source.
    for ([_]Kind{ .copy, .move, .delete }) |kind| {
        try std.testing.expectError(error.UnsupportedOperation, context.prepare(std.testing.io, std.testing.allocator, kind, "edited"));
    }
    const mkdir = try context.prepare(std.testing.io, std.testing.allocator, .mkdir, "edited");
    defer mkdir.destroy();
    try std.testing.expectEqual(@as(usize, 0), mkdir.request().sources.len);
    try std.testing.expectError(error.EmptyDestination, context.prepare(std.testing.io, std.testing.allocator, .mkdir, ""));
}

test "preparation rejects unsupported provider identities despite local-looking locators" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keep", .data = "safe" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    var foreign: PreparationCapabilities = .{};
    const panes = try PreparationPanes.init(base, base, foreign.provider(false), listing.local);
    defer panes.deinit();
    for ([_]Kind{ .copy, .move, .mkdir, .delete }) |kind| {
        try std.testing.expect(!panes.context().available(kind));
        try std.testing.expectError(error.UnsupportedOperation, panes.context().prepare(std.testing.io, std.testing.allocator, kind, "target"));
    }
    const outbound = try PreparationPanes.init(base, base, listing.local, foreign.provider(false));
    defer outbound.deinit();
    for ([_]Kind{ .copy, .move }) |kind| {
        try std.testing.expectError(error.UnsupportedOperation, outbound.context().prepare(std.testing.io, std.testing.allocator, kind, "target"));
    }
    try std.testing.expect(outbound.context().available(.mkdir));
    try std.testing.expect(outbound.context().available(.delete));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, "target", .{}));
    _ = try tmp.dir.statFile(std.testing.io, "keep", .{});
}

test "preparation preserves execution spelling for symlink parent traversal and trailing slashes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "target/child");
    try tmp.dir.symLink(io, "target/child", "link", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "safe" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    const panes = try PreparationPanes.init(base, base, listing.local, listing.local);
    defer panes.deinit();
    const job = try panes.context().prepare(io, std.testing.allocator, .mkdir, "link/../created");
    defer job.destroy();
    try std.testing.expect(std.mem.endsWith(u8, job.request().destination, "/link/../created"));
    try job.start();
    try waitForJob(job);
    try std.testing.expectEqual(null, job.status().finished.failure);
    _ = try tmp.dir.statFile(io, "target/created", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "created", .{}));
    for ([_]Kind{ .copy, .move }) |kind| {
        const slash = try panes.context().prepare(io, std.testing.allocator, kind, "missing-directory/");
        defer slash.destroy();
        try std.testing.expect(std.mem.endsWith(u8, slash.request().destination, "/missing-directory/"));
        try slash.start();
        try waitForJob(slash);
        try std.testing.expectEqual(error.DestinationMustBeDirectory, slash.status().finished.failure.?.err);
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "missing-directory", .{}));
    }
}

test "preparation expands home and retains absolute execution spelling" {
    const source = try Pane.create(std.testing.io, std.testing.allocator, "/source", .{});
    defer source.destroy();
    const context: Context = .{ .source = source, .other = source };
    const absolute = try context.prepare(std.testing.io, std.testing.allocator, .mkdir, "/link/../created/");
    defer absolute.destroy();
    try std.testing.expectEqualStrings("/link/../created/", absolute.request().destination);
    const c = @import("../platform/linux.zig").c;
    const home = std.mem.span(c.getenv("HOME") orelse return error.SkipZigTest);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ home, "created/" });
    defer std.testing.allocator.free(expected);
    const expanded = try context.prepare(std.testing.io, std.testing.allocator, .mkdir, "~/created/");
    defer expanded.destroy();
    try std.testing.expectEqualStrings(expected, expanded.request().destination);
}

test "prepared requests own marked sources and target after pane destruction" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b", .data = "b" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    const jobs: [2]*Job = blk: {
        const panes = try PreparationPanes.init(base, base, listing.local, listing.local);
        defer panes.deinit();
        panes.source.toggleSelection();
        panes.source.move(.first, false); // Marked b wins over parent cursor.
        var target = "copied".*;
        const copied = try panes.context().prepare(io, std.testing.allocator, .copy, &target);
        errdefer copied.destroy();
        const deleted = try panes.context().prepare(io, std.testing.allocator, .delete, "");
        @memset(&target, 'X');
        @memset(buffer[0..base.len], 'X');
        break :blk .{ copied, deleted };
    };
    defer jobs[0].destroy();
    defer jobs[1].destroy();
    for (jobs) |job| {
        try std.testing.expect(job.status() == .prepared);
        try std.testing.expectEqual(@as(usize, 1), job.request().sources.len);
        try std.testing.expect(std.mem.endsWith(u8, job.request().sources[0], "/b"));
    }
    try std.testing.expect(std.mem.endsWith(u8, jobs[0].request().destination, "/copied"));
    try jobs[0].start();
    try waitForJob(jobs[0]);
    try std.testing.expectEqual(null, jobs[0].status().finished.failure);
    var data: [4]u8 = undefined;
    try std.testing.expectEqualStrings("b", try tmp.dir.readFile(io, "copied", &data));
    // The prepared delete remains safe to dismiss, with no work launched.
    _ = try tmp.dir.statFile(io, "b", .{});
}
