//! Filesystem text is opaque bytes. Escape non-displayable bytes, then use
//! Ghostty's grapheme semantics so names cannot inject terminal controls.
const std = @import("std");
const unicode = @import("ghostty-vt").unicode;
pub const Glyph = struct { text: []const u8, width: u2 };

pub fn prepare(allocator: std.mem.Allocator, raw: []const u8) ![]Glyph {
    var safe: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        const length = std.unicode.utf8ByteSequenceLength(raw[i]) catch 0;
        const cp = if (length > 0 and i + length <= raw.len) std.unicode.utf8Decode(raw[i..][0..length]) catch null else null;
        if (cp == null or cp.? < 32 or (cp.? >= 127 and cp.? <= 159) or cp.? == '\\') {
            const escaped = try std.fmt.allocPrint(allocator, "\\x{X:0>2}", .{raw[i]});
            try safe.appendSlice(allocator, escaped);
            i += 1;
        } else if ((cp.? >= 0x202a and cp.? <= 0x202e) or (cp.? >= 0x2066 and cp.? <= 0x2069)) {
            try safe.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\\u{{{X}}}", .{cp.?}));
            i += length;
        } else {
            try safe.appendSlice(allocator, raw[i..][0..length]);
            i += length;
        }
    }
    var cps: std.ArrayList(u21) = .empty;
    var offsets: std.ArrayList(usize) = .empty;
    var it = (try std.unicode.Utf8View.init(safe.items)).iterator();
    while (it.nextCodepoint()) |cp| {
        try offsets.append(allocator, it.i - (try std.unicode.utf8CodepointSequenceLength(cp)));
        try cps.append(allocator, cp);
    }
    try offsets.append(allocator, safe.items.len);
    var glyphs: std.ArrayList(Glyph) = .empty;
    i = 0;
    while (i < cps.items.len) {
        const cluster = unicode.graphemeWidth(u21, cps.items[i..]);
        const bytes = safe.items[offsets.items[i]..offsets.items[i + cluster.len]];
        try glyphs.append(allocator, .{
            .text = if (cluster.width == 0) try std.mem.concat(allocator, u8, &.{ "◌", bytes }) else bytes,
            .width = @intCast(@max(1, cluster.width)),
        });
        i += cluster.len;
    }
    return glyphs.items;
}

pub fn width(glyphs: []const Glyph) usize {
    var result: usize = 0;
    for (glyphs) |glyph| result += glyph.width;
    return result;
}

test "filename controls and invalid bytes are visible, Unicode clusters stay intact" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const glyphs = try prepare(arena.allocator(), "a\x1b[31m\n\xff界e\xcc\x81");
    var text: std.ArrayList(u8) = .empty;
    for (glyphs) |glyph| try text.appendSlice(arena.allocator(), glyph.text);
    try std.testing.expectEqualStrings("a\\x1B[31m\\x0A\\xFF界e\xcc\x81", text.items);
    try std.testing.expectEqual(@as(u2, 2), glyphs[glyphs.len - 2].width);
    try std.testing.expectEqualStrings("e\xcc\x81", glyphs[glyphs.len - 1].text);
}
