pub const platform = @import("platform/linux.zig");
pub const ui = @import("lighthouse-ui");
pub const screen = ui.screen;
pub const input = ui.input;
pub const dialog = ui.dialog;
pub const PathInput = ui.TextInput;
pub const Emulator = @import("terminal/emulator.zig").Emulator;
pub const Pane = @import("core/pane.zig").Pane;
pub const App = @import("app.zig").App;

test {
    _ = @import("terminal/emulator.zig");
    _ = @import("app.zig");
    _ = @import("app/controller.zig");
    _ = @import("app/layout.zig");
    _ = @import("app/view.zig");
    _ = @import("app/widgets/dialogs.zig");
    _ = @import("core/directory.zig");
    _ = @import("core/pane.zig");
    _ = @import("core/operations.zig");
}
