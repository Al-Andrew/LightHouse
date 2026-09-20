//! Noninteractive fzf worker. Owned input/output and a cancellation flag keep
//! matching independent of the UI and of subsequent directory snapshots.
const std = @import("std");
const platform = @import("../platform/linux.zig");
const c = platform.c;

pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    query: [:0]const u8,
    names: []const u8,
    executable: [:0]const u8,
    canceled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    result: ?[]const u8 = null,
    failure: ?anyerror = null,
    future: ?std.Io.Future(void) = null,

    pub fn create(query: []const u8, entries: []const @import("directory.zig").Entry, executable: []const u8) !*Job {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const self = try allocator.create(Job);
        var names: std.ArrayList(u8) = .empty;
        for (entries) |entry| {
            try names.appendSlice(allocator, entry.name);
            try names.append(allocator, 0);
        }
        const owned_query = try allocator.dupeZ(u8, query);
        const owned_executable = try allocator.dupeZ(u8, executable);
        self.* = .{ .arena = arena, .query = owned_query, .names = names.items, .executable = owned_executable };
        return self;
    }

    pub fn destroy(self: *Job) void {
        var arena = self.arena;
        arena.deinit();
    }

    pub fn work(self: *Job) void {
        self.result = self.run() catch |err| failed: {
            self.failure = err;
            break :failed null;
        };
        self.done.store(true, .release);
    }

    fn run(self: *Job) ![]const u8 {
        const allocator = self.arena.allocator();
        // Resolve PATH before fork; the child only uses async-signal-safe calls.
        const executable = if (std.mem.indexOfScalar(u8, self.executable, '/') != null) self.executable else resolved: {
            const path = if (c.getenv("PATH")) |value| std.mem.span(value) else "/usr/local/bin:/usr/bin:/bin";
            var dirs = std.mem.splitScalar(u8, path, ':');
            while (dirs.next()) |dir| {
                const candidate = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ if (dir.len == 0) "." else dir, self.executable }, 0);
                if (c.access(candidate, c.X_OK) == 0) break :resolved candidate;
            }
            return error.FzfNotFound;
        };
        if (c.access(executable, c.X_OK) != 0) return error.FzfNotFound;
        var environment: std.ArrayList(?[*:0]const u8) = .empty;
        var i: usize = 0;
        while (c.environ[i]) |entry| : (i += 1) {
            // Includes FZF_DEFAULT_OPTS, FZF_DEFAULT_OPTS_FILE, and command
            // defaults. No environment-supplied matching/output overrides.
            if (std.mem.startsWith(u8, std.mem.span(entry), "FZF_")) continue;
            try environment.append(allocator, entry);
        }
        try environment.append(allocator, null);
        const argv = [_:null]?[*:0]const u8{ executable, "--filter", self.query, "--no-sort", "--read0", "--print0" };
        // Anonymous files avoid pipe deadlocks and SIGPIPE. They are never
        // persisted and are closed in every exit/cancellation path.
        const input = c.memfd_create("lighthouse-fzf-input", c.MFD_CLOEXEC);
        if (input < 0) return error.FzfFailed;
        defer _ = c.close(input);
        const output = c.memfd_create("lighthouse-fzf-output", c.MFD_CLOEXEC);
        if (output < 0) return error.FzfFailed;
        defer _ = c.close(output);
        const errors = c.open("/dev/null", c.O_WRONLY | c.O_CLOEXEC);
        if (errors < 0) return error.FzfFailed;
        defer _ = c.close(errors);
        try platform.writeAll(input, self.names);
        if (c.lseek(input, 0, c.SEEK_SET) < 0) return error.FzfFailed;
        if (self.canceled.load(.acquire)) return error.Canceled;
        const pid = c.fork();
        if (pid < 0) return error.FzfFailed;
        if (pid == 0) {
            if (c.dup2(input, 0) >= 0 and c.dup2(output, 1) >= 0 and c.dup2(errors, 2) >= 0)
                _ = c.execve(executable, @ptrCast(&argv), @ptrCast(environment.items.ptr));
            c._exit(127);
        }
        var reaped = false;
        defer if (!reaped) {
            _ = c.kill(pid, c.SIGKILL);
            while (c.waitpid(pid, null, 0) < 0 and platform.errno() == c.EINTR) {}
        };
        var status: c_int = 0;
        while (true) {
            if (self.canceled.load(.acquire)) return error.Canceled;
            const result = c.waitpid(pid, &status, c.WNOHANG);
            if (result == pid) {
                reaped = true;
                break;
            }
            if (result < 0 and platform.errno() != c.EINTR) return error.FzfFailed;
            _ = c.usleep(5000);
        }
        // fzf returns 1 for no matches, 0 for matches, and >=2 on error.
        if (!c.WIFEXITED(status) or (c.WEXITSTATUS(status) != 0 and c.WEXITSTATUS(status) != 1)) return error.FzfFailed;
        const length = c.lseek(output, 0, c.SEEK_END);
        if (length < 0 or length > self.names.len) return error.FzfFailed;
        if (c.lseek(output, 0, c.SEEK_SET) < 0) return error.FzfFailed;
        const bytes = try allocator.alloc(u8, @intCast(length));
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = c.read(output, bytes.ptr + offset, bytes.len - offset);
            if (n < 0 and platform.errno() == c.EINTR) continue;
            if (n <= 0) return error.FzfFailed;
            offset += @intCast(n);
        }
        if (bytes.len > 0 and bytes[bytes.len - 1] != 0) return error.FzfFailed;
        return bytes;
    }
};
