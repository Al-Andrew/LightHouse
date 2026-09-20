const std = @import("std");
const toolkit = @import("lighthouse-ui");
const ui = toolkit.screen;

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
    // Presentation allocation bounds, independent of the host platform.
    pub const max_size: toolkit.Size = .{ .width = 1000, .height = 500 };
    pub const max_adjustment: i32 = max_size.height;

    pub fn boundedSize(size: toolkit.Size) toolkit.Size {
        return .{
            .width = std.math.clamp(size.width, 1, max_size.width),
            .height = std.math.clamp(size.height, 1, max_size.height),
        };
    }

    pub fn forState(available: toolkit.Size, adjustment: i32, zoom: bool, visible: bool) Layout {
        if (visible) return calculate(available, adjustment, zoom);
        const size = boundedSize(available);
        return .{ .terminal = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, .panes_height = @max(1, size.height -| footer_rows), .compact = false };
    }

    pub fn calculate(available: toolkit.Size, adjustment: i32, zoom: bool) Layout {
        const size = boundedSize(available);
        if (zoom or size.width < min_columns or size.height < min_rows) return .{
            .terminal = .{ .x = 0, .y = 0, .width = size.width, .height = @max(1, size.height -| footer_rows) },
            .panes_height = 0,
            .compact = true,
        };
        const rows: i32 = @intCast(size.height);
        const requested_height = @divTrunc(rows, terminal_height_divisor) + std.math.clamp(adjustment, -max_adjustment, max_adjustment);
        const height: usize = @intCast(std.math.clamp(requested_height, min_terminal_rows, rows - min_pane_rows - footer_rows));
        const panes_height = size.height - height - footer_rows;
        return .{
            .terminal = .{ .x = 0, .y = panes_height, .width = size.width, .height = height },
            .panes_height = panes_height,
            .compact = false,
        };
    }
};

test "layout remains nonempty and inside every small terminal" {
    for (1..120) |cols| for (1..50) |rows| {
        for ([_]i32{ -Layout.max_adjustment, 0, Layout.max_adjustment }) |adjustment| {
            const layout = Layout.calculate(.{ .width = cols, .height = rows }, adjustment, false);
            try std.testing.expect(layout.terminal.width > 0 and layout.terminal.height > 0);
            try std.testing.expect(layout.terminal.x + layout.terminal.width <= cols);
            try std.testing.expect(layout.terminal.y + layout.terminal.height <= rows);
        }
    };
}

test "layout normalizes empty and oversized toolkit geometry for every mode" {
    for ([_]toolkit.Size{ .{ .width = 0, .height = 0 }, .{ .width = std.math.maxInt(usize), .height = std.math.maxInt(usize) } }) |available| {
        const size = Layout.boundedSize(available);
        for ([_]bool{ false, true }) |zoom| for ([_]i32{ std.math.minInt(i32), 0, std.math.maxInt(i32) }) |adjustment| {
            const layout = Layout.calculate(available, adjustment, zoom);
            try std.testing.expect(layout.terminal.width > 0 and layout.terminal.height > 0);
            try std.testing.expect(layout.terminal.x + layout.terminal.width <= size.width);
            try std.testing.expect(layout.terminal.y + layout.terminal.height <= size.height);
            try std.testing.expect(size.width <= Layout.max_size.width and size.height <= Layout.max_size.height);
        };
    }
}
