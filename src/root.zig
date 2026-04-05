// zchomd: Markdown terminal renderer for Zig.
// Mirrors the glamour Go library API.
pub const ast = @import("ast.zig");
pub const parser = @import("parser.zig");
pub const renderer = @import("renderer.zig");
pub const style = @import("style.zig");

const std = @import("std");

pub const Options = renderer.Options;

/// TermRenderer renders Markdown to ANSI-styled terminal output.
pub const TermRenderer = struct {
    allocator: std.mem.Allocator,
    opts: Options,

    pub fn init(allocator: std.mem.Allocator, opts: Options) TermRenderer {
        return .{ .allocator = allocator, .opts = opts };
    }

    /// Render `input` Markdown and return an owned string.
    /// Caller must free the returned slice.
    pub fn renderAlloc(self: *TermRenderer, input: []const u8) ![]u8 {
        const doc = try parser.parse(self.allocator, input);
        defer doc.destroy(self.allocator);

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        var r = renderer.Renderer.init(self.allocator, self.opts);
        try r.render(buf.writer(self.allocator), doc);

        return buf.toOwnedSlice(self.allocator);
    }

    /// Render `input` Markdown and write to `writer`.
    pub fn render(self: *TermRenderer, writer: anytype, input: []const u8) !void {
        const doc = try parser.parse(self.allocator, input);
        defer doc.destroy(self.allocator);

        var r = renderer.Renderer.init(self.allocator, self.opts);
        try r.render(writer, doc);
    }
};

/// Convenience: render Markdown with the given style name ("dark", "light", "notty").
/// Returns owned slice; caller must free.
pub fn renderAlloc(allocator: std.mem.Allocator, input: []const u8, style_name: []const u8) ![]u8 {
    const s = style.getStandardStyle(style_name) orelse style.dark;
    var tr = TermRenderer.init(allocator, .{ .styles = s });
    return tr.renderAlloc(input);
}

test "basic render" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tr = TermRenderer.init(allocator, .{ .styles = style.notty });
    const result = try tr.renderAlloc("# Hello\n\nWorld\n");
    defer allocator.free(result);

    try testing.expect(result.len > 0);
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "Hello"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "World"));
}

test "emphasis and strong" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tr = TermRenderer.init(allocator, .{ .styles = style.notty });
    const result = try tr.renderAlloc("*italic* and **bold**\n");
    defer allocator.free(result);

    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "italic"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "bold"));
}

test "code span" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tr = TermRenderer.init(allocator, .{ .styles = style.notty });
    const result = try tr.renderAlloc("Use `fmt.Println()` for output.\n");
    defer allocator.free(result);

    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "fmt.Println()"));
}

test "fenced code block" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tr = TermRenderer.init(allocator, .{ .styles = style.notty });
    const md =
        \\```zig
        \\const x = 42;
        \\```
        \\
    ;
    const result = try tr.renderAlloc(md);
    defer allocator.free(result);

    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "const x = 42;"));
}

test "unordered list" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tr = TermRenderer.init(allocator, .{ .styles = style.notty });
    const md =
        \\- Apple
        \\- Banana
        \\- Cherry
        \\
    ;
    const result = try tr.renderAlloc(md);
    defer allocator.free(result);

    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "Apple"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "Banana"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "Cherry"));
}

test "ordered list" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tr = TermRenderer.init(allocator, .{ .styles = style.notty });
    const md =
        \\1. First
        \\2. Second
        \\3. Third
        \\
    ;
    const result = try tr.renderAlloc(md);
    defer allocator.free(result);

    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "First"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "Second"));
}

test "blockquote" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tr = TermRenderer.init(allocator, .{ .styles = style.notty });
    const md =
        \\> This is a quote.
        \\
    ;
    const result = try tr.renderAlloc(md);
    defer allocator.free(result);

    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "This is a quote."));
}

test "link" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tr = TermRenderer.init(allocator, .{ .styles = style.notty });
    const result = try tr.renderAlloc("[Zig](https://ziglang.org)\n");
    defer allocator.free(result);

    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "Zig"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "ziglang.org"));
}

test "thematic break" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tr = TermRenderer.init(allocator, .{ .styles = style.notty });
    const result = try tr.renderAlloc("Before\n\n---\n\nAfter\n");
    defer allocator.free(result);

    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "Before"));
    try testing.expect(std.mem.containsAtLeast(u8, result, 1, "After"));
}
