//! An owned single-line text editor. Acceptance and cancellation are outcomes;
//! their meaning belongs to the application. Paste never triggers either outcome.
const std = @import("std");
const input = @import("input.zig");
const ui = @import("screen.zig");
pub const TextInput = struct {
    // Bound pasted input independently of the filesystem's path length limit.
    const max_input_bytes = 16 * 1024;
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    pasting: bool = false,
    select_all: bool = true,
    pub fn init(allocator: std.mem.Allocator, initial: []const u8) !TextInput {
        var self: TextInput = .{ .allocator = allocator };
        try self.buffer.appendSlice(allocator, initial);
        self.cursor = initial.len;
        return self;
    }
    pub fn deinit(self: *TextInput) void {
        self.buffer.deinit(self.allocator);
    }
    pub fn text(self: *const TextInput) []const u8 {
        return self.buffer.items;
    }

    /// Paint one editable row, scrolling whole glyphs to keep the caret visible.
    pub fn paint(self: *const TextInput, painter: ui.Painter, style: ui.Style) !void {
        painter.fill(style);
        if (painter.rect.width == 0 or painter.rect.height == 0) return;
        const allocator = painter.frame.arena.allocator();
        const glyphs = try ui.text_layout.prepare(allocator, self.text());
        const prefix = try ui.text_layout.prepare(allocator, self.text()[0..self.cursor]);
        const caret = ui.text_layout.width(prefix);
        const offset = caret -| (painter.rect.width - 1);
        var at: usize = 0;
        for (glyphs) |glyph| {
            if (at >= offset and at - offset + glyph.width <= painter.rect.width) {
                painter.put(at - offset, 0, .{ .text = glyph.text, .width = glyph.width, .style = style });
            }
            at += glyph.width;
        }
        painter.frame.cursor = .{ .x = painter.rect.x + caret - offset, .y = painter.rect.y, .shape = .bar };
    }
    fn previous(self: *const TextInput) usize {
        var at = self.cursor -| 1;
        while (at > 0 and self.buffer.items[at] & 0xc0 == 0x80) at -= 1;
        return at;
    }
    fn next(self: *const TextInput) usize {
        var at = @min(self.cursor + 1, self.buffer.items.len);
        while (at < self.buffer.items.len and self.buffer.items[at] & 0xc0 == 0x80) at += 1;
        return at;
    }
    fn remove(self: *TextInput, start: usize, end: usize) void {
        std.mem.copyForwards(u8, self.buffer.items[start..], self.buffer.items[end..]);
        self.buffer.items.len -= end - start;
        self.cursor = start;
    }
    fn clearSelected(self: *TextInput) bool {
        if (!self.select_all) return false;
        self.buffer.clearRetainingCapacity();
        self.cursor = 0;
        self.select_all = false;
        return true;
    }
    fn insert(self: *TextInput, bytes: []const u8) !void {
        _ = self.clearSelected();
        // Keep text entry bounded; ignore pasted newlines, NUL and other
        // control bytes rather than letting them activate navigation shortcuts.
        for (bytes) |byte| {
            if (byte < 32 or byte == 127 or self.buffer.items.len >= max_input_bytes) continue;
            try self.buffer.insert(self.allocator, self.cursor, byte);
            self.cursor += 1;
        }
    }
    pub const Result = enum { editing, accept, cancel };
    pub fn event(self: *TextInput, ev: *const input.Event) !Result {
        switch (ev.kind) {
            .paste_start => {
                self.pasting = true;
                return .editing;
            },
            .paste_end => {
                self.pasting = false;
                return .editing;
            },
            .paste_byte => {
                try self.insert(ev.text());
                return .editing;
            },
            .key => {},
        }
        switch (ev.key) {
            .escape => return .cancel,
            .enter => return .accept,
            .left => {
                self.cursor = self.previous();
                self.select_all = false;
            },
            .right => {
                self.cursor = self.next();
                self.select_all = false;
            },
            .home => {
                self.cursor = 0;
                self.select_all = false;
            },
            .end => {
                self.cursor = self.buffer.items.len;
                self.select_all = false;
            },
            .backspace => if (!self.clearSelected() and self.cursor > 0) {
                self.remove(self.previous(), self.cursor);
            },
            .delete => if (!self.clearSelected() and self.cursor < self.buffer.items.len) {
                self.remove(self.cursor, self.next());
            },
            .text => {
                if (ev.len == 1 and ev.bytes[0] == input.control('u')) {
                    self.buffer.clearRetainingCapacity();
                    self.cursor = 0;
                    self.select_all = false;
                } else if (!ev.alt and !ev.ctrl) try self.insert(ev.text());
            },
            else => {},
        }
        return .editing;
    }
};

test "text input replaces selection, edits Unicode, and cannot submit pasted newlines" {
    var editor = try TextInput.init(std.testing.allocator, "/old");
    defer editor.deinit();
    var decoder: input.Decoder = .{};
    for ("/é界") |byte| if (decoder.feed(byte)) |event| {
        _ = try editor.event(&event);
    };
    try std.testing.expectEqualStrings("/é界", editor.text());
    _ = try editor.event(&.{ .key = .backspace });
    try std.testing.expectEqualStrings("/é", editor.text());
    for ("\x1b[200~\nq\x07\x1b[201~") |byte| if (decoder.feed(byte)) |event| {
        try std.testing.expectEqual(.editing, try editor.event(&event));
    };
    try std.testing.expectEqualStrings("/éq", editor.text());
}

test "scrolled editor keeps its caret and wide glyphs inside a nested field" {
    var editor = try TextInput.init(std.testing.allocator, "/long/界é");
    defer editor.deinit();
    var frame = ui.Frame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.begin(12, 4);
    const field = frame.painter(.{ .x = 3, .y = 2, .width = 4, .height = 1 });
    try editor.paint(field, .{});
    try std.testing.expectEqualStrings("界", frame.cells[2 * frame.cols + 3].text);
    try std.testing.expectEqual(@as(u2, 0), frame.cells[2 * frame.cols + 4].width);
    try std.testing.expectEqualStrings("é", frame.cells[2 * frame.cols + 5].text);
    try std.testing.expectEqual(ui.Cursor{ .x = 6, .y = 2, .shape = .bar }, frame.cursor.?);
    frame.cursor = null;
    try editor.paint(field.inset(2), .{});
    try std.testing.expectEqual(null, frame.cursor);
}
