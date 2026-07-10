const std = @import("std");

pub fn build(b: *std.Build) void {
    const veryl_fmt = b.addSystemCommand(&.{ "veryl", "fmt" });
    const fmt_step = b.step("fmt", "Format the Veryl sources");
    fmt_step.dependOn(&veryl_fmt.step);

    const veryl_build = b.addSystemCommand(&.{ "veryl", "build" });
    const veryl_step = b.step("veryl", "Build the Veryl project");
    veryl_step.dependOn(&veryl_build.step);
    b.getInstallStep().dependOn(&veryl_build.step);

    const veryl_clean = b.addSystemCommand(&.{ "veryl", "clean" });
    const clean_step = b.step("clean", "Remove generated Veryl files");
    clean_step.dependOn(&veryl_clean.step);

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

    const test_simulator = addSimulator(b, veryl_build, true);
    const test_runner = addHostTool(b, "test-runner", "tools/test_runner.zig");
    const run_tests = b.addRunArtifact(test_runner);
    run_tests.addFileArg(test_simulator);
    if (b.args) |args| {
        run_tests.addArgs(args);
    } else {
        run_tests.addArg("test/share/riscv-tests");
    }
    const test_step = b.step("test", "Run RISC-V tests with Verilator");
    test_step.dependOn(&run_tests.step);

    const bin2hex = addHostTool(b, "bin2hex", "tools/bin2hex.zig");
    const run_bin2hex = b.addRunArtifact(bin2hex);
    if (b.args) |args| run_bin2hex.addArgs(args);
    const bin2hex_step = b.step("bin2hex", "Convert a binary file to a hex memory image");
    bin2hex_step.dependOn(&run_bin2hex.step);
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
