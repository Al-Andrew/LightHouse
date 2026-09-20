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
const commands = @import("commands.zig");

pub const Focus = enum { left, right, terminal };

/// Expected submission rejections retained by the event workflow. All other
/// errors (including allocation, lifecycle and transport) propagate to the host.
pub const Rejection = enum {
    invalid_location,
    unsupported_operation,

    fn fromError(err: anyerror) ?Rejection {
        return switch (err) {
            error.UnknownLocation, error.UnknownChild, error.InvalidLocation => .invalid_location,
            error.UnsupportedOperation => .unsupported_operation,
            else => null,
        };
    }

    pub fn message(self: Rejection) []const u8 {
        return switch (self) {
            .invalid_location => "Location not recognized. Edit the input or press Esc.",
            .unsupported_operation => "Operation unavailable. Change the target or press Esc.",
        };
    }
};
// A tagged state owns exactly one modal payload. An action cannot outlive its
// editor, and help/path/delete dialogs cannot accidentally overlap.
const Modal = union(enum) {
    none,
    help,
    notice: []const u8,
    editor: struct { input: PathInput, action: ?operations.Kind = null, rejection: ?Rejection = null },
    confirm_delete: struct { job: *operations.Job, rejection: ?Rejection = null },

    pub fn deinit(self: *Modal) void {
        switch (self.*) {
            .editor => |*editor| editor.input.deinit(),
            .confirm_delete => |confirmation| confirmation.job.destroy(),
            .none, .help, .notice => {},
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
        notice: []const u8,
        editor: struct { input: *const PathInput, action: ?operations.Kind },
        confirm_delete: *const operations.Job,
    };
    pub const Observation = struct {
        focus: Focus,
        adjustment: i32,
        zoom: bool,
        terminal_visible: bool,
        terminal_exists: bool,
        quit: bool,
        force_redraw: bool,
        modal: ModalView,
        operation: ?*const operations.Job,
        rejection: ?Rejection,

        pub fn modalVisible(self: Observation) bool {
            return self.modal != .none or self.operation != null;
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
            .terminal_visible = self.terminal_visible,
            .terminal_exists = self.terminal_exists,
            .quit = self.quit,
            .force_redraw = self.force_redraw,
            .modal = switch (self.modal) {
                .none => .none,
                .help => .help,
                .notice => |message| .{ .notice = message },
                .editor => |*editor| .{ .editor = .{ .input = &editor.input, .action = editor.action } },
                .confirm_delete => |confirmation| .{ .confirm_delete = confirmation.job },
            },
            .operation = self.operation,
            .rejection = switch (self.modal) {
                .editor => |editor| editor.rejection,
                .confirm_delete => |confirmation| confirmation.rejection,
                else => null,
            },
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

    pub const TerminalHost = struct {
        context: *anyopaque,
        start: *const fn (*anyopaque, ?[]const u8) anyerror!void,
    };

    pub fn attachTerminal(state: *State, host: TerminalHost) void {
        state.implementation().terminal_host = host;
    }

    pub fn terminalEnded(state: *State) void {
        const self = state.implementation();
        self.terminal_exists = false;
        self.terminal_visible = false;
        self.zoom = false;
        if (self.focus == .terminal) self.focus = self.last_pane;
        self.force_redraw = true;
    }

    pub fn toggleTerminal(state: *State) void {
        state.implementation().toggleTerminal();
    }

    /// Cheap observation only: no allocation, I/O, polling, or state changes.
    pub fn available(state: *const State, id: commands.Id) bool {
        const self: *const Implementation = @ptrCast(@alignCast(state));
        return self.available(id);
    }

    /// Rechecks current context. False explicitly rejects an unavailable action.
    /// The emulator is borrowed for this call only, never retained.
    pub fn invoke(state: *State, id: commands.Id, emulator: *Emulator) !bool {
        return state.implementation().invoke(id, emulator);
    }

    /// Root bindings only. Pane and terminal input stay in their widgets.
    pub fn globalEvent(state: *State, emulator: *Emulator, ev: *const input.Event) !void {
        try state.implementation().globalEvent(emulator, ev);
    }

    /// Called only by the modal widget, whose tree scope consumes every event.
    /// Expected Provider rejection stays beside the retained editor/confirmation;
    /// edits clear it, retry rechecks support, and dismissal releases the payload.
    /// Direct submit/confirmDelete calls preserve their synchronous errors.
    pub fn modalEvent(state: *State, emulator: *Emulator, ev: *const input.Event) !void {
        try state.implementation().modalEvent(emulator, ev);
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

const Implementation = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    focus: Focus = .left,
    last_pane: Focus = .left,
    adjustment: i32 = 0,
    zoom: bool = false,
    terminal_visible: bool = true,
    terminal_exists: bool = true,
    terminal_host: ?State.TerminalHost = null,
    quit: bool = false,
    force_redraw: bool = true,
    panes: [2]*Pane,
    modal: Modal = .none,
    operation: ?*operations.Job = null,

    fn activePane(self: *const Implementation) *Pane {
        return self.panes[if (self.last_pane == .right) @as(usize, 1) else 0];
    }

    fn fileActions(self: *const Implementation) operations.Context {
        return .{
            .source = self.activePane(),
            .other = self.panes[if (self.last_pane == .left) @as(usize, 1) else 0],
        };
    }

    fn actionAvailable(self: *const Implementation, kind: operations.Kind) bool {
        return self.fileActions().available(kind);
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
            self.startOperation(try self.fileActions().prepare(self.io, self.allocator, kind, value));
        } else try pane.request(value);
    }

    fn submit(self: *Implementation, value: []const u8) !void {
        if (self.modal != .editor) return error.NoEditor;
        if (value.len == 0) return;
        try self.submitEditor(value, self.modal.editor.action);
        self.modal.deinit();
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
        self.modal = .{ .confirm_delete = .{ .job = try self.fileActions().prepare(self.io, self.allocator, .delete, "") } };
        pane.cancelNavigation();
    }

    fn confirmDelete(self: *Implementation) !void {
        if (self.modal != .confirm_delete) return error.NoConfirmation;
        if (!self.actionAvailable(.delete)) return error.UnsupportedOperation;
        const job = self.modal.confirm_delete.job;
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

    fn modalEvent(self: *Implementation, emulator: *Emulator, ev: *const input.Event) !void {
        switch (self.modal) {
            .confirm_delete => {
                // Paste contents cannot confirm or dismiss a destructive action.
                if (ev.kind != .key) return;
                if (ev.key == .escape or (ev.key == .text and ev.len == 1 and ev.bytes[0] == 'n')) {
                    self.modal.deinit();
                } else if (ev.key == .enter) {
                    self.confirmDelete() catch |err| {
                        self.modal.confirm_delete.rejection = Rejection.fromError(err) orelse return err;
                    };
                }
                return;
            },
            .editor => |*editor| {
                switch (try editor.input.event(ev)) {
                    .editing => editor.rejection = null,
                    .cancel => self.modal.deinit(),
                    .accept => {
                        self.submit(editor.input.text()) catch |err| {
                            editor.rejection = Rejection.fromError(err) orelse return err;
                        };
                    },
                }
                return;
            },
            .help, .notice => {
                if (ev.kind == .key) self.modal.deinit();
                return;
            },
            .none => {},
        }
        if (ev.kind != .key) return;
        if (commands.resolve(ev)) |id| {
            // Availability admits only job quit and Ctrl+G in this scope.
            _ = try self.invoke(id, emulator);
            return;
        }
        if (self.operation) |job| {
            if (ev.key == .escape or (ev.key == .enter and job.status() == .finished)) self.dismiss();
        }
    }

    fn toggleTerminal(self: *Implementation) void {
        if (self.modal != .none or self.operation != null or !self.terminal_visible or !self.terminal_exists) return;
        if (self.focus == .terminal) {
            self.focus = self.last_pane;
            self.zoom = false;
        } else {
            self.last_pane = self.focus;
            self.focus = .terminal;
        }
    }

    fn showTerminal(self: *Implementation) void {
        if (self.modal != .none or self.operation != null) return;
        if (!self.terminal_exists) {
            const pane = self.activePane();
            const cwd = pane.provider().localPath(pane.location().locator) catch null;
            const host = self.terminal_host orelse {
                self.modal = .{ .notice = "Terminal launch unavailable" };
                return;
            };
            host.start(host.context, cwd) catch |err| {
                self.modal = .{ .notice = @errorName(err) };
                return;
            };
            self.terminal_exists = true;
        }
        self.terminal_visible = true;
        self.focus = .terminal;
    }

    fn available(self: *const Implementation, id: commands.Id) bool {
        if (self.modal != .none) return false;
        if (self.operation != null) return id == .quit;
        if (id == .toggle_terminal) return self.terminal_visible and self.terminal_exists;
        if (id == .visibility_terminal) return true;
        if (self.focus == .terminal) return false;
        return switch (id) {
            .copy => self.actionAvailable(.copy),
            .move => self.actionAvailable(.move),
            .mkdir => self.actionAvailable(.mkdir),
            .delete => self.actionAvailable(.delete),
            else => true,
        };
    }

    fn invoke(self: *Implementation, id: commands.Id, emulator: *Emulator) !bool {
        if (!self.available(id)) return false;
        switch (id) {
            .help => self.modal = .help,
            .copy => try self.openAction(.copy),
            .move => try self.openAction(.move),
            .mkdir => try self.openAction(.mkdir),
            .delete => try self.openDelete(),
            .quit => self.quit = true,
            .switch_pane => {
                self.focus = if (self.focus == .left) .right else .left;
                self.last_pane = self.focus;
            },
            .path => try self.openPath(false),
            .absolute_path => try self.openPath(true),
            .refresh => {
                self.force_redraw = true;
                try self.activePane().refresh();
            },
            .toggle_terminal => self.toggleTerminal(),
            .visibility_terminal => {
                if (self.terminal_visible) {
                    self.terminal_visible = false;
                    self.focus = self.last_pane;
                    self.zoom = false;
                } else self.showTerminal();
            },
            .focus_terminal => self.showTerminal(),
            .zoom_terminal => {
                self.showTerminal();
                if (self.focus == .terminal) self.zoom = true;
            },
            .grow_terminal => self.adjustment = @min(self.adjustment + 1, Layout.max_adjustment),
            .shrink_terminal => self.adjustment = @max(self.adjustment - 1, -Layout.max_adjustment),
            .history_up => emulator.scrollPage(.up),
            .history_down => emulator.scrollPage(.down),
        }
        return true;
    }

    fn globalEvent(self: *Implementation, emulator: *Emulator, ev: *const input.Event) !void {
        if (commands.resolve(ev)) |id| _ = try self.invoke(id, emulator);
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

const CapabilityFixture = @import("../core/testing_provider.zig").LocalCapabilities;

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
    const right = try Pane.create(io, std.testing.allocator, path, .{ .provider = fixture.provider(true) });
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
