# KeyNub License Dongle — Elixir package

```elixir
alias KeyNub.LicDongle

{:ok, secret} =
  LicDongle.with_dongle(fn d ->                   # first dongle, or with_dongle("serial", fn ...)
    LicDongle.verify_genuine!(d)                  # raises unless genuine
    LicDongle.with_session!(d, fn ->              # closed on every exit path
      LicDongle.app_decrypt!(d, sealed)           # <- build the licence check on this
    end)
  end)
```

**A small NIF, nothing linked.** The package calls the SDK's flat companion
API through a NIF of two hundred lines (`c_src/`) that loads the native
library at run time and resolves the functions by name, so nothing is linked
at build time and nothing sits in the path of the check that a customer could
substitute. The NIF is compiled when the package is (`elixir_make`: a C
compiler on Linux and macOS, Visual C++ with `nmake` on Windows). Every dongle
call runs on a dirty I/O scheduler. Elixir 1.13 or later, on Windows, Linux
and macOS.

## Setup

```elixir
def deps do
  [{:keynub_licdongle, "~> 1.1"}]
end
```

The package does not carry the native library. Take `keynub_licdongle_flat`
for your platform from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
and either put it where the operating system finds libraries (next to the
executable, or on `PATH`, `LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`), or name it
before the first call:

```elixir
KeyNub.LicDongle.set_library_path("/opt/keynub/libkeynub_licdongle_flat.so")
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. In a clone
of the SDK repository the package finds `natives/<platform>/` on its own, from
the working directory upwards, so the samples run with nothing set. A VM
loads the library once; `loaded_library_path/0` tells which. On Linux,
install the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- Every call returns `{:ok, value}`, `:ok` or `{:error, %KeyNub.LicDongle.Error{}}`;
  the `!` variant returns the value and raises the error. The error carries
  `status` (`:no_device`, `:not_genuine`, `:auth_required`, ...), `code`,
  `operation` and the library's `detail` text. Loading problems raise
  `KeyNub.LicDongle.LibraryError`.
- Results are structs (`Info`, `Genuine`, `Device`, `Record`); byte data is a
  binary. The package calls the SDK's flat API: integer handles and
  caller-provided buffers, no C structures and no hand-written layouts.
- `genuine?/1` is the boolean form for a gate and **fails closed**: every
  failure gives `false`.
- `with_dongle/2` and `with_session/2` close the dongle and the session on
  every exit path, exceptions included, and return `{:ok, fun_result}`.
- `erase_all_records/1` is deliberately separate from `erase_record/2`: an
  accidentally empty name must not wipe the dongle.
- Records are transferred in one call; the flat API has no progress
  reporting.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `unless LicDongle.genuine?(d), do: System.halt(1)`
> is one conditional branch, and patching one of those in a release binary is
> a beginner exercise. Route something the program needs through
> `app_encrypt/3` and `app_decrypt/2`, so removing the check removes the data.

## Tests

`mix test` runs without a dongle: it compiles a stand-in for the flat C API
(`bindings/flat/licd_flat.c` over `bindings/julia/test/stub/licd_stub.c`) with
the C compiler on the path and exercises every call against it.
`KEYNUB_SDK_ROOT` names the SDK sources when the package is not inside a
clone; `KEYNUB_LICDONGLE_FLAT_LIBRARY` names a compiled stand-in instead.

## Links

- [KeyNub License Dongle for Elixir](https://www.keynub.com/developers/elixir/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
