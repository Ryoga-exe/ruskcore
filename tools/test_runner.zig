const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 5) usage();

    const simulator = args[1];
    const output_path = args[2];
    const max_cycles = args[3];
    const image_path = args[4];

    const cwd = Io.Dir.cwd();
    try cwd.deleteTree(init.io, output_path);
    try cwd.createDirPath(init.io, output_path);
    var output_dir = try cwd.openDir(init.io, output_path, .{});
    defer output_dir.close(init.io);
    var image_dir = try cwd.openDir(init.io, image_path, .{ .iterate = true });
    defer image_dir.close(init.io);

    var summary_file = try output_dir.createFile(init.io, "result.txt", .{});
    defer summary_file.close(init.io);
    var summary_buffer: [4096]u8 = undefined;
    var summary_file_writer = summary_file.writer(init.io, &summary_buffer);
    const summary = &summary_file_writer.interface;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var image_names: std.ArrayList([]const u8) = .empty;
    defer image_names.deinit(allocator);
    var iterator = image_dir.iterate();
    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".hex")) continue;
        try image_names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    if (image_names.items.len == 0) {
        std.process.fatal("no test images found in '{s}'", .{image_path});
    }
    std.mem.sort([]const u8, image_names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var passed: usize = 0;
    for (image_names.items) |image_name| {
        const name = std.fs.path.stem(image_name);
        const image = try std.fs.path.join(allocator, &.{ image_path, image_name });
        const log_name = try std.fmt.allocPrint(allocator, "{s}.txt", .{name});
        var log_file = try output_dir.createFile(init.io, log_name, .{});

        const child_args = [_][]const u8{ simulator, image, max_cycles };
        var child = try std.process.spawn(init.io, .{
            .argv = &child_args,
            .stdin = .ignore,
            .stdout = .{ .file = log_file },
            .stderr = .{ .file = log_file },
        });
        const term = try child.wait(init.io);
        log_file.close(init.io);

        const success = term == .exited and term.exited == 0;
        if (success) passed += 1;
        const status = if (success) "PASS" else "FAIL";
        try stdout.print("{s} : {s}\n", .{ status, name });
        try summary.print("{s} : {s}\n", .{ status, name });
    }

    const total = image_names.items.len;

    try stdout.print("Test Result : {d} / {d}\n", .{ passed, total });
    try summary.print("Test Result : {d} / {d}\n", .{ passed, total });
    try stdout.flush();
    try summary.flush();

    if (passed != total) std.process.exit(1);
}

fn usage() noreturn {
    std.process.fatal(
        "usage: test-runner <simulator> <output-dir> <max-cycles> <image-dir>",
        .{},
    );
}
