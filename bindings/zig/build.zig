const std = @import("std");

// Build script for the Zig binding.
//
//   zig build   -- compile-check the binding
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
}
