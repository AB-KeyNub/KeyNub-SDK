// Where the native library comes from, and loading it once per process.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// The native library could not be loaded.
class LibraryLoadError implements Exception {
  LibraryLoadError(this.path, this.reason);

  /// The file the loader was asked for.
  final String path;
  final String reason;

  @override
  String toString() => "could not load the KeyNub library '$path': $reason";
}

/// The native library in use.
///
/// The package does its work through the KeyNub native library
/// (`keynub_licdongle.dll`, `libkeynub_licdongle.so`,
/// `libkeynub_licdongle.dylib`), which a process loads once, on the first call
/// that needs it. [path] names the file to load and must be set before that
/// first call. Without it the package takes, in this order, the
/// `KEYNUB_LICDONGLE_LIBRARY` environment variable, the `natives/<platform>/`
/// folder of a clone of the SDK repository found from the running script's
/// directory and from the working directory upwards, and finally the bare
/// file name, which the operating system resolves along its usual search path.
abstract final class LicDongleLibrary {
  static String? _chosen;
  static String? _loaded;
  static Api? _api;

  /// The file to load; set before the first call. `null` means automatic.
  static String? get path => _chosen;
  static set path(String? value) {
    if (_loaded != null && value != _loaded) {
      throw StateError("the KeyNub library is already loaded from '$_loaded'; "
          'a process loads it once');
    }
    _chosen = value;
  }

  /// The library the process has loaded, or `null` before the first call.
  static String? get loadedPath => _loaded;

  /// The `natives/<platform>` folder name for this process.
  static String get platform {
    final os = Platform.isWindows
        ? 'win'
        : Platform.isMacOS
            ? 'osx'
            : 'linux';
    final cpu = switch (Abi.current()) {
      Abi.windowsX64 || Abi.linuxX64 || Abi.macosX64 => 'x64',
      Abi.windowsArm64 || Abi.linuxArm64 || Abi.macosArm64 => 'arm64',
      Abi.windowsIA32 || Abi.linuxIA32 => 'x86',
      _ => 'unknown',
    };
    return '$os-$cpu';
  }

  /// The library's file name on this platform.
  static String get defaultBasename => Platform.isWindows
      ? 'keynub_licdongle.dll'
      : Platform.isMacOS
          ? 'libkeynub_licdongle.dylib'
          : 'libkeynub_licdongle.so';

  /// The path the next load would use, given [path], the environment and the
  /// file system as they are now.
  static String get resolvedPath => _chosen ?? _resolve();

  static String _resolve() {
    final env = Platform.environment['KEYNUB_LICDONGLE_LIBRARY'];
    if (env != null && env.isNotEmpty) return env;
    final relative = ['natives', platform, defaultBasename];
    final starts = <String>[];
    if (Platform.script.scheme == 'file') {
      starts.add(File.fromUri(Platform.script).parent.path);
    }
    starts.add(Directory.current.path);
    for (final start in starts) {
      var dir = Directory(start).absolute;
      for (var i = 0; i < 8; i++) {
        final candidate =
            File([dir.path, ...relative].join(Platform.pathSeparator));
        if (candidate.existsSync()) return candidate.path;
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    return defaultBasename;
  }

  /// The bound library, loading it on the first call.
  static Api api() {
    final loaded = _api;
    if (loaded != null) return loaded;
    final target = _chosen ?? _resolve();
    final DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open(target);
    } on ArgumentError catch (e) {
      throw LibraryLoadError(target, '${e.message}');
    }
    final Api api;
    try {
      api = Api(lib);
    } on ArgumentError catch (e) {
      throw LibraryLoadError(
          target, 'not the KeyNub core library: ${e.message}');
    }
    _api = api;
    _loaded = target;
    return api;
  }
}

/// The version of the loaded native library: major, minor, patch.
({int major, int minor, int patch}) libraryVersion() {
  final api = LicDongleLibrary.api();
  final ints = calloc<Int32>(3);
  try {
    api.version(ints, ints + 1, ints + 2);
    return (major: ints[0], minor: ints[1], patch: ints[2]);
  } finally {
    calloc.free(ints);
  }
}
