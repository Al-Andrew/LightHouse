//! Shared immediate-mode dialog composition. Content remains caller-owned.
const ui = @import("screen.zig");

/// Center and clip a bordered overlay, hiding any underlying terminal cursor.
/// Call inset(1) on the returned painter to paint inside its border.
pub fn begin(frame: *ui.Frame, desired_width: usize, desired_height: usize, style: ui.Style) ui.Painter {
    const width = @min(desired_width, frame.cols);
    const height = @min(desired_height, frame.rows);
    const box = frame.painter(.{
        .x = (frame.cols - width) / 2,
        .y = (frame.rows - height) / 2,
        .width = width,
        .height = height,
    });
    box.fill(style);
    box.border(style);
    frame.cursor = null;
    return box;
}
