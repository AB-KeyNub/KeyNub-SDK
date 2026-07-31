# KeyNub License Dongle — Zig binding

```zig
const keynub = @import("keynub_licdongle");

var ctx = try keynub.Context.init();
defer ctx.deinit();
var dongle = try ctx.open(null);
defer dongle.close();
_ = try dongle.verifyGenuine();                        // error unless genuine

var session = try dongle.openSession();
defer session.close();
const data = try session.appDecrypt(allocator, blob);  // the licence check
defer allocator.free(data);
```

## The one binding that cannot drift

Every other binding in this SDK re-declares the C prototypes in another language,
and each one needs a test to guarantee those declarations still match
`include/licdongle.h`. This one does not: `@cImport` compiles the header
itself. A change to the ABI is a **compile error here**, not something a test has
to catch.

That is worth knowing when the ABI next changes — this binding tells you
immediately, which makes it a useful canary for the others.

## Building

```
zig build                              # type-check the binding
zig build test -Dkeynub-lib-name=keynub_licdongle_sim -Dkeynub-lib-dir=../../build
```

| Option | Meaning |
| --- | --- |
| `-Dkeynub-lib-dir` | directory holding the native library |
| `-Dkeynub-lib-name` | library to link; `keynub_licdongle_sim` for the tests |

As a dependency, the module is exported as `keynub_licdongle`; add
`../../include` to your include path so `@cImport` can find the header.

Verified with **Zig 0.16** and built on every CI run. Zig makes no source
compatibility promise between releases, so the binding tracks the current one;
0.15 and earlier need `callconv(.C)` where this uses `callconv(.c)`, and the
`build.zig` here uses the `root_module` form introduced in 0.15. `FixedString`
is a plain struct rather than `std.BoundedArray` on purpose: that type has moved
between releases, and a licensing binding should not break on a compiler
upgrade.

## Notes

- Errors are a Zig error set, which carries no payload, so the numeric status and
  the SDK's diagnostic text are reached through `Context.last_status` and
  `Context.lastErrorDetail()` after a failure.
- Anything returning a slice takes an allocator and the caller owns the result;
  `Session.freeRecords` releases a record list.
- Progress callbacks travel as a `Progress` struct with a context pointer, since
  Zig has no closures. Returning false cancels, which surfaces as
  `Error.Cancelled`.
- `Context.adopt` takes ownership of a device opened through the C ABI directly,
  so this can be introduced into existing code a call at a time.

> Read [`../../docs/integration-security.md`](../../docs/integration-security.md)
> before writing the check. `if (dongle.isGenuine())` compiles to a conditional
> jump, and patching one of those in a release binary is a beginner exercise.
> Route something the program needs through `appEncrypt`/`appDecrypt`.

## Testing

`zig build test` runs 8 tests against an in-process software dongle — **no
hardware** — covering the full protocol stack plus what is specific here:
allocation and ownership, the error mapping, the progress bridge with
cancellation, and a session outliving its dongle. `std.testing.allocator` fails
the test on a leak, so ownership mistakes are caught rather than tolerated.
