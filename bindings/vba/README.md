# KeyNub License Dongle — Excel / VBA binding

For engineering software distributed as an Excel workbook, or any VBA host (Access,
Word, AutoCAD, SolidWorks).

**Not for VB6.** The declarations here use `PtrSafe`, which is a syntax error in
VBA6, and VB6 cannot safely call this DLL anyway — see
[the COM binding](../com/README.md), which exists for VB6 and twinBASIC and explains
why. **64-bit Office is what this binding is verified for**; for a 32-bit host, prefer
the COM binding too, for the reason under *Bitness* below.

## Install

1. Copy **`keynub_licdongle_flat.dll`** next to the workbook, or into a folder on
   the system `PATH`. It is self-contained — no other file to deploy.
2. In the VBA editor: **File ▸ Import File…** and pick
   [`KeyNubLicDongle.bas`](KeyNubLicDongle.bas).

### Bitness

**The DLL must match Office's bitness, not Windows'.** 64-bit Windows running
32-bit Excel — still a common combination — needs the 32-bit build, which the SDK
ships alongside the 64-bit one. A mismatch reports "file not found", which sends
people hunting the wrong problem.

There is a second reason to care which one you are on. A VBA `Declare` emits a
**stdcall** call; this DLL, like the rest of the SDK, is **cdecl**. On x64 that
distinction does not exist — Windows has a single calling convention there — so these
declarations are exactly right in 64-bit Office. In a **32-bit** process the two
conventions genuinely differ in who pops the arguments, and a mismatch of that kind
does not fail cleanly: it leaves the stack pointer displaced on every call.

This has not been measured on a 32-bit Office install, so it is stated as the risk
it is rather than either dismissed or asserted. If you are targeting a 32-bit host,
use
[the COM binding](../com/README.md) instead — it reaches the same library through an
object, where the calling convention is not the caller's problem.

Requires **VBA7 (Office 2010 or newer)**. The declarations use `PtrSafe`, which is
required in 64-bit Office and a syntax error in VBA6; supporting Office 2007 would
mean shipping a duplicate set of declarations for a version out of support since
2017.

## Use

```vba
Sub CheckLicence()
    Dim h As Long
    h = KeyNubOpen()                     ' raises if no dongle is attached
    Debug.Print "Serial: " & KeyNubVerifyGenuine(h)

    KeyNubSessionOpen h
    Dim rates() As Byte
    rates = KeyNubAppDecrypt(h, LoadBlobFromSheet())   ' the real licence check
    KeyNubSessionClose h

    KeyNubClose h                        ' always: the library holds 32 handles
End Sub
```

Every wrapper raises a VBA error on failure, numbered `vbObjectError + 5000 +
|status|`, with `Err.Description` carrying the SDK's own diagnostic detail — which
is what tells "no dongle attached" apart from "a dongle whose certificate did not
validate". `KeyNubIsGenuine` is the one exception: it returns `False` instead of
raising, for use in a gate, and fails closed on every kind of failure.

| Function | Notes |
| --- | --- |
| `KeyNubOpen([serial])` | returns a handle; omit the serial for the first dongle |
| `KeyNubClose h` | safe with 0; put it in your error handler too |
| `KeyNubDeviceCount` / `KeyNubDeviceSerial(i)` | enumerate without opening |
| `KeyNubVerifyGenuine(h)` | raises unless genuine; returns the certificate serial |
| `KeyNubIsGenuine(h)` | `Boolean`, fails closed, never raises |
| `KeyNubGetInfo(h)` | a `KeyNubDeviceInfo` (protocol, firmware, capacity, flags) |
| `KeyNubSessionOpen/Close h` | required before any record or app-crypto call |
| `KeyNubRecordRead/Write/Erase` | `Byte()` in and out |
| `KeyNubCounterRead/Increment` | monotonic hardware counters |
| `KeyNubAppEncrypt/Decrypt` | **the one that matters** — see below |
| `KeyNubAuthorizeWrite h, der` | your licence-issuing workbook; never ship that key |

Strings are marshalled by VBA as ANSI, which is exactly right for serials and
record names (both ASCII). Do not use non-ASCII record names from VBA.

## Where to put the check

VBA is the easiest code in the world to read and change. A workbook that does

```vba
If KeyNubIsGenuine(h) Then EnableFeatures    ' <- delete this line
```

is unprotected the moment someone opens the VBA editor — and unlike a compiled
application, they do not even need a debugger. Password-protecting the VBA project
does not help; that protection is trivially removed and always has been.

What cannot be deleted is data the workbook needs and cannot compute:

```vba
' Once, when you issue the licence (with the developer dongle):
blob = KeyNubAppEncrypt(h, KEYNUB_SCOPE_DEVELOPER, SerialiseRateTable())

' At run time, on the customer's machine:
rates = KeyNubAppDecrypt(h, blob)      ' no dongle -> no rates -> no workbook
```

Put the thing your product is actually *for* through that pair: rate tables,
correction factors, a material database, the coefficients of your calculation.
`KEYNUB_SCOPE_DEVELOPER` lets any dongle you have issued decrypt it, so one
encrypted blob ships to every customer; `KEYNUB_SCOPE_DEVICE` locks it to one
physical dongle, for per-customer data.

The envelope is authenticated, so a customer cannot edit the values either — a
tampered blob fails to decrypt rather than yielding different numbers.

[`../../docs/integration-security.md`](../../docs/integration-security.md) makes
the full argument.
