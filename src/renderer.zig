// ANSI terminal renderer for zchomd.
// Walks the AST and emits styled terminal output.
const std = @import("std");
const ast = @import("ast.zig");
const style = @import("style.zig");
const ansi_util = @import("ansi.zig");

pub const Options = struct {
    styles: style.StyleConfig = style.dark,
    word_wrap: usize = 80,
    preserve_newlines: bool = false,
    use_kitty_text_sizing: bool = false,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    opts: Options,

    pub fn init(allocator: std.mem.Allocator, opts: Options) Renderer {
        return .{ .allocator = allocator, .opts = opts };
    }

    /// Render a document node to `writer`.
    pub fn render(self: *Renderer, writer: anytype, document: *ast.Node) !void {
        var ctx = RenderContext{
            .renderer = self,
            .indent = 0,
            .list_depth = 0,
            .ordered_enum = 0,
        };
        try ctx.renderNode(writer, document);
    }
};

const RenderContext = struct {
    renderer: *Renderer,
    indent: usize, // current left margin in spaces
    list_depth: usize,
    ordered_enum: u32, // current list item enumeration

    fn opts(self: *RenderContext) Options {
        return self.renderer.opts;
    }

    fn allocator(self: *RenderContext) std.mem.Allocator {
        return self.renderer.allocator;
    }

    fn renderNode(self: *RenderContext, writer: anytype, node: *ast.Node) anyerror!void {
        switch (node.kind) {
            .document => try self.renderDocument(writer, node),
            .heading => try self.renderHeading(writer, node),
            .paragraph => try self.renderParagraph(writer, node),
            .blockquote => try self.renderBlockquote(writer, node),
            .list => try self.renderList(writer, node),
            .list_item => try self.renderListItem(writer, node),
            .fenced_code_block => try self.renderFencedCode(writer, node),
            .code_block => try self.renderCodeBlock(writer, node),
            .thematic_break => try self.renderThematicBreak(writer, node),
            .html_block => try self.renderHtmlBlock(writer, node),
            .table => try self.renderTable(writer, node),
            .table_head, .table_row, .table_cell => {},
            // Inline nodes are rendered by their parent context
            .text, .emphasis, .strong, .code_span, .link, .image,
            .auto_link, .strikethrough, .raw_html, .soft_break,
            .hard_break => try self.renderInline(writer, node),
        }
    }

    // ── Block Renderers ───────────────────────────────────────────────────────

    fn renderDocument(self: *RenderContext, writer: anytype, node: *ast.Node) anyerror!void {
        const doc_style = self.opts().styles.document;
        const margin = doc_style.margin orelse 0;
        const old_indent = self.indent;
        self.indent += margin;

        try ansi_util.writeStyled(writer, doc_style.style, doc_style.style.block_prefix);

        for (node.children.items) |child| {
            try self.renderNode(writer, child);
        }

        try ansi_util.writeStyled(writer, doc_style.style, doc_style.style.block_suffix);
        self.indent = old_indent;
    }

    fn renderHeading(self: *RenderContext, writer: anytype, node: *ast.Node) anyerror!void {
        const s = self.opts().styles;
        const use_kitty = self.opts().use_kitty_text_sizing;
        const scale: usize = if (use_kitty) switch (node.level) {
            1 => 3,
            2 => 2,
            else => 1,
        } else 1;

        // Cascade: heading base + specific level style
        var heading_style = s.heading;
        const level_style: style.StyleBlock = switch (node.level) {
            1 => s.h1,
            2 => s.h2,
            3 => s.h3,
            4 => s.h4,
            5 => s.h5,
            6 => s.h6,
            else => .{},
        };
        // Merge: level-specific overrides heading base
        heading_style = mergeBlock(heading_style, level_style);

        if (!node.is_first) {
            try writer.writeByte('\n');
        }

        // Write prefix (unstyled from parent context)
        try ansi_util.writeStyled(writer, s.document.style, heading_style.style.block_prefix);

        // Write optional level prefix (e.g. "## ")
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator());

        // Render inline children into buffer
        if (heading_style.style.prefix.len > 0) {
            try ansi_util.writeStyled(buf.writer(self.allocator()), heading_style.style, heading_style.style.prefix);
        }
        for (node.children.items) |child| {
            try self.renderInlineToWriter(buf.writer(self.allocator()), child, heading_style.style);
        }
        if (heading_style.style.suffix.len > 0) {
            try ansi_util.writeStyled(buf.writer(self.allocator()), heading_style.style, heading_style.style.suffix);
        }

        // Word-wrap and write
        const available_width = if (self.opts().word_wrap > self.indent) self.opts().word_wrap - self.indent else 0;
        const wrap_width = if (scale > 1) available_width / scale else available_width;

        const wrapped = try ansi_util.wordWrap(
            self.allocator(),
            buf.items,
            wrap_width,
            0,
        );
        defer self.allocator().free(wrapped);

        if (scale > 1) {
            var lines = std.mem.splitScalar(u8, wrapped, '\n');
            var first = true;
            while (lines.next()) |line| {
                if (!first or line.len > 0) {
                    for (0..self.indent) |_| try writer.writeByte(' ');

                    const plain = try ansi_util.stripAnsi(self.allocator(), line);
                    defer self.allocator().free(plain);

                    const had_codes = try ansi_util.writeOpen(writer, heading_style.style);
                    try writer.print("\x1b]66;s={d};{s}\x07", .{ scale, plain });
                    if (had_codes) try ansi_util.writeReset(writer);

                    // Add extra newlines for the height of scaled text
                    for (0..scale) |_| try writer.writeByte('\n');
                }
                first = false;
            }
        } else {
            try writeIndentedLines(writer, wrapped, self.indent);
        }

        try ansi_util.writeStyled(writer, s.document.style, heading_style.style.block_suffix);
    }

    fn renderParagraph(self: *RenderContext, writer: anytype, node: *ast.Node) anyerror!void {
        if (node.children.items.len == 0) return;

        if (!node.is_first) {
            try writer.writeByte('\n');
        }

        const para_style = self.opts().styles.paragraph;
        _ = para_style;

        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator());

        for (node.children.items) |child| {
            try self.renderInlineToWriter(buf.writer(self.allocator()), child, self.opts().styles.text);
        }

        const raw = buf.items;
        const text = if (self.opts().preserve_newlines)
            try self.allocator().dupe(u8, raw)
        else blk: {
            // Replace soft newlines with spaces
            const r = try self.allocator().dupe(u8, raw);
            for (r) |*c| if (c.* == '\n') {
                c.* = ' ';
            };
            break :blk r;
        };
        defer self.allocator().free(text);

        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) return;

        const wrapped = try ansi_util.wordWrap(
            self.allocator(),
            trimmed,
            if (self.opts().word_wrap > self.indent) self.opts().word_wrap - self.indent else 40,
            0,
        );
        defer self.allocator().free(wrapped);

        try writeIndentedLines(writer, wrapped, self.indent);
        try writer.writeByte('\n');
    }

    fn renderBlockquote(self: *RenderContext, writer: anytype, node: *ast.Node) anyerror!void {
        const bq_style = self.opts().styles.block_quote;
        const indent_token = bq_style.indent_token orelse "│ ";
        const extra_indent = bq_style.indent orelse 0;

        try writer.writeByte('\n');

        // Render children into a buffer, then prefix each line
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator());

        const old_indent = self.indent;
        self.indent += extra_indent + indent_token.len;
        for (node.children.items) |child| {
            try self.renderNode(buf.writer(self.allocator()), child);
        }
        self.indent = old_indent;

        // Prefix each line with the indent_token
        var lines = std.mem.splitScalar(u8, buf.items, '\n');
        var first_line = true;
        while (lines.next()) |line| {
            if (first_line and line.len == 0) {
                first_line = false;
                continue;
            }
            first_line = false;
            for (0..self.indent) |_| try writer.writeByte(' ');
            try writer.writeAll(indent_token);
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
    }

    fn renderList(self: *RenderContext, writer: anytype, node: *ast.Node) anyerror!void {
        var enum_counter: u32 = node.list_start;
        for (node.children.items, 0..) |child, i| {
            child.enumeration = enum_counter;
            child.ordered = node.ordered;
            child.is_first = (i == 0);
            if (node.ordered) enum_counter += 1;
            try self.renderListItem(writer, child);
        }
    }

    fn renderListItem(self: *RenderContext, writer: anytype, node: *ast.Node) anyerror!void {
        const s = self.opts().styles;
        const list_style = s.list;
        const level_indent = if (self.list_depth > 0) list_style.level_indent else 0;

        for (0..self.indent + level_indent) |_| try writer.writeByte(' ');

        // Write marker
        if (node.task_checked) |checked| {
            const task_s = s.task;
            const marker = if (checked) task_s.ticked else task_s.unticked;
            try ansi_util.writeStyled(writer, task_s.style, marker);
        } else if (node.ordered) {
            var nbuf: [16]u8 = undefined;
            const nstr = std.fmt.bufPrint(&nbuf, "{d}", .{node.enumeration}) catch "1";
            try writer.writeAll(nstr);
            try ansi_util.writeStyled(writer, s.enumeration, s.enumeration.block_prefix);
        } else {
            try ansi_util.writeStyled(writer, s.item, s.item.block_prefix);
        }

        // Render children (paragraphs/sub-blocks)
        const old_indent = self.indent;
        const old_depth = self.list_depth;
        self.list_depth += 1;

        // Inline content of first paragraph
        var first_para = true;
        for (node.children.items) |child| {
            switch (child.kind) {
                .paragraph => {
                    if (first_para) {
                        // Render inline on same line as marker
                        var buf = std.ArrayList(u8){};
                        defer buf.deinit(self.allocator());
                        for (child.children.items) |inline_child| {
                            try self.renderInlineToWriter(buf.writer(self.allocator()), inline_child, s.text);
                        }
                        const trimmed = std.mem.trim(u8, buf.items, " ");
                        try writer.writeAll(trimmed);
                        try writer.writeByte('\n');
                        first_para = false;
                    } else {
                        try writer.writeByte('\n');
                        self.indent = old_indent + level_indent + 2;
                        try self.renderParagraph(writer, child);
                        self.indent = old_indent;
                    }
                },
                .list => {
                    self.indent = old_indent + level_indent + 2;
                    try self.renderList(writer, child);
                    self.indent = old_indent;
                    first_para = false;
                },
                else => {
                    self.indent = old_indent + level_indent + 2;
                    try self.renderNode(writer, child);
                    self.indent = old_indent;
                    first_para = false;
                },
            }
        }

        self.indent = old_indent;
        self.list_depth = old_depth;
    }

    fn renderFencedCode(self: *RenderContext, writer: anytype, node: *ast.Node) anyerror!void {
        const cb_style = self.opts().styles.code_block;
        const margin = cb_style.block.margin orelse 0;

        try writer.writeByte('\n');
        var lines = std.mem.splitScalar(u8, node.text, '\n');
        while (lines.next()) |line| {
            for (0..self.indent + margin) |_| try writer.writeByte(' ');
            try ansi_util.writeStyled(writer, cb_style.block.style, line);
            try writer.writeByte('\n');
        }
    }

    fn renderCodeBlock(self: *RenderContext, writer: anytype, node: *ast.Node) anyerror!void {
        return self.renderFencedCode(writer, node);
    }

    fn renderThematicBreak(self: *RenderContext, writer: anytype, _: *ast.Node) anyerror!void {
        const hr_style = self.opts().styles.horizontal_rule;
        if (hr_style.format.len > 0) {
            for (0..self.indent) |_| try writer.writeByte(' ');
            try ansi_util.writeStyled(writer, hr_style, hr_style.format);
        } else {
            try writer.writeByte('\n');
            for (0..self.indent) |_| try writer.writeByte(' ');
            try ansi_util.writeStyled(writer, hr_style, "--------");
            try writer.writeByte('\n');
        }
    }

    fn renderHtmlBlock(_: *RenderContext, writer: anytype, node: *ast.Node) anyerror!void {
        // Pass HTML through as-is (strip tags for plain output)
        try writer.writeAll(node.text);
        try writer.writeByte('\n');
    }

    fn renderTable(self: *RenderContext, writer: anytype, node: *ast.Node) anyerror!void {
        if (node.children.items.len == 0) return;

        // node.children[0] = table_head, [1..] = table_row nodes
        const head = node.children.items[0];
        const ncols = head.children.items.len;
        if (ncols == 0) return;

        const nrows = node.children.items.len;
        const alloc = self.allocator();

        // Render every cell's inline content to a flat string array.
        // Index: ri * ncols + ci
        const cell_bufs = try alloc.alloc(std.ArrayList(u8), nrows * ncols);
        defer {
            for (cell_bufs) |*b| b.deinit(alloc);
            alloc.free(cell_bufs);
        }
        for (cell_bufs) |*b| b.* = .empty;

        for (node.children.items, 0..) |row_node, ri| {
            for (row_node.children.items, 0..) |cell, ci| {
                if (ci >= ncols) break;
                const idx = ri * ncols + ci;
                // Header row: render with bold style.
                const text_style = if (ri == 0)
                    mergeStylePrimitive(self.opts().styles.text, self.opts().styles.strong)
                else
                    self.opts().styles.text;
                for (cell.children.items) |inline_child| {
                    try self.renderInlineToWriter(
                        cell_bufs[idx].writer(alloc),
                        inline_child,
                        text_style,
                    );
                }
            }
        }

        // Compute visible column widths.
        const col_widths = try alloc.alloc(usize, ncols);
        defer alloc.free(col_widths);
        @memset(col_widths, 3); // minimum 3
        for (0..nrows) |ri| {
            for (0..ncols) |ci| {
                const w = ansi_util.visibleWidth(cell_bufs[ri * ncols + ci].items);
                if (w > col_widths[ci]) col_widths[ci] = w;
            }
        }

        // Column alignments (from header cells).
        const col_aligns = try alloc.alloc(ast.Align, ncols);
        defer alloc.free(col_aligns);
        for (head.children.items, 0..) |hcell, ci| {
            col_aligns[ci] = hcell.col_align;
        }

        const ts = self.opts().styles.table;

        try writer.writeByte('\n');

        // Top border: ┌───┬───┐
        try writeTableBorder(writer, col_widths, self.indent, ts, .top);

        // Rows
        for (node.children.items, 0..) |_, ri| {
            for (0..self.indent) |_| try writer.writeByte(' ');
            try writer.writeAll(ts.vertical);
            for (0..ncols) |ci| {
                const content = cell_bufs[ri * ncols + ci].items;
                try writeTableCell(writer, content, col_widths[ci], col_aligns[ci]);
                try writer.writeAll(ts.vertical);
            }
            try writer.writeByte('\n');

            // Separator after header row: ├───┼───┤
            if (ri == 0) {
                try writeTableBorder(writer, col_widths, self.indent, ts, .mid);
            }
        }

        // Bottom border: └───┴───┘
        try writeTableBorder(writer, col_widths, self.indent, ts, .bottom);
        try writer.writeByte('\n');
    }

    // ── Inline Renderers ──────────────────────────────────────────────────────

    fn renderInline(self: *RenderContext, writer: anytype, node: *ast.Node) anyerror!void {
        try self.renderInlineToWriter(writer, node, self.opts().styles.text);
    }

    fn renderInlineToWriter(
        self: *RenderContext,
        writer: anytype,
        node: *ast.Node,
        parent_style: style.StylePrimitive,
    ) anyerror!void {
        const s = self.opts().styles;
        switch (node.kind) {
            .text => {
                try ansi_util.writeStyled(writer, mergeStylePrimitive(parent_style, s.text), node.text);
            },
            .soft_break => {
                try writer.writeByte(' ');
            },
            .hard_break => {
                try writer.writeByte('\n');
                for (0..self.indent) |_| try writer.writeByte(' ');
            },
            .emphasis => {
                const em_style = mergeStylePrimitive(parent_style, s.emph);
                for (node.children.items) |child| {
                    try self.renderInlineToWriter(writer, child, em_style);
                }
            },
            .strong => {
                const st_style = mergeStylePrimitive(parent_style, s.strong);
                for (node.children.items) |child| {
                    try self.renderInlineToWriter(writer, child, st_style);
                }
            },
            .strikethrough => {
                const sk_style = mergeStylePrimitive(parent_style, s.strikethrough);
                for (node.children.items) |child| {
                    try self.renderInlineToWriter(writer, child, sk_style);
                }
            },
            .code_span => {
                const code_s = s.code.style;
                try ansi_util.writeStyled(writer, code_s, code_s.prefix);
                try ansi_util.writeStyled(writer, code_s, node.text);
                try ansi_util.writeStyled(writer, code_s, code_s.suffix);
            },
            .link => {
                // Render link text in link_text style
                const lt_style = mergeStylePrimitive(parent_style, s.link_text);
                for (node.children.items) |child| {
                    try self.renderInlineToWriter(writer, child, lt_style);
                }
                // Render URL in link style
                if (node.url.len > 0) {
                    try writer.writeAll(" (");
                    try ansi_util.writeStyled(writer, s.link, node.url);
                    try writer.writeByte(')');
                }
            },
            .image => {
                // Render as "Image: alt_text → url"
                const img_s = s.image_text;
                if (img_s.format.len > 0) {
                    // Simple format substitution: replace {s} with alt text
                    var out = std.ArrayList(u8){};
                    defer out.deinit(self.allocator());
                    var fmt_rest = img_s.format;
                    while (std.mem.indexOf(u8, fmt_rest, "{s}")) |idx| {
                        try out.appendSlice(self.allocator(), fmt_rest[0..idx]);
                        try out.appendSlice(self.allocator(), node.text);
                        fmt_rest = fmt_rest[idx + 3 ..];
                    }
                    try out.appendSlice(self.allocator(), fmt_rest);
                    try ansi_util.writeStyled(writer, img_s, out.items);
                } else {
                    try ansi_util.writeStyled(writer, img_s, node.text);
                }
                if (node.url.len > 0) {
                    try writer.writeAll(" ");
                    try ansi_util.writeStyled(writer, s.image, node.url);
                }
            },
            .auto_link => {
                try ansi_util.writeStyled(writer, s.link, node.url);
            },
            .raw_html => {
                // Strip HTML tags; output text content only
                try writer.writeAll(node.text);
            },
            else => {},
        }
    }
};

// ── Style Merge Utilities ─────────────────────────────────────────────────────

/// Merge child block style over parent: child values take precedence when set.
fn mergeBlock(parent: style.StyleBlock, child: style.StyleBlock) style.StyleBlock {
    return .{
        .style = mergeStylePrimitive(parent.style, child.style),
        .indent = child.indent orelse parent.indent,
        .indent_token = child.indent_token orelse parent.indent_token,
        .margin = child.margin orelse parent.margin,
    };
}

/// Merge child primitive style over parent.
fn mergeStylePrimitive(parent: style.StylePrimitive, child: style.StylePrimitive) style.StylePrimitive {
    return .{
        .block_prefix = if (child.block_prefix.len > 0) child.block_prefix else parent.block_prefix,
        .block_suffix = if (child.block_suffix.len > 0) child.block_suffix else parent.block_suffix,
        .prefix = if (child.prefix.len > 0) child.prefix else parent.prefix,
        .suffix = if (child.suffix.len > 0) child.suffix else parent.suffix,
        .color = child.color orelse parent.color,
        .background_color = child.background_color orelse parent.background_color,
        .underline = child.underline orelse parent.underline,
        .bold = child.bold orelse parent.bold,
        .upper = child.upper orelse parent.upper,
        .lower = child.lower orelse parent.lower,
        .title = child.title orelse parent.title,
        .italic = child.italic orelse parent.italic,
        .crossed_out = child.crossed_out orelse parent.crossed_out,
        .faint = child.faint orelse parent.faint,
        .conceal = child.conceal orelse parent.conceal,
        .inverse = child.inverse orelse parent.inverse,
        .blink = child.blink orelse parent.blink,
        .format = if (child.format.len > 0) child.format else parent.format,
    };
}

const BorderType = enum { top, mid, bottom };

/// Write a table horizontal border line using Unicode box-drawing characters.
///   top: ┌───┬───┐
///   mid: ├───┼───┤
///   bot: └───┴───┘
fn writeTableBorder(
    writer: anytype,
    col_widths: []const usize,
    indent: usize,
    ts: style.StyleTable,
    border_type: BorderType,
) !void {
    const left = switch (border_type) {
        .top => ts.top_left,
        .mid => ts.left_mid,
        .bottom => ts.bottom_left,
    };
    const right = switch (border_type) {
        .top => ts.top_right,
        .mid => ts.right_mid,
        .bottom => ts.bottom_right,
    };
    const mid = switch (border_type) {
        .top => ts.top_mid,
        .mid => ts.mid_mid,
        .bottom => ts.bottom_mid,
    };

    for (0..indent) |_| try writer.writeByte(' ');
    try writer.writeAll(left);
    for (col_widths, 0..) |w, i| {
        var j: usize = 0;
        while (j < w + 2) : (j += 1) try writer.writeAll(ts.horizontal);
        if (i < col_widths.len - 1) try writer.writeAll(mid);
    }
    try writer.writeAll(right);
    try writer.writeByte('\n');
}

/// Write a single table cell with alignment padding: ` content   `
fn writeTableCell(
    writer: anytype,
    content: []const u8,
    col_width: usize,
    alignment: ast.Align,
) !void {
    const vis = ansi_util.visibleWidth(content);
    const total_pad = if (col_width > vis) col_width - vis else 0;
    const left_pad: usize = switch (alignment) {
        .right => total_pad,
        .center => total_pad / 2,
        else => 0,
    };
    const right_pad: usize = total_pad - left_pad;

    try writer.writeByte(' ');
    for (0..left_pad) |_| try writer.writeByte(' ');
    try writer.writeAll(content);
    for (0..right_pad) |_| try writer.writeByte(' ');
    try writer.writeByte(' ');
}

/// Write text with each line indented by `indent` spaces.
fn writeIndentedLines(writer: anytype, text: []const u8, indent: usize) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first or line.len > 0) {
            for (0..indent) |_| try writer.writeByte(' ');
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
        first = false;
    }
}
