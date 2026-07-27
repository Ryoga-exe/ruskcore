const std = @import("std");

const TestSuite = struct {
    name: []const u8,
    arch: std.Target.Cpu.Arch,
};

const FpgaBoard = enum {
    tangnano9k,
    tangnano20k,
};

const FpgaConfig = struct {
    device: []const u8,
    family: []const u8,
    yosys_family: []const u8,
    constraints: []const u8,
    timing: []const u8,
};

pub fn build(b: *std.Build) void {
    const riscv_tests = b.dependency("riscv_tests", .{});
    const riscv_test_env = b.dependency("riscv_test_env", .{});

    const veryl_fmt = b.addSystemCommand(&.{ "veryl", "fmt", "--quiet" });
    const fmt_step = b.step("fmt", "Format the Veryl sources");
    fmt_step.dependOn(&veryl_fmt.step);

    const veryl_check = b.addSystemCommand(&.{ "veryl", "check", "--quiet" });
    const check_step = b.step("check", "Check the Veryl sources");
    check_step.dependOn(&veryl_check.step);

    const veryl_build = b.addSystemCommand(&.{ "veryl", "build", "--quiet" });
    const veryl_step = b.step("veryl", "Build the Veryl project");
    veryl_step.dependOn(&veryl_build.step);
    b.getInstallStep().dependOn(&veryl_build.step);

    const veryl_clean = b.addSystemCommand(&.{ "veryl", "clean", "--quiet" });
    const clean_step = b.step("clean", "Remove generated Veryl files");
    clean_step.dependOn(&veryl_clean.step);

    const fpga_board = b.option(
        FpgaBoard,
        "board",
        "FPGA board (tangnano9k or tangnano20k)",
    ) orelse .tangnano20k;
    const fpga = fpgaConfig(fpga_board);
    const bitstream = addBitstream(b, veryl_build, fpga_board, fpga);
    const install_bitstream = b.addInstallFile(
        bitstream,
        b.fmt("fpga/{s}/ruskcore.fs", .{@tagName(fpga_board)}),
    );
    const bitstream_step = b.step("bitstream", "Build a Tang Nano bitstream");
    bitstream_step.dependOn(&install_bitstream.step);

    const program = b.addSystemCommand(&.{
        "openFPGALoader",
        "-m",
        "-b",
        @tagName(fpga_board),
    });
    program.addFileArg(bitstream);
    program.has_side_effects = true;
    const program_step = b.step("program", "Program a Tang Nano SRAM");
    program_step.dependOn(&program.step);

    const flash = b.addSystemCommand(&.{
        "openFPGALoader",
        "-b",
        @tagName(fpga_board),
        "-f",
    });
    flash.addFileArg(bitstream);
    flash.has_side_effects = true;
    const flash_step = b.step("flash", "Program a Tang Nano non-volatile flash");
    flash_step.dependOn(&flash.step);

    const synth_top = b.option(
        []const u8,
        "synth-top",
        "Top-level Veryl module to synthesize",
    ) orelse "core";
    const timing_paths = b.option(
        u32,
        "timing-paths",
        "Number of timing paths to report during synthesis",
    ) orelse 10;

    const veryl_command = addHostTool(b, "veryl-command", "tools/veryl_command.zig");
    const synth = addVerylSynth(b, veryl_command, synth_top, timing_paths);
    synth.addArgs(&.{ "--dump-timing", "--dump-area" });
    _ = synth.captureStdErr(.{ .basename = "veryl-synth.stderr" });
    synth.has_side_effects = true;
    const synth_step = b.step("synth", "Run synthesis and dump timing/area reports");
    synth_step.dependOn(&synth.step);

    const fmax_synth = addVerylSynth(b, veryl_command, synth_top, 1);
    const synthesis_report = fmax_synth.captureStdOut(.{ .basename = "veryl-synth.txt" });
    _ = fmax_synth.captureStdErr(.{ .basename = "veryl-synth.stderr" });
    const fmax_tool = addHostTool(b, "fmax", "tools/fmax.zig");
    const run_fmax = b.addRunArtifact(fmax_tool);
    run_fmax.addFileArg(synthesis_report);
    const fmax_step = b.step("fmax", "Estimate fmax from the critical path");
    fmax_step.dependOn(&run_fmax.step);

    const simulator = addSimulator(b, veryl_build, false);
    const sim_step = b.step("sim", "Build the Verilator simulator");
    simulator.addStepDependencies(sim_step);

    const run_simulator = std.Build.Step.Run.create(b, "run simulator");
    run_simulator.addFileArg(simulator);
    if (b.args) |args| {
        run_simulator.addArgs(args);
    } else {
        run_simulator.addFileArg(b.path("test/sample.hex"));
        run_simulator.addArg("100");
    }
    const run_step = b.step("run", "Run the simulator (default: test/sample.hex)");
    run_step.dependOn(&run_simulator.step);

    const bin2hex = addHostTool(b, "bin2hex", "tools/bin2hex.zig");
    const run_bin2hex = b.addRunArtifact(bin2hex);
    if (b.args) |args| run_bin2hex.addArgs(args);
    const bin2hex_step = b.step("bin2hex", "Convert a binary file to a hex memory image");
    bin2hex_step.dependOn(&run_bin2hex.step);

    const test_simulator = addSimulator(b, veryl_build, true);
    const test_runner = addHostTool(b, "test-runner", "tools/test_runner.zig");
    const test_cycles = b.option(
        u64,
        "test-cycles",
        "Maximum simulation cycles per RISC-V test (0 for no limit)",
    ) orelse 1_000_000;
    const test_images = b.addWriteFiles();
    const run_tests = b.addRunArtifact(test_runner);
    run_tests.addFileArg(test_simulator);
    run_tests.addArg(b.getInstallPath(.prefix, "test-results"));
    run_tests.addArg(b.fmt("{d}", .{test_cycles}));
    run_tests.addDirectoryArg(test_images.getDirectory());
    run_tests.has_side_effects = true;
    const build_tests_step = b.step("riscv-tests", "Build the RISC-V test images");
    const test_step = b.step("test", "Run the RISC-V tests with Verilator");
    const filters = b.args orelse &.{};
    var selected_tests: usize = 0;
    const io = b.graph.io;
    var isa_dir = riscv_tests.builder.build_root.handle.openDir(io, "isa", .{ .iterate = true }) catch
        @panic("unable to open RISC-V test suites");
    defer isa_dir.close(io);
    var suite_iterator = isa_dir.iterate();
    while (suite_iterator.next(io) catch @panic("unable to enumerate RISC-V test suites")) |suite_entry| {
        if (suite_entry.kind != .directory) continue;
        const suite = parseTestSuite(suite_entry.name) orelse continue;
        if (filters.len == 0 and !isDefaultTestSuite(suite.name)) continue;

        const directory = b.fmt("isa/{s}", .{suite.name});
        var dir = riscv_tests.builder.build_root.handle.openDir(io, directory, .{ .iterate = true }) catch
            @panic("unable to open RISC-V test suite");
        defer dir.close(io);
        var iterator = dir.iterate();
        while (iterator.next(io) catch @panic("unable to enumerate RISC-V tests")) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".S")) continue;
            const name = std.fs.path.stem(entry.name);
            const test_name = b.fmt("{s}-p-{s}", .{ suite.name, name });
            if (!matchesAnyFilter(test_name, filters)) continue;
            selected_tests += 1;

            const image = addRiscvTest(
                b,
                bin2hex,
                riscv_tests,
                riscv_test_env,
                suite,
                name,
            );
            _ = test_images.addCopyFile(image, b.fmt("{s}.hex", .{test_name}));
        }
    }
    if (selected_tests == 0) {
        const no_tests = b.addFail("no RISC-V tests matched the supplied filters");
        build_tests_step.dependOn(&no_tests.step);
        test_step.dependOn(&no_tests.step);
    } else {
        build_tests_step.dependOn(&test_images.step);
        test_step.dependOn(&run_tests.step);
    }
}

fn fpgaConfig(board: FpgaBoard) FpgaConfig {
    return switch (board) {
        .tangnano9k => .{
            .device = "GW1NR-LV9QN88PC6/I5",
            .family = "GW1N-9C",
            .yosys_family = "gw1n",
            .constraints = "fpga/tangnano9k/tangnano9k.cst",
            .timing = "fpga/tangnano9k/timing.sdc",
        },
        .tangnano20k => .{
            .device = "GW2AR-LV18QN88C8/I7",
            .family = "GW2A-18C",
            .yosys_family = "gw2a",
            .constraints = "fpga/tangnano20k/tangnano20k.cst",
            .timing = "fpga/tangnano20k/timing.sdc",
        },
    };
}

fn addBitstream(
    b: *std.Build,
    veryl_build: *std.Build.Step.Run,
    board: FpgaBoard,
    config: FpgaConfig,
) std.Build.LazyPath {
    const yosys_script = b.fmt(
        "read_slang --top ruskcore_top_tang " ++
            "-F ruskcore.f; " ++
            "setattr -unset init w:*; " ++
            "synth_gowin -setundef -family {s} -top ruskcore_top_tang",
        .{config.yosys_family},
    );
    const yosys = b.addSystemCommand(&.{ "yosys", "-q", "-m", "slang", "-p" });
    yosys.addArg(yosys_script);
    yosys.addArg("-o");
    const synthesized = yosys.addOutputFileArg(b.fmt("{s}.json", .{@tagName(board)}));
    yosys.step.dependOn(&veryl_build.step);
    yosys.addFileInput(b.path("Veryl.toml"));
    yosys.addFileInput(b.path("Veryl.lock"));
    yosys.addFileInput(b.path("ruskcore.f"));
    yosys.addFileInput(b.path("test/led_counter.hex"));
    addDirectoryInputs(b, yosys, "src", ".veryl");

    const nextpnr = b.addSystemCommand(&.{ "nextpnr-himbaechel", "--json" });
    nextpnr.addFileArg(synthesized);
    nextpnr.addArg("--write");
    const routed = nextpnr.addOutputFileArg(b.fmt("{s}-pnr.json", .{@tagName(board)}));
    nextpnr.addArgs(&.{ "--device", config.device, "--vopt" });
    nextpnr.addArg(b.fmt("family={s}", .{config.family}));
    nextpnr.addArg("--vopt");
    nextpnr.addPrefixedFileArg("cst=", b.path(config.constraints));
    nextpnr.addArgs(&.{ "--freq", "27" });
    nextpnr.addArg("--sdc");
    nextpnr.addFileArg(b.path(config.timing));

    const pack = b.addSystemCommand(&.{ "gowin_pack", "-c", "-d", config.family, "-o" });
    const output = pack.addOutputFileArg(b.fmt("ruskcore-{s}.fs", .{@tagName(board)}));
    pack.addFileArg(routed);
    return output;
}

fn addRiscvTest(
    b: *std.Build,
    bin2hex: *std.Build.Step.Compile,
    riscv_tests: *std.Build.Dependency,
    riscv_test_env: *std.Build.Dependency,
    suite: TestSuite,
    name: []const u8,
) std.Build.LazyPath {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = suite.arch,
        .cpu_model = .{ .explicit = switch (suite.arch) {
            .riscv32 => &std.Target.riscv.cpu.generic_rv32,
            .riscv64 => &std.Target.riscv.cpu.generic_rv64,
            else => unreachable,
        } },
        .os_tag = .freestanding,
        .abi = .none,
    });
    const test_name = b.fmt("{s}-p-{s}", .{ suite.name, name });
    const module = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = .ReleaseSmall,
    });
    module.addAssemblyFile(riscv_tests.path(b.fmt(
        "isa/{s}/{s}.S",
        .{ suite.name, name },
    )));
    module.addIncludePath(riscv_test_env.path("p"));
    module.addIncludePath(riscv_tests.path("isa/macros/scalar"));
    if (std.mem.endsWith(u8, suite.name, "mi")) {
        // GNU as permits changing a weak symbol to global; LLVM does not.
        module.addCMacro("global", "weak");
    }

    const elf = b.addExecutable(.{
        .name = test_name,
        .root_module = module,
    });
    elf.setLinkerScript(b.path("test/riscv-tests/link.ld"));

    const binary = elf.addObjCopy(.{
        .basename = b.fmt("{s}.bin", .{test_name}),
        .format = .bin,
    });
    const convert = b.addRunArtifact(bin2hex);
    convert.addArg("8");
    convert.addFileArg(binary.getOutput());
    return convert.captureStdOut(.{ .basename = b.fmt("{s}.hex", .{test_name}) });
}

fn parseTestSuite(name: []const u8) ?TestSuite {
    const arch: std.Target.Cpu.Arch = if (std.mem.startsWith(u8, name, "rv32"))
        .riscv32
    else if (std.mem.startsWith(u8, name, "rv64"))
        .riscv64
    else
        return null;
    return .{ .name = name, .arch = arch };
}

fn isDefaultTestSuite(name: []const u8) bool {
    return std.mem.endsWith(u8, name, "ui") or std.mem.endsWith(u8, name, "mi");
}

fn matchesAnyFilter(name: []const u8, filters: []const []const u8) bool {
    if (filters.len == 0) return true;
    for (filters) |filter| {
        if (std.mem.indexOf(u8, name, filter) != null) return true;
    }
    return false;
}

fn addSimulator(b: *std.Build, veryl_build: *std.Build.Step.Run, test_mode: bool) std.Build.LazyPath {
    const executable_name = if (test_mode) "test-sim" else "sim";
    const output_name = if (test_mode) "verilator-test" else "verilator";
    const cflags = if (test_mode) "-std=c++17 -DTEST_MODE" else "-std=c++17";

    const verilator = b.addSystemCommand(&.{
        "verilator",
        "--cc",
        "--build",
        "-j",
        "0",
    });
    verilator.addArg("-DSIMULATION");
    if (test_mode) verilator.addArg("-DTEST_MODE");
    verilator.addArgs(&.{
        "--top-module",
        "ruskcore_top",
        "-CFLAGS",
        cflags,
        "-o",
        executable_name,
        "-f",
    });
    verilator.addFileArg(b.path("ruskcore.f"));
    verilator.addArg("--exe");
    verilator.addFileArg(b.path("test/tb_verilator.cpp"));
    verilator.addArg("--Mdir");
    const output = verilator.addOutputDirectoryArg(output_name);
    verilator.step.dependOn(&veryl_build.step);
    verilator.addFileInput(b.path("Veryl.toml"));
    verilator.addFileInput(b.path("Veryl.lock"));
    addDirectoryInputs(b, verilator, "src", ".veryl");

    return output.path(b, executable_name);
}

fn addHostTool(b: *std.Build, name: []const u8, source: []const u8) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
}

fn addVerylSynth(
    b: *std.Build,
    veryl_command: *std.Build.Step.Compile,
    top: []const u8,
    timing_paths: u32,
) *std.Build.Step.Run {
    const synth = b.addRunArtifact(veryl_command);
    synth.addArgs(&.{ "synth", "--top" });
    synth.addArg(top);
    synth.addArgs(&.{ "--timing-paths", b.fmt("{d}", .{timing_paths}) });
    synth.addFileInput(b.path("Veryl.toml"));
    synth.addFileInput(b.path("Veryl.lock"));
    addDirectoryInputs(b, synth, "src", ".veryl");
    return synth;
}

fn addDirectoryInputs(
    b: *std.Build,
    run: *std.Build.Step.Run,
    directory: []const u8,
    extension: []const u8,
) void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, directory, .{ .iterate = true }) catch
        @panic("unable to open input directory");
    defer dir.close(io);

    var walker = dir.walk(b.allocator) catch @panic("unable to walk input directory");
    defer walker.deinit();
    while (walker.next(io) catch @panic("unable to walk input directory")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, extension)) continue;
        run.addFileInput(b.path(b.pathJoin(&.{ directory, entry.path })));
    }
}
