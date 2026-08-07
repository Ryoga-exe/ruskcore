const std = @import("std");
const konata_trace = @import("konata_trace.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) usage();
    try konata_trace.convert(init.io, allocator, args[1], args[2]);
}

fn usage() noreturn {
    std.process.fatal("usage: konata <raw-trace> <konata-log>", .{});
}
