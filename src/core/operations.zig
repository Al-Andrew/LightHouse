//! Local file jobs. Requests own their paths; only atomic counters cross threads.
//! Never replace an existing destination. Completed items remain after failure.
const std = @import("std");
const Dir = std.Io.Dir;

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

pub const Job = struct {
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
    collected: bool = false,

    pub fn create(io: std.Io, allocator: std.mem.Allocator, kind: Kind, base: []const u8, names: []const []const u8, target: []const u8) !*Job {
        if (kind != .delete and target.len == 0) return error.EmptyDestination;
        if (kind != .mkdir and names.len == 0) return error.NoSelection;
        const self = try allocator.create(Job);
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
        return self;
    }

    pub fn start(self: *Job) !void {
        self.future = try self.io.concurrent(work, .{self});
    }

    pub fn destroy(self: *Job) void {
        if (self.future) |*future| {
            self.canceled.store(true, .release);
            future.cancel(self.io);
        }
        const allocator = self.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }

    pub fn poll(self: *Job) bool {
        if (self.collected or !self.done.load(.acquire)) return false;
        if (self.future) |*future| future.await(self.io);
        self.future = null;
        self.collected = true;
        return true;
    }

    fn check(self: *Job) !void {
        if (self.canceled.load(.acquire)) return error.Canceled;
    }

    fn pathError(self: *Job, path: []const u8) void {
        self.failed_path_len = @min(path.len, self.failed_path.len);
        @memcpy(self.failed_path[0..self.failed_path_len], path[0..self.failed_path_len]);
    }

    fn work(self: *Job) void {
        self.execute() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }

    fn execute(self: *Job) !void {
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

    fn deleteNode(self: *Job, parent: Dir, name: []const u8, display_path: []const u8, depth: usize) anyerror!void {
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

    fn validateTarget(self: *Job, source: []const u8, target: []const u8, directory: bool) !void {
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

    fn copyNode(self: *Job, source: []const u8, target: []const u8, depth: usize) anyerror!void {
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
    job.work();
    _ = job.poll();
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
    try std.testing.expectEqual(null, job.failure);
    try std.testing.expectEqual(@as(usize, 1), job.completed.load(.acquire));
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
            try std.testing.expectEqual(error.PathAlreadyExists, job.failure.?);
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
    try std.testing.expectEqual(null, renamed.failure);
    const moved = try testJob(.move, base, &.{ "renamed", "b", "folder" }, "dest");
    defer moved.destroy();
    try std.testing.expectEqual(null, moved.failure);
    try std.testing.expectEqual(@as(usize, 3), moved.completed.load(.acquire));
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
            try std.testing.expectEqual(error.DestinationInsideSource, job.failure.?);
        }
        const multiple = try testJob(kind, base, &.{ "source", "alias" }, "missing");
        defer multiple.destroy();
        try std.testing.expectEqual(error.DestinationMustBeDirectory, multiple.failure.?);
        const slash = try testJob(kind, base, &.{"source"}, "missing/");
        defer slash.destroy();
        try std.testing.expectEqual(error.DestinationMustBeDirectory, slash.failure.?);
    }
}

test "mkdir refuses existing paths and reports missing parents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    const first = try testJob(.mkdir, base, &.{}, "new folder");
    defer first.destroy();
    try std.testing.expectEqual(null, first.failure);
    const again = try testJob(.mkdir, base, &.{}, "new folder");
    defer again.destroy();
    try std.testing.expectEqual(error.PathAlreadyExists, again.failure.?);
    const missing = try testJob(.mkdir, base, &.{}, "missing/child");
    defer missing.destroy();
    try std.testing.expectEqual(error.FileNotFound, missing.failure.?);
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
    try std.testing.expectEqual(error.PathAlreadyExists, job.failure.?);
    try std.testing.expectEqual(@as(usize, 1), job.completed.load(.acquire));
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
    const source = try tmp.dir.createFile(io, "large", .{});
    defer source.close(io);
    try source.setLength(io, 4 * 1024 * 1024 * 1024);
    const job = try Job.create(io, std.testing.allocator, .copy, base, &.{"large"}, "destination");
    defer job.destroy();
    try job.start();
    for (0..5000) |_| {
        if (job.bytes.load(.acquire) > 0 or job.done.load(.acquire)) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(job.bytes.load(.acquire) > 0);
    job.canceled.store(true, .release);
    for (0..5000) |_| {
        if (job.poll()) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(job.collected);
    try std.testing.expectEqual(error.Canceled, job.failure.?);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "destination", .{}));
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024 * 1024), (try source.stat(io)).size);
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
    try std.testing.expectEqual(null, job.failure);
    try std.testing.expectEqual(@as(usize, 2), job.completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 7), job.removed.load(.acquire));
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
    try std.testing.expectEqual(error.FileNotFound, job.failure.?);
    try std.testing.expectEqual(@as(usize, 1), job.completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), job.removed.load(.acquire));
    try std.testing.expect(std.mem.endsWith(u8, job.failed_path[0..job.failed_path_len], "/missing"));
    _ = try tmp.dir.statFile(io, "last", .{});
}

test "cancellation interrupts recursive deletion and retains remaining children" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = try testBase(&tmp, &buffer);
    try tmp.dir.createDir(io, "tree", .default_dir);
    for (0..5000) |index| {
        var name: [32]u8 = undefined;
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "tree/{d}", .{index}), .data = "" });
    }
    const job = try Job.create(io, std.testing.allocator, .delete, base, &.{"tree"}, "");
    defer job.destroy();
    try job.start();
    for (0..5000) |_| {
        if (job.removed.load(.acquire) > 0 or job.done.load(.acquire)) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(job.removed.load(.acquire) > 0);
    job.canceled.store(true, .release);
    for (0..5000) |_| {
        if (job.poll()) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(job.collected);
    try std.testing.expectEqual(error.Canceled, job.failure.?);
    try std.testing.expect(job.removed.load(.acquire) < 5000);
    _ = try tmp.dir.statFile(io, "tree", .{});
}
