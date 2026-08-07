const std = @import("std");
const Io = std.Io;

const stage_names = [_][]const u8{ "IF", "ID", "EX", "MEM", "WB" };

const Instruction = struct {
    seen: bool = false,
    live: bool = false,
};

pub fn convert(
    io: Io,
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
) !void {
    const raw = try Io.Dir.cwd().readFileAlloc(
        io,
        input_path,
        allocator,
        .limited(std.math.maxInt(usize)),
    );

    var output_file = try Io.Dir.cwd().createFile(io, output_path, .{});
    defer output_file.close(io);
    var output_buffer: [4096]u8 = undefined;
    var output_file_writer = output_file.writer(io, &output_buffer);
    const output = &output_file_writer.interface;

    try output.writeAll("Kanata\t0004\nC=\t0\n");

    var instructions: std.ArrayList(Instruction) = .empty;
    defer instructions.deinit(allocator);
    var retire_id: u64 = 0;
    var saw_header = false;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!saw_header) {
            if (!std.mem.eql(u8, line, "RuskTrace\t0001")) return error.InvalidTraceHeader;
            saw_header = true;
            continue;
        }

        var fields = std.mem.tokenizeScalar(u8, line, '\t');
        const command = fields.next() orelse return error.InvalidTraceRecord;
        if (std.mem.eql(u8, command, "P")) {
            const stage = try parseInt(usize, fields.next());
            const id = try parseInt(u64, fields.next());
            const pc = try parseInt(u64, fields.next());
            const bits = try parseInt(u32, fields.next());
            if (fields.next() != null or stage >= stage_names.len) return error.InvalidTraceRecord;

            const index = std.math.cast(usize, id) orelse return error.InvalidInstructionId;
            while (instructions.items.len <= index) try instructions.append(allocator, .{});
            const instruction = &instructions.items[index];
            if (!instruction.seen) {
                instruction.* = .{ .seen = true, .live = true };
                try output.print("I\t{d}\t{d}\t0\n", .{ id, id });
                try output.print("L\t{d}\t0\t{x:0>16}: {x:0>8}\n", .{ id, pc, bits });
            } else if (!instruction.live) {
                return error.ReusedInstructionId;
            }

            try output.print("S\t{d}\t0\t{s}\n", .{ id, stage_names[stage] });
        } else if (std.mem.eql(u8, command, "C")) {
            if (fields.next() != null) return error.InvalidTraceRecord;
            try output.writeAll("C\t1\n");
        } else if (std.mem.eql(u8, command, "F")) {
            const id = try parseInt(u64, fields.next());
            if (fields.next() != null) return error.InvalidTraceRecord;
            const first_younger = @min(
                std.math.cast(usize, id +| 1) orelse instructions.items.len,
                instructions.items.len,
            );
            for (instructions.items[first_younger..], first_younger..) |*instruction, index| {
                if (!instruction.live) continue;
                try output.print("R\t{d}\t{d}\t1\n", .{ index, retire_id });
                instruction.live = false;
            }
        } else if (std.mem.eql(u8, command, "R")) {
            const id = try parseInt(u64, fields.next());
            const flushed = try parseBool(fields.next());
            if (fields.next() != null) return error.InvalidTraceRecord;
            const index = std.math.cast(usize, id) orelse return error.InvalidInstructionId;
            if (index >= instructions.items.len or !instructions.items[index].live) continue;
            try output.print("R\t{d}\t{d}\t{d}\n", .{ id, retire_id, @intFromBool(flushed) });
            instructions.items[index].live = false;
            if (!flushed) retire_id += 1;
        } else {
            return error.InvalidTraceRecord;
        }
    }
    if (!saw_header) return error.InvalidTraceHeader;

    for (instructions.items, 0..) |*instruction, id| {
        if (!instruction.live) continue;
        try output.print("R\t{d}\t{d}\t1\n", .{ id, retire_id });
        instruction.live = false;
    }
    try output.flush();
}

fn parseInt(comptime T: type, value: ?[]const u8) !T {
    return std.fmt.parseInt(T, value orelse return error.InvalidTraceRecord, 10) catch
        return error.InvalidTraceRecord;
}

fn parseBool(value: ?[]const u8) !bool {
    const text = value orelse return error.InvalidTraceRecord;
    if (std.mem.eql(u8, text, "0")) return false;
    if (std.mem.eql(u8, text, "1")) return true;
    return error.InvalidTraceRecord;
}
