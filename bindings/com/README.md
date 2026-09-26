# KeyNub License Dongle — COM / ActiveX binding

For **Visual Basic 6**, **twinBASIC**, **VBScript/HTA**, and any VBA host that would
rather have an object than thirty `Declare` statements. Also the least error-prone
way in from Delphi, PowerShell and .NET.

```vb
Dim dongle As New KeyNub.Dongle       ' or CreateObject("KeyNub.Dongle")

dongle.Open                           ' raises if no dongle is attached
Debug.Print dongle.VerifyGenuine      ' raises unless genuine; returns the cert serial

dongle.SessionOpen
Dim rates() As Byte
rates = dongle.AppDecrypt(storedBlob) ' <- the actual licence check
dongle.SessionClose
```

Samples: [VB6](../../samples/vb6/), [twinBASIC](../../samples/twinbasic/).

## Install

1. Copy the **`KeyNub.dll`** that matches your application's bitness next to your
   executable, or anywhere on the system `PATH`. It is self-contained.
2. Register it once:

   | Your application | Use this regsvr32 | With this build |
   | --- | --- | --- |
   | VB6 (always 32-bit) | `C:\Windows\SysWOW64\regsvr32.exe` | x86 |
   | 32-bit twinBASIC / Office | `C:\Windows\SysWOW64\regsvr32.exe` | x86 |
   | 64-bit twinBASIC / Office | `C:\Windows\System32\regsvr32.exe` | x64 |

**Elevation is not required.** The server registers machine-wide when it can and
falls back to the current user when it cannot, so `regsvr32` from an ordinary prompt
installs under `HKCU\Software\Classes` and works for that user. Unregister with
`regsvr32 /u`, which cleans both locations.

Bitness is the mistake that costs the most time here, because a mismatch reports
**"class not registered"** — which reads like a registry fault, not a bitness one. An
in-process COM server can only be loaded by a host of its own architecture; there is
no shim.

## Why this exists rather than `Declare` statements

VB6's `Declare` emits a **stdcall** call. The flat C API
([`bindings/flat`](../flat/)) is **cdecl**, like the rest of the SDK. On x64 that
distinction does not exist — Windows has a single calling convention there, which is
why the [VBA binding](../vba/) is safe in 64-bit Office. In a **32-bit** process the
two genuinely differ: arguments arrive correctly and the return value is right, but
neither side pops them, so the stack pointer drifts by the argument size on *every
call*. It survives a demo and fails later, somewhere unrelated.

VB6's documented `CDecl` keyword does not help: it is honoured on the Macintosh and
ignored on Windows.

Going through COM removes the question — the caller reaches the object through a
vtable or `IDispatch`, and the calling convention stops being the application's
problem.

## What the object adds beyond safety

- **The handle is owned by the object.** Dropping the reference closes the dongle.
  The flat API has a 32-slot handle table and no destructor, so in a language where
  an early `Exit Sub` skips the `Close`, slots leak until the process ends.
- **Failures raise**, with `Err.Number` = `vbObjectError + 5000 + |status|` — the same
  numbering the [VBA binding](../vba/) uses, so error handlers read identically in
  both — and `Err.Description` carrying the SDK's own diagnostic text. That detail is
  what separates *"no dongle attached"* from *"a dongle whose certificate did not
  validate"*.
- **Byte arrays are `SAFEARRAY`s**, which VB6 `Byte()` already is. No pointer
  arithmetic, no two-call buffer-size protocol.
- **`IsGenuine` is the one member that does not raise.** It returns `False` and fails
  closed on every kind of failure, for use directly in a gate.

## Early vs late binding

`CreateObject("KeyNub.Dongle")` needs no project configuration and is what the
samples use so they run immediately. For production, add **Project ▸ References ▸
KeyNub License Dongle** and declare the real type:

```vb
Dim dongle As KeyNub.Dongle
Set dongle = New KeyNub.Dongle
```

That gives IntelliSense, the object browser, compile-time checking of every member
name, and the `keynubScope*` / `keynubFlag*` / `keynubErr*` enums as named constants.

## Registration-free deployment

The type library is embedded in the DLL as a resource, so the server can be activated
from a side-by-side manifest with nothing in the registry. Reference `KeyNub.dll` and
CLSID `{335416C9-F790-454B-81B6-866020DB2A13}` in your application manifest. Useful
for a portable install; note that VB6 needs its own manifest handling for this, which
is fiddlier than `regsvr32`.

## Tests

`bindings/com/tests` builds the server from `keynub_com.cpp` over the flat API and
a stand-in for the C API (`bindings/julia/test/stub/licd_stub.c`, one imaginary
dongle held in memory) and calls every member through the vtable, as early binding
does, and through `IDispatch`, as `CreateObject` does. No dongle, no native library
and no registration are needed. With Visual C++ and the Windows SDK:

```
cmake -S bindings/com/tests -B build-com-standin -A x64
cmake --build build-com-standin --config Release
ctest --test-dir build-com-standin -C Release
```

`-A Win32` builds and tests the 32-bit server that VB6 loads.

## API

Everything raises on failure except `IsGenuine`.

| Member | Notes |
| --- | --- |
| `DeviceCount` | attached dongles; read it before `DeviceSerial` — it takes the snapshot |
| `DeviceSerial(i)` / `DevicePath(i)` | enumerate without opening |
| `Open([serial])` / `OpenPath(path)` | omit the serial for the first dongle |
| `Close` | idempotent; safe in an error handler |
| `IsOpen` | |
| `Serial` | the USB serial — **not proof of anything on its own** |
| `FirmwareVersion` / `ProtocolVersion` | `"1.2.3"` / `"1.0"` |
| `Flags` | bitmask of `keynubFlag*` |
| `Capacity` / `FreeBytes` | user storage, bytes |
| `IsGenuine` | `Boolean`, fails closed, **never raises** |
| `VerifyGenuine` | raises unless genuine; returns the certificate serial |
| `SessionOpen` / `SessionClose` | required before records, counters and app-crypto |
| `RecordCount` / `RecordName(i)` / `RecordSize(name)` | |
| `RecordRead(name)` / `RecordWrite(name, bytes)` | `Byte()` in and out |
| `RecordErase(name)` / `RecordEraseAll` | an empty name is refused, not treated as "all" |
| `CounterRead(id)` / `CounterIncrement(id)` | monotonic; increments cannot be undone |
| `AppEncrypt(scope, bytes)` / `AppDecrypt(bytes)` | **the pair that matters** — see below |
| `AuthorizeWrite(der)` | your licence-issuing tooling; never ship that key |
| `SetTrustRoot(der)` | not needed; a release build embeds the KeyNub root |
| `LastError` | diagnostic detail for logging (`Err.Description` already has it) |
| `Version` | SDK version |

## Where to put the check

A gate this pleasant to write is a gate that is pleasant to delete:

```vb
If dongle.IsGenuine Then EnableFeatures    ' <- one line for someone to cut
```

A compiled VB6 executable is harder to patch than a VBA macro, but harder is not
hard — and it only has to be defeated once before the patch circulates.

What cannot be deleted is data the program needs and cannot compute:

```vb
' Once, when you issue the licence, with your developer dongle:
envelope = dongle.AppEncrypt(keynubScopeDeveloper, SerialiseRateTable())

' At run time, on the customer's machine:
rates = dongle.AppDecrypt(envelope)   ' no dongle -> no rates -> no product
```

Put the thing your product is actually *for* through that pair: rate tables,
correction factors, a material database, the coefficients of your calculation.
`keynubScopeDeveloper` lets any dongle you have issued decrypt it, so one blob ships
to every customer; `keynubScopeDevice` locks it to one physical dongle.

The envelope is authenticated, so a customer cannot edit the values either — a
tampered envelope fails to decrypt rather than yielding different numbers.

[`../../docs/integration-security.md`](../../docs/integration-security.md) makes the
full argument.
