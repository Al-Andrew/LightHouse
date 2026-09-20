//! Test-only contract fixture. No production caller instantiates this adapter.
const std = @import("std");
const directory = @import("directory.zig");

pub const Opaque = struct {
    pub const root = "vault::R";
    pub const child = "node#17";
    pub const slow = "node#slow";
    pub const latest = "node#latest";
    started: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    canceled_seen: std.atomic.Value(bool) = .init(false),
    readable: bool = true,
    writable: bool = false,
    missing_a: bool = false,
    fail: bool = false,
    resolve_failure: ?anyerror = null,

    pub fn provider(self: *Opaque) directory.Provider {
        return .{ .identity = self, .context = self, .resolve = resolve, .has_parent = hasParent, .parent_hint = parentHint, .display = display, .capabilities = capabilities, .scan = scan };
    }
    fn resolve(context: ?*anyopaque, allocator: std.mem.Allocator, base: []const u8, request: directory.Resolution) ![]const u8 {
        const self: *Opaque = @ptrCast(@alignCast(context.?));
        if (self.resolve_failure) |err| return err;
        const target: []const u8 = switch (request) {
            .root, .parent => root,
            .child => |name| if (std.mem.eql(u8, base, root) and std.mem.eql(u8, name, "folder")) child else return error.UnknownChild,
            .user_input => |value| blk: {
                if (std.mem.eql(u8, value, "folder") and std.mem.eql(u8, base, root)) break :blk child;
                if (std.mem.eql(u8, value, "up")) break :blk root;
                for ([_][]const u8{ root, child, slow, latest, "bad-scan" }) |valid| if (std.mem.eql(u8, value, valid)) break :blk valid;
                return error.UnknownLocation;
            },
        };
        return allocator.dupe(u8, target);
    }
    fn hasParent(_: ?*anyopaque, locator: []const u8) bool {
        return !std.mem.eql(u8, locator, root);
    }
    fn parentHint(_: ?*anyopaque, locator: []const u8) ?[]const u8 {
        return if (std.mem.eql(u8, locator, child)) "folder" else null;
    }
    // Identical filesystem-looking presentation deliberately carries no identity.
    fn display(_: ?*anyopaque, _: []const u8) []const u8 {
        return "/";
    }
    fn capabilities(context: ?*anyopaque, _: []const u8) directory.Capabilities {
        const self: *Opaque = @ptrCast(@alignCast(context.?));
        return .{ .source_read = self.readable, .destination_write = self.writable };
    }
    fn scan(context: ?*anyopaque, io: std.Io, locator: []const u8, options: directory.Options, canceled: *const std.atomic.Value(bool)) !directory.Snapshot {
        const self: *Opaque = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, locator, slow)) {
            self.started.store(true, .release);
            // Deliberately return success after cancellation: Pane must suppress it.
            while (!self.release.load(.acquire)) try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            self.canceled_seen.store(canceled.load(.acquire), .release);
        } else if (canceled.load(.acquire)) return error.Canceled;
        if (self.fail or std.mem.eql(u8, locator, "bad-scan")) return error.AccessDenied;
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        var entries: std.ArrayList(directory.Entry) = .empty;
        if (std.mem.eql(u8, locator, root)) {
            try entries.append(allocator, .{ .name = try allocator.dupe(u8, "folder"), .kind = .directory, .directory = true, .size = null, .modified = null });
            const names: []const []const u8 = if (options.reverse) &.{ "b", "a", ".hidden" } else &.{ ".hidden", "a", "b" };
            for (names) |name| {
                if (!options.hidden and name[0] == '.') continue;
                if (self.missing_a and std.mem.eql(u8, name, "a")) continue;
                try entries.append(allocator, .{ .name = try allocator.dupe(u8, name), .kind = .file, .directory = false, .size = 1, .modified = 1 });
            }
        }
        return .{ .arena = arena, .locator = try allocator.dupe(u8, locator), .entries = entries.items, .options = options };
    }
    pub fn waitStarted(self: *Opaque) !void {
        for (0..5000) |_| {
            if (self.started.load(.acquire)) return;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        return error.ScanTimeout;
    }
};

pub const LocalCapabilities = struct {
    writable: bool = true,
    readable: bool = true,
    blocked: ?[]const u8 = null,
    pub fn provider(self: *LocalCapabilities, local_identity: bool) directory.Provider {
        var result = directory.local;
        result.context = self;
        result.capabilities = capabilities;
        if (!local_identity) result.identity = self;
        return result;
    }
    fn capabilities(context: ?*anyopaque, locator: []const u8) directory.Capabilities {
        const self: *LocalCapabilities = @ptrCast(@alignCast(context.?));
        return .{ .source_read = self.readable, .destination_write = self.writable and !(if (self.blocked) |blocked| std.mem.startsWith(u8, locator, blocked) else false) };
    }
};
