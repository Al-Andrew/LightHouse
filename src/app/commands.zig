//! Static built-in descriptions and default bindings, without workflow policy.
//! All returned descriptions and bindings have process lifetime; no context is held.
const input = @import("lighthouse-ui").input;

pub const Id = enum {
    help,
    edit_file,
    insert_reference,
    copy,
    move,
    mkdir,
    delete,
    quit,
    switch_pane,
    path,
    absolute_path,
    refresh,
    toggle_terminal,
    visibility_terminal,
    focus_terminal,
    zoom_terminal,
    grow_terminal,
    shrink_terminal,
    history_up,
    history_down,
};

pub const Binding = struct {
    key: input.Key = .text,
    byte: ?u8 = null,
    shift: bool = false,
    text: []const u8,

    fn matches(self: Binding, ev: *const input.Event) bool {
        // Preserve conventional bindings' modifier behavior. Shift is required
        // for history keys; other bindings historically accept extra modifiers.
        return ev.key == self.key and (!self.shift or ev.shift) and
            (if (self.byte) |byte| ev.len == 1 and ev.bytes[0] == byte else true);
    }
};

pub const Description = struct {
    id: Id,
    label: []const u8,
    help: []const u8,
    bindings: []const Binding,
};

pub const descriptions = [_]Description{
    .{ .id = .insert_reference, .label = "Insert path", .help = "Insert Cursor reference", .bindings = &.{.{ .byte = input.control('f'), .text = "Ctrl+F" }} },
    .{ .id = .edit_file, .label = "Edit", .help = "Edit Cursor file", .bindings = &.{.{ .key = .f4, .text = "F4" }} },
    .{ .id = .help, .label = "Help", .help = "Help", .bindings = &.{.{ .key = .f1, .text = "F1" }} },
    .{ .id = .copy, .label = "Copy", .help = "Copy", .bindings = &.{.{ .key = .f5, .text = "F5" }} },
    .{ .id = .move, .label = "RenMov", .help = "Move/rename", .bindings = &.{.{ .key = .f6, .text = "F6" }} },
    .{ .id = .mkdir, .label = "Mkdir", .help = "Mkdir", .bindings = &.{.{ .key = .f7, .text = "F7" }} },
    .{ .id = .delete, .label = "Delete", .help = "Delete (confirm)", .bindings = &.{.{ .key = .f8, .text = "F8" }} },
    .{ .id = .quit, .label = "Quit", .help = "Quit", .bindings = &.{ .{ .byte = 'q', .text = "q" }, .{ .key = .f10, .text = "F10" } } },
    .{ .id = .switch_pane, .label = "Pane", .help = "Switch pane", .bindings = &.{.{ .key = .tab, .text = "Tab" }} },
    .{ .id = .path, .label = "Path", .help = "Enter path", .bindings = &.{.{ .byte = input.control('l'), .text = "Ctrl+L" }} },
    .{ .id = .absolute_path, .label = "Absolute", .help = "Absolute path", .bindings = &.{.{ .byte = '/', .text = "/" }} },
    .{ .id = .refresh, .label = "Refresh", .help = "Refresh directory", .bindings = &.{.{ .byte = input.control('r'), .text = "Ctrl+R" }} },
    .{ .id = .toggle_terminal, .label = "Shell/pane", .help = "Shell/pane", .bindings = &.{.{ .byte = input.control('g'), .text = "Ctrl+G" }} },
    .{ .id = .visibility_terminal, .label = "Show/hide", .help = "Show/hide shell", .bindings = &.{.{ .key = .enter, .byte = 10, .text = "Ctrl+J" }} },
    .{ .id = .focus_terminal, .label = "Shell", .help = "Focus shell", .bindings = &.{.{ .byte = 't', .text = "t" }} },
    .{ .id = .zoom_terminal, .label = "Zoom", .help = "Zoom shell", .bindings = &.{.{ .byte = 'z', .text = "z" }} },
    .{ .id = .grow_terminal, .label = "Taller", .help = "Taller shell", .bindings = &.{.{ .byte = '+', .text = "+" }} },
    .{ .id = .shrink_terminal, .label = "Shorter", .help = "Shorter shell", .bindings = &.{.{ .byte = '-', .text = "-" }} },
    .{ .id = .history_up, .label = "History up", .help = "History up", .bindings = &.{.{ .key = .page_up, .shift = true, .text = "Shift+PgUp" }} },
    .{ .id = .history_down, .label = "History down", .help = "History down", .bindings = &.{.{ .key = .page_down, .shift = true, .text = "Shift+PgDn" }} },
};

pub fn describe(id: Id) *const Description {
    for (&descriptions) |*description| if (description.id == id) return description;
    unreachable;
}

/// Call only after the focused widget has declined an event, or in a receiving
/// modal scope. Recognizing a binding does not grant permission to invoke it.
pub fn resolve(ev: *const input.Event) ?Id {
    if (ev.kind != .key) return null;
    for (descriptions) |description| for (description.bindings) |binding| {
        if (binding.matches(ev)) return description.id;
    };
    return null;
}

/// Ten fixed function-key slots, including the unassigned slots.
pub const function_keys = [_]input.Key{ .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10 };
pub const function_numbers = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" };

pub fn functionCommand(key: input.Key) ?Id {
    for (descriptions) |description| for (description.bindings) |binding| {
        if (binding.key == key and binding.byte == null and !binding.shift) return description.id;
    };
    return null;
}

/// Presentation grouping only; descriptions and shortcut labels stay above.
pub const help_groups = [_][]const Id{
    &.{ .help, .quit, .switch_pane },
    &.{ .copy, .move, .mkdir },
    &.{ .delete, .edit_file },
    &.{ .path, .absolute_path },
    &.{ .refresh, .insert_reference },
    &.{ .toggle_terminal, .focus_terminal, .zoom_terminal },
    &.{.visibility_terminal},
    &.{ .grow_terminal, .shrink_terminal },
    &.{ .history_up, .history_down },
};
