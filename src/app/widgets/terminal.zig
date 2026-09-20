//! Application terminal widget. The generic UI library knows nothing about PTYs.
const toolkit = @import("lighthouse-ui");
const Emulator = @import("../../terminal/emulator.zig").Emulator;

pub const Terminal = struct {
    emulator: *Emulator,

    pub fn paint(self: *Terminal, node: *toolkit.Widget, painter: toolkit.Painter) !void {
        try self.emulator.paint(painter, node.focused());
    }

    pub fn event(self: *Terminal, _: *toolkit.Widget, ev: *const toolkit.Event) !bool {
        if (ev.kind == .key and ev.len == 1 and ev.bytes[0] == toolkit.input.control('g')) return false;
        try self.emulator.event(ev);
        return true;
    }
};
