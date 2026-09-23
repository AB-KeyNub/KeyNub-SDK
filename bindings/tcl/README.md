# KeyNub License Dongle — Tcl Package

```tcl
package require keynub_licdongle

set secret [keynub::licdongle with_dongle d {       ;# first dongle, or with_dongle d <serial> {...}
    keynub::licdongle verify_genuine $d            ;# raises unless genuine
    keynub::licdongle with_session $d {            ;# closed on every exit path
        keynub::licdongle app_decrypt $d $sealed   ;# <- build the licence check on this
    }
}]
```

**Nothing compiled.** The package calls the SDK's flat companion API through
[cffi](https://github.com/apnadkarni/tcl-cffi), which loads the native library
at run time, so there is no extension to build and nothing sits in the path of
the check that a customer could substitute. Tcl 8.6 or later with cffi 2.0 or
later, on Windows, Linux and macOS. The Magicsplat Tcl distribution for Windows
and BAWT ship cffi; elsewhere it builds from its sources.

## Setup

From a clone of the SDK repository:

```tcl
lappend auto_path <clone>/bindings/tcl
package require keynub_licdongle
```

Or copy `bindings/tcl` into a directory on `auto_path`. The package does not
carry the native library. In a clone it finds `keynub_licdongle_flat` for your
platform in `natives/<platform>/` on its own, from the executable's folder, the
working directory and its own folder upwards, so the samples run with nothing
set. Elsewhere, take the library from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
and either put it where the operating system finds libraries (`PATH`,
`LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`) or name it before the first call:

```tcl
keynub::licdongle library_path /opt/keynub/libkeynub_licdongle_flat.so
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. A process
loads the library once; `keynub::licdongle loaded_library_path` tells which. On
Linux, install the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- `keynub::licdongle` is an ensemble: `keynub::licdongle open`,
  `keynub::licdongle records $d` and so on; the procedures behind it live in
  the `::keynub::licdongle` namespace. Dongles are integer handles.
- Every failed call raises an error with the `-errorcode`
  `{KEYNUB <STATUS> <code> <operation>}`, for example
  `{KEYNUB NO_DEVICE -2 licdf_open}`, and a message that carries the library's
  detail text; `try ... trap {KEYNUB NOT_GENUINE}` catches one status.
  Loading problems raise `{KEYNUB LIBRARY}`.
- Results are dicts (`info`, `verify_genuine`, `library_version`) and lists of
  dicts (`devices`, `records`); record data and keys are byte strings. The
  package calls the SDK's flat API: integer handles and caller-provided
  buffers, no C structures and no hand-written layouts.
- `with_dongle` and `with_session` close the dongle and the session on every
  exit path, errors included, and return what the script returns.
- `is_genuine` is the boolean form for a gate and **fails closed**: every
  failure gives 0.
- `erase_all_records` is separate from `erase_record`: an accidentally empty
  name must not wipe the dongle.
- Records are transferred in one call; the flat API has no progress
  reporting.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `if {![keynub::licdongle is_genuine $d]} exit` is
> one conditional branch, and editing one of those in a script is no effort
> at all. Route something the program needs through `app_encrypt` and
> `app_decrypt`, so removing the check removes the data.

## Tests

`tclsh bindings/tcl/tests/standin_test.tcl` runs without a dongle: it compiles
a stand-in for the flat C API (`bindings/flat/licd_flat.c` over
`bindings/julia/test/stub/licd_stub.c`) with the C compiler on the path and
exercises every call against it. `KEYNUB_SDK_ROOT` names the SDK sources when
the package is not inside a clone; `KEYNUB_LICDONGLE_FLAT_LIBRARY` names a
compiled stand-in instead. The samples are under `samples/tcl`
(`tclsh samples/tcl/verify_and_read.tcl`).

## Links

- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
- [KeyNub License Dongle for Tcl](https://www.keynub.com/developers/tcl/): the product, and how to
  order one
