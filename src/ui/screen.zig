//! Cell composition and differential ANSI output. Frames own all dynamic text.
const std = @import("std");
const Allocator = std.mem.Allocator;
pub const text_layout = @import("text.zig");

pub const Rgb = struct { r: u8, g: u8, b: u8 };
pub const Style = struct {
    fg: Rgb = .{ .r = 220, .g = 224, .b = 230 },
    bg: Rgb = .{ .r = 20, .g = 24, .b = 30 },
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    overline: bool = false,
    blink: bool = false,
};
pub const Cell = struct {
    text: []const u8 = " ",
    width: u2 = 1, // 0 is the continuation of a two-column grapheme.
    style: Style = .{},

    fn eql(a: Cell, b: Cell) bool {
        return a.width == b.width and std.meta.eql(a.style, b.style) and std.mem.eql(u8, a.text, b.text);
    }
};
pub const Rect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};
/// DECSCUSR values for steady (non-blinking) cursor shapes.
pub const CursorShape = enum(u3) { block = 2, underline = 4, bar = 6 };
pub const Cursor = struct { x: usize, y: usize, shape: CursorShape = .block };

pub const Frame = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    cells: []Cell = &.{},
    cols: usize = 0,
    rows: usize = 0,
    cursor: ?Cursor = null,

    pub fn init(allocator: Allocator) Frame {
        return .{ .allocator = allocator, .arena = .init(allocator) };
    }
    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.cells);
        self.arena.deinit();
    }
    pub fn begin(self: *Frame, cols: usize, rows: usize) !void {
        _ = self.arena.reset(.retain_capacity);
        if (self.cells.len != cols * rows) {
            const cells = try self.allocator.alloc(Cell, cols * rows);
            self.allocator.free(self.cells);
            self.cells = cells;
        }
        self.cols = cols;
        self.rows = rows;
        self.cursor = null;
        @memset(self.cells, .{});
    }
    pub fn painter(self: *Frame, rect: Rect) Painter {
        const x = @min(rect.x, self.cols);
        const y = @min(rect.y, self.rows);
        return .{ .frame = self, .rect = .{
            .x = x,
            .y = y,
            .width = @min(rect.width, self.cols - x),
            .height = @min(rect.height, self.rows - y),
        } };
    }
};

pub const Painter = struct {
    frame: *Frame,
    rect: Rect,

    /// Shrink all edges, saturating to an empty painter for tiny rectangles.
    pub fn inset(self: Painter, padding: usize) Painter {
        return self.child(.{
            .x = padding,
            .y = padding,
            .width = (self.rect.width -| padding) -| padding,
            .height = (self.rect.height -| padding) -| padding,
        });
    }

    /// A nested clip rectangle, in this painter's local coordinates.
    pub fn child(self: Painter, rect: Rect) Painter {
        const x = @min(rect.x, self.rect.width);
        const y = @min(rect.y, self.rect.height);
        return self.frame.painter(.{
            .x = self.rect.x + x,
            .y = self.rect.y + y,
            .width = @min(rect.width, self.rect.width - x),
            .height = @min(rect.height, self.rect.height - y),
        });
    }

    pub fn text(self: Painter, x: usize, y: usize, raw: []const u8, style: Style) !void {
        if (x >= self.rect.width or y >= self.rect.height) return;
        const glyphs = try text_layout.prepare(self.frame.arena.allocator(), raw);
        var column = x;
        for (glyphs) |glyph| {
            if (column + glyph.width > self.rect.width) break;
            self.put(column, y, .{ .text = glyph.text, .width = glyph.width, .style = style });
            column += glyph.width;
        }
    }

    /// Keep the directory leaf visible when its full path exceeds the header.
    pub fn textEnd(self: Painter, raw: []const u8, style: Style) !void {
        if (self.rect.width == 0 or self.rect.height == 0) return;
        const glyphs = try text_layout.prepare(self.frame.arena.allocator(), raw);
        var remaining = text_layout.width(glyphs);
        var start: usize = 0;
        var column: usize = 0;
        if (remaining > self.rect.width) {
            self.put(0, 0, .{ .text = "…", .style = style });
            column = 1;
            while (remaining > self.rect.width - 1) : (start += 1) remaining -= glyphs[start].width;
        }
        for (glyphs[start..]) |glyph| {
            self.put(column, 0, .{ .text = glyph.text, .width = glyph.width, .style = style });
            column += glyph.width;
        }
    }

    /// Coordinates are local to the clip rectangle. Text must be a single,
    /// printable grapheme with the supplied width, owned by the frame or static.
    pub fn put(self: Painter, x: usize, y: usize, cell: Cell) void {
        if (x >= self.rect.width or y >= self.rect.height) return;
        if (cell.width == 0) return; // Continuations are created with their lead.
        if (cell.width == 2 and x + 1 >= self.rect.width) return;
        const index = (self.rect.y + y) * self.frame.cols + self.rect.x + x;
        // Overlays cannot leave half of an underlying wide glyph visible.
        // Clear its other half even when it lies just outside this clip.
        self.clearWide(index);
        if (cell.width == 2) self.clearWide(index + 1);
        self.frame.cells[index] = cell;
        if (cell.width == 2) self.frame.cells[index + 1] = .{ .width = 0, .style = cell.style };
    }
    fn clearWide(self: Painter, index: usize) void {
        const old = self.frame.cells[index];
        if (old.width == 0 and index % self.frame.cols > 0) {
            self.frame.cells[index - 1] = .{ .style = self.frame.cells[index - 1].style };
        } else if (old.width == 2 and index % self.frame.cols + 1 < self.frame.cols) {
            self.frame.cells[index + 1] = .{ .style = old.style };
        }
    }
    pub fn fill(self: Painter, style: Style) void {
        for (0..self.rect.height) |y| for (0..self.rect.width) |x| self.put(x, y, .{ .style = style });
    }
    /// ASCII labels only; untrusted path/terminal text must use grapheme cells.
    pub fn label(self: Painter, x: usize, y: usize, value: []const u8, style: Style) void {
        for (value, 0..) |ch, i| {
            if (x + i >= self.rect.width) break;
            if (ch < 32 or ch > 126) continue;
            self.put(x + i, y, .{ .text = value[i .. i + 1], .style = style });
        }
    }
    pub fn border(self: Painter, style: Style) void {
        const w = self.rect.width;
        const h = self.rect.height;
        if (w < 2 or h < 2) return;
        for (1..w - 1) |x| {
            self.put(x, 0, .{ .text = "─", .style = style });
            self.put(x, h - 1, .{ .text = "─", .style = style });
        }
        for (1..h - 1) |y| {
            self.put(0, y, .{ .text = "│", .style = style });
            self.put(w - 1, y, .{ .text = "│", .style = style });
        }
        self.put(0, 0, .{ .text = "┌", .style = style });
        self.put(w - 1, 0, .{ .text = "┐", .style = style });
        self.put(0, h - 1, .{ .text = "└", .style = style });
        self.put(w - 1, h - 1, .{ .text = "┘", .style = style });
    }
};

pub fn encode(writer: *std.Io.Writer, frame: *const Frame, previous: ?*const Frame) !void {
    const full = if (previous) |p| p.cols != frame.cols or p.rows != frame.rows else true;
    try writer.writeAll("\x1b[?25l");
    if (full) try writer.writeAll("\x1b[0m\x1b[2J");
    var last_style: ?Style = null;
    var next_index: ?usize = null;
    for (frame.cells, 0..) |cell, index| {
        if (cell.width == 0) continue;
        if (!full and cell.eql(previous.?.cells[index])) continue;
        if (next_index == null or next_index.? != index or index % frame.cols == 0) {
            try writer.print("\x1b[{d};{d}H", .{ index / frame.cols + 1, index % frame.cols + 1 });
        }
        if (last_style == null or !std.meta.eql(last_style.?, cell.style)) {
            const s = cell.style;
            try writer.print("\x1b[0;38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{ s.fg.r, s.fg.g, s.fg.b, s.bg.r, s.bg.g, s.bg.b });
            if (s.bold) try writer.writeAll("\x1b[1m");
            if (s.faint) try writer.writeAll("\x1b[2m");
            if (s.italic) try writer.writeAll("\x1b[3m");
            if (s.underline) try writer.writeAll("\x1b[4m");
            if (s.blink) try writer.writeAll("\x1b[5m");
            if (s.strike) try writer.writeAll("\x1b[9m");
            if (s.overline) try writer.writeAll("\x1b[53m");
            last_style = s;
        }
        try writer.writeAll(cell.text);
        next_index = index + cell.width;
    }
    try writer.writeAll("\x1b[0m");
    if (frame.cursor) |cursor| {
        if (cursor.x < frame.cols and cursor.y < frame.rows) {
            try writer.print("\x1b[{d};{d}H\x1b[{d} q\x1b[?25h", .{ cursor.y + 1, cursor.x + 1, @intFromEnum(cursor.shape) });
        }
    }
}

test "painter clips a wide glyph at the pane boundary" {
    var frame = Frame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.begin(8, 3);
    const painter = frame.painter(.{ .x = 2, .y = 1, .width = 3, .height = 1 });
    painter.put(2, 0, .{ .text = "界", .width = 2 });
    painter.put(0, 1, .{ .text = "X" });
    try std.testing.expectEqualStrings(" ", frame.cells[12].text);
    try std.testing.expectEqualStrings(" ", frame.cells[18].text);
    painter.put(0, 0, .{ .text = "界", .width = 2 });
    try std.testing.expectEqual(@as(u2, 0), frame.cells[11].width);
}

test "differential output erases a former wide cell" {
    var old = Frame.init(std.testing.allocator);
    defer old.deinit();
    var new = Frame.init(std.testing.allocator);
    defer new.deinit();
    try old.begin(4, 1);
    try new.begin(4, 1);
    old.painter(.{ .x = 0, .y = 0, .width = 4, .height = 1 }).put(0, 0, .{ .text = "界", .width = 2 });
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try encode(&out.writer, &new, &old);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "  ") != null);
}

test "a dialog over half a wide glyph leaves no orphan cell" {
    var frame = Frame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.begin(8, 1);
    const whole = frame.painter(.{ .x = 0, .y = 0, .width = 8, .height = 1 });
    whole.put(2, 0, .{ .text = "界", .width = 2 });
    whole.child(.{ .x = 3, .y = 0, .width = 2, .height = 1 }).put(0, 0, .{ .text = "|" });
    try std.testing.expectEqualStrings(" ", frame.cells[2].text);
    try std.testing.expectEqual(@as(u2, 1), frame.cells[2].width);
    try std.testing.expectEqualStrings("|", frame.cells[3].text);
}

test "insets stay within their parent even when padding exceeds its size" {
    var frame = Frame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.begin(10, 8);
    const parent = frame.painter(.{ .x = 2, .y = 1, .width = 6, .height = 5 });
    for ([_]usize{ 0, 1, 3, 6, std.math.maxInt(usize) }) |padding| {
        const inside = parent.inset(padding);
        try std.testing.expect(inside.rect.x >= parent.rect.x);
        try std.testing.expect(inside.rect.y >= parent.rect.y);
        try std.testing.expect(inside.rect.x + inside.rect.width <= parent.rect.x + parent.rect.width);
        try std.testing.expect(inside.rect.y + inside.rect.height <= parent.rect.y + parent.rect.height);
        inside.fill(.{});
    }
}
