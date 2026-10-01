# KeyNub License Dongle — Scala Library

```scala
// sbt:   libraryDependencies += "com.keynub" %% "keynub-licdongle-scala" % "1.1.1"
// Mill:  mvn"com.keynub::keynub-licdongle-scala:1.1.1"
import keynub.licdongle.*

val secret = LicDongle.withDongle { dongle =>  // the first dongle, or withDongle(serial) { ... }
  dongle.verifyGenuine()                        // throws unless genuine
  dongle.withSession { session =>               // closed on every exit path
    session.appDecrypt(sealedBytes)             // <- build the licence check on this
  }
}
```

A Scala 3 library over the Java binding
[`com.keynub:keynub-licdongle`](https://central.sonatype.com/artifact/com.keynub/keynub-licdongle)
(JNA), which calls the native KeyNub library. Scala 3.3 or later on Java 17 or
later, on Windows, Linux and macOS, with no driver.

## Setup

The library, like the Java binding, carries no native library. In a clone of
the SDK repository it finds `keynub_licdongle` for your platform in
`natives/<platform>/` on its own, from the working directory upwards, so the
samples run with nothing set. Elsewhere, take the library from the SDK's
[natives folder](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
and either put it where JNA finds libraries (`jna.library.path`, `PATH`,
`LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH`) or name it before the first call:

```scala
LicDongle.setLibraryPath("/opt/keynub/libkeynub_licdongle.so")
```

`KEYNUB_LICDONGLE_LIBRARY` in the environment, or the Java binding's system
property `keynub.licdongle.library`, does the same. A process loads the library
once; `LicDongle.libraryPath` tells which. On Linux, install the udev rule
described in
[`NATIVES.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
so the dongle is accessible without root.

## Notes

- `Dongle` and `Session` are `AutoCloseable`; `withDongle` and `withSession`
  close them on every exit path, exceptions included, and return what the body
  returns. A dongle has one session at a time: opening another ends the one
  before it.
- Results are case classes (`Device`, `Info`, `Verification`, `Record`) and
  vectors; record data, keys and sealed data are `Array[Byte]`. The methods that
  take data also take a `String`, used as its UTF-8 bytes, and `readString`
  reads a record back as text.
- Every failure the native library reports is thrown as a `LicDongleError`
  with `status` (`Status.NoDevice`, `Status.NotGenuine`, `Status.NotFound`,
  `Status.AuthRequired`, ...), the numeric `code` and the library's `detail`
  text, with the Java exception as its cause:
  `catch case e: LicDongleError if e.status == Status.NoDevice => ...`.
- `isGenuine` is the boolean form for a gate and **fails closed**: every
  failure gives `false`.
- Writing, erasing and incrementing need the write role:
  `session.authorizeWrite(keyBytes)` with the dongle's write key, a P-256
  private key in PKCS#8 DER. That belongs in your licence-issuing tooling,
  never in what your users run. A new dongle accepts the public factory key
  until `rotateWriteKey` replaces it with yours; do that once per dongle, when
  it arrives.
- `eraseAll()` is separate from `erase(name)`, and an empty name is refused:
  an accidentally empty name never wipes the dongle.
- `read` and `write` take an optional `(done, total) => Boolean` that cancels
  the transfer by returning `false`.

> Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `if !dongle.isGenuine then sys.exit(1)` is one
> branch, and patching one of those out of a program is no effort at all.
> Route something the program needs through `appEncrypt` and `appDecrypt`, so
> removing the check removes the data.

## Tests

`mvn test` in `bindings/scala` runs the unit tests, which need neither the
library nor a dongle, and a stand-in test without a dongle: it compiles a
stand-in for the C ABI (`bindings/julia/test/stub/licd_stub.c`) with the C
compiler on the path (cc, gcc, clang, `zig cc` or cl) and runs every call
against it. `KEYNUB_SDK_ROOT` names the SDK sources when the project is not
inside a clone; `KEYNUB_LICDONGLE_LIBRARY` names a compiled stand-in instead.
The samples are under `samples/scala`.

## Links

- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
- [KeyNub License Dongle for Scala](https://www.keynub.com/developers/scala/): the product, and how to
  order one
