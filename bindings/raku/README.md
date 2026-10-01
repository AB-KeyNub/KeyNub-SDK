# KeyNub License Dongle — Raku Distribution

```raku
use KeyNub::LicDongle;

my $secret = KeyNub::LicDongle::open(-> $d {  # first dongle, or open('serial', -> $d { ... })
    $d.verify-genuine;                         # dies unless genuine
    $d.session({                               # closed on every exit path
        $d.app-decrypt($sealed)                # <- build the licence check on this
    })
});
```

**Nothing compiled.** The distribution calls the SDK's flat companion API
through NativeCall, which loads the native library at run time, so there is no
extension to build and nothing sits in the path of the check that a customer
could substitute. No dependencies beyond Rakudo itself (NativeCall is part of
it); Raku 6.d, on Windows, Linux and macOS.

## Setup

```
zef install KeyNub::LicDongle
```

The distribution does not carry the native library. In a clone of the SDK
repository it finds `keynub_licdongle_flat` for your platform in
`natives/<platform>/` on its own, from the program's folder and the working
directory upwards, so the samples run with nothing set. Elsewhere, take the
library from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
and put it in `natives/<platform>/` beside your program, where the operating
system finds libraries (`PATH`, `LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`), or
name it before the first call:

```raku
KeyNub::LicDongle::library-path('/opt/keynub/libkeynub_licdongle_flat.so');
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. A process
loads the library once; `KeyNub::LicDongle::loaded-library-path()` tells which,
and `library-path` with a different file after that dies. On Linux, install
the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Every failed call dies with `X::KeyNub::LicDongle`, which carries `status`
  (`KeyNub::LicDongle::Status::NoDevice`, `Status::NotGenuine`,
  `Status::AuthRequired`, ...), the raw `code`, the `operation` and the
  library's `detail` text. Loading problems die with
  `X::KeyNub::LicDongle::Library`.

  ```raku
  CATCH {
      when X::KeyNub::LicDongle {
          say 'no dongle' if .status === KeyNub::LicDongle::Status::NoDevice;
      }
  }
  ```

- Results are objects (`Info`, `Genuine`, `Device`, `Record`) with kebab-case
  accessors (`.data-free`, `.write-auth-rotated`); `library-version` is a
  `Version`; byte data is a `Blob` in and a `Buf` out. The distribution calls
  the SDK's flat API: integer handles and caller-provided buffers, no C
  structures and no hand-written layouts.
- The block forms `KeyNub::LicDongle::open`, `Dongle.open`, `Dongle.open-path`
  and `$d.session` close the dongle and the session on every exit path,
  exceptions included, and return what the block returns. A `Dongle` opened
  without a block is closed by `close`, or when it is collected.
- `genuine` is the boolean form for a gate and **fails closed**: every failure
  gives `False`.
- `$d.trust-root = $der` overrides the CA root that `verify-genuine` checks
  against; applications do not need it.
- `erase-all-records` is separate from `erase-record($name)`: an accidentally
  empty name must not wipe the dongle.
- Records are transferred in one call; the flat API has no progress
  reporting.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `exit 1 unless $d.genuine` is one conditional
> branch, and editing one of those in a script is no effort at all. Route
> something the program needs through `app-encrypt` and `app-decrypt`, so
> removing the check removes the data.

## Tests

`zef test bindings/raku` runs the tests of the distribution, which need
neither the native library nor a dongle.
`raku -I bindings/raku/lib bindings/raku/test/standin_test.raku` runs without
a dongle: it compiles a stand-in for the flat C API
(`bindings/flat/licd_flat.c` over `bindings/julia/test/stub/licd_stub.c`) with
the C compiler on the path and exercises every call against it.
`KEYNUB_SDK_ROOT` names the SDK sources when the distribution is not inside a
clone; `KEYNUB_LICDONGLE_FLAT_LIBRARY` names a compiled stand-in instead. The
samples are under `samples/raku`
(`raku samples/raku/verify-and-read.raku`).

## Links

- [KeyNub License Dongle for Raku](https://www.keynub.com/developers/raku/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
