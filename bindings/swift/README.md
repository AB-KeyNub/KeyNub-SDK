# KeyNub License Dongle — Swift package

```swift
import KeyNubLicDongle

let ctx = try Context()
defer { ctx.close() }
let dongle = try ctx.open()                  // first dongle, or ctx.open(serial:)
try dongle.verifyGenuine()                   // throws unless genuine
let data = try dongle.withSession { s in     // closed on every exit path
    try s.appDecrypt(sealed)                 // <- build the licence check on this
}
```

**No dependencies.** The package is Swift over the SDK's C header; the native
library is loaded at run time with the system loader, so nothing is linked and
no build flags are needed. Nothing sits in the path of the check that a
customer could substitute.

## Setup

The package lives at the root of the SDK repository, so a dependency is the
repository itself:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/AB-KeyNub/KeyNub-SDK.git", exact: "1.1.1-swift"),
],
targets: [
    .executableTarget(name: "MyApp", dependencies: [
        .product(name: "KeyNubLicDongle", package: "KeyNub-SDK"),
    ]),
]
```

In Xcode: File > Add Package Dependencies, the repository URL, dependency rule
*Exact Version* `1.1.1-swift`.

A package dependency is a clone of the repository, and the clone carries the
prebuilt library for every platform under `natives/`. The package finds
`natives/<platform>/` there on its own (macOS Intel and Apple silicon, Linux
x64 and ARM64, Windows x64, x86 and ARM64), so a `swift run` from a checkout
needs nothing set. For an application you ship, copy the library from
[`natives/`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
into the bundle or next to the executable and name it before the first call:

```swift
Library.path = Bundle.main.privateFrameworksPath! + "/libkeynub_licdongle.dylib"
```

`KEYNUB_LICDONGLE_LIBRARY` in the environment does the same. A process loads
the library once; `Library.loadedPath` tells which.

## Notes

- Results are plain structs (`Info`, `GenuineResult`, `DeviceInfo`,
  `RecordInfo`); byte data is `[UInt8]`. The C layouts come from the SDK's own
  header, imported as the `CLicDongle` module, so nothing here hand-writes an
  offset.
- Failures throw `LicenseDongleError` with `status` (`Status.noDevice`,
  `.notGenuine`, `.authRequired`, ...), `operation` and `detail`; loading
  problems throw `LibraryError`.
- `dongle.isGenuine` is the non-throwing form for a gate and **fails closed**.
- `dongle.withSession { s in ... }` closes the session afterwards, whatever
  happens; `openSession()` gives a `Session` to close yourself.
- `readRecord` and `writeRecord` take `progress: (done, total) throws -> Bool`;
  returning `false` cancels. An error thrown inside the closure cancels the
  transfer and is rethrown after the C frames have unwound, never through them.
- `eraseAllRecords()` is deliberately separate from `eraseRecord(_:)`: to the C
  library a null name means "erase every record", and an accidentally empty
  string must not do that.
- Contexts, dongles and sessions close themselves when deinitialised, and a
  context closes the dongles still open on it.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `guard dongle.isGenuine else { exit(1) }` compiles to
> one conditional branch, and patching one of those in a release binary is a
> beginner exercise. Route something the program needs through
> `appEncrypt`/`appDecrypt`, so removing the check removes the data.

## Tests

`swift test` runs without a dongle: it compiles a stand-in for the C ABI
(`bindings/julia/test/stub/licd_stub.c`) with the C compiler on the path and
exercises every call against it.

## Links

- [KeyNub License Dongle for Swift](https://www.keynub.com/developers/swift/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
