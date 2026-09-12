const std = @import("std");

// Root build script, so this repository is a Zig package.
//
//   zig fetch --save git+https://github.com/AB-KeyNub/KeyNub-SDK#<tag>
//
// and then, in your build.zig:
//
//   const keynub = b.dependency("keynub_licdongle", .{ .target = target, .optimize = optimize });
//   exe.root_module.addImport("keynub_licdongle", keynub.module("keynub_licdongle"));
//
// The module is the binding in bindings/zig, compiled against the real header in
// include/. It also links the prebuilt native library for the target from
// natives/<platform>, so a consumer needs nothing installed: the archive Zig
// fetches carries the library. At run time the shared library still has to be
// found by the operating system -- next to the executable, or on PATH /
// LD_LIBRARY_PATH / DYLD_LIBRARY_PATH -- see NATIVES.md.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const include_path = b.path("include");

    const module = b.addModule("keynub_licdongle", .{
        .root_source_file = b.path("bindings/zig/src/licdongle.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(include_path);
    if (nativesDir(target.result)) |dir| {
        module.addLibraryPath(b.path(dir));
        module.linkSystemLibrary("keynub_licdongle", .{});
    }

    // `zig build` type-checks the binding without needing the library.
    const check_module = b.createModule(.{
        .root_source_file = b.path("bindings/zig/src/licdongle.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    check_module.addIncludePath(include_path);
    const check = b.addObject(.{
        .name = "licdongle_check",
        .root_module = check_module,
    });
    b.getInstallStep().dependOn(&check.step);
}

/// The natives/<platform> directory holding the prebuilt library for a target,
/// or null for a target this repository carries no library for.
fn nativesDir(t: std.Target) ?[]const u8 {
    return switch (t.os.tag) {
        .windows => switch (t.cpu.arch) {
            .x86_64 => "natives/win-x64",
            .x86 => "natives/win-x86",
            .aarch64 => "natives/win-arm64",
            else => null,
        },
        .linux => switch (t.cpu.arch) {
            .x86_64 => "natives/linux-x64",
            .aarch64 => "natives/linux-arm64",
            else => null,
        },
        .macos => switch (t.cpu.arch) {
            .x86_64 => "natives/osx-x64",
            .aarch64 => "natives/osx-arm64",
            else => null,
        },
        else => null,
    };
}
