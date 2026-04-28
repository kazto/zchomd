// ANSI escape code utilities for terminal styling.
const std = @import("std");
const style = @import("style.zig");

/// Parsed color representation.
pub const Color = union(enum) {
    none,
    palette: u8, // 256-color palette index "0"-"255"
    rgb: struct { r: u8, g: u8, b: u8 }, // truecolor "#RRGGBB"

    pub fn parse(s: []const u8) Color {
        if (s.len == 0) return .none;
        if (s[0] == '#' and s.len == 7) {
            const r = std.fmt.parseInt(u8, s[1..3], 16) catch return .none;
            const g = std.fmt.parseInt(u8, s[3..5], 16) catch return .none;
            const b = std.fmt.parseInt(u8, s[5..7], 16) catch return .none;
            return .{ .rgb = .{ .r = r, .g = g, .b = b } };
        }
        const n = std.fmt.parseInt(u8, s, 10) catch return .none;
        return .{ .palette = n };
    }
};

/// Write the opening ANSI escape sequence for a StylePrimitive.
/// Returns true if any codes were written (caller should write reset on close).
pub fn writeOpen(w: anytype, s: style.StylePrimitive) !bool {
    var any = false;

    if (s.color) |c| {
        const col = Color.parse(c);
        switch (col) {
            .none => {},
            .palette => |n| {
                try w.print("\x1b[38;5;{d}m", .{n});
                any = true;
            },
            .rgb => |rgb| {
                try w.print("\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b });
                any = true;
            },
        }
    }

    if (s.background_color) |c| {
        const col = Color.parse(c);
        switch (col) {
            .none => {},
            .palette => |n| {
                try w.print("\x1b[48;5;{d}m", .{n});
                any = true;
            },
            .rgb => |rgb| {
                try w.print("\x1b[48;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b });
                any = true;
            },
        }
    }

    if (s.bold) |b| if (b) {
        try w.writeAll("\x1b[1m");
        any = true;
    };
    if (s.faint) |f| if (f) {
        try w.writeAll("\x1b[2m");
        any = true;
    };
    if (s.italic) |i| if (i) {
        try w.writeAll("\x1b[3m");
        any = true;
    };
    if (s.underline) |u| if (u) {
        try w.writeAll("\x1b[4m");
        any = true;
    };
    if (s.blink) |b| if (b) {
        try w.writeAll("\x1b[5m");
        any = true;
    };
    if (s.inverse) |v| if (v) {
        try w.writeAll("\x1b[7m");
        any = true;
    };
    if (s.crossed_out) |x| if (x) {
        try w.writeAll("\x1b[9m");
        any = true;
    };

    return any;
}

/// Write ANSI reset sequence.
pub fn writeReset(w: anytype) !void {
    try w.writeAll("\x1b[0m");
}

/// Write text with full styling applied: codes, text, reset.
pub fn writeStyled(w: anytype, s: style.StylePrimitive, text: []const u8) !void {
    if (text.len == 0) return;
    const had_codes = try writeOpen(w, s);
    var transformed_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&transformed_buf);
    const txt = transformText(fba.allocator(), s, text) catch text;
    try w.writeAll(txt);
    if (had_codes) try writeReset(w);
}

/// Apply text transformations (upper/lower/title) specified by style.
fn transformText(allocator: std.mem.Allocator, s: style.StylePrimitive, text: []const u8) ![]const u8 {
    if (s.upper) |u| if (u) {
        const buf = try allocator.alloc(u8, text.len);
        return std.ascii.upperString(buf, text);
    };
    if (s.lower) |l| if (l) {
        const buf = try allocator.alloc(u8, text.len);
        return std.ascii.lowerString(buf, text);
    };
    // title case: capitalize first letter of each word
    if (s.title) |t| if (t) {
        const buf = try allocator.dupe(u8, text);
        var prev_space = true;
        for (buf, 0..) |c, i| {
            if (prev_space and std.ascii.isAlphabetic(c)) {
                buf[i] = std.ascii.toUpper(c);
            }
            prev_space = std.ascii.isWhitespace(c);
        }
        return buf;
    };
    return text;
}

/// Word-wrap text to fit within `width` columns.
/// Inserts '\n' at word boundaries. Returns allocated slice.
pub fn wordWrap(allocator: std.mem.Allocator, text: []const u8, width: usize, indent: usize) ![]u8 {
    if (width == 0 or text.len == 0) return allocator.dupe(u8, text);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var line_len: usize = indent; // current line length accounting for any leading indent
    var i: usize = 0;

    while (i < text.len) {
        // Skip leading spaces at start of line (except indent)
        if (line_len == indent) {
            while (i < text.len and text[i] == ' ') : (i += 1) {}
        }

        if (i >= text.len) break;

        if (text[i] == '\n') {
            try result.append(allocator, '\n');
            line_len = indent;
            i += 1;
            continue;
        }

        // Find end of next word
        var word_end = i;
        while (word_end < text.len and text[word_end] != ' ' and text[word_end] != '\n') {
            word_end += 1;
        }
        const word = text[i..word_end];

        // Check if word fits on current line
        if (line_len + word.len > width and line_len > indent) {
            try result.append(allocator, '\n');
            line_len = indent;
        }

        try result.appendSlice(allocator, word);
        line_len += word.len;

        if (word_end < text.len) {
            if (text[word_end] == '\n') {
                try result.append(allocator, '\n');
                line_len = indent;
                i = word_end + 1;
            } else {
                // space
                if (line_len < width) {
                    try result.append(allocator, ' ');
                    line_len += 1;
                }
                i = word_end + 1;
            }
        } else {
            i = word_end;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Remove ANSI escape sequences from a string.
/// Caller must free the returned slice.
pub fn stripAnsi(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\x1b') {
            i += 1;
            while (i < s.len and !std.ascii.isAlphabetic(s[i])) : (i += 1) {}
            if (i < s.len) i += 1;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Compute the visible display width of a string, skipping ANSI escape sequences.
/// CJK and other East Asian wide characters are counted as 2 columns.
pub fn visibleWidth(s: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\x1b') {
            // Skip escape sequence: ESC [ ... <letter>
            i += 1;
            while (i < s.len and !std.ascii.isAlphabetic(s[i])) : (i += 1) {}
            if (i < s.len) i += 1;
        } else {
            const b = s[i];
            var cp: u21 = 0;
            var char_len: usize = 1;
            if (b < 0x80) {
                cp = b;
                char_len = 1;
            } else if (b & 0xE0 == 0xC0 and i + 1 < s.len) {
                cp = (@as(u21, b & 0x1F) << 6) | (s[i + 1] & 0x3F);
                char_len = 2;
            } else if (b & 0xF0 == 0xE0 and i + 2 < s.len) {
                cp = (@as(u21, b & 0x0F) << 12) |
                    (@as(u21, s[i + 1] & 0x3F) << 6) |
                    (s[i + 2] & 0x3F);
                char_len = 3;
            } else if (b & 0xF8 == 0xF0 and i + 3 < s.len) {
                cp = (@as(u21, b & 0x07) << 18) |
                    (@as(u21, s[i + 1] & 0x3F) << 12) |
                    (@as(u21, s[i + 2] & 0x3F) << 6) |
                    (s[i + 3] & 0x3F);
                char_len = 4;
            }
            i += char_len;
            width += if (isWideCodepoint(cp)) 2 else 1;
        }
    }
    return width;
}

fn isWideCodepoint(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or // Hangul Jamo
        (cp >= 0x2E80 and cp <= 0x303F) or // CJK Radicals / Kangxi
        (cp >= 0x3040 and cp <= 0xA4CF) or // Hiragana–Yi
        (cp >= 0xAC00 and cp <= 0xD7AF) or // Hangul Syllables
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compatibility Ideographs
        (cp >= 0xFE10 and cp <= 0xFE1F) or // Vertical Forms
        (cp >= 0xFE30 and cp <= 0xFE6F) or // CJK Compatibility Forms
        (cp >= 0xFF01 and cp <= 0xFF60) or // Fullwidth ASCII / punctuation
        (cp >= 0xFFE0 and cp <= 0xFFE6); // Fullwidth Signs
}

/// Write an indented block: prepend indent_token to each line.
pub fn writeIndented(w: anytype, text: []const u8, indent_token: []const u8, margin: usize) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first or line.len > 0) {
            // write margin spaces
            for (0..margin) |_| try w.writeByte(' ');
            if (indent_token.len > 0) try w.writeAll(indent_token);
            try w.writeAll(line);
            try w.writeByte('\n');
        }
        first = false;
    }
}
