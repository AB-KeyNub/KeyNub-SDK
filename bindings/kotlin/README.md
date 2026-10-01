# KeyNub License Dongle — Kotlin Multiplatform Library

```kotlin
// Gradle: implementation("com.keynub:keynub-licdongle-kotlin:1.1.1")
import com.keynub.licdongle.kotlin.*

val secret = LicDongle.withDongle { dongle ->   // the first dongle, or withDongle(serial) { ... }
    dongle.verifyGenuine()                      // throws unless genuine
    dongle.withSession { session ->             // closed on every exit path
        session.appDecrypt(sealedBytes)         // <- build the licence check on this
    }
}
```

A Kotlin Multiplatform library over the SDK's flat C API, for the JVM (Java 17
or later, through JNA) and for Kotlin/Native on Windows x64, Linux x64 and
Linux arm64, with no driver. The library is loaded at run time on the first
call; nothing is linked at build time, and loading the library classes needs no
native library.

## Setup

The package does not contain the native library. Put
`keynub_licdongle_flat` for your platform from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
next to your program, or name it before the first call:

```kotlin
LicDongle.setLibraryPath("/opt/keynub/libkeynub_licdongle_flat.so")
```

`KEYNUB_LICDONGLE_FLAT_LIBRARY` in the environment does the same. The library
looks in `natives/<platform>/` from the program's folder and the current
directory upwards (so a program run inside an SDK clone finds the clone's
`natives/`), then asks the system loader. A process loads the library once;
`LicDongle.loadedLibraryPath` tells which. On Linux, install the udev rule
described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- `Dongle` and `Session` are `AutoCloseable`; `withDongle` and `withSession`
  close them on every exit path, exceptions included, and return what the block
  returns. A dongle has one session at a time: opening another ends the one
  before it, and the earlier `Session` then fails with `Status.SessionExpired`.
- Results are data classes (`Device`, `DeviceInfo`, `Verification`, `Record`);
  record data, keys and sealed data are `ByteArray`. The methods that take data
  also take a `String`, used as its UTF-8 bytes, and `readString` reads a
  record back as text.
- Every failed call throws `LicDongleException` with `status`
  (`Status.NoDevice`, `Status.NotGenuine`, `Status.NotFound`,
  `Status.AuthRequired`, ...), the raw `code`, the `operation` and the library's
  `detail` text. Loading problems throw `LibraryException`.
- `isGenuine()` is the boolean form for a gate and **fails closed**: every
  failure gives `false`.
- Writing, erasing and incrementing need the write role:
  `session.authorizeWrite(keyBytes)` with the dongle's write key, a P-256
  private key in PKCS#8 DER. That belongs in your licence-issuing tooling,
  never in what your users run. A new dongle accepts the public factory key
  until `rotateWriteKey` replaces it with yours; do that once per dongle, when
  it arrives.
- `eraseAll()` is separate from `erase(name)`, and an empty name is refused:
  an accidentally empty name never wipes the dongle.
- Records are transferred in one call; the flat API has no progress reporting.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `if (!dongle.isGenuine()) exitProcess(1)` is one
> branch, and patching one of those out of a program is no effort at all.
> Route something the program needs through `appEncrypt` and `appDecrypt`, so
> removing the check removes the data.

## Tests

`gradle jvmTest mingwX64Test` (or `linuxX64Test` on Linux) runs the unit tests,
which need neither the library nor a dongle, and a stand-in test without a
dongle: the build compiles a stand-in for the flat C API
(`bindings/flat/licd_flat.c` over `bindings/julia/test/stub/licd_stub.c`) with
the C compiler on the path (cc, gcc, clang, `zig cc` or cl) and runs every call
against it. `KEYNUB_SDK_ROOT` names the SDK sources when the project is not
inside a clone; `KEYNUB_LICDONGLE_FLAT_LIBRARY` names a compiled stand-in
instead. The samples are under `samples/kotlin`.

## Links

- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
- [KeyNub License Dongle for Kotlin](https://www.keynub.com/developers/kotlin/): the product, and how to
  order one
