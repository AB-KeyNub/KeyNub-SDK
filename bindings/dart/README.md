# KeyNub License Dongle — Dart package

```dart
import 'package:keynub_licdongle/keynub_licdongle.dart';

final ctx = Context();
final dongle = ctx.open();                    // first dongle, or ctx.open(serial: ...)
dongle.verifyGenuine();                       // throws unless genuine
final data = dongle.withSession((s) =>        // closed on every exit path
    s.appDecrypt(sealed));                    // <- build the licence check on this
dongle.close();
ctx.close();
```

**Pure Dart.** The package is `dart:ffi` over the SDK's C library, and the
library is loaded at run time, so there is no build step, no plugin glue and
nothing in the path of the check that a customer could substitute. It works in
Dart command-line programs and in Flutter desktop applications on Windows,
Linux and macOS alike; `package:ffi` is the one dependency, for memory the C
side reads.

## Setup

```
dart pub add keynub_licdongle
```

The package does not carry the native library. Take `keynub_licdongle` for
your platform from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
and either put it where the operating system finds libraries (next to the
executable, or on `PATH`, `LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`), or name it
before the first call:

```dart
LicDongleLibrary.path = '/opt/keynub/libkeynub_licdongle.so';
```

`KEYNUB_LICDONGLE_LIBRARY` in the environment does the same. In a clone of the
SDK repository the package finds `natives/<platform>/` on its own, from the
script's directory and the working directory upwards, so the samples run with
nothing set. A process loads the library once; `LicDongleLibrary.loadedPath`
tells which. For a Flutter application, bundle the library with the platform
build (the Windows and Linux runners take it as a CMake install target, macOS
as a framework or dylib in the bundle) and set `LicDongleLibrary.path` from
`Platform.resolvedExecutable`. On Linux, install the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Results are plain classes (`Info`, `GenuineResult`, `DeviceInfo`,
  `RecordInfo`); byte data is `Uint8List`, and every call taking bytes also
  takes a `String` for its UTF-8. The C structures are `dart:ffi` `Struct`s
  whose field types mirror the header, so Dart computes the padding.
- Failures throw `LicenseDongleError` with `status` (`Status.noDevice`,
  `.notGenuine`, `.authRequired`, ...), `operation` and `detail`; loading
  problems throw `LibraryLoadError`.
- `dongle.isGenuine` is the non-throwing form for a gate and **fails closed**.
- `dongle.withSession((s) => ...)` closes the session afterwards, whatever
  happens; `openSession()` gives a `Session` to close yourself.
- `readRecord` and `writeRecord` take `progress: (done, total) => bool`;
  returning `false` cancels. An exception thrown inside the callback cancels
  the transfer and is rethrown after the C frames have unwound, never through
  them.
- `eraseAllRecords()` is deliberately separate from `eraseRecord(name)`: to
  the C library a null name means "erase every record", and an accidentally
  empty string must not do that.
- Close what you open: a context closes the dongles still open on it, and a
  dongle closes when its context does.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `if (!dongle.isGenuine) exit(1)` is one line to
> delete, and a Dart or Flutter application ships as an AOT snapshot that
> tools read well enough to find it. Route something the program needs through
> `appEncrypt`/`appDecrypt`, so removing the check removes the data.

## Tests

`dart test` runs without a dongle: it compiles a stand-in for the C ABI
(`bindings/julia/test/stub/licd_stub.c` of the SDK repository) with a C
compiler from the path and exercises every call against it.

## Links

- [KeyNub License Dongle for Dart and Flutter](https://www.keynub.com/developers/dart/): the product,
  and how to order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
