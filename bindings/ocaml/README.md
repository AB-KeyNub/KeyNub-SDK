# KeyNub License Dongle — OCaml package

```ocaml
open Keynub_licdongle

let secret =
  with_dongle (fun d ->                        (* first dongle, or ~serial:"..." *)
    ignore (verify_genuine d);                 (* raises unless genuine *)
    with_session d (fun () ->                  (* closed on every exit path *)
      app_decrypt d sealed))                   (* <- build the licence check on this *)
```

**Pure OCaml.** The package calls the SDK's flat companion API through
`ctypes-foreign`, resolving the functions from the library loaded at run
time, so nothing is linked at build time, there are no C stubs to compile and
nothing sits in the path of the check that a customer could substitute.
`ctypes` and `ctypes-foreign` are the dependencies. OCaml 4.08 or later, on
Windows, Linux and macOS.

## Setup

```
opam install keynub-licdongle
```

and `keynub-licdongle` in the `libraries` field of your `dune` file. The
package does not carry the native library. Take `keynub_licdongle_flat` for
your platform from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
and either put it where the operating system finds libraries (next to the
executable, or on `PATH`, `LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`), or name it
before the first call:

```ocaml
Keynub_licdongle.set_library_path "/opt/keynub/libkeynub_licdongle_flat.so"
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. In a clone
of the SDK repository the package finds `natives/<platform>/` on its own, from
the working directory upwards, so the samples run with nothing set. A process
loads the library once; `loaded_library_path` tells which. On Linux, install
the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Results are records (`info`, `genuine`, `device`, `record_info`); byte
  data is `string`. The package calls the SDK's flat API: integer handles and
  caller-provided buffers, no C structures and no hand-written layouts.
- Failures raise `Error` with `status` (`No_device`, `Not_genuine`,
  `Auth_required`, ...), `code`, `operation` and `detail`; loading problems
  raise `Library_error`. Both print through `Printexc.to_string`.
- `is_genuine` is the non-raising form for a gate and **fails closed**: every
  failure gives `false`.
- `with_dongle` and `with_session` close the dongle and the session on every
  exit path, exceptions included.
- `erase_all_records` is deliberately separate from `erase_record`: an
  accidentally empty name must not wipe the dongle.
- Records are transferred in one call; the flat API has no progress
  reporting.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `if not (is_genuine d) then exit 1` is one
> conditional branch, and patching one of those in a release binary is a
> beginner exercise. Route something the program needs through `app_encrypt`
> and `app_decrypt`, so removing the check removes the data.

## Tests

`dune test` runs without a dongle: it compiles a stand-in for the flat C API
(`bindings/flat/licd_flat.c` over `bindings/julia/test/stub/licd_stub.c`) with
the C compiler on the path and exercises every call against it.
`KEYNUB_SDK_ROOT` names the SDK sources when the package is not inside a
clone; `KEYNUB_LICDONGLE_FLAT_LIBRARY` names a compiled stand-in instead.

## Links

- [KeyNub License Dongle for OCaml](https://www.keynub.com/developers/ocaml/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
