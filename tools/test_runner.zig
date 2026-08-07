const std = @import("std");
const konata_trace = @import("konata_trace.zig");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 8) usage();

    const simulator = args[1];
    const rom_path = args[2];
    const output_path = args[3];
    const max_cycles = args[4];
    const image_path = args[5];
    const debug_label = args[6];
    const enable_konata = std.mem.eql(u8, args[7], "1");

    const cwd = Io.Dir.cwd();
    try cwd.deleteTree(init.io, output_path);
    try cwd.createDirPath(init.io, output_path);
    var output_dir = try cwd.openDir(init.io, output_path, .{});
    defer output_dir.close(init.io);
    if (enable_konata) try output_dir.createDirPath(init.io, "konata");
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

    var elf_names: std.ArrayList([]const u8) = .empty;
    defer elf_names.deinit(allocator);
    var iterator = image_dir.iterate();
    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file or !try isElf(init.io, image_dir, entry.name)) continue;
        try elf_names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    if (elf_names.items.len == 0) {
        std.process.fatal("no ELF tests found in '{s}'", .{image_path});
    }
    std.mem.sort([]const u8, elf_names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var passed: usize = 0;
    for (elf_names.items) |elf_name| {
        const name = std.fs.path.stem(elf_name);
        const elf = try std.fs.path.join(allocator, &.{ image_path, elf_name });
        const debug_addr = getSectionAddress(init.io, allocator, elf, debug_label) catch |err|
            std.process.fatal(
                "unable to read section '{s}' from '{s}': {t}",
                .{ debug_label, elf, err },
            );
        const debug_addr_text = try std.fmt.allocPrint(allocator, "0x{x}", .{debug_addr});
        try init.environ_map.put("DBG_ADDR", debug_addr_text);

        const image_name = try std.fmt.allocPrint(allocator, "{s}.hex", .{elf_name});
        const image = try std.fs.path.join(allocator, &.{ image_path, image_name });
        const log_name = try std.fmt.allocPrint(allocator, "{s}.txt", .{name});
        var log_file = try output_dir.createFile(init.io, log_name, .{});

        const child_args = [_][]const u8{ simulator, rom_path, image, max_cycles };
        const konata_name = try std.fmt.allocPrint(allocator, "{s}.log", .{name});
        const konata_path = try std.fs.path.join(
            allocator,
            &.{ output_path, "konata", konata_name },
        );
        const raw_name = try std.fmt.allocPrint(allocator, "{s}.trace", .{name});
        const raw_path = try std.fs.path.join(
            allocator,
            &.{ output_path, "konata", raw_name },
        );
        const konata_child_args = [_][]const u8{
            simulator,
            rom_path,
            image,
            max_cycles,
            raw_path,
        };
        var child = try std.process.spawn(init.io, .{
            .argv = if (enable_konata) &konata_child_args else &child_args,
            .stdin = .ignore,
            .stdout = .{ .file = log_file },
            .stderr = .{ .file = log_file },
            .environ_map = init.environ_map,
        });
        const term = try child.wait(init.io);
        log_file.close(init.io);
        if (enable_konata) {
            try konata_trace.convert(init.io, allocator, raw_path, konata_path);
            try cwd.deleteFile(init.io, raw_path);
        }

        const success = term == .exited and term.exited == 0;
        if (success) passed += 1;
        const status = if (success) "PASS" else "FAIL";
        try stdout.print("{s} : {s}\n", .{ status, name });
        try summary.print("{s} : {s}\n", .{ status, name });
    }

    const total = elf_names.items.len;

    try stdout.print("Test Result : {d} / {d}\n", .{ passed, total });
    try summary.print("Test Result : {d} / {d}\n", .{ passed, total });
    try stdout.flush();
    try summary.flush();

    if (passed != total) std.process.exit(1);
}

fn isElf(io: Io, dir: Io.Dir, path: []const u8) !bool {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);

    var magic: [std.elf.MAGIC.len]u8 = undefined;
    const bytes_read = try file.readPositionalAll(io, &magic, 0);
    return bytes_read == magic.len and std.mem.eql(u8, &magic, std.elf.MAGIC);
}

fn getSectionAddress(
    io: Io,
    allocator: std.mem.Allocator,
    elf_path: []const u8,
    section_name: []const u8,
) !u64 {
    const bytes = try Io.Dir.cwd().readFileAlloc(
        io,
        elf_path,
        allocator,
        .limited(std.math.maxInt(usize)),
    );
    var reader: Io.Reader = .fixed(bytes);
    const header = try std.elf.Header.read(&reader);

    var section_headers = header.iterateSectionHeadersBuffer(bytes);
    var section_index: usize = 0;
    var string_table_header: ?std.elf.Elf64_Shdr = null;
    while (try section_headers.next()) |section_header| : (section_index += 1) {
        if (section_index == header.shstrndx) {
            string_table_header = section_header;
            break;
        }
    }
    const string_header = string_table_header orelse return error.InvalidSectionStringTable;
    const string_offset = std.math.cast(usize, string_header.sh_offset) orelse return error.InvalidSectionStringTable;
    const string_size = std.math.cast(usize, string_header.sh_size) orelse return error.InvalidSectionStringTable;
    const string_end = std.math.add(usize, string_offset, string_size) catch return error.InvalidSectionStringTable;
    if (string_end > bytes.len) return error.InvalidSectionStringTable;
    const string_table = bytes[string_offset..string_end];

    section_headers = header.iterateSectionHeadersBuffer(bytes);
    while (try section_headers.next()) |section_header| {
        const name_offset: usize = section_header.sh_name;
        if (name_offset >= string_table.len) return error.InvalidSectionName;
        const name_bytes = string_table[name_offset..];
        const name_end = std.mem.indexOfScalar(u8, name_bytes, 0) orelse return error.InvalidSectionName;
        if (std.mem.eql(u8, name_bytes[0..name_end], section_name)) return section_header.sh_addr;
    }
    return error.SectionNotFound;
}

fn usage() noreturn {
    std.process.fatal(
        "usage: test-runner <simulator> <rom> <output-dir> <max-cycles> <image-dir> <debug-label> <konata:0|1>",
        .{},
    );
}
