# KeyNub License Dongle — Deno Module

```ts
import { Dongle } from "jsr:@keynub/licdongle";

using d = Dongle.open();                              // first dongle, or Dongle.open("serial")
d.verifyGenuine();                                    // throws unless genuine
const secret = d.withSession(() => d.appDecrypt(sealed)); // <- build the licence check on this
```

**Nothing linked.** The module calls the SDK's flat companion API through
`Deno.dlopen`, which loads the native library at run time, so nothing sits in
the path of the check that a customer could substitute. No dependencies;
Deno 2 on Windows, Linux and macOS. Run with `--allow-ffi`, plus `--allow-env`
and `--allow-read` for the library search.

## Setup

```
deno add jsr:@keynub/licdongle
```

The module finds `keynub_licdongle_flat` for your platform in `natives/<platform>/`
of the [KeyNub SDK](https://github.com/AB-KeyNub/KeyNub-SDK) from the main
module's folder and the working directory upwards. To ship an application, put
the library from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
beside it, or name it before the first call:

```ts
import { setLibraryPath } from "jsr:@keynub/licdongle";
setLibraryPath("/opt/keynub/libkeynub_licdongle_flat.so");
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. After those,
the module asks the system loader. A process loads the library once;
`loadedLibraryPath()` tells which. On Linux, install the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Every failed call throws `LicDongleError` with `status` (`Status.NoDevice`,
  `Status.NotGenuine`, `Status.AuthRequired`, ...), the raw `code`, the
  `operation` and the library's `detail` text. Loading problems throw
  `LibraryError`.
- Results are plain objects (`Info`, `Genuine`, `Device`, `DongleRecord`); byte
  data is `Uint8Array`. The module calls the SDK's flat API: integer handles and
  caller-provided buffers, no C structures and no hand-written layouts.
- `Dongle` is `Disposable`: `using d = Dongle.open()` closes it at the end of
  the block. `withDongle(fn)` and `d.withSession(fn)` close the dongle and the
  session on every exit path, exceptions included, and return what `fn`
  returns. A `Dongle` opened otherwise is closed by `close()`, or when it is
  collected.
- `isGenuine()` is the boolean form for a gate and **fails closed**: every
  failure gives `false`.
- `eraseAllRecords()` is separate from `eraseRecord(name)`: an accidentally
  empty name must not wipe the dongle.
- Calls are synchronous; records are transferred in one call, and the flat API
  has no progress reporting.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `if (!d.isGenuine()) Deno.exit(1)` is one
> conditional branch, and patching one of those in a release build is a
> beginner exercise. Route something the program needs through `appEncrypt`
> and `appDecrypt`, so removing the check removes the data.

## Tests

`deno test` (in `bindings/deno`) runs the unit tests.
`deno run -A bindings/deno/test/standin_test.ts` runs without a dongle: it
compiles a stand-in for the flat C API (`bindings/flat/licd_flat.c` over
`bindings/julia/test/stub/licd_stub.c`) with the C compiler on the path and
exercises every call against it. `KEYNUB_SDK_ROOT` names the SDK sources when
the test does not run inside a clone; `KEYNUB_LICDONGLE_FLAT_LIBRARY` names a
compiled stand-in instead. The samples are under `samples/deno`.

## Links

- [KeyNub License Dongle for Deno](https://www.keynub.com/developers/deno/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
