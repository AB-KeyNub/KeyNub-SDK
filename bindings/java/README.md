# KeyNub License Dongle — Java binding

`com.keynub:keynub-licdongle` is a thin [JNA](https://github.com/java-native-access/jna)
wrapper over the native `keynub_licdongle` core — no protocol or crypto logic in Java.
Requires Java 17+. Works on Windows, Linux, and macOS with no drivers.

## Use

```java
import com.keynub.licdongle.*;

try (LicenseDongleContext ctx = new LicenseDongleContext()) {
    for (DeviceInfo d : ctx.enumerate()) {
        System.out.println(d.serial() + " " + d.path());
    }

    try (Dongle dongle = ctx.open()) {                 // first attached dongle (or open(serial))
        GenuineResult id = dongle.verifyGenuine();     // cert chain + live challenge-response

        try (Session session = dongle.openSession()) {  // ECDH -> HKDF -> AES-256-GCM
            byte[] license = session.readRecord("license");         // read role

            session.authorizeWrite(masterKeyDer);                   // licence-issuing tooling
            session.writeRecord("license", newBytes);

            byte[] blob = session.appEncrypt(Scope.DEVICE, plaintext);
            assert Arrays.equals(session.appDecrypt(blob), plaintext);
        }
    }
}
```

- `LicenseDongleContext` / `Dongle` / `Session` all implement `AutoCloseable`.
- Failures throw `LicenseDongleException` (with `getStatus()`); common cases have subclasses
  (`NotGenuineException`, `WriteAuthorizationRequiredException`, `RecordNotFoundException`, …).
- `readRecord` / `writeRecord` accept a `ProgressCallback` returning `true` to continue,
  `false` to cancel (raises `OperationCancelledException`).

## Native library resolution

JNA loads `keynub_licdongle` from `jna.library.path`, the JAR-embedded natives, or the system
search path. Override with the system property `-Dkeynub.licdongle.library=<path-or-name>`. Linux
additionally needs the shipped udev rule (a permission rule, not a driver). Per-platform natives
are embedded into the published JAR.

## Security

Read [`docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md) before
writing your licensing check. `verifyGenuine()` proves a genuine dongle is attached;
it cannot stop an attacker from patching your application or pointing
`-Dkeynub.licdongle.library` at a fake library. Branch on a boolean and you will be
bypassed — put dongle-derived data (`appEncrypt`/`appDecrypt`) on the path your
application actually needs.

## Tests

`mvn test -Dtest=StandInTest` runs without a dongle: it compiles a stand-in for
the C ABI (`bindings/julia/test/stub/licd_stub.c`) with the C compiler on the path
(cc, gcc, clang, `zig cc` or cl), loads it through `keynub.licdongle.library` and
exercises every call of the binding against it. `KEYNUB_SDK_ROOT` names the SDK
sources when the project is not inside a clone.

## License

Apache-2.0 — see [`LICENSE`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/LICENSE), [`NOTICE`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NOTICE), and
[`THIRD-PARTY-NOTICES.txt`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/THIRD-PARTY-NOTICES.txt); the build copies all three
into `META-INF/` inside the JAR. The natives statically link Mbed TLS (Apache-2.0
elected) and hidapi (BSD-style elected), and JNA is used under its Apache-2.0 option —
no GPL or LGPL terms apply.

## Links

- [KeyNub License Dongle for Java](https://www.keynub.com/developers/java/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
