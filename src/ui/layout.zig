//! Reusable cell layouts. Child order is both layout order and painting order.
const widget = @import("widget.zig");
const screen = @import("screen.zig");
pub const Axis = enum { horizontal, vertical };

/// Equal shares with deterministic remainder distribution and bounded gaps.
pub const Box = struct {
    axis: Axis,
    gap: usize = 0,

    pub fn layout(self: *Box, node: *widget.Widget, size: widget.Size) void {
        var count: usize = 0;
        for (node.children()) |child| if (child.visible() and child.isAlive()) {
            count += 1;
        };
        if (count == 0) return;
        const extent = if (self.axis == .horizontal) size.width else size.height;
        const gap = if (count > 1) @min(self.gap, extent / (count - 1)) else 0;
        const usable = extent - gap * (count - 1);
        var index: usize = 0;
        for (node.children()) |child| {
            if (!child.visible() or !child.isAlive()) continue;
            const begin = usable / count * index + @min(index, usable % count);
            const length = usable / count + @intFromBool(index < usable % count);
            child.setRect(if (self.axis == .horizontal)
                .{ .x = begin + gap * index, .y = 0, .width = length, .height = size.height }
            else
                .{ .x = 0, .y = begin + gap * index, .width = size.width, .height = length });
            index += 1;
        }
    }
};

pub fn centered(available: widget.Size, desired: widget.Size) screen.Rect {
    const width = @min(available.width, desired.width);
    const height = @min(available.height, desired.height);
    return .{ .x = (available.width - width) / 2, .y = (available.height - height) / 2, .width = width, .height = height };
}
