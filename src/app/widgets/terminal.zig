//! Application terminal widget. The generic UI library knows nothing about PTYs.
const toolkit = @import("lighthouse-ui");
const Emulator = @import("../../terminal/emulator.zig").Emulator;

pub const Input = struct {
    pasting: bool = false,
    bracketed: bool = false,

    pub fn event(self: *Input, emulator: *Emulator, ev: *const toolkit.Event) !void {
        switch (ev.kind) {
            .paste_start => {
                self.pasting = true;
                self.bracketed = emulator.bracketedPaste();
                emulator.bottom();
                if (self.bracketed) try emulator.queue(toolkit.input.paste_start);
            },
            .paste_end => {
                if (self.bracketed) try emulator.queue(toolkit.input.paste_end);
                self.pasting = false;
                self.bracketed = false;
            },
            .paste_byte => if (self.pasting) try emulator.queue(ev.text()),
            .key => try emulator.key(ev),
        }
    }
};

pub const Terminal = struct {
    emulator: *Emulator,
    input: *Input,

    pub fn paint(self: *Terminal, node: *toolkit.Widget, painter: toolkit.Painter) !void {
        try self.emulator.paint(painter, node.focused());
    }

    pub fn event(self: *Terminal, _: *toolkit.Widget, ev: *const toolkit.Event) !bool {
        if (ev.kind == .key and ev.len == 1 and ev.bytes[0] == toolkit.input.control('g')) return false;
        try self.input.event(self.emulator, ev);
        return true;
    }
};
