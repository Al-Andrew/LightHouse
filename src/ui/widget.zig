//! Retained widget ownership, focus, modal routing, and clipped traversal.
//! Opaque handles own stable storage for nodes and their model values.
const std = @import("std");
const screen = @import("screen.zig");
const input = @import("input.zig");

pub const Size = struct { width: usize = 0, height: usize = 0 };
pub const Event = input.Event;

const WidgetData = struct {
    tree: *Tree,
    parent: ?*Widget,
    children: std.ArrayList(*Widget) = .empty,
    rect: screen.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    visible: bool = true,
    focusable: bool = false,
    retired: bool = false,
    context: *anyopaque,
    callbacks: *const Widget.Callbacks,
};

/// A widget model implements any of measure, layout, paint, event, and deinit.
/// Parent-local rectangles are assigned during layout; painters are clipped by
/// the tree. Models own their values, but explicitly borrowed pointers stay borrowed.
pub const Widget = opaque {
    fn data(self: *const Widget) *WidgetData {
        return @ptrCast(@alignCast(@constCast(self)));
    }

    /// Borrowed child handles; the slots cannot be replaced or reordered.
    /// The slice expires on create/destroy or at the end of a callback traversal.
    pub fn children(self: *const Widget) []const *Widget {
        return self.data().children.items;
    }

    pub fn parent(self: *const Widget) ?*Widget {
        return self.data().parent;
    }

    pub fn tree(self: *const Widget) *Tree {
        return self.data().tree;
    }

    pub fn rect(self: *const Widget) screen.Rect {
        return self.data().rect;
    }

    pub fn visible(self: *const Widget) bool {
        return self.data().visible;
    }

    pub fn focusable(self: *const Widget) bool {
        return self.data().focusable;
    }

    pub fn setFocusable(self: *Widget, eligible: bool) void {
        if (self.data().focusable == eligible) return;
        self.data().focusable = eligible;
        const owner = self.data().tree.data();
        if (!eligible) {
            if (owner.focus == self) owner.focus = null;
            if (owner.saved_focus == self) owner.saved_focus = null;
        }
        self.invalidate();
    }

    /// Only meaningful while the borrowed handle remains valid.
    pub fn isAlive(self: *const Widget) bool {
        return self.live();
    }

    const Callbacks = struct {
        measure: *const fn (*anyopaque, Size) Size,
        layout: *const fn (*anyopaque, *Widget, Size) void,
        paint: *const fn (*anyopaque, *Widget, screen.Painter) anyerror!void,
        event: *const fn (*anyopaque, *Widget, *const Event) anyerror!bool,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    pub fn measure(self: *Widget, available: Size) Size {
        const desired = self.data().callbacks.measure(self.data().context, available);
        return .{ .width = @min(desired.width, available.width), .height = @min(desired.height, available.height) };
    }

    pub fn setRect(self: *Widget, bounds: screen.Rect) void {
        if (std.meta.eql(self.data().rect, bounds)) return;
        self.data().rect = bounds;
        self.invalidate();
    }

    pub fn setVisible(self: *Widget, shown_value: bool) void {
        if (self.data().visible == shown_value) return;
        self.data().visible = shown_value;
        self.invalidate();
    }

    pub fn focused(self: *const Widget) bool {
        return self.data().tree.data().focus == self and !self.data().retired;
    }

    pub fn invalidate(self: *Widget) void {
        self.data().tree.data().dirty = true;
    }

    /// Safe inside an input callback, including removal of the current widget
    /// or an ancestor. Storage is released after the outer traversal returns.
    pub fn destroy(self: *Widget) void {
        self.data().retired = true;
        self.data().tree.forget(self);
        self.invalidate();
        if (!self.data().tree.data().traversing) self.data().tree.collect();
    }

    fn contains(self: *const Widget, candidate: *const Widget) bool {
        var node: ?*const Widget = candidate;
        while (node) |current| : (node = current.data().parent) {
            if (current == self) return true;
        }
        return false;
    }

    fn live(self: *const Widget) bool {
        var node: ?*const Widget = self;
        while (node) |current| : (node = current.data().parent) {
            if (current.data().retired) return false;
        }
        return true;
    }

    fn shown(self: *const Widget) bool {
        var node: ?*const Widget = self;
        while (node) |current| : (node = current.data().parent) {
            if (!current.data().visible or current.data().retired) return false;
        }
        return true;
    }
};

const TreeData = struct {
    allocator: std.mem.Allocator,
    root: ?*Widget = null,
    focus: ?*Widget = null,
    modal: ?*Widget = null,
    saved_focus: ?*Widget = null,
    dirty: bool = true,
    traversing: bool = false,
};

pub const Tree = opaque {
    fn data(self: *const Tree) *TreeData {
        return @ptrCast(@alignCast(@constCast(self)));
    }

    pub fn root(self: *const Tree) ?*Widget {
        return self.data().root;
    }

    pub fn focus(self: *const Tree) ?*Widget {
        return self.data().focus;
    }

    pub fn modal(self: *const Tree) ?*Widget {
        return self.data().modal;
    }

    pub fn needsPaint(self: *const Tree) bool {
        return self.data().dirty;
    }

    /// Allocates stable opaque storage. Exactly one owner calls deinit.
    pub fn init(allocator: std.mem.Allocator) !*Tree {
        const storage = try allocator.create(TreeData);
        storage.* = .{ .allocator = allocator };
        return @ptrCast(storage);
    }

    pub fn deinit(self: *Tree) void {
        std.debug.assert(!self.data().traversing);
        if (self.data().root) |root_node| self.free(root_node);
        self.data().root = null;
        self.data().focus = null;
        self.data().modal = null;
        self.data().saved_focus = null;
        self.data().allocator.destroy(self.data());
    }

    /// Takes ownership of value only on success. Add nodes between traversals;
    /// callbacks may retire nodes but cannot change the child list in flight.
    pub fn create(self: *Tree, parent: ?*Widget, comptime Model: type, value: Model) !*Widget {
        if (self.data().traversing) return error.TreeBusy;
        if (parent) |p| {
            if (p.data().tree != self or !p.live()) return error.InvalidParent;
        } else if (self.data().root != null) return error.RootAlreadyExists;
        const model = try self.data().allocator.create(Model);
        errdefer self.data().allocator.destroy(model);
        const storage = try self.data().allocator.create(WidgetData);
        const node: *Widget = @ptrCast(storage);
        errdefer self.data().allocator.destroy(node.data());
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
                } else for (widget.data().children.items) |child| {
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
        if (parent) |p| try p.data().children.append(self.data().allocator, node);
        model.* = value;
        node.data().* = .{ .tree = self, .parent = parent, .context = model, .callbacks = &Adapter.callbacks };
        if (parent == null) self.data().root = node;
        self.data().dirty = true;
        return node;
    }

    /// Visibility controls painting, not keyboard eligibility. Applications can
    /// keep a pane focused while its viewport is collapsed to zero cells.
    pub fn setFocus(self: *Tree, widget: ?*Widget) !void {
        if (widget) |node| {
            if (node.data().tree != self or !node.live() or !node.data().focusable) return error.InvalidFocus;
            if (self.data().modal) |scope| if (!scope.contains(node)) return error.OutsideModal;
        }
        if (self.data().focus == widget) return;
        self.data().focus = widget;
        self.data().dirty = true;
    }

    /// One modal scope traps all input, even when its widgets ignore an event.
    /// Closing it restores the prior live focus. Replacing it retains that focus.
    pub fn setModal(self: *Tree, widget: ?*Widget) !void {
        if (widget) |node| if (node.data().tree != self or !node.live()) return error.InvalidModal;
        if (self.data().modal == widget) return;
        if (self.data().modal == null) self.data().saved_focus = self.data().focus;
        self.data().modal = widget;
        if (widget) |node| {
            if (self.data().focus) |focused_node| {
                if (!node.contains(focused_node)) self.data().focus = null;
            }
        } else {
            self.data().focus = self.data().saved_focus;
            self.data().saved_focus = null;
        }
        self.data().dirty = true;
    }

    pub fn dispatch(self: *Tree, ev: *const Event) !bool {
        if (self.data().traversing) return error.TreeBusy;
        self.data().traversing = true;
        defer {
            self.data().traversing = false;
            self.collect();
        }
        // Capture the scope: closing a dialog must not forward its dismissal key.
        const scope = self.data().modal;
        var node = self.data().focus orelse scope orelse self.data().root;
        while (node) |current| {
            const parent = current.data().parent;
            if (current.live() and try current.data().callbacks.event(current.data().context, current, ev)) {
                self.data().dirty = true;
                return true;
            }
            if (self.data().modal != scope) return true;
            if (scope == current) break;
            node = parent;
        }
        return scope != null;
    }

    pub fn layout(self: *Tree, size: Size) !void {
        if (self.data().traversing) return error.TreeBusy;
        self.data().traversing = true;
        defer {
            self.data().traversing = false;
            self.collect();
        }
        if (self.data().root) |root_node| {
            root_node.setRect(.{ .x = 0, .y = 0, .width = size.width, .height = size.height });
            arrange(root_node);
        }
    }

    fn arrange(node: *Widget) void {
        if (!node.live()) return;
        node.data().callbacks.layout(node.data().context, node, .{ .width = node.data().rect.width, .height = node.data().rect.height });
        for (node.data().children.items) |child| arrange(child);
    }

    pub fn paint(self: *Tree, frame: *screen.Frame) !void {
        if (self.data().traversing) return error.TreeBusy;
        self.data().traversing = true;
        self.data().dirty = false;
        errdefer self.data().dirty = true;
        defer {
            self.data().traversing = false;
            self.collect();
        }
        if (self.data().root) |root_node| {
            try paintNode(root_node, frame.painter(root_node.data().rect), null);
            // A modal subtree is composited last, independent of child order.
            if (self.data().modal) |modal_node| {
                frame.cursor = null;
                try paintNode(modal_node, painterFor(frame, modal_node), modal_node);
            }
        }
    }

    fn painterFor(frame: *screen.Frame, node: *Widget) screen.Painter {
        if (node.data().parent) |parent| return painterFor(frame, parent).child(node.data().rect);
        return frame.painter(node.data().rect);
    }

    fn paintNode(node: *Widget, painter: screen.Painter, modal_pass: ?*Widget) !void {
        if (!node.shown() or (node.data().tree.data().modal == node and modal_pass != node)) return;
        if (painter.rect.width == 0 or painter.rect.height == 0) return;
        try node.data().callbacks.paint(node.data().context, node, painter);
        for (node.data().children.items) |child| try paintNode(child, painter.child(child.data().rect), modal_pass);
    }

    fn forget(self: *Tree, removed: *Widget) void {
        if (self.data().saved_focus) |node| if (removed.contains(node)) {
            self.data().saved_focus = null;
        };
        if (self.data().focus) |node| if (removed.contains(node)) {
            self.data().focus = null;
        };
        if (self.data().modal) |node| if (removed.contains(node)) {
            self.data().modal = null;
            self.data().focus = self.data().saved_focus;
            self.data().saved_focus = null;
        };
    }

    fn free(self: *Tree, node: *Widget) void {
        for (node.data().children.items) |child| self.free(child);
        node.data().children.deinit(self.data().allocator);
        node.data().callbacks.destroy(node.data().context, self.data().allocator);
        self.data().allocator.destroy(node.data());
    }

    fn collectChildren(self: *Tree, node: *Widget) void {
        var i: usize = 0;
        while (i < node.data().children.items.len) {
            const child = node.data().children.items[i];
            if (child.data().retired) {
                _ = node.data().children.orderedRemove(i);
                self.free(child);
            } else {
                self.collectChildren(child);
                i += 1;
            }
        }
    }

    fn collect(self: *Tree) void {
        if (self.data().root) |root_node| {
            if (root_node.data().retired) {
                self.data().root = null;
                self.free(root_node);
            } else self.collectChildren(root_node);
        }
    }
};
