const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) usage();

    const bytes_per_line = std.fmt.parseInt(usize, args[1], 10) catch usage();
    if (bytes_per_line == 0) usage();

    const bytes = try Io.Dir.cwd().readFileAlloc(
        init.io,
        args[2],
        allocator,
        .limited(std.math.maxInt(usize)),
    );

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const padding = bytes_per_line - bytes.len % bytes_per_line;
    const padded_len = std.math.add(usize, bytes.len, padding) catch
        std.process.fatal("input is too large", .{});

    var offset: usize = 0;
    while (offset < padded_len) : (offset += bytes_per_line) {
        var index = offset + bytes_per_line;
        while (index > offset) {
            index -= 1;
            const byte = if (index < bytes.len) bytes[index] else 0;
            try stdout.printHex(&.{byte}, .lower);
        }
        try stdout.writeByte('\n');
    }
    try stdout.flush();
}

fn usage() noreturn {
    std.process.fatal("usage: bin2hex <bytes per line> <filename>", .{});
}
