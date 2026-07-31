# KeyNub License Dongle — LabVIEW binding

LabVIEW calls the KeyNub dongle through **`keynub_licdongle_flat`**, a
self-contained shared library that exports only simple C functions: integer
handles, caller-allocated buffers, no callbacks. Nothing else needs to be on the
system — the core, Mbed TLS and hidapi are all compiled into it.

| Platform | Library file |
| --- | --- |
| Windows | `keynub_licdongle_flat.dll` |
| Linux | `libkeynub_licdongle_flat.so` |
| macOS | `libkeynub_licdongle_flat.dylib` |

**Build it 32-bit or 64-bit to match your LabVIEW**, not your OS. A 64-bit DLL in
32-bit LabVIEW fails to load with an error that does not mention bitness.

## Fastest route: the Import Shared Library wizard

**Tools ▸ Import ▸ Shared Library (.dll)…**, then give it
`keynub_licdongle_flat.dll` and [`licd_labview.h`](licd_labview.h). That header
exists for this purpose: it declares the same functions as the SDK's
[`../flat/licd_flat.h`](../flat/licd_flat.h) but with no `#include`, no
`__declspec` and no macros inside the signatures, all of which the wizard has to
guess at otherwise. The two are kept in step by a test that runs in CI.

The generated VIs are a starting point. The wizard cannot know that `out_size` is
the capacity of `out`, so review the string and array parameters against the table
below.

## Configuring a Call Library Function Node by hand

Set **Calling convention: C** (not stdcall) on every platform.

| C parameter | Node type | Data type / details |
| --- | --- | --- |
| `int32_t handle`, `int32_t index`, `int32_t len`, `int32_t scope` | Numeric | Signed 32-bit, **Pass: Value** |
| `int32_t *out_...` | Numeric | Signed 32-bit, **Pass: Pointer to Value** |
| `const char *name` | String | **C String Pointer** |
| `char *out` (a returned string) | String | **C String Pointer**, and the wire must carry a string **pre-sized to `out_size`** — see below |
| `const uint8_t *data` (input bytes) | Array | Unsigned 8-bit, 1 dimension, **Array Data Pointer** |
| `uint8_t *out` (returned bytes) | Array | Unsigned 8-bit, 1 dimension, **Array Data Pointer**, pre-sized |
| return value | Numeric | Signed 32-bit |

**Pre-sizing is not optional.** LabVIEW does not grow a buffer for a C function.
Before the call, build the output with **Initialize Array** (bytes) or
`Concatenate Strings` of spaces / **Initialize Array + Byte Array To String**
(text), pass its size as the matching `out_size`/`out_cap`, and trim the result
afterwards. Passing a buffer smaller than you claim corrupts LabVIEW's memory; the
library cannot detect it, which is why it never writes more than the capacity you
declare.

For byte outputs, the library also tells you the size you need, so the reliable
pattern is two calls:

1. Call with `out_cap = 0`. You get `-11` (`LICD_E_RANGE`) and `out_len` set to the
   required size. Passing a zero-length array is fine — the library does not
   dereference the pointer when the capacity is 0.
2. **Initialize Array** to that size and call again.

## Error handling

Every function returns `0` on success and a negative status otherwise; the
constants are at the top of [`licd_labview.h`](licd_labview.h). `licdf_open` is the
exception: it returns a **positive handle**, or a negative status.

Turn a status into text with `licdf_strerror` (no handle needed), and get the SDK's
diagnostic detail for the last failure on a handle with `licdf_last_error` — worth
wiring into your error cluster's description, because it distinguishes "no dongle"
from "a dongle whose certificate did not validate".

A skeleton for a subVI that wraps a call:

```
handle ──> [Call Library Function Node] ──> status ──> [Select]
                                                        ├─ 0        -> pass through
                                                        └─ negative -> Error Cluster
                                                                       code = 5000 - status
                                                                       source = licdf_strerror
```

Offsetting into LabVIEW's user-error range (5000–9999) keeps KeyNub statuses from
colliding with LabVIEW's own codes.

## Sequence

```
licdf_open("")                       -> handle
licdf_verify_genuine(handle, ...)     -> 0 and genuine = 1, or an error
licdf_session_open(handle)
licdf_app_decrypt(handle, blob, ...)  -> the data your VI needs
licdf_session_close(handle)
licdf_close(handle)                   <- in a Close/abort case, always
```

Close the handle. The library holds 32 at once and returns `-13` (`LICD_E_BUSY`)
when they are gone; a VI that opens in a loop without closing will find that
limit. Put `licdf_close` where your error path reaches it too.

## Threading

Calls into the library are serialized internally, so it is safe to call from
several VIs at once — but two of them will not talk to two dongles simultaneously.
If you genuinely need parallel access to several dongles, use the core C ABI
([`../../include/licdongle.h`](../../include/licdongle.h)) instead.

Configure the node as **"Run in any thread"** only if your VI does not also touch
the dongle from the UI thread; the safe default in LabVIEW remains **"Run in UI
thread"**, and dongle operations are milliseconds.

## Where to put the check

The important part, and the part a licensing tutorial usually leaves out: do not
build your VI around `licdf_verify_genuine` returning success.

A LabVIEW application is distributed as a built executable whose block diagram an
attacker cannot read easily — but a Boolean wire is still just a Boolean wire, and
the standard attack does not read your code at all: it replaces the DLL. Rename a
stub `keynub_licdongle_flat.dll` that returns 0 from everything, and a
verify-and-branch VI is defeated in a minute.

`licdf_app_decrypt` cannot be stubbed, because a stub does not have the key. Put
something your application genuinely needs through it — calibration constants, a
device profile, the coefficients of your analysis — and encrypt that data once with
`licdf_app_encrypt` when you issue the licence. Then the replaced DLL returns
nothing usable.

[`../../docs/integration-security.md`](../../docs/integration-security.md) makes
the full argument, and
[`../../samples/matlab/licence_protected_parameters.m`](../../samples/matlab/licence_protected_parameters.m)
shows the shape in a language where it is easy to read.

## Status of this binding

The library and its whole surface are tested in CI
(the SDK test suite drives every function against an in-process
software dongle, with no hardware). The **`.vi` files are not provided**: authoring
them requires LabVIEW, which is not available on the machine this SDK is built on,
and a broken VI would be worse than none. What is here — the import header and the
node configuration — is what the wizard needs to generate them, and it is checked
against the library's real signatures by
the SDK build checks
on every push.

If you build a VI library on top of this, we would like to ship it.
