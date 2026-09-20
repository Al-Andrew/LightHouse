//! Application palette, separate from widget behavior and terminal colors.
const ui = @import("lighthouse-ui").screen;

pub const base: ui.Style = .{};
pub const accent: ui.Style = .{ .fg = .{ .r = 120, .g = 220, .b = 236 }, .bold = true };
pub const muted: ui.Style = .{ .fg = .{ .r = 150, .g = 161, .b = 178 } };
pub const dialog: ui.Style = .{ .bg = .{ .r = 42, .g = 55, .b = 73 } };
pub const destructive_dialog: ui.Style = .{ .bg = .{ .r = 70, .g = 40, .b = 45 } };
pub const selection: ui.Rgb = .{ .r = 40, .g = 78, .b = 112 };
pub const inactive_selection: ui.Rgb = .{ .r = 38, .g = 45, .b = 55 };
pub const symlink: ui.Rgb = .{ .r = 186, .g = 163, .b = 234 };
pub const marked: ui.Rgb = .{ .r = 255, .g = 208, .b = 105 };
pub const failure: ui.Style = .{ .fg = .{ .r = 255, .g = 130, .b = 130 } };
pub const disabled_key: ui.Rgb = .{ .r = 110, .g = 120, .b = 133 };
pub const action: ui.Style = .{ .fg = .{ .r = 15, .g = 26, .b = 33 }, .bg = accent.fg };
pub const disabled_action: ui.Style = .{ .fg = .{ .r = 133, .g = 153, .b = 164 }, .bg = .{ .r = 39, .g = 54, .b = 65 } };

/// Readable keyboard controls on both ordinary and problem dialogs.
pub const dialog_control: ui.Style = .{ .fg = .{ .r = 240, .g = 244, .b = 250 }, .bg = .{ .r = 73, .g = 91, .b = 116 }, .bold = true };

pub const problem_dialog: ui.Style = .{ .bg = .{ .r = 66, .g = 35, .b = 43 } };
pub const problem_heading: ui.Style = .{ .fg = .{ .r = 255, .g = 215, .b = 215 }, .bg = .{ .r = 104, .g = 37, .b = 48 }, .bold = true };
pub const problem_path: ui.Style = .{ .fg = .{ .r = 247, .g = 222, .b = 193 }, .bg = problem_dialog.bg };
