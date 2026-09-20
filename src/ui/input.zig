//! Incremental decoding of the host terminal's conventional UTF-8/xterm input.
const std = @import("std");
// Supported host sequences fit in this bounded incremental buffer.
const max_sequence_bytes = 128;
pub const escape_timeout_ms = 40;
pub const paste_start = "\x1b[200~";
pub const paste_end = "\x1b[201~";

/// ASCII control encoding for a lowercase letter (e.g. Ctrl+G).
pub fn control(comptime letter: u8) u8 {
    if (letter < 'a' or letter > 'z') @compileError("expected a lowercase ASCII letter");
    return letter - 'a' + 1;
}

pub const Key = enum { up, down, left, right, home, end, insert, delete, page_up, page_down, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, tab, enter, backspace, escape, text, unknown };
pub const Event = struct {
    kind: enum { key, paste_start, paste_end, paste_byte } = .key,
    key: Key = .unknown,
    bytes: [max_sequence_bytes]u8 = @splat(0),
    len: usize = 0,
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    pub fn text(self: *const Event) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Decoder = struct {
    bytes: [max_sequence_bytes]u8 = undefined,
    len: usize = 0,
    pasting: bool = false,

    pub fn feed(self: *Decoder, byte: u8) ?Event {
        if (self.len == self.bytes.len) {
            self.len = 0;
            return .{}; // Discard an overlong unsupported control sequence.
        }
        self.bytes[self.len] = byte;
        self.len += 1;
        const seq = self.bytes[0..self.len];
        if (self.pasting) {
            const end = paste_end;
            if (std.mem.startsWith(u8, end, seq)) {
                if (seq.len != end.len) return null;
                self.pasting = false;
                self.len = 0;
                return .{ .kind = .paste_end };
            }
            // Preserve a new Escape suffix after a failed prefix, so an
            // embedded Escape immediately before the end marker is harmless.
            if (seq.len > 1 and byte == 0x1b) {
                var event: Event = .{ .kind = .paste_byte, .len = self.len - 1 };
                @memcpy(event.bytes[0..event.len], seq[0..event.len]);
                self.bytes[0] = 0x1b;
                self.len = 1;
                return event;
            }
            return self.take(.{ .kind = .paste_byte });
        }
        if (seq[0] == 0x1b) {
            if (seq.len == 1) return null;
            if (seq[1] == '[' or seq[1] == 'O') {
                if (seq.len == 2 or byte < 0x40 or byte > 0x7e) return null;
                if (std.mem.eql(u8, seq, paste_start)) {
                    self.pasting = true;
                    self.len = 0;
                    return .{ .kind = .paste_start };
                }
                return self.take(decodeSequence(seq));
            }
            // Alt may prefix an entire UTF-8 codepoint across several reads.
            if (seq[1] >= 0x80) {
                const expected = std.unicode.utf8ByteSequenceLength(seq[1]) catch return self.take(.{});
                if (seq.len - 1 < expected) return null;
                _ = std.unicode.utf8Decode(seq[1..]) catch return self.take(.{});
            }
            return self.take(.{ .key = .text, .alt = true });
        }
        if (seq[0] >= 0x80) {
            const expected = std.unicode.utf8ByteSequenceLength(seq[0]) catch return self.take(.{});
            if (seq.len < expected) return null;
            _ = std.unicode.utf8Decode(seq) catch return self.take(.{});
        }
        return self.take(.{ .key = switch (seq[0]) {
            '\t' => .tab,
            '\r', '\n' => .enter,
            0x7f, control('h') => .backspace,
            else => .text,
        } });
    }

    /// Only ambiguous Escape/Alt prefixes time out; UTF-8 and paste framing
    /// may span arbitrarily delayed reads without turning into UI shortcuts.
    pub fn timeout(self: *Decoder) ?Event {
        if (self.pasting or self.len != 1 or self.bytes[0] != 0x1b) return null;
        return self.take(.{ .key = .escape });
    }
    fn take(self: *Decoder, base: Event) Event {
        var event = base;
        event.len = self.len;
        @memcpy(event.bytes[0..self.len], self.bytes[0..self.len]);
        self.len = 0;
        return event;
    }
};

fn decodeSequence(seq: []const u8) Event {
    const final = seq[seq.len - 1];
    var result: Event = .{ .key = switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'P' => .f1,
        'Q' => .f2,
        'R' => .f3,
        'S' => .f4,
        'Z' => .tab,
        else => .unknown,
    } };
    if (final == 'Z') result.shift = true;
    var parts = std.mem.splitScalar(u8, seq[2 .. seq.len - 1], ';');
    const first = std.fmt.parseInt(u8, parts.next().?, 10) catch 0;
    // Conventional xterm CSI <number> ~ key identifiers.
    if (final == '~') result.key = switch (first) {
        1, 7 => .home,
        2 => .insert,
        3 => .delete,
        4, 8 => .end,
        5 => .page_up,
        6 => .page_down,
        11 => .f1,
        12 => .f2,
        13 => .f3,
        14 => .f4,
        15 => .f5,
        17 => .f6,
        18 => .f7,
        19 => .f8,
        20 => .f9,
        21 => .f10,
        23 => .f11,
        24 => .f12,
        else => .unknown,
    };
    if (parts.next()) |modifier| {
        const value = std.fmt.parseInt(u8, modifier, 10) catch 1;
        // xterm encodes modifiers as 1 + Shift(1) + Alt(2) + Ctrl(4).
        const bits = value -| 1;
        result.shift = bits & 1 != 0;
        result.alt = bits & 2 != 0;
        result.ctrl = bits & 4 != 0;
    }
    return result;
}

test "fragmented input preserves arrow modifiers and UTF-8" {
    var decoder: Decoder = .{};
    for ("\x1b[1;5") |byte| try std.testing.expect(decoder.feed(byte) == null);
    const arrow = decoder.feed('A').?;
    try std.testing.expectEqual(Key.up, arrow.key);
    try std.testing.expect(arrow.ctrl);
    try std.testing.expect(decoder.feed(0xc3) == null);
    try std.testing.expect(decoder.timeout() == null);
    const text = decoder.feed(0xa9).?;
    try std.testing.expectEqualStrings("é", text.text());
}

test "bracketed paste does not interpret focus and quit keys" {
    var decoder: Decoder = .{};
    var start: ?Event = null;
    for ("\x1b[200~") |byte| start = decoder.feed(byte);
    try std.testing.expectEqual(.paste_start, start.?.kind);
    const pasted_control = decoder.feed(7).?;
    try std.testing.expectEqual(.paste_byte, pasted_control.kind);
    try std.testing.expectEqual(.paste_byte, decoder.feed('q').?.kind);
    var end: ?Event = null;
    for ("\x1b[201~") |byte| end = decoder.feed(byte);
    try std.testing.expectEqual(.paste_end, end.?.kind);
}

test "paste end marker survives an adjacent escaped prefix" {
    var decoder: Decoder = .{};
    for ("\x1b[200~") |byte| _ = decoder.feed(byte);
    try std.testing.expect(decoder.feed(0x1b) == null);
    const payload = decoder.feed(0x1b).?;
    try std.testing.expectEqualStrings("\x1b", payload.text());
    var event: ?Event = null;
    for ("[201~") |byte| event = decoder.feed(byte);
    try std.testing.expectEqual(.paste_end, event.?.kind);
}

test "Alt Unicode and CSI survive delayed reads" {
    var decoder: Decoder = .{};
    for ("\x1b\xc3") |byte| try std.testing.expect(decoder.feed(byte) == null);
    try std.testing.expect(decoder.timeout() == null);
    const event = decoder.feed(0xa9).?;
    try std.testing.expect(event.alt);
    try std.testing.expectEqualStrings("\x1bé", event.text());
    for ("\x1b[1;") |byte| _ = decoder.feed(byte);
    try std.testing.expect(decoder.timeout() == null);
    _ = decoder.feed('2');
    try std.testing.expect(decoder.feed('A').?.shift);
}

test "modified page keys retain navigation and history modifiers" {
    for ([_][]const u8{ "\x1b[5;5~", "\x1b[6;5~", "\x1b[5;2~", "\x1b[6~" }, [_]Key{ .page_up, .page_down, .page_up, .page_down }, [_]bool{ true, true, false, false }, [_]bool{ false, false, true, false }) |sequence, key, ctrl, shift| {
        var decoder: Decoder = .{};
        var event: ?Event = null;
        for (sequence) |byte| event = decoder.feed(byte);
        try std.testing.expectEqual(key, event.?.key);
        try std.testing.expectEqual(ctrl, event.?.ctrl);
        try std.testing.expectEqual(shift, event.?.shift);
    }
}
