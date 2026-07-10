const std = @import("std");

pub fn build(b: *std.Build) void {
    const veryl_fmt = b.addSystemCommand(&.{ "veryl", "fmt" });
    const fmt_step = b.step("fmt", "Format the Veryl sources");
    fmt_step.dependOn(&veryl_fmt.step);

    const veryl_build = b.addSystemCommand(&.{ "veryl", "build" });

    const veryl_step = b.step("veryl", "Build the Veryl project");
    veryl_step.dependOn(&veryl_build.step);

    b.getInstallStep().dependOn(&veryl_build.step);
}
