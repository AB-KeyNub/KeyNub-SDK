const std = @import("std");

// Build script for the Zig binding.
//
//   zig build                                     -- compile-check the binding
//   zig build test -Dkeynub-lib-name=keynub_licdongle_sim \
//                  -Dkeynub-lib-dir=../../build   -- run the suite, no hardware
//
// The include path points at the SDK's real header, which @cImport compiles: the
// binding has no re-declared prototypes to keep in sync.
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
        "Library to link (keynub_licdongle, or keynub_licdongle_sim for the tests)",
    ) orelse "keynub_licdongle";

    const include_path = b.path("../../include");

    // Exposed for downstream projects: `b.dependency("keynub_licdongle", .{})`.
    const module = b.addModule("keynub_licdongle", .{
        .root_source_file = b.path("src/licdongle.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addIncludePath(include_path);
    module.link_libc = true;

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addIncludePath(include_path);
    test_module.addLibraryPath(.{ .cwd_relative = lib_dir });
    test_module.linkSystemLibrary(lib_name, .{});
    test_module.link_libc = true;
    const tests = b.addTest(.{ .root_module = test_module });

    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the binding tests against the device simulator")
        .dependOn(&run_tests.step);

    // `zig build` on its own type-checks the binding without needing the library.
    const check_module = b.createModule(.{
        .root_source_file = b.path("src/licdongle.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_module.addIncludePath(include_path);
    check_module.link_libc = true;
    const check = b.addObject(.{
        .name = "licdongle_check",
        .root_module = check_module,
    });
    b.getInstallStep().dependOn(&check.step);
}
