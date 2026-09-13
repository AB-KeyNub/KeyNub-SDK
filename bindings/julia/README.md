# KeyNub License Dongle — Julia binding

[![Julia](https://github.com/AB-KeyNub/KeyNub-SDK/actions/workflows/julia.yml/badge.svg)](https://github.com/AB-KeyNub/KeyNub-SDK/actions/workflows/julia.yml)
[![Coverage](https://codecov.io/gh/AB-KeyNub/KeyNub-SDK/graph/badge.svg?flag=julia)](https://codecov.io/gh/AB-KeyNub/KeyNub-SDK)

```julia
using KeyNubLicenseDongle

ctx = Context()
try
    dongle = open_dongle(ctx)          # first dongle, or open_dongle(ctx, serial)
    verify_genuine(dongle)             # throws unless genuine
    session(dongle) do s
        data = app_decrypt(s, blob)    # <- build your licence check on this
    end
finally
    close(ctx)
end
```

**No packages.** `ccall` is part of the language, so the binding has no
dependencies outside the standard library — which is the right shape for
licensing: nothing in the path of the check that a customer could substitute.

Julia is also the closest commercial neighbour to the MATLAB binding: the same
engineering and scientific buyers, often the same organisation. If you sell a
Julia package, the thing worth protecting is usually the data rather than the code
— a correlation set, fitted parameters, a proprietary model's coefficients — and
that is exactly what `app_encrypt`/`app_decrypt` is for.

## Setup

```julia
using Pkg
Pkg.add("KeyNubLicenseDongle")
```

The package brings the native library with it: an artifact holding the SDK
release, from which the binding picks the library for the running platform
(Windows x64, x86 and ARM64; Linux x64 and ARM64; macOS Intel and Apple silicon).
In a clone of this repository it uses the checkout's `natives/` instead. On
Linux, install the udev rule described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

To use a specific library instead, name it before the first call:

```julia
ENV["KEYNUB_LICDONGLE_LIBRARY"] = "/path/to/libkeynub_licdongle.so"
using KeyNubLicenseDongle
```

`KeyNubLicenseDongle.LIB` holds the library in use. Julia binds each call to
the library on its first use, so the choice is made once per process.

## Tests

`Pkg.test("KeyNubLicenseDongle")` runs without a dongle: it loads the shipped
library and checks the version, enumeration, the status-code mapping and closed
handles, then compiles a stand-in for the C ABI from `test/stub/licd_stub.c`
(with `gcc`, `cc` or `clang` from the path) and exercises every call against it.

## Notes

- Results are plain structs (`Info`, `GenuineResult`, `RecordInfo`), and the C
  layouts are declared as Julia `struct`s so the padding is computed the same way
  C computes it — no hand-written offsets.
- Failures throw `LicenseDongleError` or a subtype (`NotGenuineError`,
  `CertificateInvalidError`, `WriteAuthorizationRequiredError`,
  `SessionExpiredError`, `DeviceNotFoundError`, `RecordNotFoundError`,
  `OperationCancelledError`), each carrying `status`, `operation` and `detail`.
- `is_genuine(dongle)` is the non-throwing form for a gate and **fails closed**.
- `session(dongle) do s ... end` closes the session afterwards, whatever happens.
- `read_record` and `write_record` take `progress = (done, total) -> Bool`;
  returning `false` cancels. An exception inside the callback cancels the transfer
  rather than unwinding through the C frames, which would strand the device.

> Read [`../../docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> first. `if is_genuine(dongle)` is one line to delete, and Julia ships as source
> — a sysimage only raises the effort.

## Links

- [KeyNub License Dongle for Julia](https://www.keynub.com/developers/julia/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
