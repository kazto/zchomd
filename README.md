# zchomd

A Markdown terminal renderer written in Zig, inspired by the Go [glamour](https://github.com/charmbracelet/glamour) library API.

## Requirements

- Zig 0.15.2 or later

## CLI Usage

### Build

```sh
zig build
```

The binary is placed at `zig-out/bin/zchomd`.

### Run

```sh
# Render a file
zchomd README.md

# Render multiple files
zchomd file1.md file2.md

# Read from stdin
cat README.md | zchomd

# Show help
zchomd --help
```

### Styles

Set the `GLAMOUR_STYLE` environment variable to switch styles (default: `dark`).

```sh
GLAMOUR_STYLE=light zchomd README.md
GLAMOUR_STYLE=notty zchomd README.md
```

| Style   | Description                        |
|---------|------------------------------------|
| `dark`  | For dark terminals (default)       |
| `light` | For light terminals                |
| `notty` | No ANSI codes, plain text output   |
| `ascii` | Same as `notty`                    |

## Library Usage

### Adding as a Dependency

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zchomd = .{
        .url = "https://...",
        .hash = "...",
    },
},
```

Import the module in `build.zig`:

```zig
const zchomd_dep = b.dependency("zchomd", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zchomd", zchomd_dep.module("zchomd"));
```

### Basic Usage

#### Convenience function

```zig
const std = @import("std");
const zchomd = @import("zchomd");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const markdown = "# Hello\n\nThis is **bold** and *italic* text.\n";

    // Pass one of: "dark", "light", "notty", "ascii"
    const output = try zchomd.renderAlloc(allocator, markdown, "dark");
    defer allocator.free(output);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(output);
}
```

#### Using `TermRenderer`

```zig
const std = @import("std");
const zchomd = @import("zchomd");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const markdown = "# Hello\n\nWorld\n";

    var tr = zchomd.TermRenderer.init(allocator, .{
        .styles = zchomd.style.dark,
    });

    // Returns an owned slice; caller must free
    const output = try tr.renderAlloc(markdown);
    defer allocator.free(output);

    std.debug.print("{s}", .{output});
}
```

#### Writing directly to a Writer

```zig
var tr = zchomd.TermRenderer.init(allocator, .{ .styles = zchomd.style.dark });

var stdout_buf: [4096]u8 = undefined;
var stdout_file = std.fs.File.stdout();
var stdout_writer = stdout_file.writer(&stdout_buf);
const stdout = &stdout_writer.interface;

try tr.render(stdout, markdown);
try stdout.flush();
```

## API Reference

### `zchomd.TermRenderer`

| Method | Description |
|--------|-------------|
| `init(allocator, opts)` | Initialize the renderer |
| `renderAlloc(input)` | Render Markdown and return an owned slice (caller must `free`) |
| `render(writer, input)` | Render Markdown and write to `writer` |

### `zchomd.Options`

```zig
pub const Options = struct {
    styles: style.StyleConfig = style.dark,  // Style configuration
    word_wrap: usize = 80,                   // Line wrap width in characters
    preserve_newlines: bool = false,         // Preserve newlines within paragraphs
};
```

### `zchomd.renderAlloc`

```zig
pub fn renderAlloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    style_name: []const u8,  // "dark" | "light" | "notty" | "ascii"
) ![]u8
```

Falls back to `dark` if the style name is not recognized.

### Built-in Styles

```zig
zchomd.style.dark    // For dark terminals
zchomd.style.light   // For light terminals
zchomd.style.notty   // Plain text, no ANSI codes
zchomd.style.ascii   // Same as notty
```

### Custom Styles

Build a `zchomd.style.StyleConfig` directly to define a custom style:

```zig
const my_style = zchomd.style.StyleConfig{
    .document = .{ .margin = 4 },
    .heading = .{
        .style = .{ .bold = true, .color = "33" },
    },
    .emph = .{ .italic = true },
    .strong = .{ .bold = true },
    .item = .{ .block_prefix = "- " },
    // Remaining fields use their default values
};

var tr = zchomd.TermRenderer.init(allocator, .{ .styles = my_style });
```

#### Key `StylePrimitive` fields

| Field | Type | Description |
|-------|------|-------------|
| `color` | `?[]const u8` | Foreground color (`"0"`–`"255"` or `"#RRGGBB"`) |
| `background_color` | `?[]const u8` | Background color |
| `bold` | `?bool` | Bold text |
| `italic` | `?bool` | Italic text |
| `underline` | `?bool` | Underline |
| `crossed_out` | `?bool` | Strikethrough |
| `prefix` | `[]const u8` | Text prepended to the element |
| `suffix` | `[]const u8` | Text appended to the element |

## Running Tests

```sh
zig build test
```
