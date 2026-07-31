# KeyNub License Dongle — Nim binding

```nim
import keynub_licdongle

let ctx = newContext()
defer: ctx.close()
let dongle = ctx.open()                     # first dongle, or ctx.open("serial")
discard dongle.verifyGenuine()              # raises unless genuine

let session = dongle.openSession()
defer: session.close()
let data = session.appDecrypt(blob)         # <- build the licence check on this
```

No dependencies: `importc` is part of the language, and the library is resolved at
run time through `dynlib`, so nothing needs to be linked. Verified with **Nim
2.2.10**.

The library name is a compile-time define, so a test build can point at the device
simulator without the shipping code knowing about it:

```
nim c -d:keynubLib=keynub_licdongle_sim --path:. -r the binding's end-to-end test
```

## Notes

- `Status` is an enum over the C status codes; failures raise
  `LicenseDongleError` or a subtype (`NotGenuineError`, `CertificateInvalidError`,
  `WriteAuthorizationRequiredError`, `SessionExpiredError`, `DeviceNotFoundError`,
  `RecordNotFoundError`, `OperationCancelledError`) carrying `status`, `operation`
  and `detail`.
- `dongle.isGenuine()` is the non-raising form for a gate and **fails closed**.
- Structs are `{.bycopy.}` objects whose field types mirror the header, so Nim
  computes the padding rather than anyone hand-writing offsets.
- Progress callbacks travel through a `{.threadvar.}` slot rather than the C
  `user` pointer: a Nim closure is not a plain C function pointer, and a GC'd
  value must not be handed across the boundary. An exception raised inside the
  callback cancels the transfer and is re-raised afterwards — raising through the
  C frames would skip the SDK's own cleanup and strand the device.
- `ctx.adopt(handle)` takes ownership of a device opened through the C ABI
  directly, and `ctx.rawHandle()` goes the other way, so this can be introduced
  into existing `importc` code a call at a time.

> Read [`../../docs/integration-security.md`](../../docs/integration-security.md)
> before writing the check. `if not dongle.isGenuine(): quit()` compiles to a
> conditional jump, and patching one of those in a release binary is a beginner
> exercise. Route something the program needs through `appEncrypt`/`appDecrypt`,
> so removing the check removes the data.

## Testing

8 tests against an in-process software dongle — **no hardware** — covering the full
protocol stack plus what is specific here: the struct layout across the FFI
boundary (a mistake shows up as a garbage value, not a wrong boolean), the
progress bridge with cancellation, and a session outliving its dongle. `unittest`
is a stdlib module, so the tests need no packages either.

A note on obtaining the compiler: Windows Defender has flagged Nim's release
archive as `Trojan:Win32/Vigorf.A`, a long-standing false positive on its
binaries. Verify the download against nim-lang.org's own checksum before
extracting; do not disable the scanner to get past it.
