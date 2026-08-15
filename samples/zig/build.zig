const std = @import("std");

// Build script for the Zig sample.
//
//   zig build run -Dkeynub-lib-dir=../../build
//
// The binding is added as a local module rather than a package dependency so the
// sample builds straight from a checkout with no fetch step. A real consumer would
// declare it in build.zig.zon and use b.dependency("keynub_licdongle", .{}).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_dir = b.option(
        []const u8,
        "keynub-lib-dir",
        "Directory holding the KeyNub native library",
    ) orelse "../../build";
    const lib_name = b.option(
        []const u8,
        "keynub-lib-name",
        "Library to link",
    ) orelse "keynub_licdongle";

    // @cImport compiles the real header, so this include path is what keeps the
    // binding's declarations from drifting off the ABI.
    const include_path = b.path("../../include");

    const binding = b.createModule(.{
        .root_source_file = b.path("../../bindings/zig/src/licdongle.zig"),
        .target = target,
        .optimize = optimize,
    });
    binding.addIncludePath(include_path);
    binding.link_libc = true;

    const Sample = struct { name: []const u8, source: []const u8, step: []const u8, help: []const u8 };
    const samples = [_]Sample{
        .{
            .name = "verify_and_read",
            .source = "verify_and_read.zig",
            .step = "run",
            .help = "Build and run the sample",
        },
        .{
            .name = "rotate_write_key",
            .source = "rotate_write_key.zig",
            .step = "rotate",
            .help = "Build and run the write-key rotation sample",
        },
    };

    for (samples) |sample| {
        const exe_module = b.createModule(.{
            .root_source_file = b.path(sample.source),
            .target = target,
            .optimize = optimize,
        });
        exe_module.addImport("keynub_licdongle", binding);
        exe_module.addIncludePath(include_path);
        exe_module.addLibraryPath(.{ .cwd_relative = lib_dir });
        exe_module.linkSystemLibrary(lib_name, .{});
        exe_module.link_libc = true;

        const exe = b.addExecutable(.{
            .name = sample.name,
            .root_module = exe_module,
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        // Arguments after `--` reach the sample; the rotation one needs two.
        if (b.args) |args| run_cmd.addArgs(args);
        b.step(sample.step, sample.help).dependOn(&run_cmd.step);
    }
}
