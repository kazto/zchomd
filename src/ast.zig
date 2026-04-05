// Markdown AST node definitions for zchomd.
const std = @import("std");

pub const NodeKind = enum {
    // Block elements
    document,
    heading,
    paragraph,
    blockquote,
    list,
    list_item,
    fenced_code_block,
    code_block,
    thematic_break,
    html_block,

    // Inline elements (children of paragraph, heading, etc.)
    text,
    soft_break,
    hard_break,
    emphasis,
    strong,
    code_span,
    link,
    image,
    auto_link,
    strikethrough,
    raw_html,
};

pub const Node = struct {
    kind: NodeKind,

    // Shared text content (text nodes, code content, raw html, etc.)
    text: []const u8 = "",

    // Heading level 1-6
    level: u8 = 0,

    // Link / image
    url: []const u8 = "",
    link_title: []const u8 = "",

    // Code block
    language: []const u8 = "",

    // List
    ordered: bool = false,
    list_start: u32 = 1,

    // List item
    enumeration: u32 = 0,
    task_checked: ?bool = null,

    // Whether this node is the first child of its parent
    is_first: bool = false,

    children: std.ArrayListUnmanaged(*Node) = .{},

    /// Allocate and initialize a new node.
    pub fn create(allocator: std.mem.Allocator, kind: NodeKind) !*Node {
        const node = try allocator.create(Node);
        node.* = .{ .kind = kind };
        return node;
    }

    /// Recursively free node and all its children.
    /// All string fields (text, language, url, link_title) that were
    /// allocated (non-empty) are freed.
    pub fn destroy(self: *Node, allocator: std.mem.Allocator) void {
        for (self.children.items) |child| {
            child.destroy(allocator);
        }
        self.children.deinit(allocator);
        if (self.text.len > 0) allocator.free(self.text);
        if (self.language.len > 0) allocator.free(self.language);
        if (self.url.len > 0) allocator.free(self.url);
        if (self.link_title.len > 0) allocator.free(self.link_title);
        allocator.destroy(self);
    }

    pub fn appendChild(self: *Node, allocator: std.mem.Allocator, child: *Node) !void {
        if (self.children.items.len == 0) {
            child.is_first = true;
        }
        try self.children.append(allocator, child);
    }

    pub fn lastChild(self: *Node) ?*Node {
        if (self.children.items.len == 0) return null;
        return self.children.items[self.children.items.len - 1];
    }

    pub fn childCount(self: *const Node) usize {
        return self.children.items.len;
    }
};
