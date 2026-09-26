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

The library name is a compile-time define (`-d:keynubLib=...`), so a build can be
pointed at a specific library without the source knowing about it.

## Tests

`nim c -r tests/test_standin.nim` runs without a dongle: its configuration
(`tests/test_standin.nims`) compiles a stand-in for the C ABI
(`bindings/julia/test/stub/licd_stub.c`) into the temp directory with the C
compiler on the path (cc, gcc, clang, `zig cc` or cl) and points `keynubLib` at
it, and the test exercises every call of the binding against it.
`KEYNUB_SDK_ROOT` names the SDK sources when the package is not inside a clone.

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

> Read [`../../docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `if not dongle.isGenuine(): quit()` compiles to a
> conditional jump, and patching one of those in a release binary is a beginner
> exercise. Route something the program needs through `appEncrypt`/`appDecrypt`,
> so removing the check removes the data.

## Links

- [KeyNub License Dongle for Nim](https://www.keynub.com/developers/nim/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
