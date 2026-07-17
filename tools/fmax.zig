const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) usage();

    const report = try Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        allocator,
        .limited(std.math.maxInt(usize)),
    );
    const delay = criticalPathDelay(report) orelse
        std.process.fatal("synthesis report contains no timing result", .{});
    if (delay <= 0) std.process.fatal("invalid critical-path delay: {d}", .{delay});

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.print(
        "critical_path: {d:.3} ns\nfmax: {d:.2} MHz\n",
        .{ delay, 1000.0 / delay },
    );
    try stdout.flush();
}

fn criticalPathDelay(report: []const u8) ?f64 {
    var lines = std.mem.splitScalar(u8, report, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "timing:")) continue;

        var fields = std.mem.tokenizeAny(u8, trimmed, " \t");
        _ = fields.next();
        const value = fields.next() orelse continue;
        return std.fmt.parseFloat(f64, value) catch continue;
    }
    return null;
}

fn usage() noreturn {
    std.process.fatal("usage: fmax <synthesis-report>", .{});
}

test criticalPathDelay {
    const report =
        \\critical path 0:
        \\  timing: 12.34567 ns
        \\  start: foo
    ;
    try std.testing.expectEqual(12.34567, criticalPathDelay(report).?);
    try std.testing.expectEqual(null, criticalPathDelay("no timing data\n"));
}
