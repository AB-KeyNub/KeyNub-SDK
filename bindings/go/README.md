# KeyNub License Dongle — Go binding

cgo binding over the SDK's C ABI. Go 1.17+ (for `runtime/cgo.Handle`), Windows /
Linux / macOS.

```go
ctx, err := keynub.NewContext()
defer ctx.Close()

dongle, err := ctx.Open("")          // first dongle, or a serial
defer dongle.Close()
if _, err := dongle.VerifyGenuine(); err != nil { /* not genuine */ }

session, err := dongle.OpenSession()
defer session.Close()
data, err := session.AppDecrypt(blob) // <- build your licence check on this
```

> Read [`../../docs/integration-security.md`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/docs/integration-security.md)
> first. `if licensed { }` is one line to delete from a Go binary too. Route
> something the program needs through `AppEncrypt`/`AppDecrypt` instead.

## Building

cgo needs to find the native library, and its directory is not knowable at compile
time:

```
see NATIVES.md for the prebuilt library
CGO_LDFLAGS="-L/path/to/native/" go build
```

Headers are found automatically (`#cgo CFLAGS: -I${SRCDIR}/../../include`).
At run time the shared library must be findable as usual — `PATH` on Windows,
rpath or `LD_LIBRARY_PATH` elsewhere.

On Windows cgo uses **gcc**, not MSVC, so you need MinGW-w64 (for example the
portable [WinLibs](https://winlibs.com/) build) and a matching GCC build of the
SDK. Nothing else changes.

**A path containing `#` breaks cgo.** `#cgo` directives are parsed line by line
and `#` starts a comment, so `${SRCDIR}` expanding to something like
`C:\work\#proj\SDK` fails with `malformed #cgo argument`. That is a cgo
limitation, not a KeyNub one; keep the checkout out of such a path, or reach it
through a symlink or junction.

## Errors

Every failure is a `*keynub.Error` carrying `Status`, `Op` and the SDK's
diagnostic `Detail`. It implements `Is`, so the idiomatic form works:

```go
if errors.Is(err, keynub.ErrNoDevice) {
    return fmt.Errorf("please insert your KeyNub dongle: %w", err)
}
```

Sentinels exist for the statuses a caller plausibly branches on — `ErrNoDevice`,
`ErrAccessDenied`, `ErrNotGenuine`, `ErrCertificateInvalid`, `ErrSessionExpired`,
`ErrNotFound`, `ErrAuthRequired`, `ErrCancelled`, `ErrTagMismatch`. For anything
else, compare `Error.Status`.

`dongle.IsGenuine()` is the non-erroring form for a gate, and **fails closed**: a
missing dongle, an I/O error and an invalid certificate all report `false`.

## Concurrency

`Context` is safe for concurrent use. A `Dongle` must be used by one goroutine at
a time — the C ABI's rule, not an artefact of the binding. Guard it with a mutex,
or own it from a single goroutine and pass requests in on a channel.

A progress callback that panics does not unwind through the cgo frame (that is
undefined behaviour). The panic is captured at the boundary, the transfer is
cancelled, and it is re-raised in your goroutine once C is off the stack.

## Tests

`go test -tags keynub_standin` runs without a dongle: it links a stand-in for the
C ABI (`bindings/julia/test/stub/licd_stub.c`, compiled into
`keynub_licdongle_standin` and linked under the name `keynub_licdongle`) and
exercises every call of the binding against it. Compile the stand-in first. On
Windows, in PowerShell with MinGW-w64 gcc on the path:

```
mkdir -Force $env:TEMP\kn-go > $null
gcc -shared -O1 -DLICD_BUILD_SHARED -I../../include ../julia/test/stub/licd_stub.c -o $env:TEMP\kn-go\keynub_licdongle_standin.dll "-Wl,--out-implib,$env:TEMP\kn-go\libkeynub_licdongle.dll.a"
$env:CGO_LDFLAGS = "-L$env:TEMP\kn-go"; $env:PATH = "$env:TEMP\kn-go;$env:PATH"
go test -tags keynub_standin
```

On Linux:

```
mkdir -p /tmp/kn-go
cc -shared -fPIC -O1 -DLICD_BUILD_SHARED -I../../include -Wl,-soname,libkeynub_licdongle_standin.so ../julia/test/stub/licd_stub.c -o /tmp/kn-go/libkeynub_licdongle_standin.so
ln -sf libkeynub_licdongle_standin.so /tmp/kn-go/libkeynub_licdongle.so
CGO_LDFLAGS=-L/tmp/kn-go LD_LIBRARY_PATH=/tmp/kn-go go test -tags keynub_standin
```

## License

Apache-2.0, like the rest of the SDK — see
[`../../LICENSE`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/LICENSE) and
[`../../THIRD-PARTY-NOTICES.txt`](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/THIRD-PARTY-NOTICES.txt).

## Links

- [KeyNub License Dongle for Go](https://www.keynub.com/developers/go/): the product, and how to
  order one
- [Source, samples and issue tracker](https://github.com/AB-KeyNub/KeyNub-SDK) on GitHub
- [Native library for your platform](https://github.com/AB-KeyNub/KeyNub-SDK/blob/master/NATIVES.md)
