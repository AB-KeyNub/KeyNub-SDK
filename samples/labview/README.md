# LabVIEW samples — verify and read, and take ownership

This folder holds **wiring instructions rather than a `.vi`**, deliberately. A VI is
a binary file: it cannot be reviewed in a diff, and it pins you to one LabVIEW
version. The flat API it calls is stable, so a diagram you wire from this page keeps
working. See [`../../bindings/labview`](../../bindings/labview) for the binding.

> **Read [`../../docs/integration-security.md`](../../docs/integration-security.md)
> first.** The last section here is the part that matters: a Boolean wire is one
> diagram edit away from a True constant, and unlike compiled code a VI is editable
> by whoever has it.

## Configuring a Call Library Function node

Drop a **Call Library Function Node** (Connectivity → Libraries & Executables) and
open its configuration:

| Setting | Value |
| --- | --- |
| Library name or path | `keynub_licdongle_flat.dll` (`.so` / `.dylib` elsewhere) |
| Function name | as listed below |
| Thread | **Run in any thread** is safe; the library serialises internally |
| Calling convention | **C** — *not* stdcall |

Match the bitness of your LabVIEW installation, not of the machine: 32-bit LabVIEW
needs the 32-bit library. Both are published in the release archive.

## Parameter mapping

| C parameter | LabVIEW configuration |
| --- | --- |
| `int32_t` in | Numeric, Signed 32-bit, **Pass: Value** |
| `int32_t *` out | Numeric, Signed 32-bit, **Pass: Pointer to Value** |
| `const char *` in | String, **Format: C String Pointer** |
| `char *` out | String, **Format: C String Pointer**, with the buffer pre-sized by initialising the string to *n* spaces |
| `uint8_t *` in/out | Array, Unsigned 8-bit, 1 dimension, **Format: Array Data Pointer** |
| return value | Numeric, Signed 32-bit |

Every function returns `0` on success and a negative status otherwise —
**except `licdf_open`, which returns a positive handle.**

## The flow

1. **`licdf_device_count`** → `int32_t *out_count`. Zero attached dongles is a
   normal result, not an error. Branch here and tell the operator to plug one in.
2. **`licdf_open`** → `const char *serial_or_empty`, returns the handle. Wire an
   empty string for "first dongle found". Keep the handle in a shift register for
   the rest of the VI's life.
3. **`licdf_verify_genuine`** → `handle`, `int32_t *out_genuine`,
   `char *out_serial` (15 bytes), `int32_t serial_size`.
4. **`licdf_session_open`** → `handle`. Required before any record or app-crypto
   call.
5. **`licdf_record_read`** → `handle`, `const char *name`, `uint8_t *out`,
   `int32_t out_cap`, `int32_t *out_len`. Call `licdf_record_size` first to size
   the array, or pass a capacity of `0` to be told the size it needs.
6. **`licdf_session_close`**, then **`licdf_close`**. Put both in the error path
   too — the driver keeps a small fixed table of open handles, and a VI that
   aborts without closing costs you one until the process exits.

On any failure, **`licdf_last_error`** (`handle`, `char *out` 256 bytes,
`int32_t out_size`) returns the SDK's own diagnostic text. That string is what
distinguishes "no dongle" from "certificate rejected"; wire it into your error
cluster's description rather than reporting the status number alone.

## Taking ownership of a new dongle

A dongle ships holding KeyNub's write-auth key. Replace it with yours when the
delivery arrives, after which only your key can write records, erase them or
increment counters. This is a one-off per dongle, so it belongs in a small
maintenance VI rather than in the application.

Both keys are P-256 private keys in PKCS#8 DER, read into a `uint8_t` array
(**Array Data Pointer**) exactly like record data. Generate yours with:

```
openssl ecparam -name prime256v1 -genkey -noout |
  openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
```

1. **`licdf_open`**, then **`licdf_session_open`**.
2. **`licdf_write_auth`** → `handle`, `uint8_t *der` (the key the dongle holds
   now), `int32_t der_len`. This is what proves the outgoing key is yours.
3. **`licdf_write_auth_rotate`** → `handle`, `uint8_t *der` (your replacement),
   `int32_t der_len`.
4. **`licdf_session_close`**, then **`licdf_session_open`** again. The rotation is
   only observable on a fresh session, because the one above keeps the role it was
   already granted.
5. **`licdf_write_auth`** with the *old* key — it must now fail. If it returns `0`,
   stop and do not ship the unit.
6. **`licdf_write_auth`** with your key — it must now succeed.

Steps 5 and 6 are the ones worth wiring. A rotation that returned success and
changed nothing looks identical without them.

**Keep the replacement key off the test rig.** It cannot be recovered from a
dongle, and a unit rotated to a key you have lost has to come back to be
re-provisioned.

## Where the licence check belongs

The obvious diagram is wrong:

```
licdf_verify_genuine → genuine? → [True: run] / [False: dialog + stop]
```

Anyone with the VI can replace that Boolean with a `True` constant. Instead, make
the VI need something only the dongle can produce:

1. At licence-issue time, run `licdf_app_encrypt` once against a developer dongle,
   over the data your VI genuinely cannot compute — calibration constants, limit
   tables, instrument coefficients, a filter's parameters. Scope `1` lets any dongle
   you have issued decrypt it; scope `0` locks it to one dongle.
2. Ship the encrypted blob alongside the VI.
3. At run time, call `licdf_app_decrypt` and feed the result into the computation.

Now removing the check does not unlock anything — it leaves the VI with no
coefficients. That matters more in LabVIEW than almost anywhere else, because a
test rig usually has no internet connection and never will, so a dongle is the only
form of licensing available; and because the licence can move with the rig when the
rig moves.
