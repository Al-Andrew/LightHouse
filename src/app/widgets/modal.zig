//! App-owned dialog content and workflow, hosted by the toolkit's modal scope.
const toolkit = @import("lighthouse-ui");
const State = @import("../controller.zig").State;
const dialogs = @import("dialogs.zig");

pub const Modal = struct {
    state: *State,
    emulator: *@import("../../terminal/emulator.zig").Emulator,

    pub fn measure(self: *Modal, _: toolkit.Size) toolkit.Size {
        return switch (self.state.view().modal) {
            .editor => |editor| dialogs.editorSize(editor.action, self.state.view().rejection),
            .help => dialogs.help_size,
            .confirm_delete => |job| dialogs.deleteSize(job, self.state.view().rejection),
            .none => dialogs.operation_size,
        };
    }

    pub fn paint(self: *Modal, _: *toolkit.Widget, painter: toolkit.Painter) !void {
        switch (self.state.view().modal) {
            .editor => |editor| try dialogs.paintPathInput(painter, editor.input, editor.action, self.state.activePane(), self.state.view().rejection),
            .help => dialogs.paintHelp(painter),
            .confirm_delete => |job| try dialogs.paintDeleteConfirmation(painter, job, self.state.view().rejection),
            .none => if (self.state.view().operation) |job| try dialogs.paintOperation(painter, job),
        }
    }

    pub fn event(self: *Modal, _: *toolkit.Widget, ev: *const toolkit.Event) !bool {
        try self.state.modalEvent(self.emulator, ev);
        return true;
    }
};
