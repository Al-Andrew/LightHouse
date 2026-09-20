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
const Editor = @import("editor.zig").Command;

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
    pub const ToolView = union(enum) {
        none,
        running: *Emulator,
        failed: *Emulator,
        pub fn emulator(self: ToolView) ?*Emulator {
            return switch (self) {
                .none => null,
                .running, .failed => |value| value,
            };
        }
    };
    pub const ToolHost = struct {
        context: *anyopaque,
        start: *const fn (*anyopaque, []const [:0]const u8, []const u8) anyerror!*Emulator,
    };

    pub const Observation = struct {
        focus: Focus,
        tool: ToolView,
        adjustment: i32,
        zoom: bool,
        terminal_visible: bool,
        terminal_exists: bool,
        quit: bool,
        force_redraw: bool,
        modal: ModalView,
        operation: ?*const operations.Job,
        decision_all: bool,
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
            .tool = self.tool,
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
            .decision_all = if (self.operation) |job| (job.status() == .waiting and job.status().waiting.prompt.id == self.decision_id and self.decision_all) else false,
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
    pub fn decideOperation(state: *State, choice: operations.Choice, remember: bool) bool {
        const self = state.implementation();
        const job = self.operation orelse return false;
        return job.decide(choice, remember);
    }

    pub fn dismiss(state: *State) void {
        state.implementation().dismiss();
    }

    pub fn attachTool(state: *State, host: ToolHost) void {
        state.implementation().tool_host = host;
    }

    pub fn toolEnded(state: *State, success: bool) void {
        const self = state.implementation();
        const emulator = self.tool.emulator() orelse return;
        self.tool = if (success) .none else .{ .failed = emulator };
        self.focus = self.last_pane;
        self.tool_refresh = true;
        self.force_redraw = true;
    }

    pub fn toolEvent(state: *State, ev: *const input.Event) !void {
        const self = state.implementation();
        switch (self.tool) {
            .none => {},
            .running => |emulator| try emulator.event(ev),
            .failed => if (ev.kind == .key) {
                self.tool = .none;
                self.force_redraw = true;
            },
        }
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
        if (self.tool_refresh) {
            self.tool_refresh = false;
            for (self.panes) |pane| pane.refresh() catch |err| {
                if (failure == null) failure = err;
            };
            changed = true;
        }
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
    tool: State.ToolView = .none,
    tool_host: ?State.ToolHost = null,
    tool_refresh: bool = false,
    operation: ?*operations.Job = null,
    decision_id: usize = 0,
    decision_all: bool = false,

    fn foregroundBusy(self: *const Implementation) bool {
        return self.modal != .none or self.operation != null or self.tool != .none;
    }

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
        if (self.foregroundBusy()) return error.WorkflowBusy;
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
        if (self.foregroundBusy()) return error.WorkflowBusy;
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
        self.decision_id = 0;
        self.decision_all = false;
    }

    fn openDelete(self: *Implementation) !void {
        if (self.foregroundBusy()) return error.WorkflowBusy;
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
                self.decision_id = 0;
                self.decision_all = false;
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
        if (self.operation) |job| if (job.status() == .waiting) {
            const prompt = job.status().waiting.prompt;
            if (self.decision_id != prompt.id) {
                self.decision_id = prompt.id;
                self.decision_all = false;
            }
            if (ev.key == .escape) {
                job.cancel();
                return;
            }
            if (ev.key == .text and ev.len == 1) {
                const choice: ?operations.Choice = switch (ev.bytes[0]) {
                    'o' => .overwrite,
                    'r' => .retry,
                    's' => .skip,
                    'c' => .cancel,
                    ' ' => blk: {
                        self.decision_all = !self.decision_all;
                        break :blk null;
                    },
                    else => null,
                };
                if (choice) |value| {
                    _ = job.decide(value, self.decision_all);
                    return;
                }
                if (ev.bytes[0] == ' ') return;
            }
        };
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
        if (self.foregroundBusy() or !self.terminal_visible or !self.terminal_exists) return;
        if (self.focus == .terminal) {
            self.focus = self.last_pane;
            self.zoom = false;
        } else {
            self.last_pane = self.focus;
            self.focus = .terminal;
        }
    }

    fn ensureTerminal(self: *Implementation) !void {
        if (self.terminal_exists) return;
        const pane = self.activePane();
        const cwd = pane.provider().localPath(pane.location().locator) catch null;
        const host = self.terminal_host orelse return error.TerminalLaunchUnavailable;
        try host.start(host.context, cwd);
        self.terminal_exists = true;
    }

    fn showTerminal(self: *Implementation) void {
        if (self.foregroundBusy()) return;
        self.ensureTerminal() catch |err| {
            self.modal = .{ .notice = @errorName(err) };
            return;
        };
        self.terminal_visible = true;
        self.focus = .terminal;
    }

    fn insertReference(self: *Implementation, emulator: *Emulator) !void {
        const pane = self.activePane();
        const raw = try pane.cursorReference(self.allocator);
        defer self.allocator.free(raw);
        if (raw.len == 0) return error.EmptyReference;
        for (raw) |byte| if (byte < 32 or byte == 127) return error.ControlCharacterReference;
        var quoted: std.ArrayList(u8) = .empty;
        defer quoted.deinit(self.allocator);
        try quoted.append(self.allocator, '\'');
        for (raw) |byte| {
            if (byte == '\'') try quoted.appendSlice(self.allocator, "'\\''") else try quoted.append(self.allocator, byte);
        }
        try quoted.appendSlice(self.allocator, "' ");
        // Resolve, validate and quote before creating a missing session.
        try self.ensureTerminal();
        try emulator.insert(quoted.items);
        self.terminal_visible = true;
        self.focus = .terminal;
    }

    fn editFile(self: *Implementation) !void {
        const pane = self.activePane();
        const entry = pane.view().focused() orelse return error.IneligibleEditorEntry;
        const cwd = pane.provider().localPath(pane.location().locator) catch return error.IneligibleEditorEntry;
        const working_directory = std.Io.Dir.openDirAbsolute(self.io, cwd, .{}) catch return error.WorkingDirectoryUnavailable;
        working_directory.close(self.io);
        const file = try std.fs.path.join(self.allocator, &.{ cwd, entry.name });
        defer self.allocator.free(file);
        const stat = std.Io.Dir.cwd().statFile(self.io, file, .{}) catch return error.IneligibleEditorEntry;
        if (stat.kind != .file) return error.IneligibleEditorEntry;
        var command = try Editor.load(self.io, self.allocator, cwd, file);
        defer command.deinit();
        const host = self.tool_host orelse return error.ToolLaunchUnavailable;
        const emulator = try host.start(host.context, command.argv, cwd);
        self.tool = .{ .running = emulator };
    }

    fn available(self: *const Implementation, id: commands.Id) bool {
        if (self.modal != .none or self.tool != .none) return false;
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
            .edit_file => self.editFile() catch |err| {
                self.modal = .{ .notice = switch (err) {
                    error.IneligibleEditorEntry => "Choose a local regular file with the Cursor.",
                    error.EditorNotConfigured => "Configure editor argv in lighthouse/config.json or set EDITOR.",
                    error.InvalidEditorConfiguration => "Invalid editor configuration in lighthouse/config.json.",
                    error.InvalidEditorArguments => "Invalid quoted arguments in EDITOR.",
                    error.EditorNotExecutable => "Configured editor executable is missing or inaccessible.",
                    else => @errorName(err),
                } };
            },
            .insert_reference => self.insertReference(emulator) catch |err| {
                self.modal = .{ .notice = @errorName(err) };
            },
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
    state.terminalEnded();
    try std.testing.expect(!state.view().quit);
    try std.testing.expect(state.view().operation.?.status() == .running);
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

test "Path insertion uses Provider Cursor reference independently of Marks" {
    var fixture: @import("../core/testing_provider.zig").Opaque = .{};
    const left = try Pane.create(std.testing.io, std.testing.allocator, @import("../core/testing_provider.zig").Opaque.root, .{ .provider = fixture.provider() });
    defer left.destroy();
    const right = try Pane.create(std.testing.io, std.testing.allocator, "/", .{});
    defer right.destroy();
    const state = try State.create(std.testing.io, std.testing.allocator, .{ left, right });
    defer state.destroy();
    const emulator = try Emulator.create(std.testing.io, std.testing.allocator, 80, 8);
    defer emulator.destroy();
    try left.refresh();
    try settle(state);
    left.move(.{ .by = 1 }, false);
    left.move(.{ .by = 1 }, true); // Mark folder, advance Cursor to a.
    try std.testing.expect(try state.invoke(.insert_reference, emulator));
    try std.testing.expectEqualStrings("'vault:a' ", emulator.queued());
    try std.testing.expectEqual(.terminal, state.view().focus);
    try std.testing.expect(!state.actionAvailable(.copy));
}

test "Path insertion validates quotes and admits a complete reference before taking focus" {
    const Fixture = @import("../core/testing_provider.zig").Opaque;
    var fixture: Fixture = .{};
    const left = try Pane.create(std.testing.io, std.testing.allocator, Fixture.root, .{ .provider = fixture.provider() });
    defer left.destroy();
    const right = try Pane.create(std.testing.io, std.testing.allocator, "/", .{});
    defer right.destroy();
    const state = try State.create(std.testing.io, std.testing.allocator, .{ left, right });
    defer state.destroy();
    const emulator = try Emulator.create(std.testing.io, std.testing.allocator, 80, 8);
    defer emulator.destroy();
    try left.refresh();
    try settle(state);
    left.move(.{ .by = 1 }, false);
    const Host = struct {
        calls: usize = 0,
        fail: bool = false,
        fn start(context: *anyopaque, cwd: ?[]const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expect(cwd == null);
            self.calls += 1;
            if (self.fail) return error.SpawnFailed;
        }
    };
    var host: Host = .{};
    state.attachTerminal(.{ .context = &host, .start = Host.start });
    for ([_][]const u8{ "bad\nname", "bad\x00name", "bad\x7fname", "" }) |raw| {
        state.terminalEnded();
        fixture.entry_reference = raw;
        try std.testing.expect(try state.invoke(.insert_reference, emulator));
        try std.testing.expectEqual(@as(usize, 0), host.calls);
        try std.testing.expectEqual(@as(usize, 0), emulator.queued().len);
        try std.testing.expectEqual(.left, state.view().focus);
        try std.testing.expect(state.view().modal == .notice);
        state.dismiss();
    }
    fixture.insertion_supported = false;
    _ = try state.invoke(.insert_reference, emulator);
    try std.testing.expectEqual(@as(usize, 0), host.calls);
    state.dismiss();
    fixture.insertion_supported = true;
    fixture.entry_reference = "a b'$(touch BAD);\xff";
    host.fail = true;
    _ = try state.invoke(.insert_reference, emulator);
    try std.testing.expectEqual(.left, state.view().focus);
    try std.testing.expectEqual(@as(usize, 0), emulator.queued().len);
    state.dismiss();
    host.fail = false;
    try emulator.insert("prefix ");
    _ = try state.invoke(.insert_reference, emulator);
    try std.testing.expectEqualStrings("prefix 'a b'\\''$(touch BAD);\xff' ", emulator.queued());
    try std.testing.expectEqual(@as(usize, 2), host.calls);
    state.toggleTerminal();
    _ = try state.invoke(.visibility_terminal, emulator); // hide existing session
    emulator.consumed(emulator.queued().len);
    _ = try state.invoke(.insert_reference, emulator);
    try std.testing.expect(state.view().terminal_visible);
    try std.testing.expectEqual(@as(usize, 2), host.calls);
    state.toggleTerminal();
    try state.openPath(false);
    try std.testing.expect(!try state.invoke(.insert_reference, emulator));
    state.dismiss();
    try state.openAction(.mkdir); // unavailable Provider leaves no workflow
    try std.testing.expect(try state.invoke(.help, emulator));
    try std.testing.expect(!try state.invoke(.insert_reference, emulator));
}

test "F4 direct invocation rejects Current row without launching an external tool" {
    const left = try Pane.create(std.testing.io, std.testing.allocator, "/tmp", .{});
    defer left.destroy();
    const right = try Pane.create(std.testing.io, std.testing.allocator, "/tmp", .{});
    defer right.destroy();
    const state = try State.create(std.testing.io, std.testing.allocator, .{ left, right });
    defer state.destroy();
    const emulator = try Emulator.create(std.testing.io, std.testing.allocator, 80, 8);
    defer emulator.destroy();
    _ = try state.invoke(.edit_file, emulator);
    try std.testing.expectEqualStrings("Choose a local regular file with the Cursor.", state.view().modal.notice);
    try std.testing.expectEqual(.left, state.view().focus);
    try std.testing.expect(state.view().tool == .none);
    try std.testing.expect(commands.functionCommand(.f3) == null);
}

test "Path insertion workflow preserves queue and Pane focus on allocation and backpressure errors" {
    const Fixture = @import("../core/testing_provider.zig").Opaque;
    var fixture: Fixture = .{};
    const left = try Pane.create(std.testing.io, std.testing.allocator, Fixture.root, .{ .provider = fixture.provider() });
    defer left.destroy();
    const right = try Pane.create(std.testing.io, std.testing.allocator, "/", .{});
    defer right.destroy();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const state = try State.create(std.testing.io, failing.allocator(), .{ left, right });
    defer state.destroy();
    const emulator = try Emulator.create(std.testing.io, std.testing.allocator, 80, 8);
    defer emulator.destroy();
    try left.refresh();
    try settle(state);
    left.move(.{ .by = 1 }, false);
    try emulator.insert("existing");
    failing.fail_index = failing.alloc_index;
    _ = try state.invoke(.insert_reference, emulator);
    try std.testing.expectEqualStrings("OutOfMemory", state.view().modal.notice);
    try std.testing.expectEqualStrings("existing", emulator.queued());
    try std.testing.expectEqual(.left, state.view().focus);
    state.dismiss();
    failing.fail_index = std.math.maxInt(usize);
    const raw = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(raw);
    @memset(raw, 'x');
    fixture.entry_reference = raw;
    _ = try state.invoke(.insert_reference, emulator);
    try std.testing.expectEqualStrings("TerminalInputBackpressure", state.view().modal.notice);
    try std.testing.expectEqualStrings("existing", emulator.queued());
    try std.testing.expectEqual(.left, state.view().focus);
}

test "waiting file decisions block every terminal route through retained result dismissal" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try tmp.dir.createDir(io, "dest", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "source" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dest/source", .data = "keep" });
    var panes: TestPanes = .{};
    try panes.init(path);
    defer panes.deinit();
    const state = try State.create(io, std.testing.allocator, panes.panes);
    defer state.destroy();
    const emulator = try Emulator.create(io, std.testing.allocator, 80, 8);
    defer emulator.destroy();
    for (panes.panes) |pane| try pane.refresh();
    try settle(state);
    state.activePane().move(.last, false);
    try state.openAction(.copy);
    try state.submit("dest");
    for (0..5000) |_| {
        _ = try state.poll();
        if (state.view().operation.?.status() == .waiting) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(state.view().operation.?.status() == .waiting);
    try std.testing.expect(!state.view().decision_all);
    state.terminalEnded();
    const routes = [_]commands.Id{ .toggle_terminal, .visibility_terminal, .focus_terminal, .zoom_terminal, .insert_reference, .edit_file, .history_up, .grow_terminal };
    for (routes) |id| try std.testing.expect(!try state.invoke(id, emulator));
    state.toggleTerminal();
    try std.testing.expectEqual(.left, state.view().focus);
    const prompt = state.view().operation.?.status().waiting.prompt;
    for (0..3) |_| {
        _ = state.view();
        _ = try state.poll();
        try std.testing.expectEqual(prompt.id, state.view().operation.?.status().waiting.prompt.id);
    }
    try panes.expectScans(1);
    var decoder: input.Decoder = .{};
    const space = decoder.feed(' ').?;
    try state.modalEvent(emulator, &space);
    try std.testing.expect(state.view().decision_all);
    try std.testing.expect(state.decideOperation(.skip, true));
    try settle(state);
    try panes.expectScans(2);
    try std.testing.expectEqual(@as(usize, 1), state.view().operation.?.status().progress().skipped);
    for (routes) |id| try std.testing.expect(!try state.invoke(id, emulator));
    state.dismiss();
    try std.testing.expect(state.available(.visibility_terminal));
    try state.openAction(.copy);
    try state.submit("dest");
    for (0..5000) |_| {
        _ = try state.poll();
        if (state.view().operation.?.status() == .waiting) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(state.view().operation.?.status() == .waiting);
    try std.testing.expect(!state.view().decision_all);
    try std.testing.expect(state.decideOperation(.skip, false));
    try settle(state);
}

test "Path insertion quotes current and parent rows on both Panes" {
    const allocator = std.testing.allocator;
    const left = try Pane.create(std.testing.io, allocator, "/home/user/a 'link", .{});
    defer left.destroy();
    const right = try Pane.create(std.testing.io, allocator, "/", .{});
    defer right.destroy();
    const state = try State.create(std.testing.io, allocator, .{ left, right });
    defer state.destroy();
    const emulator = try Emulator.create(std.testing.io, allocator, 80, 8);
    defer emulator.destroy();
    try emulator.insert("cd ");
    try std.testing.expect(try state.invoke(.insert_reference, emulator));
    try std.testing.expectEqualStrings("cd '/home/user/a '\\''link' ", emulator.queued());
    state.toggleTerminal();
    left.move(.{ .by = 1 }, false);
    emulator.consumed(emulator.queued().len);
    try std.testing.expect(try state.invoke(.insert_reference, emulator));
    try std.testing.expectEqualStrings("'/home/user' ", emulator.queued());
    state.toggleTerminal();
    try std.testing.expect(try state.invoke(.switch_pane, emulator));
    for (0..2) |_| {
        emulator.consumed(emulator.queued().len);
        try std.testing.expect(try state.invoke(.insert_reference, emulator));
        try std.testing.expectEqualStrings("'/' ", emulator.queued());
        state.toggleTerminal();
        right.move(.{ .by = 1 }, false);
    }
}
