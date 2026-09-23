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

## Installing

The repository is a Zig package: its root `build.zig.zon` exposes this binding
as the module `keynub_licdongle`, compiled against the real header, and links
the prebuilt native library for your target from `natives/`.

```
zig fetch --save git+https://github.com/AB-KeyNub/KeyNub-SDK#v1.1.1
```

```zig
// build.zig
const keynub = b.dependency("keynub_licdongle", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("keynub_licdongle", keynub.module("keynub_licdongle"));
```

The executable still loads the shared library at start-up, by name, so put it
next to the executable or on the system search path; `NATIVES.md` in the
repository says which file that is per platform.

## Building

```
zig build                              # type-check the binding
```

As a dependency, the module is exported as `keynub_licdongle`; add
`../../include` to your include path so `@cImport` can find the header.

Requires **Zig 0.16**. Zig makes no source
compatibility promise between releases, so the binding tracks the current one;
0.15 and earlier need `callconv(.C)` where this uses `callconv(.c)`, and the
`build.zig` here uses the `root_module` form introduced in 0.15. `FixedString`
is a plain struct rather than `std.BoundedArray` on purpose: that type has moved
between releases, and a licensing binding should not break on a compiler
upgrade.

## Tests

`zig build standin-test` runs without a dongle: it compiles a stand-in for the C
ABI (`bindings/julia/test/stub/licd_stub.c`) into the shared library
`keynub_licdongle_standin`, links the tests against it and exercises every call
of the binding. It needs no C compiler besides Zig.

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
