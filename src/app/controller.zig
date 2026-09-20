//! Owns application workflows and focus policy; widgets own scoped input routing.
const std = @import("std");
const toolkit = @import("lighthouse-ui");
const input = toolkit.input;
const ui = toolkit.screen;
const PathInput = toolkit.TextInput;
const Emulator = @import("../terminal/emulator.zig").Emulator;
const Pane = @import("../core/pane.zig").Pane;
const operations = @import("../core/operations.zig");
const Layout = @import("layout.zig").Layout;
const dialogs = @import("widgets/dialogs.zig");
const paintOperation = dialogs.paintOperation;

pub const Focus = enum { left, right, terminal };
// A tagged state owns exactly one modal payload. An action cannot outlive its
// editor, and help/path/delete dialogs cannot accidentally overlap.
const Modal = union(enum) {
    none,
    help,
    editor: struct { input: PathInput, action: ?operations.Kind = null },
    confirm_delete: *operations.Job,

    pub fn deinit(self: *Modal) void {
        switch (self.*) {
            .editor => |*editor| editor.input.deinit(),
            .confirm_delete => |job| job.destroy(),
            .none, .help => {},
        }
        self.* = .none;
    }
};

/// Owns editor/confirmation payloads and the single job through result dismissal.
/// Borrows both panes and I/O; destroy the view first, then State, then the panes.
/// Observations borrow immutable payloads until the next controller mutation.
pub const State = opaque {
    pub const ModalView = union(enum) {
        none,
        help,
        editor: struct { input: *const PathInput, action: ?operations.Kind },
        confirm_delete: *const operations.Job,
    };
    pub const Observation = struct {
        focus: Focus,
        adjustment: i32,
        zoom: bool,
        quit: bool,
        force_redraw: bool,
        modal: ModalView,
        operation: ?*const operations.Job,

        pub fn modalVisible(self: Observation) bool {
            return self.modal != .none or (self.operation != null and self.focus != .terminal);
        }
    };

    pub fn create(io: std.Io, allocator: std.mem.Allocator, borrowed_panes: [2]*Pane) !*State {
        const self = try allocator.create(Implementation);
        self.* = .{ .io = io, .allocator = allocator, .panes = borrowed_panes };
        return @ptrCast(self);
    }

    pub fn destroy(state: *State) void {
        const self = state.implementation();
        if (self.operation) |job| job.destroy();
        self.modal.deinit();
        self.allocator.destroy(self);
    }

    pub fn view(state: *const State) Observation {
        const self: *const Implementation = @ptrCast(@alignCast(state));
        return .{
            .focus = self.focus,
            .adjustment = self.adjustment,
            .zoom = self.zoom,
            .quit = self.quit,
            .force_redraw = self.force_redraw,
            .modal = switch (self.modal) {
                .none => .none,
                .help => .help,
                .editor => |*editor| .{ .editor = .{ .input = &editor.input, .action = editor.action } },
                .confirm_delete => |job| .{ .confirm_delete = job },
            },
            .operation = self.operation,
        };
    }

    pub fn panes(state: *State) [2]*Pane {
        return state.implementation().panes;
    }

    pub fn activePane(state: *State) *Pane {
        return state.implementation().activePane();
    }

    pub fn openPath(state: *State, absolute: bool) !void {
        try state.implementation().openPath(absolute);
    }

    pub fn actionAvailable(state: *const State, kind: operations.Kind) bool {
        const self: *const Implementation = @ptrCast(@alignCast(state));
        return self.actionAvailable(kind);
    }

    pub fn openAction(state: *State, kind: operations.Kind) !void {
        try state.implementation().openAction(kind);
    }

    pub fn openDelete(state: *State) !void {
        try state.implementation().openDelete();
    }

    pub fn submit(state: *State, value: []const u8) !void {
        try state.implementation().submit(value);
    }

    pub fn confirmDelete(state: *State) !void {
        try state.implementation().confirmDelete();
    }

    /// Closes an editor/confirmation, requests job cancellation, or releases its result.
    pub fn dismiss(state: *State) void {
        state.implementation().dismiss();
    }

    pub fn toggleTerminal(state: *State) void {
        state.implementation().toggleTerminal();
    }

    /// Root bindings only. Pane and terminal input stay in their widgets.
    pub fn globalEvent(state: *State, emulator: *Emulator, ev: *const input.Event) !void {
        try state.implementation().globalEvent(emulator, ev);
    }

    /// Called only by the modal widget, whose tree scope consumes every event.
    pub fn modalEvent(state: *State, ev: *const input.Event) !void {
        try state.implementation().modalEvent(ev);
    }

    pub fn requestRedraw(state: *State) void {
        state.implementation().force_redraw = true;
    }

    pub fn rendered(state: *State) void {
        state.implementation().force_redraw = false;
    }

    /// Collects completions and requests both pane refreshes exactly once.
    /// A failed refresh does not skip the other pane or retry completion later.
    /// Also publishes pane scans; true asks the host to repaint.
    pub fn poll(state: *State) !bool {
        const self = state.implementation();
        var changed = false;
        var failure: ?anyerror = null;
        if (self.operation) |job| {
            if (job.poll()) {
                for (self.panes) |pane| pane.refresh() catch |err| {
                    if (failure == null) failure = err;
                };
                changed = true;
            } else if (job.status() != .finished and self.focus != .terminal) changed = true;
        }
        for (self.panes) |pane| {
            const published = pane.poll() catch |err| {
                if (failure == null) failure = err;
                continue;
            };
            changed = changed or published;
        }
        if (failure) |err| return err;
        return changed;
    }

    fn implementation(state: *State) *Implementation {
        return @ptrCast(@alignCast(state));
    }
};

fn isToggleTerminal(ev: *const input.Event) bool {
    return ev.len == 1 and ev.bytes[0] == input.control('g');
}

const Implementation = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    focus: Focus = .left,
    last_pane: Focus = .left,
    adjustment: i32 = 0,
    zoom: bool = false,
    quit: bool = false,
    force_redraw: bool = true,
    panes: [2]*Pane,
    modal: Modal = .none,
    operation: ?*operations.Job = null,

    fn activePane(self: *const Implementation) *Pane {
        return self.panes[if (self.last_pane == .right) @as(usize, 1) else 0];
    }

    fn actionAvailable(self: *const Implementation, kind: operations.Kind) bool {
        const pane = self.activePane();
        const other = self.panes[if (self.last_pane == .left) @as(usize, 1) else 0];
        const destination = if (kind == .mkdir or kind == .delete) pane else other;
        return operations.available(kind, pane.provider(), pane.location(), destination.provider(), destination.location(), pane.sources().count);
    }

    fn openPath(self: *Implementation, absolute: bool) !void {
        if (self.modal != .none or self.operation != null) return error.WorkflowBusy;
        const pane = self.activePane();
        const initial = if (absolute) try pane.rootInput(self.allocator) else try self.allocator.dupe(u8, pane.location().locator);
        defer self.allocator.free(initial);
        self.modal = .{ .editor = .{ .input = try PathInput.init(self.allocator, initial) } };
        // Keep the base location stable while editing a relative path. A slow
        // earlier navigation must not change its meaning underneath the dialog.
        pane.cancelNavigation();
        if (absolute) self.modal.editor.input.select_all = false;
    }

    fn openAction(self: *Implementation, kind: operations.Kind) !void {
        if (self.modal != .none or self.operation != null) return error.WorkflowBusy;
        if (kind == .delete) return self.openDelete();
        const pane = self.activePane();
        if (!self.actionAvailable(kind)) return;
        const other = self.panes[if (self.last_pane == .left) @as(usize, 1) else 0];
        self.modal = .{ .editor = .{
            .input = try PathInput.init(self.allocator, if (kind == .mkdir) "" else other.location().locator),
            .action = kind,
        } };
        pane.cancelNavigation();
        other.cancelNavigation();
    }

    fn submitEditor(self: *Implementation, value: []const u8, action: ?operations.Kind) !void {
        const pane = self.activePane();
        if (action) |kind| {
            self.startOperation(try self.createOperation(kind, value));
        } else try pane.request(value);
    }

    fn submit(self: *Implementation, value: []const u8) !void {
        if (self.modal != .editor) return error.NoEditor;
        if (value.len == 0) return;
        try self.submitEditor(value, self.modal.editor.action);
        self.modal.deinit();
    }

    fn createOperation(self: *Implementation, kind: operations.Kind, target: []const u8) !*operations.Job {
        if (!self.actionAvailable(kind)) return error.UnsupportedOperation;
        const pane = self.activePane();
        const base = try pane.provider().localPath(pane.location().locator);
        const provider = pane.provider();
        const local_target = if (kind == .delete) try self.allocator.dupe(u8, base) else try provider.localTarget(self.allocator, base, target);
        defer self.allocator.free(local_target);
        if (!operations.available(kind, provider, pane.location(), provider, provider.location(local_target), pane.sources().count)) return error.UnsupportedOperation;
        _ = try provider.localPath(local_target);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        if (kind != .mkdir) {
            var sources = pane.sources();
            while (sources.next()) |name| try names.append(self.allocator, name);
        }
        return operations.Job.create(self.io, self.allocator, kind, base, names.items, local_target);
    }

    fn startOperation(self: *Implementation, job: *operations.Job) void {
        // This ownership transfer happens once; launch failures stay in the job.
        job.start() catch unreachable;
        self.operation = job;
    }

    fn openDelete(self: *Implementation) !void {
        if (self.modal != .none or self.operation != null) return error.WorkflowBusy;
        const pane = self.activePane();
        if (!self.actionAvailable(.delete)) return;
        // Own the exact names shown in the confirmation, independent of scans.
        self.modal = .{ .confirm_delete = try self.createOperation(.delete, "") };
        pane.cancelNavigation();
    }

    fn confirmDelete(self: *Implementation) !void {
        if (self.modal != .confirm_delete) return error.NoConfirmation;
        if (!self.actionAvailable(.delete)) return error.UnsupportedOperation;
        const job = self.modal.confirm_delete;
        self.modal = .none;
        self.startOperation(job);
    }

    fn dismiss(self: *Implementation) void {
        if (self.modal != .none) {
            self.modal.deinit();
        } else if (self.operation) |job| {
            if (job.status() == .finished) {
                job.destroy();
                self.operation = null;
            } else job.cancel();
        }
    }

    fn modalEvent(self: *Implementation, ev: *const input.Event) !void {
        switch (self.modal) {
            .confirm_delete => {
                // Paste contents cannot confirm or dismiss a destructive action.
                if (ev.kind != .key) return;
                if (ev.key == .escape or (ev.key == .text and ev.len == 1 and ev.bytes[0] == 'n')) {
                    self.modal.deinit();
                } else if (ev.key == .enter) {
                    try self.confirmDelete();
                }
                return;
            },
            .editor => |*editor| {
                switch (try editor.input.event(ev)) {
                    .editing => {},
                    .cancel => self.modal.deinit(),
                    .accept => {
                        try self.submit(editor.input.text());
                    },
                }
                return;
            },
            .help => {
                if (ev.kind == .key) self.modal.deinit();
                return;
            },
            .none => {},
        }
        if (ev.kind != .key) return;
        if (isToggleTerminal(ev)) {
            self.toggleTerminal();
            return;
        }
        if (self.operation) |job| {
            const finished = job.status() == .finished;
            if (ev.key == .f10 or (ev.key == .text and ev.len == 1 and ev.bytes[0] == 'q')) {
                self.quit = true;
            } else if (ev.key == .escape or (ev.key == .enter and finished)) {
                self.dismiss();
            }
            return;
        }
    }

    fn toggleTerminal(self: *Implementation) void {
        if (self.modal != .none) return;
        if (self.focus == .terminal) {
            self.focus = self.last_pane;
            self.zoom = false;
        } else {
            self.last_pane = self.focus;
            self.focus = .terminal;
        }
    }

    fn globalEvent(self: *Implementation, emulator: *Emulator, ev: *const input.Event) !void {
        if (self.modal != .none or ev.kind != .key) return;
        if (isToggleTerminal(ev)) {
            self.toggleTerminal();
            return;
        }
        if (self.focus == .terminal or self.operation != null) return;
        const pane = self.activePane();
        switch (ev.key) {
            .f1 => self.modal = .help,
            .f5 => try self.openAction(.copy),
            .f6 => try self.openAction(.move),
            .f7 => try self.openAction(.mkdir),
            .f8 => try self.openDelete(),
            .tab => {
                self.focus = if (self.focus == .left) .right else .left;
                self.last_pane = self.focus;
            },
            .f10 => self.quit = true,
            .page_up => if (ev.shift) emulator.scrollPage(.up),
            .page_down => if (ev.shift) emulator.scrollPage(.down),
            .text => if (ev.len == 1) {
                switch (ev.bytes[0]) {
                    'q' => self.quit = true,
                    't' => {
                        self.last_pane = self.focus;
                        self.focus = .terminal;
                    },
                    'z' => {
                        self.zoom = true;
                        self.last_pane = self.focus;
                        self.focus = .terminal;
                    },
                    '+' => self.adjustment = @min(self.adjustment + 1, Layout.max_adjustment),
                    '-' => self.adjustment = @max(self.adjustment - 1, -Layout.max_adjustment),
                    input.control('l') => try self.openPath(false),
                    '/' => try self.openPath(true),
                    input.control('r') => {
                        self.force_redraw = true;
                        try pane.refresh();
                    },
                    else => {},
                }
            },
            else => {},
        }
    }
};

const directory = @import("../core/directory.zig");

// Count real directory-provider invocations, not controller implementation fields.
const TestPanes = struct {
    scans: [2]std.atomic.Value(usize) = .{ .init(0), .init(0) },
    panes: [2]*Pane = undefined,

    fn init(self: *TestPanes, path: []const u8) !void {
        self.panes[0] = try Pane.create(std.testing.io, std.testing.allocator, path, .{ .provider = testLocalProvider(&self.scans[0], scan) });
        errdefer self.panes[0].destroy();
        self.panes[1] = try Pane.create(std.testing.io, std.testing.allocator, path, .{ .provider = testLocalProvider(&self.scans[1], scan) });
    }

    fn deinit(self: *TestPanes) void {
        for (self.panes) |pane| pane.destroy();
    }

    fn scan(context: ?*anyopaque, io: std.Io, path: []const u8, options: directory.Options, canceled: *const std.atomic.Value(bool)) !directory.Snapshot {
        const count: *std.atomic.Value(usize) = @ptrCast(@alignCast(context.?));
        _ = count.fetchAdd(1, .monotonic);
        return directory.local.scan(null, io, path, options, canceled);
    }

    fn expectScans(self: *TestPanes, expected: usize) !void {
        for (&self.scans) |*count| try std.testing.expectEqual(expected, count.load(.acquire));
    }
};

fn settle(state: *State) !void {
    for (0..5000) |_| {
        _ = try state.poll();
        const job_finished = if (state.view().operation) |job| job.status() == .finished else true;
        if (job_finished and state.panes()[0].view().status != .loading and state.panes()[1].view().status != .loading) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.WorkflowTimeout;
}

fn checkCompletion(outcome: enum { success, failure, launch_failure }) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    var panes: TestPanes = .{};
    try panes.init(buffer[0..len]);
    defer panes.deinit();
    const state = try State.create(if (outcome == .launch_failure) std.Io.failing else io, std.testing.allocator, panes.panes);
    defer state.destroy();
    if (outcome == .failure) try tmp.dir.createDir(io, "created", .default_dir);
    try state.openAction(.mkdir);
    try state.submit("created");
    try std.testing.expect(state.view().modal == .none);
    try std.testing.expectError(error.WorkflowBusy, state.openAction(.mkdir));
    try std.testing.expectError(error.WorkflowBusy, state.openPath(false));
    try std.testing.expectError(error.WorkflowBusy, state.openDelete());
    // Observation and painting cannot collect even a synchronous launch failure.
    var frame = ui.Frame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.begin(100, 30);
    for (0..3) |_| {
        try std.testing.expect(state.view().operation.?.status() == .running);
        try paintOperation(frame.painter(.{ .x = 0, .y = 0, .width = 100, .height = 30 }), state.view().operation.?);
    }
    try panes.expectScans(0);
    state.toggleTerminal();
    try settle(state);
    try panes.expectScans(1);
    const result = state.view().operation.?.status().finished;
    switch (outcome) {
        .success => {
            try std.testing.expect(result.failure == null);
            try std.testing.expectEqual(@as(usize, 1), result.progress.completed);
        },
        .failure => try std.testing.expectEqual(error.PathAlreadyExists, result.failure.?.err),
        .launch_failure => try std.testing.expectEqual(error.ConcurrencyUnavailable, result.failure.?.err),
    }
    if (outcome != .launch_failure) for (panes.panes) |pane| {
        try std.testing.expectEqualStrings("created", pane.view().entries[0].name);
    };
    // Polling and observing the retained result never cause another refresh.
    for (0..3) |_| {
        try std.testing.expect(!try state.poll());
        try std.testing.expectEqualDeep(result, state.view().operation.?.status().finished);
    }
    state.toggleTerminal();
    try std.testing.expect(state.view().modalVisible());
    state.dismiss();
    try std.testing.expect(state.view().operation == null);
    try std.testing.expect(!try state.poll());
    try panes.expectScans(1);
}

test "successful failed and launch-failed workflows refresh both panes once and retain results" {
    try checkCompletion(.success);
    try checkCompletion(.failure);
    try checkCompletion(.launch_failure);
}

// Gate the first deletion. Cancellation is then observed before the second item;
// shutdown cancels the waiting I/O and joins it before releasing job storage.
const DeleteGate = struct {
    threaded: std.Io.Threaded,
    vtable: std.Io.VTable = undefined,
    entered: std.Io.Event = .unset,
    released: std.Io.Event = .unset,

    fn io(self: *DeleteGate) std.Io {
        const base = self.threaded.io();
        self.vtable = base.vtable.*;
        self.vtable.dirDeleteFile = delete;
        return .{ .userdata = base.userdata, .vtable = &self.vtable };
    }

    fn delete(userdata: ?*anyopaque, dir: std.Io.Dir, path: []const u8) std.Io.Dir.DeleteFileError!void {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata.?));
        const self: *DeleteGate = @fieldParentPtr("threaded", threaded);
        const base = self.threaded.io();
        self.entered.set(base);
        try self.released.wait(base);
        return base.vtable.dirDeleteFile(base.userdata, dir, path);
    }

    fn wait(self: *DeleteGate) !void {
        for (0..5000) |_| {
            if (self.entered.isSet()) return;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
        }
        return error.GateTimeout;
    }
};

fn checkCanceledWorkflow(shutdown: bool) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a", "b" }) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    var panes: TestPanes = .{};
    try panes.init(buffer[0..len]);
    defer panes.deinit();
    var gate: DeleteGate = .{ .threaded = .init(std.testing.allocator, .{}) };
    defer gate.threaded.deinit();
    const state = try State.create(gate.io(), std.testing.allocator, panes.panes);
    var destroyed = false;
    defer if (!destroyed) state.destroy();
    for (panes.panes) |pane| try pane.refresh();
    try settle(state);
    const pane = state.activePane();
    pane.move(.{ .by = 1 }, false);
    pane.move(.last, true);
    try state.openDelete();
    try std.testing.expectEqual(@as(usize, 2), state.view().modal.confirm_delete.request().sources.len);
    try state.confirmDelete();
    try gate.wait();
    if (shutdown) {
        state.destroy();
        destroyed = true;
        // The caller's panes remain usable after State releases all its workers.
        try std.testing.expectEqual(@as(usize, 2), pane.view().entries.len);
        _ = try tmp.dir.statFile(io, "a", .{});
        _ = try tmp.dir.statFile(io, "b", .{});
    } else {
        state.dismiss();
        try std.testing.expect(state.view().operation.?.status() == .canceling);
        gate.released.set(gate.threaded.io());
        try settle(state);
        const result = state.view().operation.?.status().finished;
        try std.testing.expectEqual(error.Canceled, result.failure.?.err);
        try std.testing.expectEqual(@as(usize, 1), result.progress.completed);
        try panes.expectScans(2);
        for (panes.panes) |p| try std.testing.expectEqualStrings("b", p.view().entries[0].name);
        try std.testing.expect(!try state.poll());
        state.dismiss();
        try std.testing.expect(!try state.poll());
        try panes.expectScans(2);
    }
}

test "canceled workflow refreshes both panes once after collection" {
    try checkCanceledWorkflow(false);
}

test "controller shutdown cancels and joins outstanding work while preserving borrowed panes" {
    try checkCanceledWorkflow(true);
}

fn allocateWorkflow(allocator: std.mem.Allocator, panes: [2]*Pane) !void {
    const state = try State.create(std.Io.failing, allocator, panes);
    defer state.destroy();
    try state.openAction(.mkdir);
    try state.submit("created");
}

test "allocation failures release controller editor and prepared job ownership" {
    var panes: TestPanes = .{};
    try panes.init("/");
    defer panes.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateWorkflow, .{panes.panes});
}

test "completion attempts the other pane refresh even when the first cannot allocate" {
    var left_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var scans = [_]std.atomic.Value(usize){ .init(0), .init(0) };
    const left = try Pane.create(std.testing.io, left_allocator.allocator(), "/", .{ .provider = testLocalProvider(&scans[0], TestPanes.scan) });
    defer left.destroy();
    const right = try Pane.create(std.testing.io, std.testing.allocator, "/", .{ .provider = testLocalProvider(&scans[1], TestPanes.scan) });
    defer right.destroy();
    const state = try State.create(std.Io.failing, std.testing.allocator, .{ left, right });
    defer state.destroy();
    try state.openAction(.mkdir);
    try state.submit("unused");
    left_allocator.fail_index = left_allocator.alloc_index;
    try std.testing.expectError(error.OutOfMemory, state.poll());
    try std.testing.expect(state.view().operation.?.status() == .finished);
    left_allocator.fail_index = std.math.maxInt(usize);
    try settle(state);
    try std.testing.expectEqual(@as(usize, 0), scans[0].load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), scans[1].load(.acquire));
    try std.testing.expect(!try state.poll());
    state.dismiss();
    try std.testing.expect(!try state.poll());
    try std.testing.expectEqual(@as(usize, 0), scans[0].load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), scans[1].load(.acquire));
}

fn testLocalProvider(context: ?*anyopaque, scan: @TypeOf(directory.local.scan)) directory.Provider {
    var result = directory.local;
    result.context = context;
    result.scan = scan;
    return result;
}

const CapabilityFixture = struct {
    writable: bool = true,
    readable: bool = true,
    blocked: ?[]const u8 = null,
    fn provider(self: *CapabilityFixture, local_identity: bool) directory.Provider {
        var result = directory.local;
        result.context = self;
        result.capabilities = capabilities;
        if (!local_identity) result.identity = self;
        return result;
    }
    fn capabilities(context: ?*anyopaque, locator: []const u8) directory.Capabilities {
        const self: *CapabilityFixture = @ptrCast(@alignCast(context.?));
        return .{ .source_read = self.readable, .destination_write = self.writable and !(if (self.blocked) |blocked| std.mem.startsWith(u8, locator, blocked) else false) };
    }
};

test "provider-looking local paths never enter local jobs without the local executor" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "keep", .data = "safe" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buffer[0..try tmp.dir.realPath(io, &buffer)];
    var fixture: CapabilityFixture = .{};
    const foreign = try Pane.create(io, std.testing.allocator, path, .{ .provider = fixture.provider(false) });
    defer foreign.destroy();
    const local_pane = try Pane.create(io, std.testing.allocator, path, .{});
    defer local_pane.destroy();
    const state = try State.create(io, std.testing.allocator, .{ foreign, local_pane });
    defer state.destroy();
    try foreign.refresh();
    try local_pane.refresh();
    try settle(state);
    foreign.move(.last, false);
    local_pane.move(.last, false);
    for ([_]operations.Kind{ .copy, .move, .mkdir, .delete }) |kind| {
        try std.testing.expect(!state.actionAvailable(kind));
        try state.openAction(kind);
        try std.testing.expect(state.view().modal == .none);
        try std.testing.expect(state.view().operation == null);
    }
    const outbound = try State.create(io, std.testing.allocator, .{ local_pane, foreign });
    defer outbound.destroy();
    try std.testing.expect(!outbound.actionAvailable(.copy));
    try std.testing.expect(!outbound.actionAvailable(.move));
    try std.testing.expect(outbound.actionAvailable(.delete));
    try outbound.openAction(.copy);
    try std.testing.expect(outbound.view().modal == .none);
    _ = try tmp.dir.statFile(io, "keep", .{});
}

test "workflow submission rechecks actual destination capabilities and delete confirmation" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "keep", .data = "safe" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const blocked = try std.fs.path.join(std.testing.allocator, &.{ path, "blocked" });
    defer std.testing.allocator.free(blocked);
    var fixture: CapabilityFixture = .{ .blocked = blocked };
    const left = try Pane.create(io, std.testing.allocator, path, .{ .provider = fixture.provider(true) });
    defer left.destroy();
    const right = try Pane.create(io, std.testing.allocator, path, .{});
    defer right.destroy();
    const state = try State.create(io, std.testing.allocator, .{ left, right });
    defer state.destroy();
    try left.refresh();
    try settle(state);
    left.move(.last, false);
    for ([_]operations.Kind{ .copy, .move, .mkdir }) |kind| {
        try state.openAction(kind);
        try std.testing.expectError(error.UnsupportedOperation, state.submit("blocked/new"));
        try std.testing.expect(state.view().operation == null);
        state.dismiss();
    }
    try state.openAction(.copy);
    fixture.readable = false;
    try std.testing.expectError(error.UnsupportedOperation, state.submit("copied"));
    try std.testing.expect(state.view().operation == null);
    state.dismiss();
    fixture.readable = true;
    try state.openDelete();
    fixture.writable = false;
    try std.testing.expectError(error.UnsupportedOperation, state.confirmDelete());
    try std.testing.expect(state.view().operation == null);
    try std.testing.expect(state.view().modal == .confirm_delete);
    _ = try tmp.dir.statFile(io, "keep", .{});
}

test "path editors round trip opaque current and provider root locators" {
    const Fixture = @import("../core/testing_provider.zig").Opaque;
    var fixture: Fixture = .{};
    const left = try Pane.create(std.testing.io, std.testing.allocator, Fixture.child, .{ .provider = fixture.provider() });
    defer left.destroy();
    const right = try Pane.create(std.testing.io, std.testing.allocator, "/", .{});
    defer right.destroy();
    const state = try State.create(std.testing.io, std.testing.allocator, .{ left, right });
    defer state.destroy();
    try state.openPath(false);
    try std.testing.expectEqualStrings(Fixture.child, state.view().modal.editor.input.text());
    try state.submit(state.view().modal.editor.input.text());
    try settle(state);
    try std.testing.expectEqualStrings(Fixture.child, left.location().locator);
    try state.openPath(true);
    try std.testing.expectEqualStrings(Fixture.root, state.view().modal.editor.input.text());
    try state.submit(state.view().modal.editor.input.text());
    try settle(state);
    try std.testing.expectEqualStrings(Fixture.root, left.location().locator);
}

test "local workflow targets preserve symlink parent traversal and trailing slash constraints" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "target/child");
    try tmp.dir.symLink(io, "target/child", "link", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "safe" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const left = try Pane.create(io, std.testing.allocator, path, .{});
    defer left.destroy();
    const right = try Pane.create(io, std.testing.allocator, path, .{});
    defer right.destroy();
    const state = try State.create(io, std.testing.allocator, .{ left, right });
    defer state.destroy();
    try state.openAction(.mkdir);
    try state.submit("link/../created");
    try settle(state);
    try std.testing.expect(state.view().operation.?.status().finished.failure == null);
    _ = try tmp.dir.statFile(io, "target/created", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "created", .{}));
    state.dismiss();
    left.move(.last, false);
    try std.testing.expectEqualStrings("source", left.view().focused().?.name);
    try state.openAction(.copy);
    try state.submit("missing-directory/");
    try settle(state);
    try std.testing.expect(state.view().operation.?.status().finished.failure != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "missing-directory", .{}));
}
