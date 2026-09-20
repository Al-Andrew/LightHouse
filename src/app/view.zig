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
        self.modal = try self.tree.create(root, Modal, .{ .state = state });
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
    view.modal = try view.tree.create(view.tree.root(), Modal, .{ .state = state });
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
