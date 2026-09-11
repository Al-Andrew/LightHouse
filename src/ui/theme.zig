//! Application palette, separate from widget behavior and terminal colors.
const ui = @import("screen.zig");

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
