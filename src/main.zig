// zchomd CLI: render Markdown files to the terminal.
const std = @import("std");
const zchomd = @import("zchomd");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_file = std.fs.File.stderr();
    var stderr_writer = stderr_file.writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    // Determine style from GLAMOUR_STYLE env var, default "dark"
    const env_style = std.process.getEnvVarOwned(allocator, "GLAMOUR_STYLE") catch
        try allocator.dupe(u8, "dark");
    defer allocator.free(env_style);

    const style_cfg = zchomd.style.getStandardStyle(env_style) orelse zchomd.style.dark;

    var tr = zchomd.TermRenderer.init(allocator, .{ .styles = style_cfg });

    if (args.len < 2) {
        // Read from stdin
        const input = try std.fs.File.stdin().readToEndAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(input);

        try tr.render(stdout, input);
        try stdout.flush();
        return;
    }

    for (args[1..]) |path| {
        if (std.mem.eql(u8, path, "--help") or std.mem.eql(u8, path, "-h")) {
            try stderr.writeAll(
                \\zchomd - Markdown terminal renderer
                \\
                \\Usage:
                \\  zchomd [file...]      render file(s) to terminal
                \\  zchomd               read from stdin
                \\
                \\Environment:
                \\  GLAMOUR_STYLE        style name: dark (default), light, notty, ascii
                \\
            );
            return;
        }

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            try stderr.print("zchomd: cannot open '{s}': {}\n", .{ path, err });
            continue;
        };
        defer file.close();

        const input = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(input);

        try tr.render(stdout, input);
        try stdout.flush();
    }
}
