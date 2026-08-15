# KeyNub License Dongle — flat companion API

The same functionality as the core C ABI, restated so that a language which can
only call simple C functions can use it. Built as one self-contained shared
library, `keynub_licdongle_flat`, with the core, Mbed TLS and hidapi compiled in.

This is not a language binding. It is the surface the
[LabVIEW](../labview/README.md) and [Excel/VBA](../vba/README.md) bindings sit on,
and the right target for anything else with a limited FFI — Fortran
(`ISO_C_BINDING`), Delphi's older `external` syntax, AutoIt, PowerBuilder, a shell
tool.

**Use the core ABI, or a real binding over it, whenever your language can.** This
layer cannot report progress or cancel a transfer, and it serializes calls.

## What it removes

LabVIEW, VBA, Fortran and most scripting FFIs share three limitations. Each one is
gone here:

| The core ABI uses | Flat API instead |
| --- | --- |
| opaque pointers (`licd_ctx *`) | `int32` handles from a table inside the library |
| library-allocated buffers plus a matching `free` | caller-allocated buffers only |
| function-pointer callbacks | none at all |
| arrays of strings (`char ***`) | index-addressed accessors |

## Conventions

- Every function returns `int32`: `0` on success, otherwise the negative
  `licd_status` from [`../../include/licdongle.h`](../../include/licdongle.h).
  **`licdf_open` is the exception** — it returns a positive handle, or a negative
  status.
- Strings are UTF-8 and NUL-terminated on return. An **empty** input string means
  "not specified" wherever a null pointer would in the core API.
- **Byte buffers use a two-call protocol.** Pass your capacity; on success
  `*out_len` is what was written. If the buffer is too small you get
  `LICD_E_RANGE` (`-11`) and `*out_len` set to the size required — so the reliable
  pattern is to ask once with a capacity of `0`, allocate, and ask again. The
  library never dereferences a buffer whose declared capacity is `0`.
- **All out-parameters may be null.** Pass only the values you want.
- `licdf_get_info` returns its booleans as a bitmask (`LICDF_FLAG_*`), because a
  struct is the other thing these callers cannot express.

## Deliberate differences from the core API

Two guards exist because the languages above have no optional arguments and no
exceptions, so an uninitialised variable is the ordinary kind of mistake:

- **`licdf_record_erase` refuses an empty name.** In the core, a null name means
  "erase every record". Here that is a separate function,
  `licdf_record_erase_all`, so an empty string cannot wipe a customer's dongle.
- **Counter values are `int32`.** The secure element's counters are 32-bit, so a
  value above 2³¹ would not fit a signed carrier. In practice it cannot arise: a
  licence counter incremented once a second would take 68 years to get there, and
  the flat ABI exists for languages whose only integer type is signed. Callers
  that need the full range should use the C API, where the value is `uint32_t`.

## Threading

One lock is held for the whole of each call. It is safe to call from several
threads, but two of them will not talk to two dongles at the same time. The callers
this exists for are not chasing throughput, and serializing removes a class of
question: no handle can be closed underneath an operation, and the enumeration
snapshot cannot change while it is being read. If you need parallel access to
several dongles, use the core ABI.

## Handles

32 at once. `licdf_open` returns `LICD_E_BUSY` (`-13`) when they are exhausted —
which is what a loop that forgets `licdf_close` will see. Handle ids are not reused
while a handle is live, so a stale id is rejected rather than silently addressing
someone else's dongle.

## Building

Built by default with the SDK (`-DLICD_BUILD_FLAT=OFF` to skip it):

```
see NATIVES.md for the prebuilt library
# -> keynub_licdongle_flat.dll / .so / .dylib
```

It exports **only** `licdf_*`. The core's `licd_*` symbols are compiled in but
hidden, so the two ABIs cannot be confused for one another.
