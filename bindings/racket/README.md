# KeyNub License Dongle — Racket Package

```racket
(require keynub/licdongle)

(define secret
  (with-dongle (d)                ; first dongle, or (d #:serial "...")
    (dongle-verify-genuine d)     ; raises unless genuine
    (with-session d               ; closed on every exit path
      (app-decrypt d sealed))))   ; <- build the licence check on this
```

**Nothing linked.** The package calls the SDK's flat companion API through
`ffi/unsafe`, from the native library loaded at run time on the first call;
nothing is linked at build time. Requiring the module and building its
documentation need no library. No dependencies beyond `base`; Racket 8.0 or
later, on Windows, Linux and macOS.

## Setup

```
raco pkg install keynub-licdongle
```

or straight from the repository, under the package's name (without `--name`,
raco names it after the last path segment):

```
raco pkg install --name keynub-licdongle "https://github.com/AB-KeyNub/KeyNub-SDK.git?path=bindings/racket#racket-v1.1.1"
```

The package does not contain the native library. Put the library for your
platform from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
next to your program, or name it before the first call:

```racket
(set-library-path! "/opt/keynub/libkeynub_licdongle_flat.so")
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. The package
looks in `natives/<platform>/` from the program's folder, the current
directory and its own folder upwards (so a package linked from an SDK clone
finds the clone's `natives/`), then asks the system loader. A process loads
the library once; `(loaded-library-path)` tells which. On Linux, install the
udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Every failed call raises `exn:fail:keynub` with `status` (`'no-device`,
  `'not-genuine`, `'auth-required`, ...), the raw `code`, the `operation` and
  the library's `detail` text. Loading problems raise
  `exn:fail:keynub:library`. Both are `exn:fail`.
- Every provided function checks its arguments with a contract. Results are
  transparent structs (`device-info`, `verification`, `device`, `record`);
  byte data is a byte string. The package calls the SDK's flat API: integer
  handles and caller-provided buffers, no C structures and no hand-written
  layouts.
- `with-dongle` / `call-with-dongle` and `with-session` / `call-with-session`
  close the dongle and the session on every exit path, exceptions included,
  and return what the body returns. A dongle opened with `dongle-open` is
  closed by `dongle-close`, or when it is collected.
- `dongle-genuine?` is the boolean form for a gate and **fails closed**: every
  failure gives `#f`.
- `erase-all-records!` is the only call that erases more than one record;
  `erase-record!` erases the one record it names.
- Records are transferred in one call; the flat API has no progress
  reporting.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `(unless (dongle-genuine? d) (exit 1))` is one
> conditional branch, and patching one of those in a release binary is a
> beginner exercise. Route something the program needs through `app-encrypt`
> and `app-decrypt`, so removing the check removes the data.

## Layout

`bindings/racket` is the package: a single-collection package for the
collection `keynub`, so `licdongle.rkt` is `keynub/licdongle`. The manual is
`scribblings/licdongle.scrbl` (`raco docs keynub/licdongle` once installed).
The samples are under `samples/racket`
(`racket samples/racket/verify-and-read.rkt`).

## Tests

`raco test -p keynub-licdongle` runs the unit tests, which need neither the
library nor a dongle. `racket bindings/racket/test/standin-test.rkt` runs
without a dongle: it compiles a stand-in for the flat C API
(`bindings/flat/licd_flat.c` over `bindings/julia/test/stub/licd_stub.c`) with
the C compiler on the path and exercises every call against it.
`KEYNUB_SDK_ROOT` names the SDK sources when the package is not inside a clone;
`KEYNUB_LICDONGLE_FLAT_LIBRARY` names a compiled stand-in instead.

## Links

- [KeyNub License Dongle for Racket](https://www.keynub.com/developers/racket/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
