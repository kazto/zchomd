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
