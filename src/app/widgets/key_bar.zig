//! Far-style function-key slots. Unassigned keys keep an empty label.
const ui = @import("lighthouse-ui").screen;
const theme = @import("../theme.zig");
const toolkit = @import("lighthouse-ui");
const State = @import("../controller.zig").State;

pub const KeyBar = struct {
    state: *const State,

    pub fn paint(self: *KeyBar, _: *toolkit.Widget, painter: ui.Painter) !void {
        paintActions(painter, self.state.focus != .terminal and self.state.modal == .none and self.state.operation == null);
    }
};

fn paintActions(painter: ui.Painter, pane_active: bool) void {
    const actions = [_]struct { key: []const u8, label: []const u8 = "" }{
        .{ .key = "1", .label = "Help" },
        .{ .key = "2" },
        .{ .key = "3" },
        .{ .key = "4" },
        .{ .key = "5", .label = "Copy" },
        .{ .key = "6", .label = "RenMov" },
        .{ .key = "7", .label = "Mkdir" },
        .{ .key = "8", .label = "Delete" },
        .{ .key = "9" },
        .{ .key = "10", .label = "Quit" },
    };
    const key_style = theme.base;
    painter.fill(key_style);
    for (actions, 0..) |action, i| {
        const x = painter.rect.width * i / actions.len;
        const end = painter.rect.width * (i + 1) / actions.len;
        const slot = painter.child(.{ .x = x, .y = 0, .width = end - x, .height = 1 });
        const enabled = pane_active and action.label.len > 0;
        var number_style = key_style;
        if (!enabled) number_style.fg = theme.disabled_key;
        slot.label(0, 0, action.key, number_style);
        const label = slot.child(.{ .x = action.key.len, .y = 0, .width = slot.rect.width -| (action.key.len + 1), .height = 1 });
        const style = if (enabled) theme.action else theme.disabled_action;
        label.fill(style);
        label.label(0, 0, action.label, style);
    }
}
