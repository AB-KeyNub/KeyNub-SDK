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

            session.authorizeWrite(masterKeyDer);                   // vendor/provisioning tools
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
are embedded into the published JAR by the build/CI.

## Build & test (no hardware required)

The suite runs the whole binding against the in-process software dongle
(`keynub_licdongle_sim`, shipped as a prebuilt binary), driven through the same simulator entry points as the C,
.NET, and Python suites. The test picks up `KEYNUB_SIM_PATH`, else the standard `native/` output.

```
see NATIVES.md for the prebuilt library
cd bindings/java
KEYNUB_SIM_PATH=../../build/libkeynub_licdongle_sim.so mvn test
mvn package     # produces target/keynub-licdongle-1.0.0.jar
```

## Security

Read [`docs/integration-security.md`](../../docs/integration-security.md) before
writing your licensing check. `verifyGenuine()` proves a genuine dongle is attached;
it cannot stop an attacker from patching your application or pointing
`-Dkeynub.licdongle.library` at a fake library. Branch on a boolean and you will be
bypassed — put dongle-derived data (`appEncrypt`/`appDecrypt`) on the path your
application actually needs.

## License

Apache-2.0 — see [`LICENSE`](../../LICENSE), [`NOTICE`](../../NOTICE), and
[`THIRD-PARTY-NOTICES.txt`](../../THIRD-PARTY-NOTICES.txt); the build copies all three
into `META-INF/` inside the JAR. The natives statically link Mbed TLS (Apache-2.0
elected) and hidapi (BSD-style elected), and JNA is used under its Apache-2.0 option —
no GPL or LGPL terms apply.
