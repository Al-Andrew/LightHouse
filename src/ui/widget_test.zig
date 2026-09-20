const std = @import("std");
const ui = @import("root.zig");
const testing = std.testing;

const Probe = struct {
    visits: *usize,
    drops: *usize,
    handles: bool = false,
    remove_parent: bool = false,

    pub fn event(self: *Probe, node: *ui.Widget, _: *const ui.Event) !bool {
        self.visits.* += 1;
        if (self.remove_parent) node.parent().?.destroy();
        return self.handles;
    }

    pub fn deinit(self: *Probe) void {
        self.drops.* += 1;
    }
};

test "focused input bubbles and a modal traps ignored input then restores focus" {
    const tree = try ui.Tree.init(testing.allocator);
    defer tree.deinit();
    var root_events: usize = 0;
    var child_events: usize = 0;
    var modal_events: usize = 0;
    var drops: usize = 0;
    const root = try tree.create(null, Probe, .{ .visits = &root_events, .drops = &drops });
    const child = try tree.create(root, Probe, .{ .visits = &child_events, .drops = &drops });
    child.setFocusable(true);
    const modal = try tree.create(root, Probe, .{ .visits = &modal_events, .drops = &drops });
    try tree.setFocus(child);
    try testing.expect(!try tree.dispatch(&.{ .key = .enter }));
    try testing.expectEqual(@as(usize, 1), child_events);
    try testing.expectEqual(@as(usize, 1), root_events);
    try tree.setModal(modal);
    try testing.expectError(error.OutsideModal, tree.setFocus(child));
    try testing.expect(try tree.dispatch(&.{ .key = .enter }));
    try testing.expectEqual(@as(usize, 1), modal_events);
    try testing.expectEqual(@as(usize, 1), root_events);
    try tree.setModal(null);
    try testing.expect(child.focused());
}

test "callback removal defers disposal and releases every owned model exactly once" {
    const tree = try ui.Tree.init(testing.allocator);
    var root_events: usize = 0;
    var events: usize = 0;
    var drops: usize = 0;
    const root = try tree.create(null, Probe, .{ .visits = &root_events, .drops = &drops });
    const modal = try tree.create(root, Probe, .{ .visits = &events, .drops = &drops });
    const child = try tree.create(modal, Probe, .{ .visits = &events, .drops = &drops, .remove_parent = true });
    child.setFocusable(true);
    try tree.setModal(modal);
    try tree.setFocus(child);
    try testing.expect(try tree.dispatch(&.{ .key = .escape }));
    try testing.expectEqual(@as(usize, 2), drops);
    try testing.expectEqual(@as(usize, 0), root_events);
    try testing.expect(tree.focus() == null and tree.modal() == null);
    tree.deinit();
    try testing.expectEqual(@as(usize, 3), drops);
}

const Ink = struct {
    value: []const u8,

    pub fn paint(self: *Ink, _: *ui.Widget, painter: ui.Painter) !void {
        try painter.text(0, 0, self.value, .{});
    }
};

test "nested layout clips wide glyphs and modal painting stays above later siblings" {
    const tree = try ui.Tree.init(testing.allocator);
    defer tree.deinit();
    const root = try tree.create(null, ui.layout.Box, .{ .axis = .horizontal, .gap = 1 });
    const left = try tree.create(root, Ink, .{ .value = "a界x" });
    const right = try tree.create(root, Ink, .{ .value = "right" });
    var frame = ui.Frame.init(testing.allocator);
    defer frame.deinit();
    try frame.begin(7, 2);
    try tree.layout(.{ .width = 7, .height = 2 });
    try tree.paint(&frame);
    try testing.expectEqualStrings("a", frame.cells[0].text);
    try testing.expectEqualStrings("界", frame.cells[1].text);
    try testing.expectEqual(@as(u2, 0), frame.cells[2].width);
    try testing.expectEqualStrings(" ", frame.cells[3].text);
    try testing.expectEqualStrings("r", frame.cells[4].text);
    // Overlapping siblings: modal appears above a later ordinary sibling.
    right.setRect(left.rect());
    try tree.setModal(left);
    try frame.begin(7, 2);
    try tree.paint(&frame);
    try testing.expectEqualStrings("a", frame.cells[0].text);
    try testing.expectEqualStrings("界", frame.cells[1].text);
}

test "layout supports empty and tiny bounds and visibility invalidates the frame" {
    const tree = try ui.Tree.init(testing.allocator);
    defer tree.deinit();
    const root = try tree.create(null, ui.layout.Box, .{ .axis = .vertical, .gap = 100 });
    const first = try tree.create(root, Ink, .{ .value = "one" });
    const second = try tree.create(root, Ink, .{ .value = "two" });
    _ = try tree.create(root, Ink, .{ .value = "three" });
    var frame = ui.Frame.init(testing.allocator);
    defer frame.deinit();
    for (0..10) |height| {
        try tree.layout(.{ .width = 2, .height = height });
        for (root.children()) |child| try testing.expect(child.rect().y + child.rect().height <= height);
        try frame.begin(2, height);
        try tree.paint(&frame);
    }
    try testing.expect(!tree.needsPaint());
    first.setVisible(false);
    try testing.expect(tree.needsPaint());
    try tree.layout(.{ .width = 2, .height = 5 });
    try testing.expectEqual(@as(usize, 0), second.rect().y);
}

test "reentrant dispatch and additions during callbacks are rejected safely" {
    const Reentrant = struct {
        pub fn event(_: *@This(), node: *ui.Widget, ev: *const ui.Event) !bool {
            try testing.expectError(error.TreeBusy, node.tree().dispatch(ev));
            try testing.expectError(error.TreeBusy, node.tree().layout(.{ .width = 10, .height = 2 }));
            var frame = ui.Frame.init(testing.allocator);
            defer frame.deinit();
            try testing.expectError(error.TreeBusy, node.tree().paint(&frame));
            try testing.expectError(error.TreeBusy, node.tree().create(node, Ink, .{ .value = "no" }));
            return true;
        }
    };
    const tree = try ui.Tree.init(testing.allocator);
    defer tree.deinit();
    _ = try tree.create(null, Reentrant, .{});
    try testing.expect(try tree.dispatch(&.{ .key = .enter }));
}

test "removing the saved focus while a modal is open never restores a freed node" {
    const tree = try ui.Tree.init(testing.allocator);
    defer tree.deinit();
    const root = try tree.create(null, Ink, .{ .value = "root" });
    const child = try tree.create(root, Ink, .{ .value = "child" });
    child.setFocusable(true);
    const modal = try tree.create(root, Ink, .{ .value = "modal" });
    try tree.setFocus(child);
    try tree.setModal(modal);
    child.destroy();
    try tree.setModal(null);
    try testing.expect(tree.focus() == null);
}

test "opening a modal during dispatch does not leak the opening key to an ancestor" {
    const Open = struct {
        scope: *ui.Widget,
        pub fn event(self: *@This(), node: *ui.Widget, _: *const ui.Event) !bool {
            try node.tree().setModal(self.scope);
            return false;
        }
    };
    const tree = try ui.Tree.init(testing.allocator);
    defer tree.deinit();
    var events: usize = 0;
    var drops: usize = 0;
    const root = try tree.create(null, Probe, .{ .visits = &events, .drops = &drops });
    const scope = try tree.create(root, Ink, .{ .value = "modal" });
    const opener = try tree.create(root, Open, .{ .scope = scope });
    opener.setFocusable(true);
    try tree.setFocus(opener);
    try testing.expect(try tree.dispatch(&.{ .key = .enter }));
    try testing.expectEqual(@as(usize, 0), events);
}

test "a modal under a hidden ancestor stays clipped out of painting" {
    const tree = try ui.Tree.init(testing.allocator);
    defer tree.deinit();
    const root = try tree.create(null, Ink, .{ .value = "root" });
    const group = try tree.create(root, Ink, .{ .value = "group" });
    const modal = try tree.create(group, Ink, .{ .value = "modal" });
    group.setVisible(false);
    try tree.setModal(modal);
    var frame = ui.Frame.init(testing.allocator);
    defer frame.deinit();
    try frame.begin(10, 2);
    try tree.layout(.{ .width = 10, .height = 2 });
    try tree.paint(&frame);
    try testing.expectEqualStrings("r", frame.cells[0].text);
}

test "opaque handles expose observations without mutable ownership storage" {
    try testing.expect(@typeInfo(ui.Widget) == .@"opaque");
    try testing.expect(@typeInfo(ui.Tree) == .@"opaque");
    const tree = try ui.Tree.init(testing.allocator);
    defer tree.deinit();
    const root = try tree.create(null, Ink, .{ .value = "root" });
    const child = try tree.create(root, Ink, .{ .value = "child" });
    try testing.expectEqual(@as(?*ui.Widget, root), tree.root());
    try testing.expectEqual(@as(?*ui.Widget, root), child.parent());
    try testing.expectEqual(tree, child.tree());
    try testing.expect(@TypeOf(root.children()) == []const *ui.Widget);
    try testing.expectEqual(child, root.children()[0]);
}

test "hidden widgets remain eligible but disabling focus clears current and saved targets" {
    const tree = try ui.Tree.init(testing.allocator);
    defer tree.deinit();
    var visits: usize = 0;
    var drops: usize = 0;
    const root = try tree.create(null, Ink, .{ .value = "root" });
    const child = try tree.create(root, Probe, .{ .visits = &visits, .drops = &drops, .handles = true });
    const modal = try tree.create(root, Ink, .{ .value = "modal" });
    child.setFocusable(true);
    child.setVisible(false);
    try tree.setFocus(child);
    try testing.expect(try tree.dispatch(&.{ .key = .enter }));
    try testing.expectEqual(@as(usize, 1), visits);
    child.setFocusable(false);
    try testing.expect(tree.focus() == null);
    try testing.expect(!child.focusable());
    try testing.expectError(error.InvalidFocus, tree.setFocus(child));
    child.setFocusable(true);
    try tree.setFocus(child);
    try tree.setModal(modal);
    child.setFocusable(false);
    try tree.setModal(null);
    try testing.expect(tree.focus() == null);
}

test "failed creation keeps model ownership with caller at every allocation boundary" {
    var succeeded = false;
    var offset: usize = 0;
    while (offset < 16) : (offset += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const tree = try ui.Tree.init(failing.allocator());
        defer tree.deinit();
        const root = try tree.create(null, Ink, .{ .value = "root" });
        var visits: usize = 0;
        var drops: usize = 0;
        var value: Probe = .{ .visits = &visits, .drops = &drops };
        failing.fail_index = failing.alloc_index + offset;
        const child = tree.create(root, Probe, value) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), drops);
            try testing.expectEqual(@as(usize, 0), root.children().len);
            value.deinit();
            try testing.expectEqual(@as(usize, 1), drops);
            continue;
        };
        try testing.expectEqual(@as(usize, 0), drops);
        child.destroy();
        try testing.expectEqual(@as(usize, 1), drops);
        try testing.expectEqual(@as(usize, 0), root.children().len);
        succeeded = true;
        break;
    }
    try testing.expect(succeeded);
}

test "destroy releases descendants before their parents exactly once" {
    const Order = struct {
        sequence: *[3]u8,
        count: *usize,
        id: u8,
        pub fn deinit(self: *@This()) void {
            self.sequence[self.count.*] = self.id;
            self.count.* += 1;
        }
    };
    const tree = try ui.Tree.init(testing.allocator);
    var sequence: [3]u8 = undefined;
    var count: usize = 0;
    const root = try tree.create(null, Order, .{ .sequence = &sequence, .count = &count, .id = 0 });
    const child = try tree.create(root, Order, .{ .sequence = &sequence, .count = &count, .id = 1 });
    _ = try tree.create(child, Order, .{ .sequence = &sequence, .count = &count, .id = 2 });
    tree.deinit();
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualSlices(u8, &.{ 2, 1, 0 }, &sequence);
}

test "invalidation and paint errors request another frame" {
    const Repaint = struct {
        invalidate: *bool,
        fail: *bool,
        pub fn paint(self: *@This(), node: *ui.Widget, _: ui.Painter) !void {
            if (self.invalidate.*) node.invalidate();
            if (self.fail.*) return error.PaintFailed;
        }
    };
    const tree = try ui.Tree.init(testing.allocator);
    defer tree.deinit();
    var invalidate = true;
    var fail = false;
    _ = try tree.create(null, Repaint, .{ .invalidate = &invalidate, .fail = &fail });
    var frame = ui.Frame.init(testing.allocator);
    defer frame.deinit();
    try frame.begin(10, 2);
    try tree.layout(.{ .width = 10, .height = 2 });
    try tree.paint(&frame);
    try testing.expect(tree.needsPaint());
    invalidate = false;
    try tree.paint(&frame);
    try testing.expect(!tree.needsPaint());
    fail = true;
    try testing.expectError(error.PaintFailed, tree.paint(&frame));
    try testing.expect(tree.needsPaint());
}
