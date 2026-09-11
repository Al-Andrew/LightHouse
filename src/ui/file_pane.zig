//! Rendering only; directory I/O and navigation live in core/Pane.
const std = @import("std");
const ui = @import("screen.zig");
const theme = @import("theme.zig");
const Pane = @import("../core/pane.zig").Pane;

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

pub fn paint(painter: ui.Painter, pane: *Pane, focused: bool) !void {
    const base = theme.base;
    const accent = theme.accent;
    const muted = theme.muted;
    const allocator = painter.frame.arena.allocator();
    const w = painter.rect.width;
    const h = painter.rect.height;
    painter.border(if (focused) accent else base);
    const inside = painter.inset(1);
    const title = try std.fmt.allocPrint(allocator, " {s} ", .{pane.path()});
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
    const rows = visibleRows(h);
    pane.ensureVisible(rows);
    for (0..rows) |row_index| {
        const index = pane.scroll + row_index;
        if (index >= pane.count()) break;
        const parent = pane.hasParent() and index == 0;
        const entry = if (parent) null else &pane.entries()[index - @intFromBool(pane.hasParent())];
        var style = base;
        if (entry) |item| {
            if (item.directory) style.fg = accent.fg;
            if (item.kind == .sym_link) style.fg = theme.symlink;
            if (item.selected) style.fg = theme.marked;
        }
        if (index == pane.cursor) {
            style.bg = if (focused) theme.selection else theme.inactive_selection;
            style.bold = focused;
        }
        const row = inside.child(.{ .x = 0, .y = row_index + 1, .width = width, .height = 1 });
        row.fill(style);
        if (entry) |item| {
            row.label(0, 0, if (item.selected) "*" else " ", style);
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
            row.label(1, 0, "/..", style);
            if (with_size) row.label(size_x, 0, "<UP>", style);
        }
    }
    const status = inside.child(.{ .x = 0, .y = h - 3, .width = width, .height = 1 });
    if (pane.failure) |err| {
        try status.text(0, 0, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ errorText(err), pane.failed_path orelse "" }), theme.failure);
    } else if (pane.busy()) {
        status.label(0, 0, "Loading...", accent);
    } else {
        const options = if (pane.snapshot) |snapshot| snapshot.options else pane.options;
        const summary = try std.fmt.allocPrint(allocator, "{d} items | {d} marked | {s}{s}{s}", .{
            pane.entries().len,                       pane.selectedCount(),                    @tagName(options.sort),
            if (options.reverse) " desc" else " asc", if (options.hidden) " | hidden" else "",
        });
        status.label(0, 0, summary, muted);
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
