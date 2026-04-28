// Style configuration for zchomd terminal Markdown renderer.
// Mirrors glamour's ansi/style.go structure.
const std = @import("std");

/// StylePrimitive holds basic ANSI style settings for inline elements.
pub const StylePrimitive = struct {
    block_prefix: []const u8 = "",
    block_suffix: []const u8 = "",
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    /// Color: "0"-"255" for 256-color palette, or "#RRGGBB" for truecolor.
    color: ?[]const u8 = null,
    background_color: ?[]const u8 = null,
    underline: ?bool = null,
    bold: ?bool = null,
    upper: ?bool = null,
    lower: ?bool = null,
    title: ?bool = null,
    italic: ?bool = null,
    crossed_out: ?bool = null,
    faint: ?bool = null,
    conceal: ?bool = null,
    inverse: ?bool = null,
    blink: ?bool = null,
    format: []const u8 = "",
};

/// StyleTask holds style settings for task list items.
pub const StyleTask = struct {
    style: StylePrimitive = .{},
    ticked: []const u8 = "[✓] ",
    unticked: []const u8 = "[ ] ",
};

/// StyleBlock holds style settings for block-level elements.
pub const StyleBlock = struct {
    style: StylePrimitive = .{},
    indent: ?u32 = null,
    indent_token: ?[]const u8 = null,
    margin: ?u32 = null,
};

/// StyleCodeBlock holds style settings for fenced code blocks.
pub const StyleCodeBlock = struct {
    block: StyleBlock = .{},
    theme: []const u8 = "",
};

/// StyleList holds style settings for lists.
pub const StyleList = struct {
    block: StyleBlock = .{},
    level_indent: u32 = 0,
};

/// StyleTable holds style settings for tables.
pub const StyleTable = struct {
    block: StyleBlock = .{},
    // Horizontal line
    horizontal: []const u8 = "─",
    // Vertical line
    vertical: []const u8 = "│",
    // Corners
    top_left: []const u8 = "┌",
    top_right: []const u8 = "┐",
    bottom_left: []const u8 = "└",
    bottom_right: []const u8 = "┘",
    // T-junctions
    top_mid: []const u8 = "┬",
    bottom_mid: []const u8 = "┴",
    left_mid: []const u8 = "├",
    right_mid: []const u8 = "┤",
    // Cross junction
    mid_mid: []const u8 = "┼",
};

/// ASCII-only table style (for notty / piped output).
pub const ascii_table: StyleTable = .{
    .horizontal = "-",
    .vertical = "|",
    .top_left = "+",
    .top_right = "+",
    .bottom_left = "+",
    .bottom_right = "+",
    .top_mid = "+",
    .bottom_mid = "+",
    .left_mid = "+",
    .right_mid = "+",
    .mid_mid = "+",
};

/// StyleConfig is the top-level style configuration.
pub const StyleConfig = struct {
    document: StyleBlock = .{},
    block_quote: StyleBlock = .{},
    paragraph: StyleBlock = .{},
    list: StyleList = .{},

    heading: StyleBlock = .{},
    h1: StyleBlock = .{},
    h2: StyleBlock = .{},
    h3: StyleBlock = .{},
    h4: StyleBlock = .{},
    h5: StyleBlock = .{},
    h6: StyleBlock = .{},

    text: StylePrimitive = .{},
    strikethrough: StylePrimitive = .{},
    emph: StylePrimitive = .{},
    strong: StylePrimitive = .{},
    horizontal_rule: StylePrimitive = .{},

    item: StylePrimitive = .{},
    enumeration: StylePrimitive = .{},
    task: StyleTask = .{},

    link: StylePrimitive = .{},
    link_text: StylePrimitive = .{},

    image: StylePrimitive = .{},
    image_text: StylePrimitive = .{},

    code: StyleBlock = .{},
    code_block: StyleCodeBlock = .{},

    table: StyleTable = .{},

    definition_list: StyleBlock = .{},
    definition_term: StylePrimitive = .{},
    definition_description: StylePrimitive = .{},

    html_block: StyleBlock = .{},
    html_span: StyleBlock = .{},
};

// ── Built-in Styles ───────────────────────────────────────────────────────────

/// dark style: matches glamour's dark.json
pub const dark: StyleConfig = .{
    .document = .{
        .style = .{
            .block_prefix = "\n",
            .block_suffix = "\n",
            .color = "252",
        },
        .margin = 2,
    },
    .block_quote = .{
        .indent = 1,
        .indent_token = "│ ",
    },
    .list = .{
        .block = .{},
        .level_indent = 2,
    },
    .heading = .{
        .style = .{
            .block_suffix = "\n",
            .color = "39",
            .bold = true,
        },
    },
    .h1 = .{
        .style = .{
            .prefix = " ",
            .suffix = " ",
            .color = "228",
            .background_color = "63",
            .bold = true,
        },
    },
    .h2 = .{
        .style = .{ .prefix = "## " },
    },
    .h3 = .{
        .style = .{ .prefix = "### " },
    },
    .h4 = .{
        .style = .{ .prefix = "#### " },
    },
    .h5 = .{
        .style = .{ .prefix = "##### " },
    },
    .h6 = .{
        .style = .{
            .prefix = "###### ",
            .color = "35",
            .bold = false,
        },
    },
    .strikethrough = .{ .crossed_out = true },
    .emph = .{ .italic = true },
    .strong = .{ .bold = true },
    .horizontal_rule = .{
        .color = "240",
        .format = "\n--------\n",
    },
    .item = .{ .block_prefix = "• " },
    .enumeration = .{ .block_prefix = ". " },
    .task = .{
        .ticked = "[✓] ",
        .unticked = "[ ] ",
    },
    .link = .{
        .color = "30",
        .underline = true,
    },
    .link_text = .{
        .color = "35",
        .bold = true,
    },
    .image = .{
        .color = "212",
        .underline = true,
    },
    .image_text = .{
        .color = "243",
        .format = "Image: {s} →",
    },
    .code = .{
        .style = .{
            .prefix = " ",
            .suffix = " ",
            .color = "203",
            .background_color = "236",
        },
    },
    .code_block = .{
        .block = .{
            .style = .{ .color = "244" },
            .margin = 2,
        },
    },
};

/// light style: matches glamour's light.json (simplified)
pub const light: StyleConfig = .{
    .document = .{
        .style = .{
            .block_prefix = "\n",
            .block_suffix = "\n",
            .color = "232",
        },
        .margin = 2,
    },
    .block_quote = .{
        .indent = 1,
        .indent_token = "│ ",
    },
    .list = .{
        .level_indent = 2,
    },
    .heading = .{
        .style = .{
            .block_suffix = "\n",
            .color = "27",
            .bold = true,
        },
    },
    .h1 = .{
        .style = .{
            .prefix = " ",
            .suffix = " ",
            .color = "228",
            .background_color = "69",
            .bold = true,
        },
    },
    .h2 = .{ .style = .{ .prefix = "## " } },
    .h3 = .{ .style = .{ .prefix = "### " } },
    .h4 = .{ .style = .{ .prefix = "#### " } },
    .h5 = .{ .style = .{ .prefix = "##### " } },
    .h6 = .{ .style = .{ .prefix = "###### ", .color = "28" } },
    .strikethrough = .{ .crossed_out = true },
    .emph = .{ .italic = true },
    .strong = .{ .bold = true },
    .horizontal_rule = .{ .color = "249", .format = "\n--------\n" },
    .item = .{ .block_prefix = "• " },
    .enumeration = .{ .block_prefix = ". " },
    .task = .{ .ticked = "[✓] ", .unticked = "[ ] " },
    .link = .{ .color = "26", .underline = true },
    .link_text = .{ .color = "22", .bold = true },
    .image = .{ .color = "205", .underline = true },
    .image_text = .{ .color = "243", .format = "Image: {s} →" },
    .code = .{
        .style = .{
            .prefix = " ",
            .suffix = " ",
            .color = "166",
            .background_color = "255",
        },
    },
    .code_block = .{
        .block = .{
            .style = .{ .color = "242" },
            .margin = 2,
        },
    },
};

/// notty style: no ANSI codes, plain text output
pub const notty: StyleConfig = .{
    .document = .{
        .style = .{ .block_prefix = "\n", .block_suffix = "\n" },
        .margin = 2,
    },
    .block_quote = .{ .indent = 1, .indent_token = "│ " },
    .list = .{ .level_indent = 2 },
    .h1 = .{ .style = .{ .prefix = "# " } },
    .h2 = .{ .style = .{ .prefix = "## " } },
    .h3 = .{ .style = .{ .prefix = "### " } },
    .h4 = .{ .style = .{ .prefix = "#### " } },
    .h5 = .{ .style = .{ .prefix = "##### " } },
    .h6 = .{ .style = .{ .prefix = "###### " } },
    .horizontal_rule = .{ .format = "\n--------\n" },
    .item = .{ .block_prefix = "• " },
    .enumeration = .{ .block_prefix = ". " },
    .task = .{ .ticked = "[x] ", .unticked = "[ ] " },
    .table = ascii_table,
};

pub const ascii: StyleConfig = notty;

pub const StandardStyle = enum { dark, light, notty, ascii };

pub fn getStandardStyle(name: []const u8) ?StyleConfig {
    if (std.mem.eql(u8, name, "dark")) return dark;
    if (std.mem.eql(u8, name, "light")) return light;
    if (std.mem.eql(u8, name, "notty")) return notty;
    if (std.mem.eql(u8, name, "ascii")) return ascii;
    return null;
}
