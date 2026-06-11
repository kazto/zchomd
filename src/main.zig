// zchomd CLI: render Markdown files to the terminal.
const std = @import("std");
const zchomd = @import("zchomd");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // Determine style from GLAMOUR_STYLE env var, default "dark"
    const env_style = init.environ_map.get("GLAMOUR_STYLE") orelse "dark";

    const style_cfg = zchomd.style.getStandardStyle(env_style) orelse zchomd.style.dark;

    var tr = zchomd.TermRenderer.init(allocator, .{ .styles = style_cfg });

    if (args.len < 2) {
        // Read from stdin
        var input_reader_buf: [4096]u8 = undefined;
        var input_reader = std.Io.File.stdin().reader(io, &input_reader_buf);
        const input = try input_reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024));
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

        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
            try stderr.print("zchomd: cannot open '{s}': {}\n", .{ path, err });
            continue;
        };
        defer file.close(io);

        var input_reader_buf: [4096]u8 = undefined;
        var input_reader = file.reader(io, &input_reader_buf);
        const input = try input_reader.interface.allocRemaining(allocator, .limited(10 * 1024 * 1024));
        defer allocator.free(input);

        try tr.render(stdout, input);
        try stdout.flush();
    }
}
