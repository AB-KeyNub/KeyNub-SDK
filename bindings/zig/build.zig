const std = @import("std");

// Build script for the Zig binding.
//
//   zig build                -- compile-check the binding
//   zig build standin-test   -- run the tests against the C ABI stand-in
//
// The include path points at the SDK's real header, which @cImport compiles: the
// binding has no re-declared prototypes to keep in sync.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const include_path = b.path("../../include");

    // Exposed for downstream projects: `b.dependency("keynub_licdongle", .{})`.
    const module = b.addModule("keynub_licdongle", .{
        .root_source_file = b.path("src/licdongle.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addIncludePath(include_path);
    module.link_libc = true;

    // `zig build` type-checks the binding without needing the library.
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

    // `zig build standin-test` runs src/standin_tests.zig against the C ABI stand-in
    // (bindings/julia/test/stub/licd_stub.c), compiled here into the shared library
    // keynub_licdongle_standin: no dongle and no native library needed.
    const standin_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    standin_module.addIncludePath(include_path);
    standin_module.addCSourceFile(.{
        .file = b.path("../julia/test/stub/licd_stub.c"),
        .flags = &.{"-DLICD_BUILD_SHARED"},
    });
    const standin = b.addLibrary(.{
        .name = "keynub_licdongle_standin",
        .linkage = .dynamic,
        .root_module = standin_module,
    });
    const standin_test_module = b.createModule(.{
        .root_source_file = b.path("src/standin_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    standin_test_module.addIncludePath(include_path);
    standin_test_module.linkLibrary(standin);
    const standin_tests = b.addTest(.{ .root_module = standin_test_module });
    b.step("standin-test", "Run the binding tests against the C ABI stand-in")
        .dependOn(&b.addRunArtifact(standin_tests).step);
}
