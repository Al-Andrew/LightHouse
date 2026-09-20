//! Retained widget ownership, focus, modal routing, and clipped traversal.
//! Keep a Tree at a stable address. It owns all nodes and their model values.
const std = @import("std");
const screen = @import("screen.zig");
const input = @import("input.zig");

pub const Size = struct { width: usize = 0, height: usize = 0 };
pub const Event = input.Event;

/// A widget model implements any of measure, layout, paint, event, and deinit.
/// Parent-local rectangles are assigned during layout; painters are clipped by
/// the tree. Models own their values, but explicitly borrowed pointers stay borrowed.
pub const Widget = struct {
    tree: *Tree,
    parent: ?*Widget,
    children: std.ArrayList(*Widget) = .empty,
    rect: screen.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    visible: bool = true,
    focusable: bool = false,
    retired: bool = false,
    context: *anyopaque,
    callbacks: *const Callbacks,

    const Callbacks = struct {
        measure: *const fn (*anyopaque, Size) Size,
        layout: *const fn (*anyopaque, *Widget, Size) void,
        paint: *const fn (*anyopaque, *Widget, screen.Painter) anyerror!void,
        event: *const fn (*anyopaque, *Widget, *const Event) anyerror!bool,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    pub fn measure(self: *Widget, available: Size) Size {
        const desired = self.callbacks.measure(self.context, available);
        return .{ .width = @min(desired.width, available.width), .height = @min(desired.height, available.height) };
    }

    pub fn setRect(self: *Widget, rect: screen.Rect) void {
        if (std.meta.eql(self.rect, rect)) return;
        self.rect = rect;
        self.invalidate();
    }

    pub fn setVisible(self: *Widget, visible: bool) void {
        if (self.visible == visible) return;
        self.visible = visible;
        self.invalidate();
    }

    pub fn focused(self: *const Widget) bool {
        return self.tree.focus == self and !self.retired;
    }

    pub fn invalidate(self: *Widget) void {
        self.tree.dirty = true;
    }

    /// Safe inside an input callback, including removal of the current widget
    /// or an ancestor. Storage is released after the outer traversal returns.
    pub fn destroy(self: *Widget) void {
        self.retired = true;
        self.tree.forget(self);
        self.invalidate();
        if (!self.tree.traversing) self.tree.collect();
    }

    fn contains(self: *const Widget, candidate: *const Widget) bool {
        var node: ?*const Widget = candidate;
        while (node) |current| : (node = current.parent) {
            if (current == self) return true;
        }
        return false;
    }

    fn live(self: *const Widget) bool {
        var node: ?*const Widget = self;
        while (node) |current| : (node = current.parent) {
            if (current.retired) return false;
        }
        return true;
    }

    fn shown(self: *const Widget) bool {
        var node: ?*const Widget = self;
        while (node) |current| : (node = current.parent) {
            if (!current.visible or current.retired) return false;
        }
        return true;
    }
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    root: ?*Widget = null,
    focus: ?*Widget = null,
    modal: ?*Widget = null,
    saved_focus: ?*Widget = null,
    dirty: bool = true,
    traversing: bool = false,

    pub fn init(allocator: std.mem.Allocator) Tree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tree) void {
        std.debug.assert(!self.traversing);
        if (self.root) |root| self.free(root);
        self.root = null;
        self.focus = null;
        self.modal = null;
        self.saved_focus = null;
    }

    /// Takes ownership of value only on success. Add nodes between traversals;
    /// callbacks may retire nodes but cannot change the child list in flight.
    pub fn create(self: *Tree, parent: ?*Widget, comptime Model: type, value: Model) !*Widget {
        if (self.traversing) return error.TreeBusy;
        if (parent) |p| {
            if (p.tree != self or !p.live()) return error.InvalidParent;
        } else if (self.root != null) return error.RootAlreadyExists;
        const model = try self.allocator.create(Model);
        errdefer self.allocator.destroy(model);
        const node = try self.allocator.create(Widget);
        errdefer self.allocator.destroy(node);
        const Adapter = struct {
            fn cast(context: *anyopaque) *Model {
                return @ptrCast(@alignCast(context));
            }
            fn measure(context: *anyopaque, available: Size) Size {
                if (@hasDecl(Model, "measure")) return cast(context).measure(available);
                return available;
            }
            fn layout(context: *anyopaque, widget: *Widget, size: Size) void {
                if (@hasDecl(Model, "layout")) {
                    cast(context).layout(widget, size);
                } else for (widget.children.items) |child| {
                    child.setRect(.{ .x = 0, .y = 0, .width = size.width, .height = size.height });
                }
            }
            fn paint(context: *anyopaque, widget: *Widget, painter: screen.Painter) !void {
                if (@hasDecl(Model, "paint")) try cast(context).paint(widget, painter);
            }
            fn event(context: *anyopaque, widget: *Widget, ev: *const Event) !bool {
                if (@hasDecl(Model, "event")) return cast(context).event(widget, ev);
                return false;
            }
            fn destroy(context: *anyopaque, allocator: std.mem.Allocator) void {
                const owned = cast(context);
                if (@hasDecl(Model, "deinit")) owned.deinit();
                allocator.destroy(owned);
            }
            const callbacks: Widget.Callbacks = .{ .measure = measure, .layout = @This().layout, .paint = @This().paint, .event = event, .destroy = destroy };
        };
        if (parent) |p| try p.children.append(self.allocator, node);
        model.* = value;
        node.* = .{ .tree = self, .parent = parent, .context = model, .callbacks = &Adapter.callbacks };
        if (parent == null) self.root = node;
        self.dirty = true;
        return node;
    }

    /// Visibility controls painting, not keyboard eligibility. Applications can
    /// keep a pane focused while its viewport is collapsed to zero cells.
    pub fn setFocus(self: *Tree, widget: ?*Widget) !void {
        if (widget) |node| {
            if (node.tree != self or !node.live() or !node.focusable) return error.InvalidFocus;
            if (self.modal) |scope| if (!scope.contains(node)) return error.OutsideModal;
        }
        if (self.focus == widget) return;
        self.focus = widget;
        self.dirty = true;
    }

    /// One modal scope traps all input, even when its widgets ignore an event.
    /// Closing it restores the prior live focus. Replacing it retains that focus.
    pub fn setModal(self: *Tree, widget: ?*Widget) !void {
        if (widget) |node| if (node.tree != self or !node.live()) return error.InvalidModal;
        if (self.modal == widget) return;
        if (self.modal == null) self.saved_focus = self.focus;
        self.modal = widget;
        if (widget) |node| {
            if (self.focus) |focused_node| {
                if (!node.contains(focused_node)) self.focus = null;
            }
        } else {
            self.focus = self.saved_focus;
            self.saved_focus = null;
        }
        self.dirty = true;
    }

    pub fn dispatch(self: *Tree, ev: *const Event) !bool {
        if (self.traversing) return error.TreeBusy;
        self.traversing = true;
        defer {
            self.traversing = false;
            self.collect();
        }
        // Capture the scope: closing a dialog must not forward its dismissal key.
        const scope = self.modal;
        var node = self.focus orelse scope orelse self.root;
        while (node) |current| {
            const parent = current.parent;
            if (current.live() and try current.callbacks.event(current.context, current, ev)) {
                self.dirty = true;
                return true;
            }
            if (self.modal != scope) return true;
            if (scope == current) break;
            node = parent;
        }
        return scope != null;
    }

    pub fn layout(self: *Tree, size: Size) !void {
        if (self.traversing) return error.TreeBusy;
        self.traversing = true;
        defer {
            self.traversing = false;
            self.collect();
        }
        if (self.root) |root| {
            root.setRect(.{ .x = 0, .y = 0, .width = size.width, .height = size.height });
            arrange(root);
        }
    }

    fn arrange(node: *Widget) void {
        if (!node.live()) return;
        node.callbacks.layout(node.context, node, .{ .width = node.rect.width, .height = node.rect.height });
        for (node.children.items) |child| arrange(child);
    }

    pub fn paint(self: *Tree, frame: *screen.Frame) !void {
        if (self.traversing) return error.TreeBusy;
        self.traversing = true;
        self.dirty = false;
        errdefer self.dirty = true;
        defer {
            self.traversing = false;
            self.collect();
        }
        if (self.root) |root| {
            try paintNode(root, frame.painter(root.rect), null);
            // A modal subtree is composited last, independent of child order.
            if (self.modal) |modal| {
                frame.cursor = null;
                try paintNode(modal, painterFor(frame, modal), modal);
            }
        }
    }

    fn painterFor(frame: *screen.Frame, node: *Widget) screen.Painter {
        if (node.parent) |parent| return painterFor(frame, parent).child(node.rect);
        return frame.painter(node.rect);
    }

    fn paintNode(node: *Widget, painter: screen.Painter, modal_pass: ?*Widget) !void {
        if (!node.shown() or (node.tree.modal == node and modal_pass != node)) return;
        if (painter.rect.width == 0 or painter.rect.height == 0) return;
        try node.callbacks.paint(node.context, node, painter);
        for (node.children.items) |child| try paintNode(child, painter.child(child.rect), modal_pass);
    }

    fn forget(self: *Tree, removed: *Widget) void {
        if (self.saved_focus) |node| if (removed.contains(node)) {
            self.saved_focus = null;
        };
        if (self.focus) |node| if (removed.contains(node)) {
            self.focus = null;
        };
        if (self.modal) |node| if (removed.contains(node)) {
            self.modal = null;
            self.focus = self.saved_focus;
            self.saved_focus = null;
        };
    }

    fn free(self: *Tree, node: *Widget) void {
        for (node.children.items) |child| self.free(child);
        node.children.deinit(self.allocator);
        node.callbacks.destroy(node.context, self.allocator);
        self.allocator.destroy(node);
    }

    fn collectChildren(self: *Tree, node: *Widget) void {
        var i: usize = 0;
        while (i < node.children.items.len) {
            const child = node.children.items[i];
            if (child.retired) {
                _ = node.children.orderedRemove(i);
                self.free(child);
            } else {
                self.collectChildren(child);
                i += 1;
            }
        }
    }

    fn collect(self: *Tree) void {
        if (self.root) |root| {
            if (root.retired) {
                self.root = null;
                self.free(root);
            } else self.collectChildren(root);
        }
    }
};
