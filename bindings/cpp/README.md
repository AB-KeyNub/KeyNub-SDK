# KeyNub License Dongle — C++ binding

Header-only RAII wrapper over the C ABI. One file, no library beyond the core
itself, nothing to build.

```cpp
#include <licdongle.hpp>          // add bindings/cpp to your include path

keynub::Context ctx;
keynub::Dongle dongle = ctx.open();       // first dongle, or pass a serial
dongle.verifyGenuine();                   // throws unless genuine

keynub::Session session = dongle.openSession();
keynub::Bytes data = session.appDecrypt(blob);   // build the licence check here
// session, dongle and ctx all close themselves
```

**C++11**, deliberately — not C++17. The desktop engineering applications this
dongle is sold to are frequently pinned to an older toolchain, and a licensing SDK
that forces a compiler upgrade does not get adopted.

The repository is a CMake package. Fetch it and link the C++ target, which
carries the header and the core library:

```cmake
include(FetchContent)
FetchContent_Declare(keynub_licdongle
    GIT_REPOSITORY https://github.com/AB-KeyNub/KeyNub-SDK.git
    GIT_TAG        v1.1.1)
FetchContent_MakeAvailable(keynub_licdongle)

target_link_libraries(myapp PRIVATE keynub::licdongle_cpp)
keynub_copy_runtime(myapp)      # puts the shared library next to the executable
```

From a clone or an installed prefix, `find_package(keynub_licdongle CONFIG REQUIRED)`
provides the same targets; `keynub::licdongle` is the C API alone.

> **Read [`../../docs/integration-security.md`](../../docs/integration-security.md)
> before writing your check.** `if (dongle.isGenuine())` compiles to a conditional
> jump, and patching one of those in a stripped release binary is a beginner
> exercise. Route something the program needs through `appEncrypt`/`appDecrypt`
> instead, so there is nothing left to run when the check is removed.

## What the wrapper adds over calling C directly

- **Deterministic cleanup**, including the session: `licd_session_close` on scope
  exit, `licd_close` and `licd_free` after it, in the right order.
- **Typed exceptions.** `NotGenuineError`, `CertificateInvalidError`,
  `WriteAuthorizationRequiredError`, `SessionExpiredError`, `DeviceNotFoundError`,
  `RecordNotFoundError`, `CancelledError` — all deriving from `keynub::Error`,
  which carries `status()` and the SDK's `detail()`. Catch the base class if the
  distinction does not matter to you.
- **No manual frees.** `licd_free_buffer`, `licd_free_device_list` and
  `licd_free_record_list` are handled, including on the exception paths — which is
  where hand-written code leaks.
- **`std::function` progress callbacks** that may throw. An exception is captured,
  the transfer is cancelled, and it is rethrown once the SDK has unwound — never
  thrown through the C frames, which would strand the device mid-transfer.
- **A Session cannot dangle.** Dongle and Session share the device state, so a
  Session that outlives its Dongle becomes inert and reports it, instead of calling
  `licd_session_close` on freed memory. That is the mistake a first-draft wrapper
  makes, and the destructor ordering that triggers it (`Session` declared before
  `Dongle`) is entirely ordinary.

Move-only throughout: a dongle handle is not a value to copy.

## Mixing with the C API

`Context::raw()` and `Dongle::raw()` hand back the underlying handles, and
`Dongle::adopt(device, ctx)` takes ownership of a device opened through
`licd_open` directly — so an existing codebase can adopt this wrapper a function at
a time rather than all at once.
