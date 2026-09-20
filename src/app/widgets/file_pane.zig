//! File-pane presentation and bindings; directory state and I/O live in core/Pane.
const std = @import("std");
const ui = @import("lighthouse-ui").screen;
const theme = @import("../theme.zig");
const Pane = @import("../../core/pane.zig").Pane;
const toolkit = @import("lighthouse-ui");

/// The widget borrows its domain pane. The application owns the pane's lifetime.
pub const FilePane = struct {
    pane: *Pane,
    allocator: std.mem.Allocator,
    input: ?toolkit.TextInput = null,
    editing: bool = false,

    pub fn deinit(self: *FilePane) void {
        if (self.input) |*input| input.deinit();
    }
    fn syncInput(self: *FilePane) !void {
        const filter = self.pane.view().filter;
        if (!filter.active) {
            if (self.input) |*input| input.deinit();
            self.input = null;
            self.editing = false;
        } else if (self.input == null) {
            self.input = try toolkit.TextInput.init(self.allocator, filter.query);
            self.input.?.select_all = false;
            self.editing = true;
        }
    }
    pub fn layout(self: *FilePane, _: *toolkit.Widget, size: toolkit.Size) void {
        self.pane.setViewportRows(visibleRows(size.height) -| @intFromBool(self.pane.view().filter.active));
    }
    pub fn paint(self: *FilePane, node: *toolkit.Widget, painter: ui.Painter) !void {
        try paintListing(painter, self.pane.view(), node.focused());
        if (self.pane.view().filter.active) if (self.input) |*input| {
            if (painter.rect.height < 3 or painter.rect.width < 3) return;
            const row = painter.child(.{ .x = 1, .y = painter.rect.height - 2, .width = painter.rect.width - 2, .height = 1 });
            row.label(0, 0, "/", theme.accent);
            const previous_cursor = painter.frame.cursor;
            try input.paint(row.child(.{ .x = 1, .y = 0, .width = row.rect.width -| 1, .height = 1 }), theme.base);
            if (!self.editing or !node.focused()) painter.frame.cursor = previous_cursor;
        };
    }
    pub fn event(self: *FilePane, _: *toolkit.Widget, ev: *const toolkit.Event) !bool {
        try self.syncInput();
        if (self.input) |*input| {
            if (self.editing) {
                if (ev.kind == .key and (ev.key == .tab or (ev.key == .text and ev.len == 1 and ev.bytes[0] == toolkit.input.control('l')))) return false;
                switch (try input.event(ev)) {
                    .cancel => {
                        try self.pane.closeFilter();
                        try self.syncInput();
                    },
                    .accept => self.editing = false,
                    .editing => try self.pane.setFilter(input.text()),
                }
                return true;
            }
            if (ev.kind == .key and ev.key == .escape) {
                try self.pane.closeFilter();
                try self.syncInput();
                return true;
            }
        }
        if (ev.kind == .key and ev.key == .text and ev.len == 1 and ev.bytes[0] == '/') {
            try self.pane.setFilter(self.pane.view().filter.query);
            try self.syncInput();
            self.editing = true;
            return true;
        }
        return handleEvent(self.pane, ev);
    }
};

// These descriptions own both dispatch and help. Shift marks movement only for
// the keys that opt in; shifted pages must bubble to terminal history commands.
const Action = union(enum) {
    move: Pane.Movement,
    enter,
    parent,
    mark,
    mark_advance,
    cancel,
    listing: Pane.ListingChange,
};
const Binding = struct {
    key: toolkit.input.Key = .text,
    byte: ?u8 = null,
    text: []const u8,
    action: Action,
    shift: enum { ignore, mark, bubble } = .ignore,
    ctrl: ?bool = null,

    fn matches(self: Binding, ev: *const toolkit.Event) bool {
        // Page keys distinguish Ctrl navigation from ordinary movement;
        // shifted pages continue to bubble to terminal history.
        return ev.key == self.key and !(ev.shift and self.shift == .bubble) and
            (if (self.ctrl) |ctrl| ev.ctrl == ctrl else true) and
            (if (self.byte) |byte| ev.len == 1 and ev.bytes[0] == byte else true);
    }
};
const Description = struct { help: []const u8, bindings: []const Binding };
const descriptions = [_]Description{
    .{ .help = "Move cursor", .bindings = &.{
        .{ .key = .up, .text = "Up", .action = .{ .move = .{ .by = -1 } }, .shift = .mark },
        .{ .key = .down, .text = "Down", .action = .{ .move = .{ .by = 1 } }, .shift = .mark },
        .{ .key = .home, .text = "Home", .action = .{ .move = .first }, .shift = .mark },
        .{ .key = .end, .text = "End", .action = .{ .move = .last }, .shift = .mark },
        .{ .key = .page_up, .text = "PgUp", .action = .{ .move = .page_up }, .shift = .bubble, .ctrl = false },
        .{ .key = .page_down, .text = "PgDn", .action = .{ .move = .page_down }, .shift = .bubble, .ctrl = false },
    } },
    .{ .help = "Enter directory", .bindings = &.{
        .{ .key = .enter, .text = "Enter", .action = .enter },
        .{ .key = .right, .text = "Right", .action = .enter },
        .{ .key = .page_down, .text = "Ctrl+PgDn", .action = .enter, .shift = .bubble, .ctrl = true },
    } },
    .{ .help = "Parent directory", .bindings = &.{
        .{ .key = .backspace, .text = "Backspace", .action = .parent },
        .{ .key = .left, .text = "Left", .action = .parent },
        .{ .key = .page_up, .text = "Ctrl+PgUp", .action = .parent, .shift = .bubble, .ctrl = true },
    } },
    .{ .help = "Toggle mark", .bindings = &.{.{ .byte = ' ', .text = "Space", .action = .mark }} },
    .{ .help = "Mark and advance", .bindings = &.{.{ .key = .insert, .text = "Insert", .action = .mark_advance }} },
    .{ .help = "Cancel read / clear error", .bindings = &.{.{ .key = .escape, .text = "Esc", .action = .cancel }} },
    .{ .help = "Toggle hidden files", .bindings = &.{.{ .byte = '.', .text = ".", .action = .{ .listing = .toggle_hidden } }} },
    .{ .help = "Sort field", .bindings = &.{.{ .byte = 's', .text = "s", .action = .{ .listing = .cycle_sort } }} },
    .{ .help = "Reverse order", .bindings = &.{.{ .byte = 'r', .text = "r", .action = .{ .listing = .reverse } }} },
};

/// Process-lifetime help generated from the same aliases and modifier policy
/// used by dispatch. Consumers only lay out these lines; they own no bindings.
pub const help_lines = blk: {
    var lines: [descriptions.len + 1][]const u8 = undefined;
    var shifted: []const u8 = "";
    for (descriptions, 0..) |description, i| {
        var keys: []const u8 = "";
        for (description.bindings, 0..) |binding, j| {
            keys = keys ++ (if (j == 0) "" else "/") ++ binding.text;
            if (binding.shift == .mark)
                shifted = shifted ++ (if (shifted.len == 0) "Shift+" else "/") ++ binding.text;
        }
        lines[i] = keys ++ "  " ++ description.help;
    }
    lines[descriptions.len] = shifted ++ "  Toggle marks while moving";
    break :blk lines;
};

/// Pane-local bindings. Unhandled commands bubble to the application widget.
pub fn handleEvent(pane: *Pane, ev: *const toolkit.Event) !bool {
    if (ev.kind != .key) return false;
    // Let Ctrl+J bubble only after the focused filter input declines it.
    if (@import("../commands.zig").resolve(ev) == .visibility_terminal) return false;
    for (descriptions) |description| for (description.bindings) |binding| {
        if (!binding.matches(ev)) continue;
        switch (binding.action) {
            .move => |movement| pane.move(movement, ev.shift and binding.shift == .mark),
            .enter => try pane.enter(),
            .parent => try pane.parent(),
            .mark => pane.toggleSelection(),
            .mark_advance => {
                pane.toggleSelection();
                pane.move(.{ .by = 1 }, false);
            },
            .cancel => pane.cancelNavigation(),
            .listing => |change| try pane.changeListing(change),
        }
        return true;
    };
    return false;
}

// Borders plus the column header and status row.
const reserved_rows = 4;
const min_size_columns = 26;
const min_date_columns = 55;
const size_column_width = 10;
const date_column_width = 11; // YYYY-MM-DD plus a separator.
const metadata_gap = 1;
const name_prefix_width = 2; // Mark and entry-kind indicators.
const kibibyte = 1024;
const last_supported_timestamp = 253402300799; // 9999-12-31 23:59:59 UTC.

pub fn visibleRows(height: usize) usize {
    return height -| reserved_rows;
}

fn paintListing(painter: ui.Painter, view: Pane.View, focused: bool) !void {
    const base = theme.base;
    const accent = theme.accent;
    const muted = theme.muted;
    const allocator = painter.frame.arena.allocator();
    const w = painter.rect.width;
    const h = painter.rect.height;
    painter.border(if (focused) accent else base);
    const inside = painter.inset(1);
    const title = try std.fmt.allocPrint(allocator, " {s} ", .{view.path});
    try painter.child(.{ .x = 2, .y = 0, .width = w -| 4, .height = 1 }).textEnd(title, if (focused) accent else base);
    if (h < 5 or w < 8) return;
    const width = inside.rect.width;
    const with_size = width >= min_size_columns;
    const with_date = width >= min_date_columns;
    const size_x = if (with_date) width - (size_column_width + metadata_gap + date_column_width) else width -| size_column_width;
    const name_width = if (with_size) size_x -| (name_prefix_width + metadata_gap) else width -| name_prefix_width;
    inside.label(2, 0, "Name", muted);
    if (with_size) inside.label(size_x, 0, "Size", muted);
    if (with_date) inside.label(width - date_column_width, 0, "Modified", muted);
    const rows = visibleRows(h) -| @intFromBool(view.filter.active);
    for (0..rows) |row_index| {
        const item_row = view.row(row_index) orelse break;
        const entry = item_row.entry;
        var style = base;
        if (entry) |item| {
            if (item.directory) style.fg = accent.fg;
            if (item.kind == .sym_link) style.fg = theme.symlink;
            if (item_row.marked) style.fg = theme.marked;
        }
        if (item_row.focused) {
            style.bg = if (focused) theme.selection else theme.inactive_selection;
            style.bold = focused;
        }
        const row = inside.child(.{ .x = 0, .y = row_index + 1, .width = width, .height = 1 });
        row.fill(style);
        if (entry) |item| {
            row.label(0, 0, if (item_row.marked) "*" else " ", style);
            row.label(1, 0, if (item.kind == .sym_link) "@" else if (item.directory) "/" else " ", style);
            try row.child(.{ .x = 2, .y = 0, .width = name_width, .height = 1 }).text(0, 0, item.name, style);
            if (with_size) {
                const size = if (item.directory) "<DIR>" else if (item.size) |bytes| try formatSize(allocator, bytes) else "?";
                row.label(size_x, 0, size, style);
            }
            if (with_date) {
                const date = if (item.modified) |seconds| try formatDate(allocator, seconds) else "?";
                row.label(width - date_column_width, 0, date, style);
            }
        } else {
            row.label(1, 0, if (item_row.kind == .current) "/." else "/..", style);
            if (with_size) row.label(size_x, 0, if (item_row.kind == .current) "<DIR>" else "<UP>", style);
        }
    }
    const status = inside.child(.{ .x = 0, .y = h - 3 - @intFromBool(view.filter.active), .width = width, .height = 1 });
    if (view.filter.failure) |err| {
        status.label(0, 0, if (err == error.FzfNotFound) "Install fzf in PATH; Esc clears filter" else "fzf failed; check installation; Esc clears", theme.failure);
        return;
    }
    if (view.filter.loading) {
        status.label(0, 0, "Filtering...", accent);
        return;
    }
    if (view.filter.active and view.entries.len == 0 and view.status == .ready) {
        status.label(0, 0, "No matches", theme.muted);
        return;
    }
    switch (view.status) {
        .failed => |failure| try status.text(0, 0, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ errorText(failure.err), failure.path orelse "" }), theme.failure),
        .loading => status.label(0, 0, "Loading...", accent),
        .ready => {
            const options = view.options;
            const summary = try std.fmt.allocPrint(allocator, "{d} items | {d} marked | {s}{s}{s}", .{
                view.entries.len,                         view.marked_count,                       @tagName(options.sort),
                if (options.reverse) " desc" else " asc", if (options.hidden) " | hidden" else "",
            });
            status.label(0, 0, summary, muted);
        },
    }
}

fn errorText(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "Not found",
        error.NotDir => "Not a directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.SymLinkLoop => "Symlink loop",
        error.OutOfMemory => "Not enough memory",
        error.ConcurrencyUnavailable => "Directory reader unavailable",
        else => "Cannot read directory",
    };
}

fn formatSize(allocator: std.mem.Allocator, bytes: u64) ![]const u8 {
    if (bytes < kibibyte) return std.fmt.allocPrint(allocator, "{d} B", .{bytes});
    const units = [_][]const u8{ "K", "M", "G", "T", "P", "E" };
    var value = bytes;
    var unit: usize = 0;
    while (value >= kibibyte * kibibyte and unit + 1 < units.len) : (unit += 1) value /= kibibyte;
    return std.fmt.allocPrint(allocator, "{d}.{d}{s}", .{ value / kibibyte, (value % kibibyte) * 10 / kibibyte, units[unit] });
}
fn formatDate(allocator: std.mem.Allocator, seconds: i64) ![]const u8 {
    if (seconds < 0 or seconds > last_supported_timestamp) return allocator.dupe(u8, "--");
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(seconds) };
    const day = epoch.getEpochDay();
    const year = day.calculateYearDay();
    const month = year.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year.year, month.month.numeric(), month.day_index + 1 });
}
