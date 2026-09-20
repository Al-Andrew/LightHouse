const std = @import("std");
const ui = @import("lighthouse-ui").screen;
const PathInput = @import("lighthouse-ui").TextInput;
const Pane = @import("../../core/pane.zig").Pane;
const operations = @import("../../core/operations.zig");
const dialog = @import("lighthouse-ui").dialog;
const help_lines = @import("file_pane.zig").help_lines;
const commands = @import("../commands.zig");
const theme = @import("../theme.zig");
const path_dialog_width = 84;
const job_dialog_width = 90;
const help_dialog_width = 66;
const delete_preview_items = 4;
const Rejection = @import("../controller.zig").Rejection;
const Size = @import("lighthouse-ui").Size;

pub fn editorSize(action: ?operations.Kind, rejection: ?Rejection) Size {
    const transfer = action == .copy or action == .move;
    return .{ .width = path_dialog_width, .height = @as(usize, if (transfer) 12 else if (action != null) 6 else 4) + @intFromBool(rejection != null) };
}

pub fn deleteSize(job: *const operations.Job, rejection: ?Rejection) Size {
    const shown: usize = @min(delete_preview_items, job.request().sources.len);
    return .{ .width = job_dialog_width, .height = shown + 6 + @intFromBool(rejection != null) };
}

pub const operation_size: Size = .{ .width = job_dialog_width, .height = 10 };

pub fn operationSize(job: *const operations.Job) Size {
    return if (job.status() == .waiting) .{ .width = job_dialog_width, .height = 22 } else operation_size;
}
pub const help_size: Size = .{ .width = help_dialog_width, .height = help_lines.len + commands.help_groups.len + 3 };

pub fn paintPathInput(painter: ui.Painter, editor: *const PathInput, action: ?operations.Kind, pane: ?*const Pane, rejection: ?Rejection) !void {
    if (action == .copy or action == .move) return paintTransferInput(painter, editor, action.?, pane, rejection);
    const style = theme.dialog;
    const size = editorSize(action, rejection);
    const box = dialog.beginIn(painter, size.width, size.height, style);
    const width = box.rect.width;
    const height = box.rect.height;
    if (width < 5 or height < 3) return;
    box.child(.{ .x = 2, .y = 0, .width = width - 4, .height = 1 }).label(0, 0, if (action) |kind| kind.title() else " Go to directory ", style);
    const field = box.child(.{ .x = 1, .y = 1, .width = width - 2, .height = 1 });
    try editor.paint(field, .{ .bg = if (editor.select_all) theme.selection else theme.base.bg });
    if (rejection) |reason| box.child(.{ .x = 1, .y = size.height - 2, .width = width - 2, .height = 1 }).label(0, 0, reason.message(), style);
    const allocator = painter.frame.arena.allocator();
    if (action) |kind| {
        if (height > 3) if (pane) |p| {
            var sources = p.sources();
            const summary = if (kind == .mkdir) "Create one folder; its parent must exist." else if (p.view().marked_count > 0)
                try std.fmt.allocPrint(allocator, "{d} marked items. Conflicts ask for a decision.", .{sources.count})
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

const Control = struct {
    label: []const u8,
    mnemonic: bool = false,

    fn width(self: Control) usize {
        return (std.unicode.utf8CountCodepoints(self.label) catch unreachable) + 2;
    }
};

fn controlRows(width: usize, controls: []const Control) usize {
    var rows: usize = 1;
    var x: usize = 0;
    for (controls) |control| {
        if (x > 0 and x + control.width() > width) {
            rows += 1;
            x = 0;
        }
        x += control.width() + 3;
    }
    return rows;
}

fn paintControls(painter: ui.Painter, controls: []const Control) !void {
    var x: usize = 0;
    var y: usize = 0;
    for (controls) |control| {
        if (x > 0 and x + control.width() > painter.rect.width) {
            y += 1;
            x = 0;
        }
        const button = painter.child(.{ .x = x, .y = y, .width = control.width(), .height = 1 });
        button.fill(theme.dialog_control);
        try button.text(1, 0, control.label, theme.dialog_control);
        if (control.mnemonic) {
            var mnemonic = theme.dialog_control;
            mnemonic.underline = true;
            button.label(1, 0, control.label[0..1], mnemonic);
        }
        x += control.width() + 3;
    }
}

fn contentRow(inside: ui.Painter, y: usize) ui.Painter {
    return inside.child(.{ .x = 0, .y = y, .width = inside.rect.width, .height = 1 });
}

fn paddedContent(box: ui.Painter) ui.Painter {
    const padding: usize = if (box.rect.width >= 60) 3 else 1;
    return box.child(.{ .x = padding, .y = 1, .width = box.rect.width -| (2 * padding), .height = box.rect.height -| 2 });
}

fn paintTransferInput(painter: ui.Painter, editor: *const PathInput, kind: operations.Kind, pane: ?*const Pane, rejection: ?Rejection) !void {
    const size = editorSize(kind, rejection);
    const box = dialog.beginIn(painter, size.width, size.height, theme.dialog);
    const inside = paddedContent(box);
    const controls = [_]Control{ .{ .label = "Enter — Start" }, .{ .label = "Esc — Cancel" }, .{ .label = "Ctrl+U — Clear" } };
    const footer_rows = if (inside.rect.height >= 6) controlRows(inside.rect.width, &controls) else 0;
    const footer_y = inside.rect.height -| footer_rows;
    const content = inside.child(.{ .x = 0, .y = 0, .width = inside.rect.width, .height = footer_y });
    const spacious = content.rect.height >= @as(usize, 7) + @intFromBool(rejection != null);
    var heading = theme.dialog;
    heading.bold = true;
    const validation_rows: usize = @intFromBool(rejection != null and content.rect.height >= 2);
    var row: usize = 0;
    if (content.rect.height >= 3 + validation_rows) {
        content.label(0, row, kind.title(), heading);
        row += if (spacious) @as(usize, 2) else 1;
    }
    if (content.rect.height >= 4 + validation_rows) {
        if (pane) |p| {
            var sources = p.sources();
            const summary = if (p.view().marked_count > 0)
                try std.fmt.allocPrint(painter.frame.arena.allocator(), "Sources: {d} marked items", .{sources.count})
            else if (sources.next()) |name|
                try std.fmt.allocPrint(painter.frame.arena.allocator(), "Source: {s}", .{name})
            else
                "Source: no file-action sources";
            try contentRow(content, row).text(0, 0, summary, theme.dialog);
        }
        row += if (spacious) @as(usize, 2) else 1;
    }
    if (content.rect.height >= 2 + validation_rows) {
        content.label(0, row, "Destination path", heading);
        row += 1;
    }
    try editor.paint(contentRow(content, row), .{ .bg = if (editor.select_all) theme.selection else theme.base.bg });
    if (rejection) |reason| {
        var failure = theme.failure;
        failure.bg = theme.dialog.bg;
        contentRow(content, row + 1).label(0, 0, reason.message(), failure);
    }
    try paintControls(inside.child(.{ .x = 0, .y = footer_y, .width = inside.rect.width, .height = footer_rows }), &controls);
}

pub fn paintDeleteConfirmation(painter: ui.Painter, job: *const operations.Job, rejection: ?Rejection) !void {
    const request = job.request();
    const shown: usize = @min(delete_preview_items, request.sources.len);
    const style = theme.destructive_dialog;
    // Two warning rows, source previews, overflow hint, controls, and borders.
    const size = deleteSize(job, rejection);
    const box = dialog.beginIn(painter, size.width, size.height, style);
    const inside = box.inset(1);
    const summary = try std.fmt.allocPrint(painter.frame.arena.allocator(), "Permanently delete {d} item(s)?", .{request.sources.len});
    inside.label(0, 0, summary, style);
    inside.label(0, 1, "Folders include all contents. This cannot be undone.", style);
    for (request.sources[0..shown], 0..) |source, i| try inside.child(.{ .x = 0, .y = i + 2, .width = inside.rect.width, .height = 1 }).textEnd(source, style);
    if (request.sources.len > shown) inside.label(0, shown + 2, "...and the other marked entries", style);
    inside.label(0, shown + 3, "Enter delete  |  Esc / n cancel", style);
    if (rejection != null) inside.label(0, shown + 4, "Delete unavailable. Retry or press Esc / n to cancel.", style);
}

pub fn paintOperation(painter: ui.Painter, job: *const operations.Job) !void {
    if (job.status() == .waiting) return paintProblem(painter, job);
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
        inside.label(0, 2, if (result.failure) |failure| operationError(failure.err) else if (progress.skipped > 0 or progress.errors > 0 or progress.incomplete > 0) "Partial" else "Completed", style);
        if (result.failure) |failure| {
            if (failure.path) |path| try inside.text(0, 3, path, style);
            inside.label(0, 4, if (request.kind == .copy) "Completed copies remain; unfinished folders may be partial." else if (request.kind == .delete) "Deleted entries stay deleted; folders may be partly removed." else "Completed actions remain; remaining items were not processed.", style);
        }
        inside.label(0, 5, "Enter / Esc close", style);
        const details = try std.fmt.allocPrint(allocator, "{d} transferred | {d} skipped | {d} errors | {d} incomplete folders", .{ progress.transferred, progress.skipped, progress.errors, progress.incomplete });
        inside.label(0, 6, details, style);
    } else {
        inside.label(0, 2, if (status == .canceling) "Canceling..." else if (request.kind == .delete) "Deleting..." else "Working... Completed actions are retained.", style);
        inside.label(0, 5, "Esc cancel  |  F10 quit", style);
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
        try paintPathInput(frame.painter(.{ .x = 0, .y = 0, .width = frame.cols, .height = frame.rows }), &editor, .copy, null, .invalid_location);
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
        try paintDeleteConfirmation(frame.painter(.{ .x = 0, .y = 0, .width = frame.cols, .height = frame.rows }), job, .unsupported_operation);
    }
}

const conflict_controls = [_]Control{ .{ .label = "Overwrite", .mnemonic = true }, .{ .label = "Skip", .mnemonic = true }, .{ .label = "Cancel job (Esc)", .mnemonic = true }, .{ .label = "F10 Quit" } };
const error_controls = [_]Control{ .{ .label = "Retry", .mnemonic = true }, .{ .label = "Skip", .mnemonic = true }, .{ .label = "Cancel job (Esc)", .mnemonic = true }, .{ .label = "F10 Quit" } };
const mismatch_controls = [_]Control{ .{ .label = "Skip", .mnemonic = true }, .{ .label = "Cancel job (Esc)", .mnemonic = true }, .{ .label = "F10 Quit" } };

const ProblemLayout = struct {
    inside: ui.Painter,
    body: ui.Painter,
    policy_y: usize,
    footer_y: usize,
    controls: []const Control,

    fn init(painter: ui.Painter, job: *const operations.Job) ProblemLayout {
        const size = operationSize(job);
        const box = painter.child(@import("lighthouse-ui").layout.centered(
            .{ .width = painter.rect.width, .height = painter.rect.height },
            size,
        ));
        const inside = paddedContent(box);
        const prompt = job.status().waiting.prompt;
        const controls: []const Control = if (prompt.err != null) &error_controls else if (prompt.conflict == .mismatch) &mismatch_controls else &conflict_controls;
        const footer_rows = controlRows(inside.rect.width, controls);
        // Reserve the footer first; shorter windows drop optional detail rows.
        const footer_y = inside.rect.height -| (footer_rows + 1);
        const policy_y = footer_y -| 3;
        return .{
            .inside = inside,
            .body = inside.child(.{ .x = 0, .y = 0, .width = inside.rect.width, .height = policy_y }),
            .policy_y = policy_y,
            .footer_y = footer_y,
            .controls = controls,
        };
    }
};

fn paintProblem(painter: ui.Painter, job: *const operations.Job) !void {
    const size = operationSize(job);
    _ = dialog.beginIn(painter, size.width, size.height, theme.problem_dialog);
    const layout = ProblemLayout.init(painter, job);
    const content = layout.body;
    const prompt = job.status().waiting.prompt;
    const progress = job.status().progress();
    const request = job.request();
    const allocator = painter.frame.arena.allocator();
    const spacious = content.rect.height >= 12;
    var row: usize = 0;
    if (content.rect.height >= 2) {
        content.label(0, row, request.kind.title(), theme.problem_heading);
        row += 1;
    }
    if (content.rect.height >= 7) {
        const summary = try std.fmt.allocPrint(allocator, "{d}/{d} items complete | {d} bytes copied", .{ progress.completed, request.sources.len, progress.bytes });
        content.label(0, row, summary, theme.problem_dialog);
        row += if (spacious) @as(usize, 2) else 1;
    }
    const heading = if (prompt.err) |err| operationError(err) else if (prompt.conflict == .mismatch) "Type mismatch" else "Destination conflict";
    contentRow(content, row).fill(theme.problem_heading);
    content.label(0, row, heading, theme.problem_heading);
    row += if (spacious) @as(usize, 2) else 1;
    const inline_paths = content.rect.height < 7;
    row = try paintProblemPath(content, row, "Source path", prompt.source, inline_paths);
    if (spacious) row += 1;
    _ = try paintProblemPath(content, row, "Destination path", prompt.destination, inline_paths);
    const footer = layout.inside.child(.{ .x = 0, .y = layout.footer_y, .width = layout.inside.rect.width, .height = layout.inside.rect.height -| layout.footer_y });
    try paintControls(footer, layout.controls);
    const blocked_y = controlRows(layout.inside.rect.width, layout.controls);
    footer.label(0, blocked_y, "Terminal input blocked", theme.problem_dialog);
}

fn paintProblemPath(content: ui.Painter, row: usize, label: []const u8, path: []const u8, inline_value: bool) !usize {
    if (path.len == 0) return row;
    const rows: usize = if (inline_value) 1 else 2;
    if (row + rows > content.rect.height) return row;
    content.label(0, row, label, theme.problem_dialog);
    if (inline_value) {
        content.label(label.len, row, ":", theme.problem_dialog);
        try content.child(.{ .x = label.len + 2, .y = row, .width = content.rect.width -| (label.len + 2), .height = 1 }).textEnd(path, theme.problem_path);
    } else {
        try contentRow(content, row + 1).textEnd(path, theme.problem_path);
    }
    return row + rows;
}

pub fn paintDecisionPolicy(painter: ui.Painter, job: *const operations.Job, checked: bool) void {
    if (job.status() != .waiting) return;
    const layout = ProblemLayout.init(painter, job);
    const policy = layout.inside.child(.{ .x = 0, .y = layout.policy_y, .width = layout.inside.rect.width, .height = layout.footer_y -| layout.policy_y });
    policy.label(0, 0, if (checked) "[x]" else "[ ]", theme.dialog_control);
    policy.label(4, 0, if (job.status().waiting.prompt.err != null) "Skip all errors of this kind" else "Apply to all matching conflicts", theme.problem_dialog);
    policy.label(0, 1, " Space ", theme.dialog_control);
    policy.label(8, 1, "Toggle", theme.problem_dialog);
}

fn renderedRow(frame: *const ui.Frame, needle: []const u8) ?usize {
    for (0..frame.rows) |y| {
        var row: std.ArrayList(u8) = .empty;
        defer row.deinit(std.testing.allocator);
        for (frame.cells[y * frame.cols ..][0..frame.cols]) |cell| {
            if (cell.width > 0) row.appendSlice(std.testing.allocator, cell.text) catch unreachable;
        }
        if (std.mem.indexOf(u8, row.items, needle) != null) return y;
    }
    return null;
}

test "copy and move editors separate destination input validation and shortcut footer" {
    var frame = ui.Frame.init(std.testing.allocator);
    defer frame.deinit();
    var editor = try PathInput.init(std.testing.allocator, "/destination/界/file");
    defer editor.deinit();
    for ([_]operations.Kind{ .copy, .move }) |kind| {
        for ([_]Size{ .{ .width = 100, .height = 30 }, .{ .width = 40, .height = 12 } }) |size| {
            try frame.begin(size.width, size.height);
            try paintPathInput(frame.painter(.{ .x = 0, .y = 0, .width = size.width, .height = size.height }), &editor, kind, null, .invalid_location);
            const label_row = renderedRow(&frame, "Destination path") orelse return error.MissingDestinationLabel;
            const input_row = renderedRow(&frame, "/destination/界/file") orelse return error.MissingInput;
            const error_row = renderedRow(&frame, "Location not recognized") orelse return error.MissingValidation;
            const footer_row = renderedRow(&frame, "Enter — Start") orelse return error.MissingStart;
            try std.testing.expect(label_row < input_row and input_row < error_row and error_row < footer_row);
            try std.testing.expect(renderedRow(&frame, "Esc — Cancel") != null);
            try std.testing.expect(renderedRow(&frame, "Ctrl+U — Clear") != null);
            try std.testing.expect(renderedRow(&frame, "Existing folder:") == null);
        }
    }
}

test "problem dialogs label paths highlight policy and underline valid decisions" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const base = buffer[0..try tmp.dir.realPath(io, &buffer)];
    try tmp.dir.createDir(io, "dest", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "source-界", .data = "new" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dest/source-界", .data = "old" });
    const job = try operations.Job.create(io, std.testing.allocator, .copy, base, &.{"source-界"}, "dest");
    defer job.destroy();
    try job.start();
    for (0..5000) |_| {
        if (job.status() == .waiting) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(job.status() == .waiting);
    var frame = ui.Frame.init(std.testing.allocator);
    defer frame.deinit();
    for ([_]Size{ .{ .width = 100, .height = 30 }, .{ .width = 40, .height = 16 }, .{ .width = 40, .height = 12 } }) |size| {
        for ([_]bool{ false, true }) |checked| {
            try frame.begin(size.width, size.height);
            const painter = frame.painter(.{ .x = 0, .y = 0, .width = size.width, .height = size.height });
            try paintOperation(painter, job);
            paintDecisionPolicy(painter, job, checked);
            try std.testing.expect(renderedRow(&frame, "Source path") != null);
            try std.testing.expect(renderedRow(&frame, "Destination path") != null);
            try std.testing.expect(renderedRow(&frame, "Destination conflict") != null);
            try std.testing.expect(renderedRow(&frame, if (checked) "[x] Apply to all matching conflicts" else "[ ] Apply to all matching conflicts") != null);
            try std.testing.expect(renderedRow(&frame, "Space") != null);
            try std.testing.expect(renderedRow(&frame, "Esc") != null);
            try std.testing.expect(renderedRow(&frame, "F10") != null);
            const problem_row = renderedRow(&frame, "Destination conflict").?;
            const problem_cell = frame.cells[problem_row * frame.cols + frame.cols / 2];
            try std.testing.expect(problem_cell.style.bg.r > problem_cell.style.bg.g);
            var underlined: std.ArrayList(u8) = .empty;
            defer underlined.deinit(std.testing.allocator);
            for (frame.cells) |cell| {
                if (cell.style.underline) try underlined.appendSlice(std.testing.allocator, cell.text);
            }
            try std.testing.expectEqualStrings("OSC", underlined.items);
        }
    }
}
