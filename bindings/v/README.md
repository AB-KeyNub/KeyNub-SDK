# KeyNub License Dongle — V Module

```v
import ab_keynub.licdongle // v install AB-KeyNub.licdongle

fn unseal(sealed []u8) ![]u8 {
	mut d := licdongle.open('')! // first dongle, or open('<serial>')
	defer {
		d.close()
	}
	d.verify_genuine()! // an error unless genuine
	d.open_session()!
	defer {
		d.close_session()
	}
	return d.app_decrypt(sealed)! // <- build the licence check on this
}
```

**Nothing linked.** The module calls the KeyNub SDK's flat companion API
through V's `dl` module, from the native library loaded at run time on the
first call; there is no `#flag` and nothing to link. Importing the module needs
no library. No dependencies beyond V's standard library; V 0.5.2 or later, on
Windows, Linux and macOS.

## Setup

```
v install AB-KeyNub.licdongle
```

installs the module from [vpm](https://vpm.vlang.io/packages/AB-KeyNub.licdongle),
imported as `import ab_keynub.licdongle`: V clones the whole
[SDK repository](https://github.com/AB-KeyNub/KeyNub-SDK) into your V modules
folder, and the repository's root `v.mod` points V at
`bindings/v/keynub_licdongle`. The clone brings the native libraries along.
`v install --git https://github.com/AB-KeyNub/KeyNub-SDK` installs the same
module straight from GitHub, imported as `import keynub_licdongle as licdongle`.

To work from a clone of your own instead, name `bindings/v` as a module folder
when you build (the samples do this, and import `keynub_licdongle`):

```
v -path "@vlib|@vmodules|/path/to/KeyNub-SDK/bindings/v" run .
```

or link the module into your V modules folder once, after which
`import keynub_licdongle` works without `-path`:

```
ln -s /path/to/KeyNub-SDK/bindings/v/keynub_licdongle ~/.vmodules/keynub_licdongle
mklink /J %USERPROFILE%\.vmodules\keynub_licdongle C:\path\to\KeyNub-SDK\bindings\v\keynub_licdongle
```

(the first on Linux and macOS, the second on Windows).

The native library for each platform is in the clone's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md),
and the module finds it there on its own: it looks in `natives/<platform>/`
from the program's folder, the current directory and its own source folder
upwards, then asks the system loader. Ship the library for your platform next
to your program, or name it before the first call:

```v
licdongle.set_library_path('/opt/keynub/libkeynub_licdongle_flat.so')!
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. A process
loads the library once; `licdongle.loaded_library_path()` tells which, and
`set_library_path` with a different file after that returns a `LibraryError`.
On Linux, install the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Every call that can fail returns a result (`!`). A failed dongle call
  returns a `DongleError` with `status` (`.no_device`, `.not_genuine`,
  `.auth_required`, ...), the raw code from `code()`, the `operation` and the
  library's `detail` text. Loading problems return a `LibraryError`. Both
  implement `IError`.

  ```v
  d := licdongle.open('') or {
  	if err is licdongle.DongleError && err.status == .no_device {
  		println('no dongle')
  	}
  	return
  }
  ```

- Results are structs (`DeviceInfo`, `Verification`, `Device`, `Record`,
  `Version`); byte data is `[]u8`. The module calls the SDK's flat API: integer
  handles and caller-provided buffers, no C structures and no hand-written
  layouts.
- `close` and `close_session` return nothing, so they sit in a `defer` block
  as they are. `close` is safe to call twice; after it, calls on the dongle
  fail with `.invalid_arg`.
- `is_genuine` is the boolean form for a gate and **fails closed**: every
  failure gives `false`.
- `app_encrypt` takes the scope as `.device` (this dongle only) or
  `.developer` (any dongle issued by the same developer).
- `set_trust_root` overrides the CA root that `verify_genuine` checks
  against; applications do not need it.
- `erase_all_records` is the only call that erases more than one record;
  `erase_record` erases the one record it names.
- Records are transferred in one call; the flat API has no progress
  reporting.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `if !d.is_genuine() { exit(1) }` is one
> conditional branch, and patching one of those in a release binary is a
> beginner exercise. Route something the program needs through `app_encrypt`
> and `app_decrypt`, so removing the check removes the data.

## Tests

From the repository root, `v test bindings/v` runs the unit tests, which need
neither the library nor a dongle.
`v -path "@vlib|@vmodules|bindings/v" run bindings/v/test/standin.v` runs
without a dongle: it compiles a stand-in for the flat C API
(`bindings/flat/licd_flat.c` over `bindings/julia/test/stub/licd_stub.c`) with
the C compiler on the path and exercises every call against it.
`KEYNUB_SDK_ROOT` names the SDK sources when the test does not run inside a
clone; `KEYNUB_LICDONGLE_FLAT_LIBRARY` names a compiled stand-in instead. The
samples are under `samples/v`
(`v -path "@vlib|@vmodules|bindings/v" run samples/v/verify_and_read.v`).

## Links

- [KeyNub License Dongle for V](https://www.keynub.com/developers/v/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
