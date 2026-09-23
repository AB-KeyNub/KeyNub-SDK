# KeyNub License Dongle — Crystal Shard

```crystal
require "keynub_licdongle"

secret = KeyNub::LicDongle.open do |d|  # first dongle, or open("serial")
  d.verify_genuine                      # raises unless genuine
  d.session do                          # closed on every exit path
    d.app_decrypt(sealed)               # <- build the licence check on this
  end
end
```

**Nothing linked.** The shard calls the SDK's flat companion API through
function pointers resolved by name from the native library, which is loaded at
run time (`dlopen`, `LoadLibrary`), so nothing is linked at build time and
nothing sits in the path of the check that a customer could substitute. No
dependencies; Crystal 1.10 or later, on Windows, Linux and macOS.

## Setup

```yaml
dependencies:
  keynub_licdongle:
    github: AB-KeyNub/KeyNub-SDK
    version: 1.1.1-crystal
```

The `-crystal` prerelease tag carries this first release; from the next SDK
release the plain version tag carries the shard and `version: ~> 1.1` works.

`shards install` checks out the whole repository, `natives/` included, and the
shard finds `keynub_licdongle_flat` for your platform there, so `crystal run`
works with nothing set. To ship an application, put the library from the
SDK's [natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
next to the executable, where the shard looks first, or name it before the
first call:

```crystal
KeyNub::LicDongle.library_path = "/opt/keynub/libkeynub_licdongle_flat.so"
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. The shard
looks in `natives/<platform>/` from the executable's folder and the working
directory upwards, then in the checkout it was installed from, then asks the
system loader. A process loads the library once;
`KeyNub::LicDongle.loaded_library_path` tells which. On Linux, install the udev
rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Every failed call raises `KeyNub::LicDongle::Error` with `status`
  (`Status::NoDevice`, `Status::NotGenuine`, `Status::AuthRequired`, ...), the
  raw `code`, the `operation` and the library's `detail` text. Loading
  problems raise `KeyNub::LicDongle::LibraryError`.
- Results are records (`Info`, `Genuine`, `Device`, `Record`); byte data is
  `Bytes`. The shard calls the SDK's flat API: integer handles and
  caller-provided buffers, no C structures and no hand-written layouts.
- The block forms of `open` and `session` close the dongle and the session on
  every exit path, exceptions included, and return what the block returns. A
  `Dongle` opened without a block is closed by `close`, or when it is
  collected.
- `genuine?` is the boolean form for a gate and **fails closed**: every
  failure gives `false`.
- `erase_all_records` is separate from `erase_record(name)`: an accidentally
  empty name must not wipe the dongle.
- Records are transferred in one call; the flat API has no progress
  reporting.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `exit 1 unless d.genuine?` is one conditional
> branch, and patching one of those in a release binary is a beginner
> exercise. Route something the program needs through `app_encrypt` and
> `app_decrypt`, so removing the check removes the data.

## Layout

`shard.yml` sits at the repository root, which is where shards looks for it,
with `keynub_licdongle.cr` beside it so that `require "keynub_licdongle"`
finds the sources under `bindings/crystal/src`. The samples are under
`samples/crystal` (`crystal run samples/crystal/verify_and_read.cr`).

## Tests

`crystal spec bindings/crystal/spec` runs the unit spec.
`crystal run bindings/crystal/test/standin_test.cr` runs without a dongle: it
compiles a stand-in for the flat C API (`bindings/flat/licd_flat.c` over
`bindings/julia/test/stub/licd_stub.c`) with the C compiler on the path and
exercises every call against it. `KEYNUB_SDK_ROOT` names the SDK sources when
the shard is not inside a clone; `KEYNUB_LICDONGLE_FLAT_LIBRARY` names a
compiled stand-in instead.

## Links

- [KeyNub License Dongle for Crystal](https://www.keynub.com/developers/crystal/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
