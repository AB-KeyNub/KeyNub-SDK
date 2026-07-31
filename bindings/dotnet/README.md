# KeyNub License Dongle — .NET binding

`KeyNub.LicenseDongle` is a thin, idiomatic .NET wrapper over the native
`keynub_licdongle` core. It carries no protocol or crypto logic of its own — it
marshals to the C ABI and maps status codes to exceptions. Targets **`net8.0`**
and **`netstandard2.0`** (the latter covers .NET Framework 4.8 and 32-bit Windows).

## Install

```
dotnet add package KeyNub.LicenseDongle
```

Native binaries ship inside the package under `runtimes/<rid>/native/` for
`win-x86`, `win-x64`, `win-arm64`, `linux-x64`, `linux-arm64`, and `osx`. On
`net8.0`+ the host selects the right one automatically; on .NET Framework the
bundled MSBuild targets copy it next to your app and the binding pre-loads it.
No driver install on any platform (Linux needs the shipped udev rule).

## Shape

```csharp
using KeyNub.LicenseDongle;

using var ctx = LicenseDongleContext.Create();
using Dongle dongle = ctx.Open();            // first attached dongle (or by serial)

GenuineResult id = dongle.VerifyGenuine();   // cert chain + live challenge-response
Console.WriteLine($"genuine={id.IsGenuine} serial={id.Serial}");

using Session session = dongle.OpenSession();     // ECDH → HKDF → AES-256-GCM
byte[] license = session.ReadRecord("license");   // read role

// Developer/provisioning tools elevate to the write role with the master key:
session.AuthorizeWrite(masterKeyDer);
session.WriteRecord("license", newBytes);

// App-data envelope encryption — data unusable without a genuine dongle:
byte[] sealed = session.AppEncrypt(Scope.Device, plaintext);
byte[] plain  = session.AppDecrypt(sealed);
```

- `LicenseDongleContext` — thread-safe entry point: enumerate / open / logging.
- `Dongle` — one connection: `GetInfo`, `GetSerial`, `VerifyGenuine`, `OpenSession`.
- `Session` — the session-scoped operations: records, counters, app-crypto, `AuthorizeWrite`.
- Failures throw `LicenseDongleException` (with a `LicdStatus`); common cases have
  subclasses (`NotGenuineException`, `WriteAuthorizationRequiredException`, …).

## Build & test — no hardware required

The tests run the whole managed API against an **in-process software dongle**: the
the native build target `keynub_licdongle_sim` is the full core ABI plus a `licd_open_simulated`
entry point backed by the C device simulator and the committed X.509/key fixtures.
A `DllImportResolver` in the test project loads that library in place of the
production DLL, so every marshaling path, the crypto handshake, and the record /
counter / app-crypto operations are exercised end-to-end.

```powershell
# 1) Build the native simulator (see README.md for the MSVC/Ninja recipe):
see NATIVES.md for the prebuilt library
see NATIVES.md for the prebuilt library

# 2) Point the tests at it and run:
$sim = "native//keynub_licdongle_sim.dll"
$env:KEYNUB_SIM_PATH = $sim
dotnet test bindings/dotnet/KeyNub.LicenseDongle.Tests -p:KeynubSimNative=$sim
```

The production package never contains the simulator — it is a test-only artifact
(configure with `-DLICD_BUILD_SIM=OFF` to skip building it).

## Security

Read [`docs/integration-security.md`](../../docs/integration-security.md) before
writing your licensing check. `VerifyGenuine()` proves a genuine dongle is attached;
it cannot stop an attacker from patching your application or substituting a fake
native library. Branch on a boolean and you will be bypassed — put dongle-derived
data (`AppEncrypt`/`AppDecrypt`) on the path your application actually needs.

## License

Apache-2.0 — see [`LICENSE`](../../LICENSE), [`NOTICE`](../../NOTICE), and
[`THIRD-PARTY-NOTICES.txt`](../../THIRD-PARTY-NOTICES.txt) (all three ship inside the
NuGet package). The bundled natives statically link Mbed TLS (Apache-2.0 elected) and
hidapi (BSD-style elected); no GPL terms apply.
