pub const platform = @import("platform/linux.zig");
pub const screen = @import("ui/screen.zig");
pub const input = @import("ui/input.zig");
pub const dialog = @import("ui/dialog.zig");
pub const PathInput = @import("ui/path_input.zig").PathInput;
pub const Emulator = @import("terminal/emulator.zig").Emulator;
pub const Pane = @import("core/pane.zig").Pane;
pub const run = @import("app.zig").run;

test {
    _ = screen;
    _ = input;
    _ = dialog;
    _ = @import("terminal/emulator.zig");
    _ = @import("app.zig");
    _ = @import("core/directory.zig");
    _ = @import("core/pane.zig");
    _ = @import("core/operations.zig");
    _ = @import("ui/text.zig");
    _ = @import("ui/path_input.zig");
}
