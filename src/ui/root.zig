//! Importable terminal UI toolkit. No application, filesystem, or PTY policy.
pub const screen = @import("screen.zig");
pub const input = @import("input.zig");
pub const text = @import("text.zig");
pub const dialog = @import("dialog.zig");
pub const layout = @import("layout.zig");
pub const Widget = @import("widget.zig").Widget;
pub const Tree = @import("widget.zig").Tree;
pub const Size = @import("widget.zig").Size;
pub const Event = input.Event;
pub const Frame = screen.Frame;
pub const Painter = screen.Painter;
pub const Style = screen.Style;
pub const Rect = screen.Rect;
pub const TextInput = @import("text_input.zig").TextInput;

test {
    _ = screen;
    _ = input;
    _ = text;
    _ = dialog;
    _ = layout;
    _ = @import("widget.zig");
    _ = @import("text_input.zig");
    _ = @import("widget_test.zig");
}
