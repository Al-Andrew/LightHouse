//! Far-style function-key slots. Unassigned keys keep an empty label.
const ui = @import("lighthouse-ui").screen;
const theme = @import("../theme.zig");
const toolkit = @import("lighthouse-ui");
const commands = @import("../commands.zig");
const State = @import("../controller.zig").State;

pub const KeyBar = struct {
    state: *const State,

    pub fn paint(self: *KeyBar, _: *toolkit.Widget, painter: ui.Painter) !void {
        paintActions(painter, self.state);
    }
};

fn paintActions(painter: ui.Painter, state: *const State) void {
    const key_style = theme.base;
    painter.fill(key_style);
    for (commands.function_keys, commands.function_numbers, 0..) |key, number, i| {
        const id = commands.functionCommand(key);
        const caption = if (id) |command| commands.describe(command).label else "";
        const x = painter.rect.width * i / commands.function_keys.len;
        const end = painter.rect.width * (i + 1) / commands.function_keys.len;
        const slot = painter.child(.{ .x = x, .y = 0, .width = end - x, .height = 1 });
        const enabled = if (id) |command| state.available(command) else false;
        var number_style = key_style;
        if (!enabled) number_style.fg = theme.disabled_key;
        slot.label(0, 0, number, number_style);
        const label = slot.child(.{ .x = number.len, .y = 0, .width = slot.rect.width -| (number.len + 1), .height = 1 });
        const style = if (enabled) theme.action else theme.disabled_action;
        label.fill(style);
        label.label(0, 0, caption, style);
    }
}
