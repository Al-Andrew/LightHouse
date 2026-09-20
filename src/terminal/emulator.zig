//! All Ghostty-specific types stay behind this adapter.
const std = @import("std");
const vt = @import("ghostty-vt");
const ui = @import("lighthouse-ui").screen;
const input = @import("lighthouse-ui").input;
// The Zig API exposes the DA response type through its callback signature.
const DeviceAttributes = @typeInfo(std.meta.Child(std.meta.Child(
    @FieldType(vt.TerminalStream.Handler.Effects, "device_attributes"),
))).@"fn".return_type.?;

pub const Emulator = struct {
    allocator: std.mem.Allocator,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    render: vt.RenderState = .empty,
    pending: std.ArrayList(u8) = .empty,
    pending_offset: usize = 0,
    failed: bool = false,
    paste: enum { inactive, plain, bracketed } = .inactive,
    const max_pending_bytes = 1024 * 1024;
    // Reserve half the queue for encoded keys, paste framing, and VT replies.
    const input_high_water_bytes = max_pending_bytes / 2;
    const max_scrollback_bytes = 8 * 1024 * 1024;
    const encoded_key_bytes = 256;

    /// Heap allocation gives the stream's handler a stable terminal address.
    pub fn create(io: std.Io, allocator: std.mem.Allocator, cols: u16, rows: u16) !*Emulator {
        const self = try allocator.create(Emulator);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .terminal = try vt.Terminal.init(io, allocator, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback_bytes = max_scrollback_bytes,
                .kitty_image_storage_limit = 0,
            }),
            .stream = undefined,
        };
        var handler = self.terminal.vtHandler();
        handler.effects.write_pty = reply;
        handler.effects.device_attributes = deviceAttributes;
        handler.effects.size = terminalSize;
        handler.effects.xtversion = version;
        handler.terminfo_name = "xterm-256color";
        self.stream = vt.TerminalStream.init(.{ .allocator = allocator, .handler = handler });
        return self;
    }
    pub fn destroy(self: *Emulator) void {
        self.stream.deinit();
        self.render.deinit(self.allocator);
        self.terminal.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    /// Keep the borrowed adapter address stable while replacing all VT state.
    pub fn reset(self: *Emulator, io: std.Io, cols: u16, rows: u16) !void {
        const fresh = try create(io, self.allocator, cols, rows);
        std.mem.swap(Emulator, self, fresh);
        self.stream.handler.terminal = &self.terminal;
        fresh.stream.handler.terminal = &fresh.terminal;
        fresh.destroy();
    }
    fn reply(handler: *vt.TerminalStream.Handler, bytes: []const u8) void {
        const self: *Emulator = @fieldParentPtr("terminal", handler.terminal);
        self.queue(bytes) catch {
            self.failed = true;
        };
    }
    fn deviceAttributes(_: *vt.TerminalStream.Handler) DeviceAttributes {
        // VT220 with ANSI color; no graphics or clipboard feature claims.
        return .{};
    }
    fn terminalSize(handler: *vt.TerminalStream.Handler) ?vt.size_report.Size {
        return .{ .rows = handler.terminal.rows, .columns = handler.terminal.cols, .cell_width = 0, .cell_height = 0 };
    }
    fn version(_: *vt.TerminalStream.Handler) []const u8 {
        return "LightHouse 0.0.0";
    }
    pub fn feed(self: *Emulator, bytes: []const u8) !void {
        self.stream.nextSlice(bytes);
        if (self.failed or self.stream.handler.semantic_failure) return error.TerminalProcessingFailed;
    }
    pub fn resize(self: *Emulator, cols: u16, rows: u16) !void {
        try self.terminal.resize(self.allocator, .{ .cols = cols, .rows = rows });
    }
    fn queue(self: *Emulator, bytes: []const u8) !void {
        if (self.pending_offset > 0) {
            const remaining = self.pending.items.len - self.pending_offset;
            std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[self.pending_offset..]);
            self.pending.items.len = remaining;
            self.pending_offset = 0;
        }
        if (self.pending.items.len + bytes.len > max_pending_bytes) return error.TerminalInputBackpressure;
        try self.pending.appendSlice(self.allocator, bytes);
    }
    /// Admit one entire insertion, including paste framing, or leave the queue
    /// unchanged. Physical delivery can still use normal short PTY writes.
    pub fn insert(self: *Emulator, bytes: []const u8) !void {
        const bracketed = self.terminal.modes.get(.bracketed_paste);
        const framing: usize = if (bracketed) input.paste_start.len + input.paste_end.len else 0;
        const remaining = self.pending.items.len - self.pending_offset;
        if (bytes.len > max_pending_bytes - remaining or framing > max_pending_bytes - remaining - bytes.len) return error.TerminalInputBackpressure;
        // Reserve before touching queue contents, offsets or viewport.
        try self.pending.ensureUnusedCapacity(self.allocator, bytes.len + framing);
        if (bracketed) self.pending.appendSliceAssumeCapacity(input.paste_start);
        self.pending.appendSliceAssumeCapacity(bytes);
        if (bracketed) self.pending.appendSliceAssumeCapacity(input.paste_end);
        self.bottom();
    }

    pub fn acceptsInput(self: *const Emulator) bool {
        return self.pending.items.len - self.pending_offset < input_high_water_bytes;
    }

    pub fn queued(self: *Emulator) []const u8 {
        return self.pending.items[self.pending_offset..];
    }
    pub fn consumed(self: *Emulator, count: usize) void {
        self.pending_offset += count;
        if (self.pending_offset == self.pending.items.len) {
            self.pending.clearRetainingCapacity();
            self.pending_offset = 0;
        }
    }
    /// Encodes terminal input; application focus policy belongs to the caller.
    /// Capture paste mode once so a child mode change cannot unbalance framing.
    pub fn event(self: *Emulator, ev: *const input.Event) !void {
        switch (ev.kind) {
            .paste_start => {
                self.paste = if (self.terminal.modes.get(.bracketed_paste)) .bracketed else .plain;
                self.bottom();
                if (self.paste == .bracketed) try self.queue(input.paste_start);
            },
            .paste_byte => if (self.paste != .inactive) try self.queue(ev.text()),
            .paste_end => {
                if (self.paste == .bracketed) try self.queue(input.paste_end);
                self.paste = .inactive;
            },
            .key => try self.key(ev),
        }
    }

    pub fn scrollPage(self: *Emulator, direction: enum { up, down }) void {
        const rows: isize = self.terminal.rows;
        self.scroll(if (direction == .up) -rows else rows);
    }
    fn scroll(self: *Emulator, delta: isize) void {
        self.terminal.scrollViewport(.{ .delta = delta });
    }
    fn bottom(self: *Emulator) void {
        self.terminal.scrollViewport(.bottom);
    }

    fn key(self: *Emulator, ev: *const input.Event) !void {
        self.bottom();
        if (ev.key == .enter and ev.len == 1 and ev.bytes[0] == 10) return self.queue("\n");
        var key_ev: vt.input.KeyEvent = .{
            .mods = .{ .shift = ev.shift, .alt = ev.alt, .ctrl = ev.ctrl },
            .key = switch (ev.key) {
                .up => .arrow_up,
                .down => .arrow_down,
                .left => .arrow_left,
                .right => .arrow_right,
                .text, .unknown => .unidentified,
                inline else => |tag| @field(vt.input.Key, @tagName(tag)),
            },
        };
        if (ev.key == .unknown) return;
        if (ev.key == .text) {
            const text = if (ev.alt and ev.len > 1 and ev.bytes[0] == 0x1b) ev.text()[1..] else ev.text();
            if (text.len == 1 and text[0] >= 1 and text[0] <= 26) {
                key_ev.mods.ctrl = true;
                key_ev.unshifted_codepoint = 'a' + text[0] - 1;
                key_ev.key = @enumFromInt(@intFromEnum(vt.input.Key.key_a) + text[0] - 1);
            } else {
                key_ev.utf8 = text;
                key_ev.unshifted_codepoint = std.unicode.utf8Decode(text) catch 0;
            }
        }
        var storage: [encoded_key_bytes]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&storage);
        try vt.input.encodeKey(&writer, key_ev, .fromTerminal(&self.terminal));
        try self.queue(writer.buffered());
    }

    pub fn paint(self: *Emulator, painter: ui.Painter, focused: bool) !void {
        try self.render.update(self.allocator, &self.terminal);
        const colors = self.render.colors;
        const arena = painter.frame.arena.allocator();
        for (self.render.row_data.items(.cells), 0..) |row, y| {
            if (y >= painter.rect.height) break;
            for (row.items(.raw), 0..) |raw, x| {
                if (x >= painter.rect.width) break;
                if (raw.wide == .spacer_tail) continue;
                const style: vt.Style = if (raw.style_id != 0) row.items(.style)[x] else .{};
                var fg = style.fg(.{ .default = colors.foreground, .palette = &colors.palette });
                var bg = style.bg(&raw, &colors.palette) orelse colors.background;
                if (style.flags.inverse) std.mem.swap(vt.color.RGB, &fg, &bg);
                if (style.flags.invisible) fg = bg;
                var cell: ui.Cell = .{ .style = .{
                    .fg = rgb(fg),
                    .bg = rgb(bg),
                    .bold = style.flags.bold,
                    .faint = style.flags.faint,
                    .italic = style.flags.italic,
                    .underline = style.flags.underline != .none,
                    .strike = style.flags.strikethrough,
                    .overline = style.flags.overline,
                    .blink = style.flags.blink,
                } };
                const cp = raw.codepoint();
                if (cp >= 32 and cp != 127 and raw.wide != .spacer_head) {
                    const extra: []const u21 = if (raw.content_tag == .codepoint_grapheme) row.items(.grapheme)[x] else &.{};
                    const bytes = try arena.alloc(u8, 4 * (1 + extra.len));
                    var len: usize = try std.unicode.utf8Encode(cp, bytes[0..4]);
                    for (extra) |part| len += try std.unicode.utf8Encode(part, bytes[len..][0..4]);
                    cell.text = bytes[0..len];
                    cell.width = if (raw.wide == .wide) 2 else 1;
                }
                painter.put(x, y, cell);
            }
        }
        if (focused and self.render.cursor.visible) {
            if (self.render.cursor.viewport) |cursor| {
                painter.frame.cursor = .{
                    .x = painter.rect.x + cursor.x,
                    .y = painter.rect.y + cursor.y,
                    .shape = switch (self.render.cursor.visual_style) {
                        .block, .block_hollow => .block,
                        .underline => .underline,
                        .bar => .bar,
                    },
                };
            }
        }
        self.render.dirty = .false;
    }
};
fn rgb(value: vt.color.RGB) ui.Rgb {
    return .{ .r = value.r, .g = value.g, .b = value.b };
}

test "fragmented VT input, Unicode, styles, alternate screen and query replies" {
    const emulator = try Emulator.create(std.testing.io, std.testing.allocator, 20, 4);
    defer emulator.destroy();
    try emulator.feed("\x1b[3");
    try emulator.feed("1mAé界e\xcc\x81\x1b[0m");
    var frame = ui.Frame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.begin(20, 4);
    try emulator.paint(frame.painter(.{ .x = 0, .y = 0, .width = 20, .height = 4 }), true);
    try std.testing.expectEqualStrings("é", frame.cells[1].text);
    try std.testing.expectEqualStrings("界", frame.cells[2].text);
    try std.testing.expectEqual(@as(u2, 0), frame.cells[3].width);
    try std.testing.expectEqualStrings("e\xcc\x81", frame.cells[4].text);
    try std.testing.expect(frame.cells[0].style.fg.r > frame.cells[0].style.fg.g);
    try emulator.feed("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;6R", emulator.queued());
    try emulator.feed("\x1b[?1049hALT\x1b[?1049l");
    try emulator.resize(12, 3);
    const text = try emulator.terminal.plainString(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Aé界") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "ALT") == null);
}

test "arrow encoding follows the child terminal mode" {
    const emulator = try Emulator.create(std.testing.io, std.testing.allocator, 20, 4);
    defer emulator.destroy();
    const event: input.Event = .{ .key = .up };
    try emulator.event(&event);
    try std.testing.expectEqualStrings("\x1b[A", emulator.queued());
    emulator.consumed(emulator.queued().len);
    try emulator.feed("\x1b[?1049h\x1b[?1h");
    try emulator.event(&event);
    try std.testing.expectEqualStrings("\x1bOA", emulator.queued());
}

test "fragmented paste captures mode at start and preserves control bytes" {
    const emulator = try Emulator.create(std.testing.io, std.testing.allocator, 20, 4);
    defer emulator.destroy();
    for ([_]bool{ false, true }) |bracketed| {
        try emulator.feed(if (bracketed) "\x1b[?2004h" else "\x1b[?2004l");
        var decoder: input.Decoder = .{};
        for ("\x1b[200~q\x07") |byte| if (decoder.feed(byte)) |ev| try emulator.event(&ev);
        // Child output can arrive between any two host input fragments.
        try emulator.feed(if (bracketed) "\x1b[?2004l" else "\x1b[?2004h");
        for ("\n界\x1b[201~") |byte| if (decoder.feed(byte)) |ev| try emulator.event(&ev);
        try std.testing.expectEqualStrings(if (bracketed) "\x1b[200~q\x07\n界\x1b[201~" else "q\x07\n界", emulator.queued());
        emulator.consumed(emulator.queued().len);
        // Orphan payload/end events do not inject data or extra framing.
        var orphan: input.Event = .{ .kind = .paste_byte, .len = 1 };
        orphan.bytes[0] = 'x';
        try emulator.event(&orphan);
        try emulator.event(&.{ .kind = .paste_end });
        try std.testing.expectEqualStrings("", emulator.queued());
    }
    var decoder: input.Decoder = .{};
    for ("q\x03\x07") |byte| if (decoder.feed(byte)) |ev| try emulator.event(&ev);
    try std.testing.expectEqualStrings("q\x03\x07", emulator.queued());
}

test "terminal input backpressure leaves room for framing and VT replies" {
    const emulator = try Emulator.create(std.testing.io, std.testing.allocator, 20, 4);
    defer emulator.destroy();
    try emulator.feed("\x1b[?2004h");
    try emulator.event(&.{ .kind = .paste_start });
    var byte: input.Event = .{ .kind = .paste_byte, .len = 1 };
    byte.bytes[0] = 'x';
    while (emulator.acceptsInput()) try emulator.event(&byte);
    const payload_length = emulator.queued().len;
    try std.testing.expectEqual(Emulator.input_high_water_bytes, payload_length);
    try emulator.feed("\x1b[6n");
    try emulator.event(&.{ .kind = .paste_end });
    try std.testing.expectEqualStrings("\x1b[1;1R\x1b[201~", emulator.queued()[payload_length..]);
    emulator.consumed(100);
    try emulator.event(&.{ .key = .enter });
    try std.testing.expect(emulator.acceptsInput());
    const overflow = try std.testing.allocator.alloc(u8, Emulator.max_pending_bytes);
    defer std.testing.allocator.free(overflow);
    try std.testing.expectError(error.TerminalInputBackpressure, emulator.queue(overflow));
}

test "page scrolling uses resized height and input returns to the bottom" {
    const emulator = try Emulator.create(std.testing.io, std.testing.allocator, 20, 4);
    defer emulator.destroy();
    try emulator.feed("0\r\n1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n9");
    try emulator.resize(20, 3);
    var frame = ui.Frame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.begin(20, 3);
    const rect: ui.Rect = .{ .x = 0, .y = 0, .width = 20, .height = 3 };
    try emulator.paint(frame.painter(rect), true);
    try std.testing.expectEqualStrings("7", frame.cells[0].text);
    emulator.scrollPage(.up);
    try emulator.paint(frame.painter(rect), true);
    try std.testing.expectEqualStrings("4", frame.cells[0].text);
    emulator.scrollPage(.down);
    try emulator.paint(frame.painter(rect), true);
    try std.testing.expectEqualStrings("7", frame.cells[0].text);
    emulator.scrollPage(.up);
    try emulator.event(&.{ .key = .enter });
    try emulator.paint(frame.painter(rect), true);
    try std.testing.expectEqualStrings("7", frame.cells[0].text);
    emulator.scrollPage(.up);
    try emulator.event(&.{ .kind = .paste_start });
    try emulator.paint(frame.painter(rect), true);
    try std.testing.expectEqualStrings("7", frame.cells[0].text);
}

test "whole insertion rejects allocation and backpressure without queueing framing or prefix" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const emulator = try Emulator.create(std.testing.io, failing.allocator(), 80, 8);
    defer emulator.destroy();
    try emulator.insert("existing");
    try emulator.feed("\x1b[?2004h");
    const before = try std.testing.allocator.dupe(u8, emulator.queued());
    defer std.testing.allocator.free(before);
    const large = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    try std.testing.expectError(error.TerminalInputBackpressure, emulator.insert(large));
    try std.testing.expectEqualStrings(before, emulator.queued());
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, emulator.insert(large[0..10000]));
    try std.testing.expectEqualStrings(before, emulator.queued());
    failing.fail_index = std.math.maxInt(usize);
    try emulator.insert("'path' ");
    try std.testing.expectEqualStrings("existing\x1b[200~'path' \x1b[201~", emulator.queued());
}
