//! Compose app widgets using the independent retained UI library.
const std = @import("std");
const ui = @import("lighthouse-ui");
const State = @import("controller.zig").State;
const Layout = @import("layout.zig").Layout;
const Emulator = @import("../terminal/emulator.zig").Emulator;
const FilePane = @import("widgets/file_pane.zig").FilePane;
const Terminal = @import("widgets/terminal.zig").Terminal;
const KeyBar = @import("widgets/key_bar.zig").KeyBar;
const Modal = @import("widgets/modal.zig").Modal;

pub const View = struct {
    allocator: std.mem.Allocator,
    tree: *ui.Tree,
    pane_area: *ui.Widget,
    key_bar: *ui.Widget,
    state: *State,
    emulator: *Emulator,
    panes: [2]*ui.Widget,
    terminal: *ui.Widget,
    modal: *ui.Widget,

    pub fn create(allocator: std.mem.Allocator, state: *State, emulator: *Emulator) !*View {
        const self = try allocator.create(View);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .tree = try ui.Tree.init(allocator), .pane_area = undefined, .key_bar = undefined, .state = state, .emulator = emulator, .panes = undefined, .terminal = undefined, .modal = undefined };
        errdefer self.tree.deinit();
        const root = try self.tree.create(null, Root, .{ .view = self });
        self.pane_area = try self.tree.create(root, ui.layout.Box, .{ .axis = .horizontal });
        for (state.panes(), 0..) |pane, i| {
            self.panes[i] = try self.tree.create(self.pane_area, FilePane, .{ .pane = pane });
            self.panes[i].setFocusable(true);
        }
        self.terminal = try self.tree.create(root, Terminal, .{ .emulator = emulator });
        self.terminal.setFocusable(true);
        self.key_bar = try self.tree.create(root, KeyBar, .{ .state = state });
        self.modal = try self.tree.create(root, Modal, .{ .state = state, .emulator = emulator });
        self.modal.setFocusable(true);
        try self.sync();
        return self;
    }

    pub fn destroy(self: *View) void {
        const allocator = self.allocator;
        self.tree.deinit();
        allocator.destroy(self);
    }

    fn sync(self: *View) !void {
        const modal = self.state.view().modalVisible();
        self.modal.setVisible(modal);
        try self.tree.setModal(if (modal) self.modal else null);
        try self.tree.setFocus(if (modal) self.modal else switch (self.state.view().focus) {
            .left => self.panes[0],
            .right => self.panes[1],
            .terminal => self.terminal,
        });
    }

    pub fn event(self: *View, ev: *const ui.Event) !void {
        try self.sync();
        _ = try self.tree.dispatch(ev);
        try self.sync();
    }

    pub fn resize(self: *View, size: ui.Size) !void {
        try self.tree.layout(Layout.boundedSize(size));
    }

    pub fn paint(self: *View, frame: *ui.Frame, available: ui.Size) !void {
        const size = Layout.boundedSize(available);
        try self.sync();
        try self.resize(size);
        try frame.begin(size.width, size.height);
        try self.tree.paint(frame);
    }
};

const Root = struct {
    // View retains each role until tree destruction; its stable address outlives us.
    view: *View,

    pub fn layout(self: *Root, _: *ui.Widget, size: ui.Size) void {
        const geometry = Layout.calculate(size, self.view.state.view().adjustment, self.view.state.view().zoom);
        self.view.pane_area.setVisible(!geometry.compact);
        self.view.pane_area.setRect(.{ .x = 0, .y = 0, .width = size.width, .height = geometry.panes_height });
        self.view.terminal.setRect(geometry.terminal);
        self.view.key_bar.setVisible(size.height > 1);
        self.view.key_bar.setRect(.{ .x = 0, .y = size.height -| 1, .width = size.width, .height = 1 });
        self.view.modal.setRect(ui.layout.centered(size, self.view.modal.measure(size)));
    }

    pub fn event(self: *Root, _: *ui.Widget, ev: *const ui.Event) !bool {
        try self.view.state.globalEvent(self.view.emulator, ev);
        return true;
    }
};

test "retained app view traps editor paste and restores the active pane after dismissal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Pane = @import("../core/pane.zig").Pane;
    const left = try Pane.create(io, allocator, "/", .{});
    defer left.destroy();
    const right = try Pane.create(io, allocator, "/", .{});
    defer right.destroy();
    const emulator = try Emulator.create(io, allocator, 80, 8);
    defer emulator.destroy();
    const state = try State.create(io, allocator, .{ left, right });
    defer state.destroy();
    const view = try View.create(allocator, state, emulator);
    defer view.destroy();
    // Put an unrelated child before a replacement role: layout must follow the
    // retained modal handle, not the old child index.
    const extra = try view.tree.create(view.tree.root(), struct {}, .{});
    const extra_rect: ui.Rect = .{ .x = 3, .y = 2, .width = 1, .height = 1 };
    extra.setRect(extra_rect);
    view.modal.destroy();
    view.modal = try view.tree.create(view.tree.root(), Modal, .{ .state = state, .emulator = emulator });
    view.modal.setFocusable(true);
    try view.resize(.{ .width = 80, .height = 24 });
    try std.testing.expectEqual(extra_rect, extra.rect());
    try std.testing.expectEqual(@as(usize, 80), view.pane_area.rect().width);
    try std.testing.expectEqual(@as(usize, 23), view.key_bar.rect().y);
    try view.event(&.{ .key = .tab });
    try std.testing.expect(view.panes[1].focused());
    var decoder: ui.input.Decoder = .{};
    for ("\x0c\x1b[200~q\x07\n\x1b[201~") |byte| if (decoder.feed(byte)) |ev| try view.event(&ev);
    try std.testing.expect(state.view().modal == .editor);
    try std.testing.expectEqualStrings("q", state.view().modal.editor.input.text());
    try std.testing.expect(view.modal.focused());
    try std.testing.expectEqual(@as(usize, 0), emulator.queued().len);
    var frame = ui.Frame.init(allocator);
    defer frame.deinit();
    for ([_]ui.Size{ .{ .width = 80, .height = 24 }, .{ .width = 7, .height = 4 }, .{ .width = 1, .height = 1 } }) |size| {
        try view.paint(&frame, size);
        if (frame.cursor) |cursor| try std.testing.expect(cursor.x < size.width and cursor.y < size.height);
    }
    try view.event(&.{ .key = .escape });
    try std.testing.expect(state.view().modal == .none);
    try std.testing.expect(view.panes[1].focused());
    try std.testing.expect(!view.pane_area.visible());
    for ("\x07q\x07") |byte| if (decoder.feed(byte)) |ev| try view.event(&ev);
    try std.testing.expect(view.panes[1].focused());
    try std.testing.expectEqualStrings("q", emulator.queued());
    try std.testing.expect(!state.view().quit);
}

test "View routes compact pane input terminal controls and workflow modals once" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Pane = @import("../core/pane.zig").Pane;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const left = try Pane.create(io, allocator, buffer[0..len], .{});
    defer left.destroy();
    const right = try Pane.create(io, allocator, buffer[0..len], .{});
    defer right.destroy();
    const emulator = try Emulator.create(io, allocator, 20, 4);
    defer emulator.destroy();
    // Only job launch fails; real panes still load and refresh normally.
    const state = try State.create(std.Io.failing, allocator, .{ left, right });
    defer state.destroy();
    const view = try View.create(allocator, state, emulator);
    defer view.destroy();
    for (state.panes()) |pane| try pane.refresh();
    for (0..5000) |_| {
        _ = try state.poll();
        if (left.view().status != .loading and right.view().status != .loading) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(left.view().status == .ready);
    try view.resize(.{ .width = 7, .height = 4 });
    try view.event(&.{ .key = .down });
    try std.testing.expectEqualStrings("file", left.view().focused().?.name);
    var decoder: ui.input.Decoder = .{};
    try feed(view, &decoder, " ");
    try std.testing.expectEqual(@as(usize, 1), left.view().marked_count);
    try feed(view, &decoder, "\x07q\x03\x07");
    try std.testing.expectEqualStrings("q\x03", emulator.queued());
    try std.testing.expect(!state.view().quit);
    try std.testing.expect(view.panes[0].focused());
    // Empty editor acceptance stays open; Escape releases its action payload.
    try view.event(&.{ .key = .f5 });
    try feed(view, &decoder, "\x15\r");
    try std.testing.expect(state.view().modal == .editor);
    try view.event(&.{ .key = .escape });
    try view.event(&.{ .key = .f1 });
    try feed(view, &decoder, "\x1b[200~q\x07\x1b[201~");
    try std.testing.expect(state.view().modal == .help);
    try view.event(&.{ .key = .escape });
    // A pasted confirmation cannot delete, dismiss, or switch focus.
    try view.event(&.{ .key = .f8 });
    try feed(view, &decoder, "\x1b[200~\r\nn\x07\x1b[201~");
    try std.testing.expect(state.view().modal == .confirm_delete);
    try std.testing.expect(state.view().operation == null);
    var frame = ui.Frame.init(allocator);
    defer frame.deinit();
    for ([_]ui.Size{ .{ .width = 80, .height = 24 }, .{ .width = 7, .height = 4 }, .{ .width = 1, .height = 1 } }) |size| {
        try view.paint(&frame, size);
        try std.testing.expect(frame.cursor == null);
    }
    try view.event(&.{ .key = .escape });
    try std.testing.expect(state.view().modal == .none);
    try view.event(&.{ .key = .f8 });
    try view.event(&.{ .key = .enter });
    try view.event(&.{ .key = .enter });
    try std.testing.expect(state.view().operation.?.status() == .running);
    try view.paint(&frame, .{ .width = 80, .height = 24 });
    try std.testing.expect(state.view().operation.?.status() == .running);
    _ = try state.poll();
    try std.testing.expectEqual(error.ConcurrencyUnavailable, state.view().operation.?.status().finished.failure.?.err);
    // Enter in the persistent terminal cannot dismiss the retained result.
    try feed(view, &decoder, "\x07\r\x07");
    try std.testing.expectEqualStrings("q\x03\r", emulator.queued());
    try std.testing.expect(view.modal.focused());
    try std.testing.expect(state.view().operation != null);
    try view.event(&.{ .key = .enter });
    try std.testing.expect(state.view().operation == null);
    try std.testing.expect(view.panes[0].focused());
    try std.testing.expect(!state.view().quit);
    _ = try tmp.dir.statFile(io, "file", .{});
}

fn feed(view: *View, decoder: *ui.input.Decoder, bytes: []const u8) !void {
    for (bytes) |byte| if (decoder.feed(byte)) |ev| try view.event(&ev);
}

test "view routes Ctrl+G keys to focus policy and preserves Ctrl+G inside terminal paste" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Pane = @import("../core/pane.zig").Pane;
    const left = try Pane.create(io, allocator, "/", .{});
    defer left.destroy();
    const right = try Pane.create(io, allocator, "/", .{});
    defer right.destroy();
    const emulator = try Emulator.create(io, allocator, 80, 8);
    defer emulator.destroy();
    const state = try State.create(io, allocator, .{ left, right });
    defer state.destroy();
    const view = try View.create(allocator, state, emulator);
    defer view.destroy();
    try view.resize(.{ .width = 80, .height = 24 });
    var decoder: ui.input.Decoder = .{};
    for ("\x07\x1b[200~q\x07") |byte| if (decoder.feed(byte)) |ev| try view.event(&ev);
    try std.testing.expect(view.terminal.focused());
    try emulator.feed("\x1b[?2004h");
    for ("\n\x1b[201~\x03") |byte| if (decoder.feed(byte)) |ev| try view.event(&ev);
    try std.testing.expectEqualStrings("q\x07\n\x03", emulator.queued());
    try std.testing.expect(view.terminal.focused());
    for ("\x07\x1b[200~q\x07\x1b[201~") |byte| if (decoder.feed(byte)) |ev| try view.event(&ev);
    try std.testing.expect(view.panes[0].focused());
    try std.testing.expect(!state.view().quit);
    try std.testing.expectEqualStrings("q\x07\n\x03", emulator.queued());
}

test "command presentation and direct invocation recheck sources modal focus and job context" {
    const theme = @import("theme.zig");
    const Pane = @import("../core/pane.zig").Pane;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const left = try Pane.create(io, allocator, buffer[0..len], .{});
    defer left.destroy();
    const right = try Pane.create(io, allocator, buffer[0..len], .{});
    defer right.destroy();
    const emulator = try Emulator.create(io, allocator, 80, 8);
    defer emulator.destroy();
    const state = try State.create(std.Io.failing, allocator, .{ left, right });
    defer state.destroy();
    const view = try View.create(allocator, state, emulator);
    defer view.destroy();
    var frame = ui.Frame.init(allocator);
    defer frame.deinit();
    try view.paint(&frame, .{ .width = 80, .height = 24 });
    try std.testing.expect(!state.available(.copy));
    try std.testing.expect(!state.available(.move));
    try std.testing.expect(!state.available(.delete));
    try std.testing.expect(state.available(.mkdir));
    try std.testing.expectEqualDeep(theme.disabled_action, frame.cells[23 * 80 + 33].style);
    try std.testing.expectEqualDeep(theme.action, frame.cells[23 * 80 + 49].style);
    try view.event(&.{ .key = .f5 });
    try std.testing.expect(!try state.invoke(.copy, emulator));
    try std.testing.expect(state.view().modal == .none);
    try std.testing.expect(state.view().operation == null);
    try left.refresh();
    for (0..5000) |_| {
        _ = try state.poll();
        if (left.view().status != .loading) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try view.event(&.{ .key = .down });
    try std.testing.expect(state.available(.copy));
    try view.paint(&frame, .{ .width = 80, .height = 24 });
    try std.testing.expectEqualDeep(theme.action, frame.cells[23 * 80 + 33].style);
    // A previously enabled action cannot bypass current pane/source observations.
    try view.event(&.{ .key = .tab });
    try std.testing.expect(!try state.invoke(.copy, emulator));
    try view.event(&.{ .key = .tab });
    try std.testing.expect(try state.invoke(.help, emulator));
    try std.testing.expect(!try state.invoke(.copy, emulator));
    try std.testing.expect(!try state.invoke(.quit, emulator));
    try std.testing.expect(!try state.invoke(.toggle_terminal, emulator));
    try view.paint(&frame, .{ .width = 80, .height = 24 });
    // Help still fits a normal terminal and displays aliases from the binding data.
    try expectFrameText(&frame, "q/F10 Quit");
    try expectFrameText(&frame, "Ctrl+G Shell/pane");
    try expectFrameText(&frame, "Shift+PgDn History down");
    try expectFrameText(&frame, "Any key closes help");
    try view.event(&.{ .key = .f5 }); // Help dismissal must not also open Copy.
    try std.testing.expect(state.view().modal == .none);
    var decoder: ui.input.Decoder = .{};
    try feed(view, &decoder, "t");
    try std.testing.expect(!try state.invoke(.copy, emulator));
    try std.testing.expect(!try state.invoke(.quit, emulator));
    try feed(view, &decoder, "\x1b[15~q\x1b[21~t/\x0c\x07");
    try std.testing.expectEqualStrings("\x1b[15~q\x1b[21~t/\x0c", emulator.queued());
    try std.testing.expect(!state.view().quit);
    try std.testing.expect(view.panes[0].focused());
    try std.testing.expect(try state.invoke(.mkdir, emulator));
    try std.testing.expect(!try state.invoke(.copy, emulator));
    try state.submit("created");
    // Launch failure stays uncollected across availability, invocation and paint.
    for (0..3) |_| {
        try std.testing.expect(state.available(.quit));
        try std.testing.expect(state.available(.toggle_terminal));
        try std.testing.expect(!state.available(.mkdir));
        try std.testing.expect(!try state.invoke(.copy, emulator));
        try view.paint(&frame, .{ .width = 80, .height = 24 });
        try std.testing.expectEqualDeep(theme.action, frame.cells[23 * 80 + 74].style);
        try std.testing.expectEqualDeep(theme.disabled_action, frame.cells[23 * 80 + 49].style);
        try std.testing.expect(state.view().operation.?.status() == .running);
    }
    try view.event(&.{ .key = .f5 });
    try std.testing.expect(state.view().modal == .none);
    try feed(view, &decoder, "\x07");
    try std.testing.expect(view.terminal.focused());
    try std.testing.expect(!try state.invoke(.quit, emulator));
    try feed(view, &decoder, "\x07");
    try std.testing.expect(view.modal.focused());
    try view.event(&.{ .key = .f10 });
    try std.testing.expect(state.view().quit);
}

fn expectFrameText(frame: *const ui.Frame, expected: []const u8) !void {
    for (0..frame.rows) |y| {
        var row: std.ArrayList(u8) = .empty;
        defer row.deinit(std.testing.allocator);
        for (frame.cells[y * frame.cols ..][0..frame.cols]) |cell| try row.appendSlice(std.testing.allocator, cell.text);
        if (std.mem.indexOf(u8, row.items, expected) != null) return;
    }
    return error.MissingFrameText;
}

test "View retains path aliases terminal geometry and job quit text binding" {
    const Pane = @import("../core/pane.zig").Pane;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const left = try Pane.create(io, allocator, "/tmp", .{});
    defer left.destroy();
    const right = try Pane.create(io, allocator, "/", .{});
    defer right.destroy();
    const emulator = try Emulator.create(io, allocator, 80, 8);
    defer emulator.destroy();
    const state = try State.create(std.Io.failing, allocator, .{ left, right });
    defer state.destroy();
    const view = try View.create(allocator, state, emulator);
    defer view.destroy();
    var decoder: ui.input.Decoder = .{};
    try feed(view, &decoder, "\x0c");
    try std.testing.expectEqualStrings("/tmp", state.view().modal.editor.input.text());
    try view.event(&.{ .key = .escape });
    try feed(view, &decoder, "/");
    try std.testing.expectEqualStrings("/", state.view().modal.editor.input.text());
    try std.testing.expect(!state.view().modal.editor.input.select_all);
    try view.event(&.{ .key = .escape });
    try feed(view, &decoder, "++-");
    try std.testing.expectEqual(@as(i32, 1), state.view().adjustment);
    try feed(view, &decoder, "z");
    try std.testing.expect(state.view().zoom);
    try std.testing.expect(view.terminal.focused());
    try std.testing.expect(!try state.invoke(.grow_terminal, emulator));
    try feed(view, &decoder, "\x07");
    try std.testing.expect(!state.view().zoom);
    try std.testing.expect(view.panes[0].focused());
    // Extra key modifiers retain their existing matching behavior.
    try view.event(&.{ .key = .f7, .shift = true, .alt = true, .ctrl = true });
    try std.testing.expect(state.view().modal.editor.action == .mkdir);
    try state.submit("unused");
    try feed(view, &decoder, "t"); // Only Ctrl+G may switch focus in the job scope.
    try std.testing.expect(view.modal.focused());
    try feed(view, &decoder, "q");
    try std.testing.expect(state.view().quit);
}

test "View and direct commands share current provider support without starting work" {
    const directory = @import("../core/directory.zig");
    const Pane = @import("../core/pane.zig").Pane;
    const theme = @import("theme.zig");
    const Fixture = struct {
        writable: bool = true,
        scans: std.atomic.Value(usize) = .init(0),
        fn capabilities(context: ?*anyopaque, _: []const u8) directory.Capabilities {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return .{ .source_read = true, .destination_write = self.writable };
        }
        fn scan(context: ?*anyopaque, io: std.Io, path: []const u8, options: directory.Options, canceled: *const std.atomic.Value(bool)) !directory.Snapshot {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.scans.fetchAdd(1, .monotonic);
            return directory.local.scan(null, io, path, options, canceled);
        }
    };
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const foreign_identity: u8 = 0;
    for ([_]bool{ false, true }) |foreign| {
        var fixture: Fixture = .{};
        var provider = directory.local;
        provider.context = &fixture;
        provider.capabilities = Fixture.capabilities;
        provider.scan = Fixture.scan;
        if (foreign) provider.identity = &foreign_identity;
        const left = try Pane.create(io, allocator, buffer[0..len], .{});
        defer left.destroy();
        const right = try Pane.create(io, allocator, buffer[0..len], .{ .provider = provider });
        defer right.destroy();
        const emulator = try Emulator.create(io, allocator, 80, 8);
        defer emulator.destroy();
        const state = try State.create(io, allocator, .{ left, right });
        defer state.destroy();
        const view = try View.create(allocator, state, emulator);
        defer view.destroy();
        for (state.panes()) |pane| try pane.refresh();
        for (0..5000) |_| {
            _ = try state.poll();
            if (left.view().status != .loading and right.view().status != .loading) break;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        try view.event(&.{ .key = .down });
        try std.testing.expectEqual(!foreign, state.available(.copy));
        try std.testing.expectEqual(!foreign, state.available(.move));
        try std.testing.expect(state.available(.delete));
        // Capabilities can change after an observation, without a scan or focus change.
        fixture.writable = false;
        var frame = ui.Frame.init(allocator);
        defer frame.deinit();
        for (0..3) |_| {
            try view.paint(&frame, .{ .width = 80, .height = 24 });
            try std.testing.expect(!state.available(.copy));
            try std.testing.expect(!state.available(.move));
            try std.testing.expect(!try state.invoke(.copy, emulator));
            try std.testing.expect(!try state.invoke(.move, emulator));
            try std.testing.expectEqualDeep(theme.disabled_action, frame.cells[23 * 80 + 33].style);
        }
        try view.event(&.{ .key = .f5 });
        try view.event(&.{ .key = .f6 });
        try std.testing.expect(state.view().modal == .none);
        try std.testing.expect(state.view().operation == null);
        try view.event(&.{ .key = .tab });
        try view.event(&.{ .key = .down });
        try std.testing.expect(!try state.invoke(.mkdir, emulator));
        try std.testing.expect(!try state.invoke(.delete, emulator));
        try view.event(&.{ .key = .f7 });
        try view.event(&.{ .key = .f8 });
        try std.testing.expect(state.view().modal == .none);
        try std.testing.expect(state.view().operation == null);
        try std.testing.expectEqual(@as(usize, 1), fixture.scans.load(.acquire));
        fixture.writable = true;
        // Capability bits alone never authorize an unsupported provider executor.
        try std.testing.expectEqual(!foreign, state.available(.mkdir));
        try std.testing.expectEqual(!foreign, state.available(.delete));
        try std.testing.expectEqual(!foreign, try state.invoke(.mkdir, emulator));
        if (!foreign) state.dismiss();
        try std.testing.expectEqual(@as(usize, 1), fixture.scans.load(.acquire));
        _ = try tmp.dir.statFile(io, "source", .{});
    }
}

test "View retains rejected opaque Location input for correction" {
    const Pane = @import("../core/pane.zig").Pane;
    const Fixture = @import("../core/testing_provider.zig").Opaque;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture: Fixture = .{};
    const left = try Pane.create(io, allocator, Fixture.root, .{ .provider = fixture.provider() });
    defer left.destroy();
    const right = try Pane.create(io, allocator, "/", .{});
    defer right.destroy();
    const emulator = try Emulator.create(io, allocator, 80, 8);
    defer emulator.destroy();
    const state = try State.create(io, allocator, .{ left, right });
    defer state.destroy();
    const view = try View.create(allocator, state, emulator);
    defer view.destroy();
    try left.refresh();
    try settleWorkflow(state);
    const previous_listing = left.view().entries.ptr;
    var decoder: ui.input.Decoder = .{};
    try feed(view, &decoder, "\x0cinvalid\r");
    try std.testing.expect(state.view().modal == .editor);
    try std.testing.expectEqualStrings("invalid", state.view().modal.editor.input.text());
    try std.testing.expect(state.view().operation == null);
    try std.testing.expectEqual(.invalid_location, state.view().rejection.?);
    try std.testing.expectEqualStrings(Fixture.root, left.location().locator);
    try std.testing.expectEqual(previous_listing, left.view().entries.ptr);
    try std.testing.expect(left.view().status == .ready);
    try std.testing.expect(view.modal.focused());
    var frame = ui.Frame.init(allocator);
    defer frame.deinit();
    try view.paint(&frame, .{ .width = 80, .height = 24 });
    try expectFrameText(&frame, "Location not recognized.");
    try expectFrameText(&frame, "invalid");
    for ([_]ui.Size{ .{ .width = 7, .height = 4 }, .{ .width = 1, .height = 1 } }) |size| {
        try view.paint(&frame, size);
        if (frame.cursor) |cursor| try std.testing.expect(cursor.x < size.width and cursor.y < size.height);
    }
    try feed(view, &decoder, "\x15folder");
    try std.testing.expect(state.view().rejection == null);
    try view.event(&.{ .key = .enter });
    try settleWorkflow(state);
    try std.testing.expect(state.view().modal == .none);
    try std.testing.expectEqualStrings(Fixture.child, left.location().locator);
    try std.testing.expect(view.panes[0].focused());
    // A new rejection can be dismissed, then terminal input is routed normally.
    try feed(view, &decoder, "\x0cwrong\r");
    try view.event(&.{ .key = .escape });
    try std.testing.expect(state.view().rejection == null);
    try feed(view, &decoder, "\x07q\x07");
    try std.testing.expectEqualStrings("q", emulator.queued());
    try std.testing.expect(!state.view().quit);
}

fn settleWorkflow(state: *State) !void {
    for (0..5000) |_| {
        _ = try state.poll();
        const finished = if (state.view().operation) |job| job.status() == .finished else true;
        if (finished and state.panes()[0].view().status != .loading and state.panes()[1].view().status != .loading) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.WorkflowTimeout;
}

test "View retains capability rejection and never starts unsupported file actions" {
    const Pane = @import("../core/pane.zig").Pane;
    const Fixture = @import("../core/testing_provider.zig").LocalCapabilities;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "keep", .data = "safe" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const blocked = try std.fs.path.join(allocator, &.{ path, "blocked" });
    defer allocator.free(blocked);
    var fixture: Fixture = .{ .blocked = blocked };
    const left = try Pane.create(io, allocator, path, .{ .provider = fixture.provider(true) });
    defer left.destroy();
    const right = try Pane.create(io, allocator, path, .{ .provider = fixture.provider(true) });
    defer right.destroy();
    const emulator = try Emulator.create(io, allocator, 80, 8);
    defer emulator.destroy();
    const state = try State.create(io, allocator, .{ left, right });
    defer state.destroy();
    const view = try View.create(allocator, state, emulator);
    defer view.destroy();
    try left.refresh();
    try settleWorkflow(state);
    try view.event(&.{ .key = .down });
    var decoder: ui.input.Decoder = .{};
    var frame = ui.Frame.init(allocator);
    defer frame.deinit();
    var data: [16]u8 = undefined;
    // Changed capabilities and edited destinations are both rechecked at Enter.
    for ([_]ui.input.Key{ .f5, .f6, .f7 }) |key| {
        try view.event(&.{ .key = key });
        try feed(view, &decoder, "\x15blocked/new");
        fixture.writable = false;
        try view.event(&.{ .key = .enter });
        try std.testing.expectEqual(.unsupported_operation, state.view().rejection.?);
        try std.testing.expectEqualStrings("blocked/new", state.view().modal.editor.input.text());
        try std.testing.expect(state.view().operation == null);
        try view.paint(&frame, .{ .width = 80, .height = 24 });
        try expectFrameText(&frame, "Operation unavailable.");
        fixture.writable = true;
        try view.event(&.{ .key = .enter });
        try std.testing.expect(state.view().operation == null);
        try std.testing.expectEqual(.unsupported_operation, state.view().rejection.?);
        try std.testing.expectEqualStrings("safe", try tmp.dir.readFile(io, "keep", &data));
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "blocked", .{}));
        try view.event(&.{ .key = .escape });
        try std.testing.expect(state.view().rejection == null);
        try std.testing.expect(view.panes[0].focused());
    }
    try view.event(&.{ .key = .f8 });
    const prepared = state.view().modal.confirm_delete;
    fixture.writable = false;
    try view.event(&.{ .key = .enter });
    try std.testing.expectEqual(prepared, state.view().modal.confirm_delete);
    try std.testing.expect(prepared.status() == .prepared);
    try std.testing.expectEqualStrings("keep", std.fs.path.basename(prepared.request().sources[0]));
    try std.testing.expect(state.view().operation == null);
    try std.testing.expectEqual(.unsupported_operation, state.view().rejection.?);
    try view.paint(&frame, .{ .width = 80, .height = 24 });
    try expectFrameText(&frame, "Delete unavailable.");
    try expectFrameText(&frame, "keep");
    try feed(view, &decoder, "\x1b[200~n\r\x1b[201~");
    try std.testing.expectEqual(prepared, state.view().modal.confirm_delete);
    try view.event(&.{ .key = .escape });
    try std.testing.expectEqualStrings("safe", try tmp.dir.readFile(io, "keep", &data));
    fixture.writable = true;
    // Correcting a rejected copy starts exactly the supported request.
    try view.event(&.{ .key = .f5 });
    try feed(view, &decoder, "blocked/new\r");
    try std.testing.expect(state.view().operation == null);
    try feed(view, &decoder, "\x15copied\r");
    try std.testing.expect(state.view().modal == .none);
    try std.testing.expect(state.view().rejection == null);
    try settleWorkflow(state);
    try std.testing.expect(state.view().operation.?.status().finished.failure == null);
    try std.testing.expectEqualStrings("safe", try tmp.dir.readFile(io, "copied", &data));
    try std.testing.expectEqualStrings("safe", try tmp.dir.readFile(io, "keep", &data));
    try view.event(&.{ .key = .escape });
    try view.event(&.{ .key = .tab });
    try std.testing.expect(view.panes[1].focused());
}

test "View propagates fatal Provider failures without converting them to rejection" {
    const Pane = @import("../core/pane.zig").Pane;
    const Fixture = @import("../core/testing_provider.zig").Opaque;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var fixture: Fixture = .{};
    const left = try Pane.create(io, allocator, Fixture.root, .{ .provider = fixture.provider() });
    defer left.destroy();
    const right = try Pane.create(io, allocator, "/", .{});
    defer right.destroy();
    const emulator = try Emulator.create(io, allocator, 80, 8);
    defer emulator.destroy();
    const state = try State.create(io, allocator, .{ left, right });
    defer state.destroy();
    const view = try View.create(allocator, state, emulator);
    defer view.destroy();
    var decoder: ui.input.Decoder = .{};
    try feed(view, &decoder, "\x0cfolder");
    for ([_]anyerror{ error.OutOfMemory, error.Canceled, error.ConcurrencyUnavailable, error.ConnectionResetByPeer }) |err| {
        fixture.resolve_failure = err;
        try std.testing.expectError(err, view.event(&.{ .key = .enter }));
        try std.testing.expect(state.view().rejection == null);
        try std.testing.expect(state.view().operation == null);
        try std.testing.expectEqualStrings("folder", state.view().modal.editor.input.text());
        try std.testing.expectEqualStrings(Fixture.root, left.location().locator);
    }
}

test "View dispatches Pane aliases marking and modifiers while unhandled commands bubble" {
    const Pane = @import("../core/pane.zig").Pane;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "child", .default_dir);
    for ([_][]const u8{ "a", "b", "c", ".hidden" }) |name|
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buffer);
    const left = try Pane.create(io, allocator, buffer[0..len], .{});
    defer left.destroy();
    const right = try Pane.create(io, allocator, buffer[0..len], .{});
    defer right.destroy();
    const emulator = try Emulator.create(io, allocator, 20, 3);
    defer emulator.destroy();
    const state = try State.create(io, allocator, .{ left, right });
    defer state.destroy();
    const view = try View.create(allocator, state, emulator);
    defer view.destroy();
    try left.refresh();
    try settlePane(state, left);
    // Two visible rows make PageUp/Down behavior observable independently of End.
    try view.resize(.{ .width = 80, .height = 10 });
    try std.testing.expectEqual(@as(usize, 2), left.view().visible_rows);
    var decoder: ui.input.Decoder = .{};
    try feed(view, &decoder, " "); // Parent row is never marked.
    try std.testing.expectEqual(@as(usize, 0), left.view().marked_count);
    try view.event(&.{ .key = .insert, .shift = true, .ctrl = true, .alt = true });
    try std.testing.expectEqual(@as(usize, 1), left.view().cursor);
    try std.testing.expectEqual(@as(usize, 0), left.view().marked_count);
    try std.testing.expectEqualStrings("child", left.view().focused().?.name);
    try view.event(&.{ .key = .insert });
    try std.testing.expectEqual(@as(usize, 2), left.view().cursor);
    try std.testing.expectEqual(@as(usize, 1), left.view().marked_count);
    try view.event(&.{ .key = .up, .ctrl = true, .alt = true });
    try std.testing.expect(left.view().focusedMarked());
    var space: ui.Event = .{ .key = .text, .len = 1, .shift = true, .ctrl = true, .alt = true };
    space.bytes[0] = ' ';
    try view.event(&space);
    try std.testing.expectEqual(@as(usize, 0), left.view().marked_count);
    try view.event(&.{ .key = .home });
    try view.event(&.{ .key = .down, .shift = true });
    try std.testing.expectEqual(@as(usize, 0), left.view().marked_count);
    try view.event(&.{ .key = .down, .shift = true });
    try std.testing.expectEqual(@as(usize, 1), left.view().marked_count);
    try view.event(&.{ .key = .up, .shift = true });
    try std.testing.expectEqual(@as(usize, 2), left.view().marked_count);
    try view.event(&.{ .key = .home, .shift = true });
    try std.testing.expectEqual(@as(usize, 0), left.view().cursor);
    try std.testing.expectEqual(@as(usize, 1), left.view().marked_count);
    try view.event(&.{ .key = .end, .shift = true });
    try std.testing.expectEqual(@as(usize, 4), left.view().cursor);
    try std.testing.expectEqual(@as(usize, 3), left.view().marked_count);
    try view.event(&.{ .key = .home, .shift = true });
    try std.testing.expectEqual(@as(usize, 1), left.view().marked_count);
    try view.event(&.{ .key = .page_down, .ctrl = true, .alt = true });
    try std.testing.expectEqual(@as(usize, 2), left.view().cursor);
    try view.event(&.{ .key = .page_up });
    try std.testing.expectEqual(@as(usize, 0), left.view().cursor);
    try view.event(&.{ .key = .end });
    try std.testing.expectEqual(@as(usize, 4), left.view().cursor);
    try std.testing.expectEqual(@as(usize, 1), left.view().marked_count);
    // Both entering and parent aliases operate through the focused widget.
    for ([_]ui.input.Key{ .enter, .right }, [_]ui.input.Key{ .backspace, .left }) |enter, parent| {
        try view.event(&.{ .key = .home });
        try view.event(&.{ .key = .down });
        try view.event(&.{ .key = enter, .shift = true, .alt = true, .ctrl = true });
        try settlePane(state, left);
        try std.testing.expect(std.mem.endsWith(u8, left.view().path, "/child"));
        try view.event(&.{ .key = parent, .shift = true, .alt = true, .ctrl = true });
        try settlePane(state, left);
        try std.testing.expectEqualStrings(buffer[0..len], left.view().path);
    }
    try feed(view, &decoder, ".");
    try settlePane(state, left);
    try std.testing.expect(left.view().options.hidden);
    try std.testing.expectEqual(@as(usize, 5), left.view().entries.len);
    const original_sort = left.view().options.sort;
    try feed(view, &decoder, "s");
    try settlePane(state, left);
    try std.testing.expect(left.view().options.sort != original_sort);
    try feed(view, &decoder, "r");
    try settlePane(state, left);
    try std.testing.expect(left.view().options.reverse);
    // Escape clears a failed read without moving or changing focus.
    try left.request("missing");
    try settlePane(state, left);
    try std.testing.expect(left.view().status == .failed);
    try view.event(&.{ .key = .escape });
    try std.testing.expect(left.view().status == .ready);
    // Multi-byte text and paste cannot activate a single-byte Pane binding.
    const cursor = left.view().cursor;
    var text_event: ui.Event = .{ .key = .text, .len = 2 };
    @memcpy(text_event.bytes[0..2], " r");
    try view.event(&text_event);
    try feed(view, &decoder, "\x1b[200~ .sr\x1b[201~");
    try std.testing.expectEqual(cursor, left.view().cursor);
    try std.testing.expectEqual(@as(usize, 0), left.view().marked_count);
    try std.testing.expect(left.view().options.reverse);
    try std.testing.expect(left.view().status == .ready);
    // Shift pages reach terminal history even with extra modifiers, without
    // moving/marking the Pane or delivering bytes to the shell.
    try emulator.feed("0\r\n1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n9");
    var frame = ui.Frame.init(allocator);
    defer frame.deinit();
    try frame.begin(20, 3);
    const painter = frame.painter(.{ .x = 0, .y = 0, .width = 20, .height = 3 });
    try view.event(&.{ .key = .page_up, .shift = true, .alt = true, .ctrl = true });
    try emulator.paint(painter, false);
    try std.testing.expectEqualStrings("4", frame.cells[0].text);
    try view.event(&.{ .key = .page_down, .shift = true, .alt = true, .ctrl = true });
    try emulator.paint(painter, false);
    try std.testing.expectEqualStrings("7", frame.cells[0].text);
    try std.testing.expectEqual(cursor, left.view().cursor);
    try std.testing.expectEqual(@as(usize, 0), left.view().marked_count);
    try std.testing.expectEqual(@as(usize, 0), emulator.queued().len);
    try view.event(&.{ .key = .tab });
    try std.testing.expect(view.panes[1].focused());
    try view.event(&.{ .key = .f1 });
    try std.testing.expect(state.view().modal == .help);
    const pane_help = @import("widgets/file_pane.zig").help_lines;
    const help_size = @import("widgets/dialogs.zig").help_size;
    try std.testing.expect(help_size.width <= 80 and help_size.height <= 24);
    for ([_]ui.Size{ .{ .width = 80, .height = 24 }, help_size }) |size| {
        try view.paint(&frame, size);
        for (pane_help) |line| try expectFrameText(&frame, line);
        try expectFrameText(&frame, "Any key closes help");
    }
    for ([_]ui.Size{ .{ .width = 40, .height = 12 }, .{ .width = 7, .height = 4 }, .{ .width = 1, .height = 1 } }) |size| {
        try view.paint(&frame, size);
        try std.testing.expect(frame.cursor == null);
    }
}

fn settlePane(state: *State, pane: *@import("../core/pane.zig").Pane) !void {
    for (0..5000) |_| {
        _ = try state.poll();
        if (pane.view().status != .loading) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    return error.PaneReadTimedOut;
}
