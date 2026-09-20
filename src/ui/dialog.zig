//! Shared immediate-mode dialog composition. Content remains caller-owned.
const ui = @import("screen.zig");
const layout = @import("layout.zig");

/// Draw dialog chrome inside a widget's own clip rectangle.
pub fn paint(box: ui.Painter, style: ui.Style) void {
    box.fill(style);
    box.border(style);
    box.frame.cursor = null;
}

/// Center and clip a bordered overlay, hiding any underlying terminal cursor.
/// Call inset(1) on the returned painter to paint inside its border.
pub fn begin(frame: *ui.Frame, desired_width: usize, desired_height: usize, style: ui.Style) ui.Painter {
    return beginIn(frame.painter(.{ .x = 0, .y = 0, .width = frame.cols, .height = frame.rows }), desired_width, desired_height, style);
}

pub fn beginIn(painter: ui.Painter, desired_width: usize, desired_height: usize, style: ui.Style) ui.Painter {
    const box = painter.child(layout.centered(
        .{ .width = painter.rect.width, .height = painter.rect.height },
        .{ .width = desired_width, .height = desired_height },
    ));
    paint(box, style);
    return box;
}
