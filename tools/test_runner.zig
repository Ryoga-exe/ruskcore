const std = @import("std");
const Io = std.Io;

const max_cycles = "1000000";

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 3) usage();

    const simulator = args[1];
    const test_directory = args[2];
    const filters = args[3..];

    var directory = Io.Dir.cwd().openDir(init.io, test_directory, .{ .iterate = true }) catch |err|
        std.process.fatal("unable to open test directory '{s}': {t}", .{ test_directory, err });
    defer directory.close(init.io);

    var walker = try directory.walk(allocator);
    defer walker.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var total: usize = 0;
    var passed: usize = 0;
    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".hex")) continue;
        if (!matchesAnyFilter(entry.path, filters)) continue;

        const test_path = try std.fs.path.join(allocator, &.{ test_directory, entry.path });
        const child_args = [_][]const u8{ simulator, test_path, max_cycles };
        var child = try std.process.spawn(init.io, .{
            .argv = &child_args,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const term = try child.wait(init.io);
        const success = term == .exited and term.exited == 0;

        total += 1;
        if (success) passed += 1;
        try stdout.print("{s}: {s}\n", .{ if (success) "PASS" else "FAIL", test_path });
    }

    if (total == 0) {
        std.process.fatal("no .hex tests found in '{s}'", .{test_directory});
    }
    try stdout.print("Test result: {d}/{d}\n", .{ passed, total });
    try stdout.flush();

    if (passed != total) std.process.exit(1);
}

fn matchesAnyFilter(path: []const u8, filters: []const []const u8) bool {
    if (filters.len == 0) return true;
    for (filters) |filter| {
        if (std.mem.indexOf(u8, path, filter) != null) return true;
    }
    return false;
}

fn usage() noreturn {
    std.process.fatal("usage: test-runner <simulator> <test directory> [filters...]", .{});
}
