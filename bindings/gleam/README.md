# KeyNub License Dongle — Gleam Package

```gleam
import gleam/option.{None}
import gleam/result
import keynub/licdongle

pub fn unlock(sealed: BitArray) -> Result(BitArray, licdongle.DongleError) {
  use d <- licdongle.with_dongle(None)            // first dongle, or Some("serial")
  use _ <- result.try(licdongle.verify_genuine(d)) // Error unless genuine
  use <- licdongle.with_session(d)                // closed on every exit path
  licdongle.app_decrypt(d, sealed)                // <- build the licence check on this
}
```

**Nothing linked.** Typed Gleam over the
[`keynub_licdongle`](https://hex.pm/packages/keynub_licdongle) Hex package, whose
small NIF loads the SDK's native library at run time, so nothing sits in the
path of the check that a customer could substitute. Erlang target; needs Elixir
installed to build that dependency, and a C compiler for its NIF.

## Setup

```
gleam add keynub_licdongle_gleam
```

The package finds `keynub_licdongle_flat` for your platform in `natives/<platform>/`
of the [KeyNub SDK](https://github.com/AB-KeyNub/KeyNub-SDK) from the working
directory upwards. To ship an application, put the library from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
where it runs, or name it before the first call:

```gleam
let assert Ok(Nil) = licdongle.set_library_path("/opt/keynub/libkeynub_licdongle_flat.so")
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. A process
loads the library once; `loaded_library_path()` tells which. On Linux, install
the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Every call returns a `Result`. `CallError` carries the `status` (`NoDevice`,
  `NotGenuine`, `AuthRequired`, ...), the raw `code`, the `operation` and the
  library's `detail` text; `LibraryError` reports a library that cannot be
  loaded.
- Results are records (`Info`, `Genuine`, `Device`, `DongleRecord`); byte data
  is `BitArray`.
- `with_dongle` and `with_session` close the dongle and the session on every
  exit path, crashes included, and return what the body returns. They suit
  `use`.
- `is_genuine` is the boolean form for a gate and **fails closed**: every
  failure gives `False`.
- `erase_all_records` is separate from `erase_record(name)`: an accidentally
  empty name must not wipe the dongle.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. A `case licdongle.is_genuine(d)` is one
> conditional branch, and patching one of those in a release is a beginner
> exercise. Route something the program needs through `app_encrypt` and
> `app_decrypt`, so removing the check removes the data.

## Tests

`gleam test` runs the unit tests. `gleam run -m standin` runs without a dongle:
it compiles a stand-in for the flat C API (`bindings/flat/licd_flat.c` over
`bindings/julia/test/stub/licd_stub.c`) with the C compiler on the path and
exercises every call against it. `KEYNUB_SDK_ROOT` names the SDK sources when
the package is not inside a clone; `KEYNUB_LICDONGLE_FLAT_LIBRARY` names a
compiled stand-in instead. The samples are a Gleam project under
`samples/gleam` (`gleam run -m verify_and_read`).

## Links

- [KeyNub License Dongle for Gleam](https://www.keynub.com/developers/gleam/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
