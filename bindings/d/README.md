# KeyNub License Dongle — D package

```d
import keynub.licdongle;

auto secret = withDongle((ref Dongle d) {         // first dongle, or withDongle("serial", ...)
    d.verifyGenuine();                            // throws unless genuine
    return d.withSession(() =>                    // closed on every exit path
        d.appDecrypt(sealed));                    // <- build the licence check on this
});
```

**Nothing linked.** The package calls the SDK's flat companion API through
`extern(C)` function pointers resolved by name from the native library, which
is loaded at run time (`dlopen`, `LoadLibrary`), so nothing is linked at build
time and nothing sits in the path of the check that a customer could
substitute. No dependencies; D 2.098 (ldc 1.28, dmd 2.098) or later, on
Windows, Linux and macOS.

## Setup

```sdl
dependency "keynub-licdongle" version="~>1.1.1-d"
```

The `-d` prerelease tag carries this first release; from the next SDK release
the plain version tag carries the package and `version="~>1.1"` works.

The package does not carry the native library. Take `keynub_licdongle_flat`
for your platform from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
and either put it where the operating system finds libraries (next to the
executable, or on `PATH`, `LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`), or name it
before the first call:

```d
setLibraryPath("/opt/keynub/libkeynub_licdongle_flat.so");
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. In a clone
of the SDK repository the package finds `natives/<platform>/` on its own, from
the executable's folder and the working directory upwards, so the samples run
with nothing set. A process loads the library once; `loadedLibraryPath()`
tells which. On Linux, install the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Every failed call throws `LicDongleException` with `status`
  (`Status.noDevice`, `Status.notGenuine`, `Status.authRequired`, ...), the
  raw `code`, the `operation` and the library's `detail` text. Loading
  problems throw `LibraryException`.
- Results are structs (`Info`, `Genuine`, `Device`, `Record`); byte data is
  `ubyte[]`. The package calls the SDK's flat API: integer handles and
  caller-provided buffers, no C structures and no hand-written layouts.
- `Dongle` is not copyable; `close()` it, or let it go out of scope.
  `withDongle` and `withSession` close the dongle and the session on every
  exit path, exceptions included, and return what the delegate returns.
- `isGenuine()` is the boolean form for a gate and **fails closed**: every
  failure gives `false`.
- `eraseAllRecords()` is deliberately separate from `eraseRecord(name)`: an
  accidentally empty name must not wipe the dongle.
- Records are transferred in one call; the flat API has no progress
  reporting.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `if (!d.isGenuine()) exit(1);` is one conditional
> branch, and patching one of those in a release binary is a beginner
> exercise. Route something the program needs through `appEncrypt` and
> `appDecrypt`, so removing the check removes the data.

## Layout

`dub.sdl` sits at the repository root, which is where dub and the DUB registry
look for it; the sources are under `bindings/d/source`, the samples under
`samples/d` (`dub run --single samples/d/verify_and_read.d`).

## Tests

`dub test` runs the unit tests. `dub run --config=standin-test` runs without a
dongle: it compiles a stand-in for the flat C API (`bindings/flat/licd_flat.c`
over `bindings/julia/test/stub/licd_stub.c`) with the C compiler on the path
and exercises every call against it. `KEYNUB_SDK_ROOT` names the SDK sources
when the package is not inside a clone; `KEYNUB_LICDONGLE_FLAT_LIBRARY` names
a compiled stand-in instead.

## Links

- [KeyNub License Dongle for D](https://www.keynub.com/developers/d/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
