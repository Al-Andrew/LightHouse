const std = @import("std");
const ui = @import("lighthouse-ui").screen;
const PathInput = @import("lighthouse-ui").TextInput;
const Pane = @import("../../core/pane.zig").Pane;
const operations = @import("../../core/operations.zig");
const dialog = @import("lighthouse-ui").dialog;
const commands = @import("../commands.zig");
const theme = @import("../theme.zig");
const path_dialog_width = 84;
const job_dialog_width = 90;
const help_dialog_width = 66;
const delete_preview_items = 4;
const Size = @import("lighthouse-ui").Size;

pub fn editorSize(action: ?operations.Kind) Size {
    return .{ .width = path_dialog_width, .height = if (action != null) 6 else 4 };
}

pub fn deleteSize(job: *const operations.Job) Size {
    const shown: usize = @min(delete_preview_items, job.request().sources.len);
    return .{ .width = job_dialog_width, .height = shown + 6 };
}

pub const operation_size: Size = .{ .width = job_dialog_width, .height = 8 };
pub const help_size: Size = .{ .width = help_dialog_width, .height = help_lines.len + commands.help_groups.len + 3 };

pub fn paintPathInput(painter: ui.Painter, editor: *const PathInput, action: ?operations.Kind, pane: ?*const Pane) !void {
    const style = theme.dialog;
    const size = editorSize(action);
    const box = dialog.beginIn(painter, size.width, size.height, style);
    const width = box.rect.width;
    const height = box.rect.height;
    if (width < 5 or height < 3) return;
    box.child(.{ .x = 2, .y = 0, .width = width - 4, .height = 1 }).label(0, 0, if (action) |kind| kind.title() else " Go to directory ", style);
    const field = box.child(.{ .x = 1, .y = 1, .width = width - 2, .height = 1 });
    try editor.paint(field, .{ .bg = if (editor.select_all) theme.selection else theme.base.bg });
    const allocator = painter.frame.arena.allocator();
    if (action) |kind| {
        if (height > 3) if (pane) |p| {
            var sources = p.sources();
            const summary = if (kind == .mkdir) "Create one folder; its parent must exist." else if (p.view().marked_count > 0)
                try std.fmt.allocPrint(allocator, "{d} marked items. Existing destinations are refused.", .{sources.count})
            else if (sources.next()) |name|
                try std.fmt.allocPrint(allocator, "Source: {s}", .{name})
            else
                "";
            try box.child(.{ .x = 1, .y = 2, .width = width - 2, .height = 1 }).text(0, 0, summary, style);
        };
        if (height > 4) box.child(.{ .x = 1, .y = 3, .width = width - 2, .height = 1 }).label(0, 0, "Enter start  |  Esc cancel  |  Ctrl+U clear", style);
        if (height > 5 and kind != .mkdir) box.child(.{ .x = 1, .y = 4, .width = width - 2, .height = 1 }).label(0, 0, "Existing folder: place inside. New path: rename destination.", style);
    } else if (height > 3) box.child(.{ .x = 1, .y = 2, .width = width - 2, .height = 1 }).label(0, 0, "Enter open  |  Esc cancel  |  Ctrl+U clear", style);
}

pub fn paintDeleteConfirmation(painter: ui.Painter, job: *const operations.Job) !void {
    const request = job.request();
    const shown: usize = @min(delete_preview_items, request.sources.len);
    const style = theme.destructive_dialog;
    // Two warning rows, source previews, overflow hint, controls, and borders.
    const size = deleteSize(job);
    const box = dialog.beginIn(painter, size.width, size.height, style);
    const inside = box.inset(1);
    const summary = try std.fmt.allocPrint(painter.frame.arena.allocator(), "Permanently delete {d} item(s)?", .{request.sources.len});
    inside.label(0, 0, summary, style);
    inside.label(0, 1, "Folders include all contents. This cannot be undone.", style);
    for (request.sources[0..shown], 0..) |source, i| try inside.child(.{ .x = 0, .y = i + 2, .width = inside.rect.width, .height = 1 }).textEnd(source, style);
    if (request.sources.len > shown) inside.label(0, shown + 2, "...and the other marked entries", style);
    inside.label(0, shown + 3, "Enter delete  |  Esc / n cancel", style);
}

pub fn paintOperation(painter: ui.Painter, job: *const operations.Job) !void {
    const style = theme.dialog;
    const box = dialog.beginIn(painter, operation_size.width, operation_size.height, style);
    const inside = box.inset(1);
    const allocator = painter.frame.arena.allocator();
    const request = job.request();
    const status = job.status();
    const progress = status.progress();
    inside.label(0, 0, request.kind.title(), style);
    const summary = try std.fmt.allocPrint(allocator, "{d}/{d} items complete | {d} {s}", .{
        progress.completed,
        if (request.kind == .mkdir) @as(usize, 1) else request.sources.len,
        if (request.kind == .delete) progress.removed else progress.bytes,
        if (request.kind == .delete) "entries deleted" else "bytes copied",
    });
    inside.label(0, 1, summary, style);
    if (status == .finished) {
        const result = status.finished;
        inside.label(0, 2, if (result.failure) |failure| operationError(failure.err) else "Completed", style);
        if (result.failure) |failure| {
            if (failure.path) |path| try inside.text(0, 3, path, style);
            inside.label(0, 4, if (request.kind == .copy) "Completed copies remain; unfinished folders may be partial." else if (request.kind == .delete) "Deleted entries stay deleted; folders may be partly removed." else "Completed actions remain; remaining items were not processed.", style);
        }
        inside.label(0, 5, "Enter / Esc close  |  Ctrl+G shell", style);
    } else {
        inside.label(0, 2, if (status == .canceling) "Canceling..." else if (request.kind == .delete) "Deleting..." else "Working... Existing destinations are never replaced.", style);
        inside.label(0, 5, "Esc cancel  |  Ctrl+G shell  |  F10 quit", style);
    }
}

fn operationError(err: anyerror) []const u8 {
    return switch (err) {
        error.PathAlreadyExists => "Destination already exists; nothing overwritten.",
        error.DestinationInsideSource => "Destination is inside the source directory.",
        error.DestinationMustBeDirectory => "Destination must be an existing directory.",
        error.CrossDevice => "Moves between filesystems are not supported yet; source retained.",
        error.Canceled => "Canceled",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.FileNotFound => "Not found",
        error.SourceChanged => "Source changed during copying; file was not published.",
        error.UnsupportedFileType => "Unsupported file type (only files, folders and symlinks can be copied).",
        else => @errorName(err),
    };
}

const help_lines = [_][]const u8{
    "Arrows / PgUp / PgDn / Home / End   Move cursor",
    "Enter / Right                      Enter directory",
    "Backspace / Left                   Parent directory",
    "Space / Insert                     Mark / mark and advance",
    "Shift+Up/Down/Home/End               Toggle marks while moving",
    "Esc                                Cancel read / clear error",
    ".                                  Toggle hidden files",
    "s / r                              Sort field / reverse order",
};

pub fn paintHelp(painter: ui.Painter) void {
    const style = theme.dialog;
    const box = dialog.beginIn(painter, help_size.width, help_size.height, style);
    const inside = box.inset(1);
    for (help_lines, 0..) |line, i| inside.label(0, i, line, style);
    for (commands.help_groups, 0..) |group, row| {
        var x: usize = 0;
        for (group, 0..) |id, i| {
            const description = commands.describe(id);
            if (i > 0) {
                inside.label(x, help_lines.len + row, " | ", style);
                x += 3;
            }
            for (description.bindings, 0..) |binding, j| {
                if (j > 0) {
                    inside.label(x, help_lines.len + row, "/", style);
                    x += 1;
                }
                inside.label(x, help_lines.len + row, binding.text, style);
                x += binding.text.len;
            }
            inside.label(x, help_lines.len + row, " ", style);
            x += 1;
            inside.label(x, help_lines.len + row, description.help, style);
            x += description.help.len;
        }
    }
    inside.label(0, help_lines.len + commands.help_groups.len, "Any key closes help. Shell keys pass through when focused.", style);
}

test "file action dialogs fit tiny windows with Unicode input" {
    const allocator = std.testing.allocator;
    var frame = ui.Frame.init(allocator);
    defer frame.deinit();
    var editor = try PathInput.init(allocator, "/dest/界");
    defer editor.deinit();
    const job = try operations.Job.create(std.testing.io, allocator, .copy, "/source", &.{"file"}, "/target");
    defer job.destroy();
    for (1..95) |cols| for (1..10) |rows| {
        try frame.begin(cols, rows);
        try paintPathInput(frame.painter(.{ .x = 0, .y = 0, .width = frame.cols, .height = frame.rows }), &editor, .copy, null);
        if (frame.cursor) |cursor| try std.testing.expect(cursor.x < cols and cursor.y < rows);
        try paintOperation(frame.painter(.{ .x = 0, .y = 0, .width = frame.cols, .height = frame.rows }), job);
        try std.testing.expect(frame.cursor == null);
    };
}

test "delete confirmation handles multiple selections" {
    const allocator = std.testing.allocator;
    var frame = ui.Frame.init(allocator);
    defer frame.deinit();
    const names = [_][]const u8{ "a", "b", "c", "d", "e" };
    for (2..names.len + 1) |count| {
        const job = try operations.Job.create(std.testing.io, allocator, .delete, "/unused", names[0..count], "");
        defer job.destroy();
        try frame.begin(100, 30);
        try paintDeleteConfirmation(frame.painter(.{ .x = 0, .y = 0, .width = frame.cols, .height = frame.rows }), job);
    }
}
