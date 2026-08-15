# KeyNub License Dongle — Julia binding

```julia
using KeyNubLicDongle

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
dependencies outside `Base` — which is the right shape for licensing: nothing in
the path of the check that a customer could substitute.

Julia is also the closest commercial neighbour to the MATLAB binding: the same
engineering and scientific buyers, often the same organisation. If you sell a
Julia package, the thing worth protecting is usually the data rather than the code
— a correlation set, fitted parameters, a proprietary model's coefficients — and
that is exactly what `app_encrypt`/`app_decrypt` is for.

## Setup

Point the binding at a specific library before `using`, if it is not on the
system search path:

```julia
ENV["KEYNUB_LICDONGLE_LIBRARY"] = "/path/to/libkeynub_licdongle.so"
```

The path is resolved once, when the module is first loaded.

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

> Read [`../../docs/integration-security.md`](../../docs/integration-security.md)
> first. `if is_genuine(dongle)` is one line to delete, and Julia ships as source
> — a sysimage only raises the effort.

