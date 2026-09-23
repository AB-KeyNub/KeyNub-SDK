# KeyNub License Dongle — Rust binding

`keynub-licdongle` — a safe wrapper over the SDK's C ABI. **No dependencies**
beyond `std`: a licensing crate is the last place a customer wants a transitive
dependency tree, and there is nothing here that needs one.

```rust
use keynub_licdongle::{Context, Scope};

let ctx = Context::new()?;
let dongle = ctx.open(None)?;              // first dongle, or Some("serial")
dongle.verify_genuine()?;                  // errors unless genuine

let session = dongle.open_session()?;
let data = session.app_decrypt(&blob)?;    // <- build your licence check on this
# Ok::<(), keynub_licdongle::Error>(())
```

> Read [`../../docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> before writing the check. `if dongle.is_genuine()` compiles to a conditional
> jump, and patching one of those in a release binary is a beginner exercise —
> Rust's guarantees stop at the machine code and were never about an adversary
> with a debugger. Route something the program needs through
> `app_encrypt`/`app_decrypt`, so removing the check removes the data.

## What the type system buys you here

Every other binding in this SDK has to defend at runtime against a session
outliving the dongle it came from, and against a dongle outliving its context —
the destructor order that triggers it is entirely ordinary. In Rust those are
lifetimes:

```rust
let session = {
    let dongle = ctx.open(None)?;
    dongle.open_session()?
};                       // error[E0597]: `dongle` does not live long enough
```

That does not compile, so the check that other bindings pay for at runtime costs
nothing here.

Threading follows the C ABI's contract: `Context` is `Send + Sync`, `Dongle` is
`Send` but not `Sync` (one thread at a time per device).

A panic inside a progress callback is caught at the FFI boundary, the transfer is
cancelled, and the panic is resumed once C is off the stack — unwinding through
an `extern "C"` frame is undefined behaviour, so it cannot simply propagate.

## Building

The native library is shipped as a prebuilt binary, so the crate
links against it rather than vendoring the C sources:

```
see NATIVES.md for the prebuilt library
KEYNUB_LIB_DIR=/path/to/native/ cargo build
```

| Variable | Meaning |
| --- | --- |
| `KEYNUB_LIB_DIR` | directory holding the library |
| `KEYNUB_LIB_NAME` | override the library name |
| `KEYNUB_STATIC=1` | link the static library and its platform dependencies |

At run time the shared library must be findable as usual (`PATH` on Windows,
rpath or `LD_LIBRARY_PATH` elsewhere). `KEYNUB_STATIC=1` avoids that entirely and
produces a single binary, which is usually what you want for a licensed product.

## `unsafe`

The safe API contains no `unsafe` that a caller can reach. Four functions are
`unsafe` on purpose, all of them escape hatches for mixing this crate with direct
FFI: `Context::as_raw`, `Dongle::as_raw`, `Context::adopt`, and the whole `sys`
module. `Context::adopt` in particular is how an existing codebase moves to this
crate one call at a time.

## Tests

`cargo test --test standin -- --ignored` runs without a dongle: it links a
stand-in for the C ABI (`bindings/julia/test/stub/licd_stub.c`, compiled into
`keynub_licdongle_standin`) and exercises every call of the binding against it.
The stand-in tests are ignored in a normal `cargo test`. Compile the stand-in
first. On Windows, in PowerShell with `zig cc` or MinGW-w64 `gcc` on the path:

```
mkdir -Force $env:TEMP\kn-rust > $null
zig cc -shared -O1 -DLICD_BUILD_SHARED -I../../include ../julia/test/stub/licd_stub.c -o $env:TEMP\kn-rust\keynub_licdongle_standin.dll "-Wl,--out-implib,$env:TEMP\kn-rust\keynub_licdongle_standin.lib"
$env:KEYNUB_LIB_DIR = "$env:TEMP\kn-rust"; $env:KEYNUB_LIB_NAME = "keynub_licdongle_standin"
$env:PATH = "$env:TEMP\kn-rust;$env:PATH"
cargo test --test standin -- --ignored
```

On Linux:

```
mkdir -p /tmp/kn-rust
cc -shared -fPIC -O1 -DLICD_BUILD_SHARED -I../../include ../julia/test/stub/licd_stub.c -o /tmp/kn-rust/libkeynub_licdongle_standin.so
KEYNUB_LIB_DIR=/tmp/kn-rust KEYNUB_LIB_NAME=keynub_licdongle_standin LD_LIBRARY_PATH=/tmp/kn-rust cargo test --test standin -- --ignored
```

## License

Apache-2.0, like the rest of the SDK. The native library statically links
Mbed TLS (Apache-2.0 elected) and hidapi (BSD-style elected) — see
[`../../THIRD-PARTY-NOTICES.txt`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/THIRD-PARTY-NOTICES.txt).

## Links

- [KeyNub License Dongle for Rust](https://www.keynub.com/developers/rust/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
