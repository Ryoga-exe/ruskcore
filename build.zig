const std = @import("std");

const TestSuite = struct {
    name: []const u8,
    arch: std.Target.Cpu.Arch,
};

const RiscvTestArtifacts = struct {
    elf: std.Build.LazyPath,
    image: std.Build.LazyPath,
};

const SimulatorOptions = struct {
    test_mode: bool = false,
    print_debug: bool = false,
    enable_debug_input: bool = false,
    enable_konata_trace: bool = false,
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
    reset_active_high: bool,
};

pub fn build(b: *std.Build) void {
    const riscv_tests = b.dependency("riscv_tests", .{});
    const riscv_test_env = b.dependency("riscv_test_env", .{});
    const coremark = b.dependency("coremark", .{});
    const rom_path = b.option(
        []const u8,
        "rom",
        "ROM image used by the Verilator simulator",
    ) orelse "bootrom.hex";
    const rom = pathOption(b, rom_path);
    const print_debug = b.option(
        bool,
        "print-debug",
        "Enable verbose simulation debug output",
    ) orelse false;
    const enable_konata = b.option(
        bool,
        "konata",
        "Generate Konata pipeline traces",
    ) orelse false;
    const coremark_iterations = b.option(
        u32,
        "coremark-iterations",
        "Number of CoreMark iterations",
    ) orelse if (enable_konata) @as(u32, 1) else 200;
    const coremark_cycles = b.option(
        u64,
        "coremark-cycles",
        "Maximum CoreMark simulation cycles (0 for no limit)",
    ) orelse if (enable_konata) @as(u64, 10_000_000) else 400_000_000;
    const coremark_clock_hz = b.option(
        u64,
        "coremark-clock-hz",
        "Clock frequency used to convert mcycle to seconds",
    ) orelse 27_000_000;

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

    const simulator = addSimulator(b, veryl_build, .{
        .print_debug = print_debug,
    });
    const sim_step = b.step("sim", "Build the Verilator simulator");
    simulator.addStepDependencies(sim_step);

    const run_simulator = std.Build.Step.Run.create(b, "run simulator");
    run_simulator.addFileArg(simulator);
    run_simulator.addFileArg(rom);
    if (b.args) |args| {
        run_simulator.addArgs(args);
    } else {
        run_simulator.addFileArg(b.path("test/sample.hex"));
        run_simulator.addArg("100");
    }
    const run_step = b.step(
        "run",
        "Run the simulator (default ROM: bootrom.hex, RAM: test/sample.hex)",
    );
    run_step.dependOn(&run_simulator.step);

    const konata_simulator = addSimulator(b, veryl_build, .{
        .enable_konata_trace = true,
    });
    const run_konata = std.Build.Step.Run.create(b, "run simulator with Konata trace");
    run_konata.addFileArg(konata_simulator);
    run_konata.addFileArg(rom);
    const konata_args_valid = if (b.args) |args| args.len == 2 else true;
    if (b.args) |args| {
        if (args.len == 2) {
            run_konata.addFileArg(pathOption(b, args[0]));
            run_konata.addArg(args[1]);
        }
    } else {
        run_konata.addFileArg(b.path("test/sample.hex"));
        run_konata.addArg("1000");
    }
    const konata_raw = run_konata.addOutputFileArg("konata.trace");
    const konata_converter = addHostTool(b, "konata", "tools/konata.zig");
    const convert_konata = b.addRunArtifact(konata_converter);
    convert_konata.addFileArg(konata_raw);
    const konata_log = convert_konata.addOutputFileArg("konata.log");
    const install_konata_log = b.addInstallFile(konata_log, "trace/konata.log");
    const konata_step = b.step(
        "konata",
        "Run the simulator and generate a Konata pipeline trace",
    );
    if (konata_args_valid) {
        konata_step.dependOn(&install_konata_log.step);
    } else {
        const invalid_args = b.addFail("usage: zig build konata -- <RAM image> <cycles>");
        konata_step.dependOn(&invalid_args.step);
    }

    const bin2hex = addHostTool(b, "bin2hex", "tools/bin2hex.zig");
    const run_bin2hex = b.addRunArtifact(bin2hex);
    if (b.args) |args| run_bin2hex.addArgs(args);
    const bin2hex_step = b.step("bin2hex", "Convert a binary file to a hex memory image");
    bin2hex_step.dependOn(&run_bin2hex.step);

    const gpu_image = addZigImage(b, bin2hex, "gpu");
    const install_gpu_image = b.addInstallFile(gpu_image, "test/zig/gpu.hex");
    const update_gpu_image = b.addUpdateSourceFiles();
    update_gpu_image.addCopyFileToSource(gpu_image, "test/zig/gpu.hex");
    const gpu_image_step = b.step("gpu-image", "Build the graphics MMIO demo RAM image");
    gpu_image_step.dependOn(&install_gpu_image.step);
    gpu_image_step.dependOn(&update_gpu_image.step);

    const uart_image = addZigImageWithLinker(
        b,
        bin2hex,
        "uart_image",
        "test/zig/uart_image.ld",
    );
    const install_uart_image = b.addInstallFile(uart_image, "test/zig/uart_image.hex");
    const update_uart_image = b.addUpdateSourceFiles();
    update_uart_image.addCopyFileToSource(uart_image, "test/zig/uart_image.hex");
    const uart_image_step = b.step(
        "uart-image",
        "Build the UART graphics receiver RAM image",
    );
    uart_image_step.dependOn(&install_uart_image.step);
    uart_image_step.dependOn(&update_uart_image.step);

    const debug_output_image = addDebugImage(b, bin2hex, "debug_output");
    const install_debug_output_image = b.addInstallFile(
        debug_output_image,
        "test/debug_output.hex",
    );
    const debug_output_image_step = b.step(
        "debug-output-image",
        "Build the debug MMIO example RAM image",
    );
    debug_output_image_step.dependOn(&install_debug_output_image.step);

    const run_debug_output = std.Build.Step.Run.create(b, "run debug MMIO example");
    run_debug_output.addFileArg(simulator);
    run_debug_output.addFileArg(rom);
    run_debug_output.addFileArg(debug_output_image);
    run_debug_output.addArg("10000");
    run_debug_output.setEnvironmentVariable("DBG_ADDR", "0x40000000");
    run_debug_output.has_side_effects = true;
    const debug_output_step = b.step(
        "debug-output",
        "Build and run the debug MMIO example with Verilator",
    );
    debug_output_step.dependOn(&run_debug_output.step);

    const debug_input_image = addDebugImage(b, bin2hex, "debug_input");
    const install_debug_input_image = b.addInstallFile(
        debug_input_image,
        "test/debug_input.hex",
    );
    const debug_input_image_step = b.step(
        "debug-input-image",
        "Build the debug MMIO input example RAM image",
    );
    debug_input_image_step.dependOn(&install_debug_input_image.step);

    const debug_input_simulator = addSimulator(b, veryl_build, .{
        .print_debug = print_debug,
        .enable_debug_input = true,
    });
    const run_debug_input = std.Build.Step.Run.create(b, "run debug MMIO input example");
    run_debug_input.addFileArg(debug_input_simulator);
    run_debug_input.addFileArg(rom);
    run_debug_input.addFileArg(debug_input_image);
    if (b.args) |args| {
        run_debug_input.addArgs(args);
    } else {
        run_debug_input.addArg("0");
    }
    run_debug_input.setEnvironmentVariable("DBG_ADDR", "0x40000000");
    run_debug_input.has_side_effects = true;
    const debug_input_step = b.step(
        "debug-input",
        "Build and run the interactive debug MMIO input example with Verilator",
    );
    debug_input_step.dependOn(&run_debug_input.step);

    const test_simulator = addSimulator(b, veryl_build, .{
        .test_mode = true,
        .print_debug = print_debug,
        .enable_konata_trace = enable_konata,
    });
    const coremark_artifacts = addCoreMark(
        b,
        bin2hex,
        coremark,
        coremark_iterations,
        coremark_clock_hz,
    );
    const run_coremark = std.Build.Step.Run.create(b, "run CoreMark");
    run_coremark.addFileArg(test_simulator);
    run_coremark.addFileArg(rom);
    run_coremark.addFileArg(coremark_artifacts.image);
    run_coremark.addArg(b.fmt("{d}", .{coremark_cycles}));
    const coremark_raw = if (enable_konata)
        run_coremark.addOutputFileArg("coremark.trace")
    else
        null;
    run_coremark.setEnvironmentVariable("DBG_ADDR", "0x40000000");
    run_coremark.has_side_effects = true;
    const install_coremark_elf = b.addInstallFile(
        coremark_artifacts.elf,
        "coremark/coremark.elf",
    );
    const install_coremark_image = b.addInstallFile(
        coremark_artifacts.image,
        "coremark/coremark.hex",
    );
    const coremark_step = b.step(
        "coremark",
        "Build and run CoreMark with Verilator",
    );
    coremark_step.dependOn(&run_coremark.step);
    coremark_step.dependOn(&install_coremark_elf.step);
    coremark_step.dependOn(&install_coremark_image.step);
    if (coremark_raw) |raw| {
        const convert_coremark = b.addRunArtifact(konata_converter);
        convert_coremark.addFileArg(raw);
        const coremark_log = convert_coremark.addOutputFileArg("coremark.log");
        const install_coremark_log = b.addInstallFile(
            coremark_log,
            "coremark/coremark.log",
        );
        coremark_step.dependOn(&install_coremark_log.step);
    }

    const test_runner = addHostTool(b, "test-runner", "tools/test_runner.zig");
    const test_cycles = b.option(
        u64,
        "test-cycles",
        "Maximum simulation cycles per RISC-V test (0 for no limit)",
    ) orelse 1_000_000;
    const debug_label = b.option(
        []const u8,
        "debug-label",
        "ELF section mapped to the simulator debug device",
    ) orelse ".tohost";
    const test_images = b.addWriteFiles();
    const run_tests = b.addRunArtifact(test_runner);
    run_tests.addFileArg(test_simulator);
    run_tests.addFileArg(rom);
    run_tests.addArg(b.getInstallPath(.prefix, "test-results"));
    run_tests.addArg(b.fmt("{d}", .{test_cycles}));
    run_tests.addDirectoryArg(test_images.getDirectory());
    run_tests.addArg(debug_label);
    run_tests.addArg(if (enable_konata) "1" else "0");
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

            const artifacts = addRiscvTest(
                b,
                bin2hex,
                riscv_tests,
                riscv_test_env,
                suite,
                name,
            );
            _ = test_images.addCopyFile(artifacts.elf, test_name);
            _ = test_images.addCopyFile(artifacts.image, b.fmt("{s}.hex", .{test_name}));
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

fn pathOption(b: *std.Build, path: []const u8) std.Build.LazyPath {
    return if (std.fs.path.isAbsolute(path))
        .{ .cwd_relative = path }
    else
        b.path(path);
}

fn fpgaConfig(board: FpgaBoard) FpgaConfig {
    return switch (board) {
        .tangnano9k => .{
            .device = "GW1NR-LV9QN88PC6/I5",
            .family = "GW1N-9C",
            .yosys_family = "gw1n",
            .constraints = "fpga/tangnano9k/tangnano9k.cst",
            .timing = "fpga/tangnano9k/timing.sdc",
            .reset_active_high = false,
        },
        .tangnano20k => .{
            .device = "GW2AR-LV18QN88C8/I7",
            .family = "GW2A-18C",
            .yosys_family = "gw2a",
            .constraints = "fpga/tangnano20k/tangnano20k.cst",
            .timing = "fpga/tangnano20k/timing.sdc",
            .reset_active_high = true,
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
        "read_slang --top ruskcore_top_tang -G RESET_ACTIVE_HIGH={d} " ++
            "-F ruskcore.f; " ++
            "setattr -unset init w:*; " ++
            "synth_gowin -setundef -family {s} -top ruskcore_top_tang",
        .{ @intFromBool(config.reset_active_high), config.yosys_family },
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
) RiscvTestArtifacts {
    const riscv = std.Target.riscv;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = suite.arch,
        .cpu_model = .{ .explicit = switch (suite.arch) {
            .riscv32 => &std.Target.riscv.cpu.generic_rv32,
            .riscv64 => &std.Target.riscv.cpu.generic_rv64,
            else => unreachable,
        } },
        .cpu_features_add = riscv.featureSet(&[_]riscv.Feature{
            .m,
            .a,
        }),
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
    return .{
        .elf = elf.getEmittedBin(),
        .image = convert.captureStdOut(.{ .basename = b.fmt("{s}.hex", .{test_name}) }),
    };
}

fn addDebugImage(
    b: *std.Build,
    bin2hex: *std.Build.Step.Compile,
    name: []const u8,
) std.Build.LazyPath {
    const riscv = std.Target.riscv;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .cpu_model = .{ .explicit = &riscv.cpu.generic_rv64 },
        .cpu_features_add = riscv.featureSet(&.{.m}),
        .os_tag = .freestanding,
        .abi = .none,
    });
    const module = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = .ReleaseSmall,
        .code_model = .medany,
    });
    module.addAssemblyFile(b.path("test/entry.S"));
    module.addCSourceFile(.{
        .file = b.path(b.fmt("test/{s}.c", .{name})),
        .flags = &.{ "-std=c11", "-ffreestanding" },
    });

    const elf = b.addExecutable(.{
        .name = name,
        .root_module = module,
    });
    elf.setLinkerScript(b.path("test/link.ld"));

    const binary = elf.addObjCopy(.{
        .basename = b.fmt("{s}.bin", .{name}),
        .format = .bin,
    });
    const convert = b.addRunArtifact(bin2hex);
    convert.addArg("8");
    convert.addFileArg(binary.getOutput());
    return convert.captureStdOut(.{ .basename = b.fmt("{s}.hex", .{name}) });
}

fn addZigImage(
    b: *std.Build,
    bin2hex: *std.Build.Step.Compile,
    name: []const u8,
) std.Build.LazyPath {
    return addZigImageWithLinker(b, bin2hex, name, "test/link.ld");
}

fn addZigImageWithLinker(
    b: *std.Build,
    bin2hex: *std.Build.Step.Compile,
    name: []const u8,
    linker_script: []const u8,
) std.Build.LazyPath {
    const riscv = std.Target.riscv;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .cpu_model = .{ .explicit = &riscv.cpu.generic_rv64 },
        .cpu_features_add = riscv.featureSet(&.{.m}),
        .os_tag = .freestanding,
        .abi = .none,
    });
    const module = b.createModule(.{
        .root_source_file = b.path(b.fmt("test/zig/{s}.zig", .{name})),
        .target = target,
        .optimize = .ReleaseSmall,
        .code_model = .medany,
    });
    module.addAssemblyFile(b.path("test/entry.S"));

    const elf = b.addExecutable(.{
        .name = name,
        .root_module = module,
    });
    elf.entry = .{ .symbol_name = "_start" };
    elf.setLinkerScript(b.path(linker_script));

    const binary = elf.addObjCopy(.{
        .basename = b.fmt("{s}.bin", .{name}),
        .format = .bin,
    });
    const convert = b.addRunArtifact(bin2hex);
    convert.addArg("8");
    convert.addFileArg(binary.getOutput());
    return convert.captureStdOut(.{ .basename = b.fmt("{s}.hex", .{name}) });
}

fn addCoreMark(
    b: *std.Build,
    bin2hex: *std.Build.Step.Compile,
    coremark: *std.Build.Dependency,
    iterations: u32,
    clock_hz: u64,
) RiscvTestArtifacts {
    const riscv = std.Target.riscv;
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .cpu_model = .{ .explicit = &riscv.cpu.generic_rv64 },
        .cpu_features_add = riscv.featureSet(&.{.m}),
        .os_tag = .freestanding,
        .abi = .none,
    });
    const module = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = .ReleaseFast,
        .code_model = .medany,
    });
    module.addAssemblyFile(b.path("test/entry.S"));
    for ([_][]const u8{
        "core_list_join.c",
        "core_main.c",
        "core_matrix.c",
        "core_state.c",
        "core_util.c",
    }) |source| {
        module.addCSourceFile(.{
            .file = coremark.path(source),
            .flags = &.{ "-std=c11", "-ffreestanding", "-fno-builtin" },
        });
    }
    module.addCSourceFile(.{
        .file = b.path("test/coremark/core_portme.c"),
        .flags = &.{ "-std=c11", "-ffreestanding", "-fno-builtin" },
    });
    module.addIncludePath(b.path("test/coremark"));
    module.addIncludePath(coremark.path(""));
    module.addCMacro("ITERATIONS", b.fmt("{d}", .{iterations}));
    module.addCMacro("COREMARK_CLOCK_HZ", b.fmt("{d}", .{clock_hz}));

    const elf = b.addExecutable(.{
        .name = "coremark",
        .root_module = module,
    });
    elf.setLinkerScript(b.path("test/coremark/link.ld"));

    const binary = elf.addObjCopy(.{
        .basename = "coremark.bin",
        .format = .bin,
    });
    const convert = b.addRunArtifact(bin2hex);
    convert.addArg("8");
    convert.addFileArg(binary.getOutput());
    return .{
        .elf = elf.getEmittedBin(),
        .image = convert.captureStdOut(.{ .basename = "coremark.hex" }),
    };
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

fn addSimulator(
    b: *std.Build,
    veryl_build: *std.Build.Step.Run,
    options: SimulatorOptions,
) std.Build.LazyPath {
    const executable_name = if (options.enable_konata_trace)
        "konata-sim"
    else if (options.enable_debug_input)
        "debug-input-sim"
    else if (options.test_mode)
        "test-sim"
    else
        "sim";
    const output_name = if (options.enable_konata_trace)
        "verilator-konata"
    else if (options.enable_debug_input)
        "verilator-debug-input"
    else if (options.test_mode)
        "verilator-test"
    else
        "verilator";
    const cflags = b.fmt("-std=c++17{s}{s}{s}", .{
        if (options.test_mode) " -DTEST_MODE" else "",
        if (options.enable_debug_input) " -DENABLE_DEBUG_INPUT" else "",
        if (options.enable_konata_trace) " -DKONATA_TRACE" else "",
    });

    const verilator = b.addSystemCommand(&.{
        "verilator",
        "--cc",
        "--build",
        "-j",
        "0",
    });
    verilator.addArg("-DSIMULATION");
    if (options.test_mode) verilator.addArg("-DTEST_MODE");
    if (options.print_debug) verilator.addArg("-DPRINT_DEBUG");
    if (options.enable_debug_input) verilator.addArg("-DENABLE_DEBUG_INPUT");
    if (options.enable_konata_trace) verilator.addArg("-DKONATA_TRACE");
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
