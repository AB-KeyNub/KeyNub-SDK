# KeyNub License Dongle — Odin Package

```odin
import kn "keynub:keynub_licdongle"

unseal :: proc(sealed: []u8) -> (data: []u8, err: kn.Error) {
	d := kn.open() or_return // first dongle, or kn.open("<serial>")
	defer kn.close(&d)
	_ = kn.verify_genuine(d, context.temp_allocator) or_return // an error unless genuine
	kn.open_session(d) or_return
	defer kn.close_session(d)
	return kn.app_decrypt(d, sealed) // <- build the licence check on this
}
```

**Nothing linked.** The package calls the KeyNub SDK's flat companion API
through `core:dynlib`, from the native library loaded at run time on the
first call; there is no `foreign import` and nothing to link. Importing the
package needs no library. No dependencies beyond Odin's core library; Odin
dev-2026-03 or later, on Windows, Linux and macOS.

## Setup

Clone the [SDK repository](https://github.com/AB-KeyNub/KeyNub-SDK) and name
its `bindings/odin` folder as a collection when you build:

```
odin build . -collection:keynub=/path/to/KeyNub-SDK/bindings/odin
```

after which `import kn "keynub:keynub_licdongle"` works. To keep the package
in your own project instead, copy the `bindings/odin/keynub_licdongle` folder
next to your source files and import it by relative path:

```odin
import kn "keynub_licdongle"
```

A copy in the `shared` folder of your Odin installation imports as
`"shared:keynub_licdongle"`.

The native library for each platform is in the clone's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md),
and the package finds it there on its own: it looks in `natives/<platform>/`
from the program's folder, the current directory and its own source folder
upwards, then asks the system loader. Ship the library for your platform next
to your program, or name it before the first call:

```odin
kn.set_library_path("/opt/keynub/libkeynub_licdongle_flat.so") or_return
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. A process
loads the library once; `kn.loaded_library_path()` tells which, and
`set_library_path` with a different file after that returns
`.Already_Loaded`. On Linux, install the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Every call that can fail returns a `kn.Error` as its last value, so
  `or_return` works on it. The error is nil on success, a `kn.Status` for a
  failed dongle call (`.No_Device`, `.Not_Genuine`, `.Auth_Required`, ...)
  and a `kn.Library_Error` for a loading problem (`.Load_Failed`,
  `.Already_Loaded`). `kn.error_message(err)` returns the library's text for
  a status and what was tried for a loading problem; `kn.last_error(d)`
  returns the library's diagnostic detail for the most recent failure on a
  dongle.

  ```odin
  d, err := kn.open()
  if err == kn.Status.No_Device {
  	fmt.println("no dongle")
  }
  ```

- Results are structs (`Device_Info`, `Verification`, `Device`, `Record`,
  `Version`); byte data is `[]u8`. Every procedure that allocates takes an
  `allocator` parameter, `context.allocator` by default; free byte data and
  strings with `delete`, and lists and verifications with `delete_devices`,
  `delete_records` and `delete_verification`. The package calls the SDK's
  flat API: integer handles and caller-provided buffers, no C structures and
  no hand-written layouts.
- `close` and `close_session` return nothing, so they sit behind `defer` as
  they are. `close` takes `&d` and is safe to call twice; after it, calls on
  the dongle fail with `.Invalid_Arg`.
- `is_genuine` is the boolean form for a gate and **fails closed**: every
  failure gives `false`.
- `app_encrypt` takes the scope as `.Device` (this dongle only) or
  `.Developer` (any dongle issued by the same developer).
- `set_trust_root` overrides the CA root that `verify_genuine` checks
  against; applications do not need it.
- `erase_all_records` is the only call that erases more than one record;
  `erase_record` erases the one record it names.
- Records are transferred in one call; the flat API has no progress
  reporting.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `if !kn.is_genuine(d) { os.exit(1) }` is one
> conditional branch, and patching one of those in a release binary is a
> beginner exercise. Route something the program needs through `app_encrypt`
> and `app_decrypt`, so removing the check removes the data.

## Tests

From the repository root, `odin test bindings/odin/test/unit` runs the unit
tests, which need neither the library nor a dongle.
`odin run bindings/odin/test/standin` runs without a dongle: it compiles a
stand-in for the flat C API (`bindings/flat/licd_flat.c` over
`bindings/julia/test/stub/licd_stub.c`) with the C compiler on the path and
exercises every call against it. `KEYNUB_SDK_ROOT` names the SDK sources when
the test does not run inside a clone; `KEYNUB_LICDONGLE_FLAT_LIBRARY` names a
compiled stand-in instead. The samples are under `samples/odin`
(`odin run samples/odin/verify_and_read.odin -file -collection:keynub=bindings/odin`).

## Links

- [KeyNub License Dongle for Odin](https://www.keynub.com/developers/odin/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
