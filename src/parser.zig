// Markdown parser for zchomd.
// Implements a two-pass parser: block structure first, then inline elements.
const std = @import("std");
const ast = @import("ast.zig");

// ── Public API ────────────────────────────────────────────────────────────────

/// Parse Markdown input and return the root document node.
/// All nodes are allocated using `allocator`. Caller must call
/// `document.destroy(allocator)` when done.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !*ast.Node {
    var parser = try Parser.init(allocator, input);
    return parser.parseDocument();
}

// ── Internal Types ────────────────────────────────────────────────────────────

const MarkerInfo = struct {
    ordered: bool,
    start: u32,
    content_offset: usize, // bytes to skip past the marker
};

const Parser = struct {
    allocator: std.mem.Allocator,
    lines: [][]const u8,
    pos: usize, // current line index

    fn init(allocator: std.mem.Allocator, input: []const u8) !Parser {
        var line_list: std.ArrayList([]const u8) = .empty;
        errdefer line_list.deinit(allocator);

        var it = std.mem.splitScalar(u8, input, '\n');
        while (it.next()) |line| {
            try line_list.append(allocator, line);
        }
        // Remove trailing empty line if input ends with \n
        if (line_list.items.len > 0 and
            line_list.items[line_list.items.len - 1].len == 0)
        {
            _ = line_list.pop();
        }

        return .{
            .allocator = allocator,
            .lines = try line_list.toOwnedSlice(allocator),
            .pos = 0,
        };
    }

    fn deinit(self: *Parser) void {
        self.allocator.free(self.lines);
    }

    fn atEnd(self: *Parser) bool {
        return self.pos >= self.lines.len;
    }

    fn current(self: *Parser) []const u8 {
        if (self.pos >= self.lines.len) return "";
        return self.lines[self.pos];
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.lines.len) self.pos += 1;
    }

    // ── Block Parsing ─────────────────────────────────────────────────────────

    fn parseDocument(self: *Parser) !*ast.Node {
        const doc = try ast.Node.create(self.allocator, .document);
        while (!self.atEnd()) {
            const line = self.current();
            if (isBlankLine(line)) {
                self.advance();
                continue;
            }
            const block = try self.parseBlock(0) orelse continue;
            try doc.appendChild(self.allocator, block);
        }
        self.deinit();
        return doc;
    }

    /// Parse a single block element at the given indentation level.
    fn parseBlock(self: *Parser, indent: usize) !?*ast.Node {
        const line = self.current();
        const stripped = stripIndent(line, indent);

        if (isBlankLine(stripped)) {
            self.advance();
            return null;
        }
        if (isThematicBreak(stripped)) {
            self.advance();
            return ast.Node.create(self.allocator, .thematic_break);
        }
        if (headingLevel(stripped)) |level| {
            return self.parseHeading(level, indent);
        }
        if (isFencedCodeFence(stripped)) {
            return self.parseFencedCode(indent);
        }
        if (isBlockquote(stripped)) {
            return self.parseBlockquote(indent);
        }
        if (listMarker(stripped)) |_| {
            return self.parseList(indent);
        }
        if (isIndentedCode(line, indent)) {
            return self.parseIndentedCode(indent);
        }
        // GFM table: current line has '|' and next line is a separator row
        if (std.mem.indexOfScalar(u8, stripped, '|') != null and
            self.pos + 1 < self.lines.len)
        {
            const next_line = stripIndent(self.lines[self.pos + 1], indent);
            if (isTableSeparator(next_line)) {
                return self.parseTable(indent);
            }
        }
        return self.parseParagraph(indent);
    }

    fn parseHeading(self: *Parser, level: u8, indent: usize) !*ast.Node {
        const line = stripIndent(self.current(), indent);
        self.advance();

        // Strip leading '#' chars and space
        var text = line[level..];
        if (text.len > 0 and text[0] == ' ') text = text[1..];
        // Strip trailing '#' (closing sequence)
        const trimmed = std.mem.trimRight(u8, text, " ");
        var end = trimmed.len;
        while (end > 0 and trimmed[end - 1] == '#') : (end -= 1) {}
        if (end < trimmed.len and (end == 0 or trimmed[end - 1] == ' ')) {
            text = std.mem.trimRight(u8, trimmed[0..end], " ");
        } else {
            text = trimmed;
        }

        const node = try ast.Node.create(self.allocator, .heading);
        node.level = level;
        try parseInlineChildren(self.allocator, node, text);
        return node;
    }

    fn parseFencedCode(self: *Parser, indent: usize) !*ast.Node {
        const fence_line = stripIndent(self.current(), indent);
        self.advance();

        const fence_char: u8 = fence_line[0];
        var fence_len: usize = 0;
        while (fence_len < fence_line.len and fence_line[fence_len] == fence_char) {
            fence_len += 1;
        }
        const info = std.mem.trim(u8, fence_line[fence_len..], " \t");

        var code_buf: std.ArrayList(u8) = .empty;
        defer code_buf.deinit(self.allocator);

        while (!self.atEnd()) {
            const line = self.current();
            const s = stripIndent(line, indent);
            if (isClosingFence(s, fence_char, fence_len)) {
                self.advance();
                break;
            }
            try code_buf.appendSlice(self.allocator, line);
            try code_buf.append(self.allocator, '\n');
            self.advance();
        }

        const node = try ast.Node.create(self.allocator, .fenced_code_block);
        node.language = try self.allocator.dupe(u8, info);
        node.text = try code_buf.toOwnedSlice(self.allocator);
        return node;
    }

    fn parseBlockquote(self: *Parser, indent: usize) !*ast.Node {
        // Collect all blockquote lines, strip '>' prefix, then parse recursively
        var inner_buf: std.ArrayList(u8) = .empty;
        defer inner_buf.deinit(self.allocator);

        while (!self.atEnd()) {
            const line = self.current();
            const stripped = stripIndent(line, indent);
            if (isBlankLine(stripped)) break;
            if (!isBlockquote(stripped)) break;

            const content = blockquoteContent(stripped);
            try inner_buf.appendSlice(self.allocator, content);
            try inner_buf.append(self.allocator, '\n');
            self.advance();
        }

        const inner_text = try inner_buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(inner_text);

        // Recursively parse the inner content
        var inner_parser = try Parser.init(self.allocator, inner_text);
        const inner_doc = try inner_parser.parseDocument();
        defer inner_doc.destroy(self.allocator);

        const node = try ast.Node.create(self.allocator, .blockquote);
        // Move children from inner_doc to blockquote node
        for (inner_doc.children.items) |child| {
            // We need to transfer ownership; re-allocate children isn't ideal.
            // Instead, use appendChild which just appends the pointer.
            try node.children.append(self.allocator, child);
        }
        // Clear inner_doc's children so destroy doesn't double-free
        inner_doc.children.clearRetainingCapacity();
        return node;
    }

    fn parseList(self: *Parser, indent: usize) !*ast.Node {
        const first_line = stripIndent(self.current(), indent);
        const first_marker = listMarker(first_line).?;

        const list_node = try ast.Node.create(self.allocator, .list);
        list_node.ordered = first_marker.ordered;
        list_node.list_start = first_marker.start;

        while (!self.atEnd()) {
            const line = self.current();
            if (isBlankLine(line)) {
                self.advance();
                if (!self.atEnd()) {
                    const next = stripIndent(self.current(), indent);
                    if (!isBlankLine(next) and listMarker(next) == null) break;
                }
                continue;
            }

            const stripped = stripIndent(line, indent);
            if (isBlankLine(stripped)) {
                self.advance();
                continue;
            }

            const marker = listMarker(stripped) orelse break;
            if (marker.ordered != first_marker.ordered) break;

            const item = try self.parseListItem(indent, marker);
            try list_node.appendChild(self.allocator, item);
        }

        return list_node;
    }

    fn parseListItem(self: *Parser, indent: usize, marker: MarkerInfo) !*ast.Node {
        const item_node = try ast.Node.create(self.allocator, .list_item);
        item_node.enumeration = marker.start;
        item_node.ordered = marker.ordered;

        const line = stripIndent(self.current(), indent);
        var content = line[marker.content_offset..];
        self.advance();

        // Check for task checkbox
        if (std.mem.startsWith(u8, content, "[ ] ") or
            std.mem.startsWith(u8, content, "[x] ") or
            std.mem.startsWith(u8, content, "[X] "))
        {
            item_node.task_checked = (content[1] == 'x' or content[1] == 'X');
            content = content[4..];
        }

        // Parse inline content of first line
        const para = try ast.Node.create(self.allocator, .paragraph);
        try parseInlineChildren(self.allocator, para, std.mem.trimRight(u8, content, " \t\r"));
        try item_node.appendChild(self.allocator, para);

        // Parse continuation lines
        const continuation_indent = indent + marker.content_offset;
        while (!self.atEnd()) {
            const next = self.current();
            if (isBlankLine(next)) {
                self.advance();
                var lookahead: usize = 0;
                while (self.pos + lookahead < self.lines.len and
                    isBlankLine(self.lines[self.pos + lookahead])) : (lookahead += 1)
                {}
                if (self.pos + lookahead >= self.lines.len) break;
                const la = self.lines[self.pos + lookahead];
                const la_stripped = stripIndent(la, indent);
                if (listMarker(la_stripped) != null or !hasIndent(la, continuation_indent)) break;
                continue;
            }
            if (!hasIndent(next, continuation_indent) and
                listMarker(stripIndent(next, indent)) != null)
            {
                break;
            }
            if (!hasIndent(next, continuation_indent)) break;

            if (try self.parseBlock(continuation_indent)) |sub| {
                try item_node.appendChild(self.allocator, sub);
            }
        }

        return item_node;
    }

    fn parseIndentedCode(self: *Parser, indent: usize) !*ast.Node {
        var code_buf: std.ArrayList(u8) = .empty;
        defer code_buf.deinit(self.allocator);

        while (!self.atEnd()) {
            const line = self.current();
            if (isBlankLine(line)) {
                try code_buf.append(self.allocator, '\n');
                self.advance();
                continue;
            }
            if (!hasIndent(line, indent + 4)) break;
            try code_buf.appendSlice(self.allocator, line[indent + 4 ..]);
            try code_buf.append(self.allocator, '\n');
            self.advance();
        }

        const all_code = try code_buf.toOwnedSlice(self.allocator);
        const trimmed = std.mem.trimRight(u8, all_code, "\n");

        const node = try ast.Node.create(self.allocator, .code_block);
        node.text = try self.allocator.dupe(u8, trimmed);
        self.allocator.free(all_code);
        return node;
    }

    fn parseParagraph(self: *Parser, indent: usize) !*ast.Node {
        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(self.allocator);

        while (!self.atEnd()) {
            const line = self.current();
            const stripped = stripIndent(line, indent);
            if (isBlankLine(stripped)) break;
            if (headingLevel(stripped) != null) break;
            if (isFencedCodeFence(stripped)) break;
            if (isThematicBreak(stripped)) break;
            if (isBlockquote(stripped)) break;

            if (text_buf.items.len > 0) {
                const prev = std.mem.trimRight(u8, text_buf.items, " ");
                const trailing_spaces = text_buf.items.len - prev.len;
                if (trailing_spaces >= 2) {
                    text_buf.items.len = prev.len;
                    try text_buf.append(self.allocator, '\n');
                } else {
                    if (text_buf.items.len > 0 and
                        text_buf.items[text_buf.items.len - 1] != '\n')
                    {
                        try text_buf.append(self.allocator, ' ');
                    }
                }
            }
            try text_buf.appendSlice(self.allocator, std.mem.trimRight(u8, stripped, " \t\r"));
            self.advance();
        }

        const node = try ast.Node.create(self.allocator, .paragraph);
        const raw = std.mem.trim(u8, text_buf.items, " \t");
        try parseInlineChildren(self.allocator, node, raw);
        return node;
    }
    fn parseTable(self: *Parser, indent: usize) !*ast.Node {
        const table = try ast.Node.create(self.allocator, .table);

        // ── Header row ────────────────────────────────────────────────────────
        const head = try ast.Node.create(self.allocator, .table_head);
        const header_line = stripIndent(self.current(), indent);
        self.advance();
        {
            const cells = tableCellSplit(header_line);
            var it = std.mem.splitScalar(u8, cells, '|');
            while (it.next()) |raw| {
                const text = std.mem.trim(u8, raw, " \t");
                const cell = try ast.Node.create(self.allocator, .table_cell);
                try parseInlineChildren(self.allocator, cell, text);
                try head.appendChild(self.allocator, cell);
            }
        }
        try table.appendChild(self.allocator, head);

        // ── Separator row — extract column alignment ───────────────────────
        const sep_line = stripIndent(self.current(), indent);
        self.advance();
        {
            const cells = tableCellSplit(sep_line);
            var it = std.mem.splitScalar(u8, cells, '|');
            var col: usize = 0;
            while (it.next()) |raw| : (col += 1) {
                const text = std.mem.trim(u8, raw, " ");
                if (text.len == 0) continue;
                if (col < head.children.items.len) {
                    head.children.items[col].col_align = tableAlignFrom(text);
                }
            }
        }

        // ── Body rows ─────────────────────────────────────────────────────────
        while (!self.atEnd()) {
            const line = self.current();
            const stripped = stripIndent(line, indent);
            if (isBlankLine(stripped)) break;
            if (std.mem.indexOfScalar(u8, stripped, '|') == null) break;
            self.advance();

            const row = try ast.Node.create(self.allocator, .table_row);
            const cells = tableCellSplit(stripped);
            var it = std.mem.splitScalar(u8, cells, '|');
            var col: usize = 0;
            while (it.next()) |raw| : (col += 1) {
                const text = std.mem.trim(u8, raw, " \t");
                const cell = try ast.Node.create(self.allocator, .table_cell);
                // Copy alignment from the corresponding header cell.
                if (col < head.children.items.len) {
                    cell.col_align = head.children.items[col].col_align;
                }
                try parseInlineChildren(self.allocator, cell, text);
                try row.appendChild(self.allocator, cell);
            }
            try table.appendChild(self.allocator, row);
        }

        return table;
    }
};

// ── Inline Parser ─────────────────────────────────────────────────────────────

/// Parse inline elements from `text` and append as children of `parent`.
fn parseInlineChildren(
    allocator: std.mem.Allocator,
    parent: *ast.Node,
    text: []const u8,
) !void {
    var p = InlineParser.init(allocator, text);
    try p.parse(parent);
}

const InlineParser = struct {
    allocator: std.mem.Allocator,
    src: []const u8,
    pos: usize,

    fn init(allocator: std.mem.Allocator, src: []const u8) InlineParser {
        return .{ .allocator = allocator, .src = src, .pos = 0 };
    }

    fn atEnd(self: *InlineParser) bool {
        return self.pos >= self.src.len;
    }

    fn ch(self: *InlineParser) u8 {
        return self.src[self.pos];
    }

    fn parse(self: *InlineParser, parent: *ast.Node) anyerror!void {
        var text_start = self.pos;

        while (!self.atEnd()) {
            const c = self.ch();

            switch (c) {
                '`' => {
                    try self.flushText(parent, text_start);
                    if (try self.parseCodeSpan()) |node| {
                        try parent.appendChild(self.allocator, node);
                    } else {
                        self.pos += 1;
                    }
                    text_start = self.pos;
                },
                '*', '_' => {
                    try self.flushText(parent, text_start);
                    if (try self.parseEmphStrong()) |node| {
                        try parent.appendChild(self.allocator, node);
                        text_start = self.pos;
                    } else {
                        self.pos += 1;
                        text_start = self.pos - 1;
                    }
                },
                '~' => {
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '~') {
                        try self.flushText(parent, text_start);
                        if (try self.parseStrikethrough()) |node| {
                            try parent.appendChild(self.allocator, node);
                            text_start = self.pos;
                        } else {
                            self.pos += 1;
                            text_start = self.pos - 1;
                        }
                    } else {
                        self.pos += 1;
                    }
                },
                '[' => {
                    try self.flushText(parent, text_start);
                    if (try self.parseLinkOrImage(false)) |node| {
                        try parent.appendChild(self.allocator, node);
                        text_start = self.pos;
                    } else {
                        self.pos += 1;
                        text_start = self.pos - 1;
                    }
                },
                '!' => {
                    if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '[') {
                        try self.flushText(parent, text_start);
                        self.pos += 1; // skip '!'
                        if (try self.parseLinkOrImage(true)) |node| {
                            try parent.appendChild(self.allocator, node);
                            text_start = self.pos;
                        } else {
                            self.pos -= 1;
                            self.pos += 1;
                            text_start = self.pos - 1;
                        }
                    } else {
                        self.pos += 1;
                    }
                },
                '<' => {
                    try self.flushText(parent, text_start);
                    if (try self.parseAutoLink()) |node| {
                        try parent.appendChild(self.allocator, node);
                        text_start = self.pos;
                    } else {
                        self.pos += 1;
                        text_start = self.pos - 1;
                    }
                },
                '\n' => {
                    try self.flushText(parent, text_start);
                    const brk = try ast.Node.create(self.allocator, .hard_break);
                    try parent.appendChild(self.allocator, brk);
                    self.pos += 1;
                    text_start = self.pos;
                },
                '\\' => {
                    try self.flushText(parent, text_start);
                    self.pos += 1;
                    if (!self.atEnd()) {
                        const escaped = try ast.Node.create(self.allocator, .text);
                        escaped.text = self.src[self.pos .. self.pos + 1];
                        try parent.appendChild(self.allocator, escaped);
                        self.pos += 1;
                    }
                    text_start = self.pos;
                },
                else => {
                    self.pos += 1;
                },
            }
        }
        try self.flushText(parent, text_start);
    }

    fn flushText(self: *InlineParser, parent: *ast.Node, start: usize) !void {
        if (self.pos > start) {
            const t = self.src[start..self.pos];
            if (t.len > 0) {
                const node = try ast.Node.create(self.allocator, .text);
                node.text = try self.allocator.dupe(u8, t);
                try parent.appendChild(self.allocator, node);
            }
        }
    }

    fn parseCodeSpan(self: *InlineParser) !?*ast.Node {
        const start = self.pos;
        var tick_count: usize = 0;
        while (self.pos < self.src.len and self.src[self.pos] == '`') {
            tick_count += 1;
            self.pos += 1;
        }
        const content_start = self.pos;

        while (self.pos < self.src.len) {
            if (self.src[self.pos] == '`') {
                var close_count: usize = 0;
                const close_start = self.pos;
                while (self.pos < self.src.len and self.src[self.pos] == '`') {
                    close_count += 1;
                    self.pos += 1;
                }
                if (close_count == tick_count) {
                    var code = self.src[content_start..close_start];
                    if (code.len > 0 and code[0] == ' ' and code[code.len - 1] == ' ') {
                        code = code[1 .. code.len - 1];
                    }
                    const node = try ast.Node.create(self.allocator, .code_span);
                    node.text = try self.allocator.dupe(u8, code);
                    return node;
                }
            } else {
                self.pos += 1;
            }
        }
        self.pos = start + 1;
        return null;
    }

    fn parseEmphStrong(self: *InlineParser) !?*ast.Node {
        const delim = self.src[self.pos];
        var count: usize = 0;
        while (self.pos < self.src.len and self.src[self.pos] == delim) {
            count += 1;
            self.pos += 1;
        }
        if (count > 2) {
            self.pos -= count;
            self.pos += 1;
            return null;
        }

        const is_strong = count == 2;
        const kind: ast.NodeKind = if (is_strong) .strong else .emphasis;

        var closing_buf: [2]u8 = undefined;
        const closing_str = blk: {
            if (is_strong) {
                closing_buf = .{ delim, delim };
                break :blk closing_buf[0..2];
            } else {
                closing_buf[0] = delim;
                break :blk closing_buf[0..1];
            }
        };

        const content_start = self.pos;
        const close_idx = std.mem.indexOf(u8, self.src[self.pos..], closing_str);
        if (close_idx == null) {
            self.pos = content_start - count + 1;
            return null;
        }

        const content_end = self.pos + close_idx.?;
        const content = self.src[content_start..content_end];

        const node = try ast.Node.create(self.allocator, kind);
        var inner = InlineParser.init(self.allocator, content);
        try inner.parse(node);

        self.pos = content_end + closing_str.len;
        return node;
    }

    fn parseStrikethrough(self: *InlineParser) !?*ast.Node {
        const start = self.pos;
        self.pos += 2;

        const close = std.mem.indexOf(u8, self.src[self.pos..], "~~") orelse {
            self.pos = start + 1;
            return null;
        };

        const content = self.src[self.pos .. self.pos + close];
        const node = try ast.Node.create(self.allocator, .strikethrough);
        var inner = InlineParser.init(self.allocator, content);
        try inner.parse(node);
        self.pos += close + 2;
        return node;
    }

    fn parseLinkOrImage(self: *InlineParser, is_image: bool) !?*ast.Node {
        const start = self.pos;
        if (self.pos >= self.src.len or self.src[self.pos] != '[') {
            return null;
        }
        self.pos += 1;

        const text_start = self.pos;
        var depth: usize = 1;
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                '[' => depth += 1,
                ']' => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                else => {},
            }
            self.pos += 1;
        }
        if (self.pos >= self.src.len) {
            self.pos = start;
            return null;
        }
        const text_end = self.pos;
        self.pos += 1;

        if (self.pos >= self.src.len or self.src[self.pos] != '(') {
            self.pos = start;
            return null;
        }
        self.pos += 1;

        const dest_start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != ')') {
            self.pos += 1;
        }
        if (self.pos >= self.src.len) {
            self.pos = start;
            return null;
        }
        const dest_end = self.pos;
        self.pos += 1;

        const dest_raw = self.src[dest_start..dest_end];
        var url: []const u8 = dest_raw;
        var title: []const u8 = "";

        if (std.mem.indexOfScalar(u8, dest_raw, '"')) |ti| {
            url = std.mem.trimRight(u8, dest_raw[0..ti], " ");
            const title_start = ti + 1;
            const title_end = std.mem.lastIndexOfScalar(u8, dest_raw, '"') orelse dest_raw.len;
            if (title_end > title_start) title = dest_raw[title_start..title_end];
        } else if (std.mem.indexOfScalar(u8, dest_raw, '\'')) |ti| {
            url = std.mem.trimRight(u8, dest_raw[0..ti], " ");
            const title_start = ti + 1;
            const title_end = std.mem.lastIndexOfScalar(u8, dest_raw, '\'') orelse dest_raw.len;
            if (title_end > title_start) title = dest_raw[title_start..title_end];
        }

        const link_text = self.src[text_start..text_end];
        const node_kind: ast.NodeKind = if (is_image) .image else .link;
        const node = try ast.Node.create(self.allocator, node_kind);
        node.url = try self.allocator.dupe(u8, url);
        node.link_title = try self.allocator.dupe(u8, title);

        if (is_image) {
            node.text = try self.allocator.dupe(u8, link_text);
        } else {
            var inner = InlineParser.init(self.allocator, link_text);
            try inner.parse(node);
        }
        return node;
    }

    fn parseAutoLink(self: *InlineParser) !?*ast.Node {
        const start = self.pos;
        self.pos += 1; // skip '<'

        const end = std.mem.indexOfScalarPos(u8, self.src, self.pos, '>') orelse {
            self.pos = start;
            return null;
        };
        const content = self.src[self.pos..end];

        if (std.mem.indexOfScalar(u8, content, ' ') != null) {
            self.pos = start;
            return null;
        }
        if (std.mem.indexOfScalar(u8, content, ':') == null and
            std.mem.indexOfScalar(u8, content, '@') == null)
        {
            self.pos = start;
            return null;
        }

        self.pos = end + 1;
        const node = try ast.Node.create(self.allocator, .auto_link);
        node.url = try self.allocator.dupe(u8, content);
        node.text = try self.allocator.dupe(u8, content);
        return node;
    }
};

// ── Helper Functions ──────────────────────────────────────────────────────────

fn isBlankLine(line: []const u8) bool {
    return std.mem.trim(u8, line, " \t\r").len == 0;
}

fn isThematicBreak(line: []const u8) bool {
    const s = std.mem.trim(u8, line, " \t");
    if (s.len < 3) return false;
    const c = s[0];
    if (c != '-' and c != '*' and c != '_') return false;
    for (s) |ch| {
        if (ch != c and ch != ' ') return false;
    }
    var count: usize = 0;
    for (s) |ch| if (ch == c) {
        count += 1;
    };
    return count >= 3;
}

fn headingLevel(line: []const u8) ?u8 {
    const s = std.mem.trimLeft(u8, line, " ");
    if (s.len == 0 or s[0] != '#') return null;
    var level: u8 = 0;
    while (level < s.len and s[level] == '#' and level < 6) : (level += 1) {}
    if (level == 0 or level > 6) return null;
    if (level < s.len and s[level] != ' ') return null;
    return level;
}

fn isFencedCodeFence(line: []const u8) bool {
    const s = std.mem.trimLeft(u8, line, " ");
    if (s.len < 3) return false;
    const c = s[0];
    if (c != '`' and c != '~') return false;
    var i: usize = 0;
    while (i < s.len and s[i] == c) : (i += 1) {}
    return i >= 3;
}

fn isClosingFence(line: []const u8, fence_char: u8, min_len: usize) bool {
    const s = std.mem.trim(u8, line, " \t");
    if (s.len < min_len) return false;
    for (s) |c| if (c != fence_char) return false;
    return s.len >= min_len;
}

fn isBlockquote(line: []const u8) bool {
    const s = std.mem.trimLeft(u8, line, " ");
    return s.len > 0 and s[0] == '>';
}

fn blockquoteContent(line: []const u8) []const u8 {
    const s = std.mem.trimLeft(u8, line, " ");
    if (s.len == 0 or s[0] != '>') return line;
    if (s.len > 1 and s[1] == ' ') return s[2..];
    return s[1..];
}

fn isIndentedCode(line: []const u8, indent: usize) bool {
    return hasIndent(line, indent + 4);
}

fn hasIndent(line: []const u8, n: usize) bool {
    var spaces: usize = 0;
    for (line) |c| {
        if (c == ' ') spaces += 1 else if (c == '\t') spaces += 4 else break;
        if (spaces >= n) return true;
    }
    return false;
}

fn stripIndent(line: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var spaces: usize = 0;
    while (i < line.len and spaces < n) {
        if (line[i] == ' ') {
            spaces += 1;
            i += 1;
        } else if (line[i] == '\t') {
            spaces += 4;
            i += 1;
        } else {
            break;
        }
    }
    return line[i..];
}

/// Return true if `line` looks like a GFM table separator (`|:?-+:?|...`).
fn isTableSeparator(line: []const u8) bool {
    const s = std.mem.trim(u8, line, " \t");
    if (std.mem.indexOfScalar(u8, s, '|') == null) return false;
    if (std.mem.indexOfScalar(u8, s, '-') == null) return false;
    const cells = tableCellSplit(s);
    var it = std.mem.splitScalar(u8, cells, '|');
    var found: usize = 0;
    while (it.next()) |raw| {
        const cell = std.mem.trim(u8, raw, " ");
        if (cell.len == 0) continue;
        const inner = std.mem.trim(u8, cell, ":");
        if (inner.len == 0) return false;
        for (inner) |c| {
            if (c != '-') return false;
        }
        found += 1;
    }
    return found > 0;
}

/// Derive column alignment from a separator cell like `---`, `:---`, `---:`, `:---:`.
fn tableAlignFrom(cell: []const u8) ast.Align {
    if (cell.len == 0) return .none;
    const left = cell[0] == ':';
    const right = cell[cell.len - 1] == ':';
    if (left and right) return .center;
    if (right) return .right;
    if (left) return .left;
    return .none;
}

/// Strip leading/trailing `|` from a table row and return the inner cell string.
fn tableCellSplit(line: []const u8) []const u8 {
    var s = std.mem.trim(u8, line, " \t");
    if (s.len > 0 and s[0] == '|') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '|') s = s[0 .. s.len - 1];
    return s;
}

fn listMarker(line: []const u8) ?MarkerInfo {
    const s = std.mem.trimLeft(u8, line, " \t");
    if (s.len == 0) return null;

    const leading = line.len - s.len;

    if (s[0] == '-' or s[0] == '*' or s[0] == '+') {
        if (s.len > 1 and (s[1] == ' ' or s[1] == '\t')) {
            return .{ .ordered = false, .start = 0, .content_offset = leading + 2 };
        }
    }

    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i > 0 and i < s.len and (s[i] == '.' or s[i] == ')')) {
        if (i + 1 < s.len and (s[i + 1] == ' ' or s[i + 1] == '\t')) {
            const n = std.fmt.parseInt(u32, s[0..i], 10) catch 1;
            return .{ .ordered = true, .start = n, .content_offset = leading + i + 2 };
        }
    }

    return null;
}
