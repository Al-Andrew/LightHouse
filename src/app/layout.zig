const std = @import("std");
const ui = @import("lighthouse-ui").screen;
const platform = @import("../platform/linux.zig");

pub const Layout = struct {
    terminal: ui.Rect,
    panes_height: usize,
    compact: bool,

    const min_columns = 32;
    const min_rows = 10;
    const footer_rows = 1;
    const min_pane_rows = 5;
    const min_terminal_rows = 2;
    const terminal_height_divisor = 3;
    pub const max_adjustment = platform.Console.max_rows;

    pub fn calculate(size: platform.Size, adjustment: i32, zoom: bool) Layout {
        if (zoom or size.cols < min_columns or size.rows < min_rows) return .{
            .terminal = .{ .x = 0, .y = 0, .width = size.cols, .height = @max(1, size.rows -| footer_rows) },
            .panes_height = 0,
            .compact = true,
        };
        const height: usize = @intCast(std.math.clamp(@as(i32, size.rows / terminal_height_divisor) + adjustment, min_terminal_rows, @as(i32, size.rows) - min_pane_rows - footer_rows));
        const panes_height = size.rows - height - footer_rows;
        return .{
            .terminal = .{ .x = 0, .y = panes_height, .width = size.cols, .height = height },
            .panes_height = panes_height,
            .compact = false,
        };
    }
};

test "layout remains nonempty and inside every small terminal" {
    for (1..120) |cols| for (1..50) |rows| {
        for ([_]i32{ -Layout.max_adjustment, 0, Layout.max_adjustment }) |adjustment| {
            const layout = Layout.calculate(.{ .cols = @intCast(cols), .rows = @intCast(rows) }, adjustment, false);
            try std.testing.expect(layout.terminal.width > 0 and layout.terminal.height > 0);
            try std.testing.expect(layout.terminal.x + layout.terminal.width <= cols);
            try std.testing.expect(layout.terminal.y + layout.terminal.height <= rows);
        }
    };
}
