const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) usage();

    const child_args = try allocator.alloc([]const u8, args.len);
    child_args[0] = "veryl";
    @memcpy(child_args[1..], args[1..]);
    const result = try std.process.run(allocator, init.io, .{ .argv = child_args });

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(result.stdout);
    try stdout.flush();

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    var lines = std.mem.splitScalar(u8, result.stderr, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "[INFO ]")) continue;
        if (line.len == 0) continue;
        try stderr.print("{s}\n", .{line});
    }
    try stderr.flush();

    switch (result.term) {
        .exited => |code| if (code != 0) std.process.exit(code),
        else => std.process.fatal("veryl terminated unexpectedly", .{}),
    }
}

fn usage() noreturn {
    std.process.fatal("usage: veryl-command <arguments...>", .{});
}
