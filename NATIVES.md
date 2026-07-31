# Getting the native library

Every binding in this repository is a thin layer over one native library. That
library is distributed as a **prebuilt binary** — download it from the
[latest release](https://github.com/AB-KeyNub/KeyNub-SDK/releases/latest) rather than
building it yourself.

Later releases will also publish through the package registries (NuGet, PyPI, npm,
crates.io), at which point the managed-language bindings will pull the native
automatically and you can skip this page.

## Which download

One archive per platform, each self-contained — headers, libraries, licences, a
README and a `SHA256SUMS` covering its own contents:

| Asset | Contains |
| --- | --- |
| `keynub-sdk-<version>-windows.zip` | `include/`, `x64/`, `x86/` |
| `keynub-sdk-<version>-linux-x64.tar.gz` | `include/`, `lib/`, the udev rule |
| `keynub-sdk-<version>-macos-arm64.tar.gz` | `include/`, `lib/` |
| `keynub-sdk-<version>-SHA256SUMS` | checksums for the three archives |

The Linux build is x86_64 and the macOS build is arm64 (Apple Silicon). If you
need another architecture — aarch64 Linux, Intel macOS, a universal binary —
[ask us](https://www.keynub.com/#contact).

## What is in the archive

```
include/    licdongle.h        the core C ABI
            licd_flat.h        the flat companion API
            licd_labview.h     LabVIEW declarations over the flat API
x64/  x86/  Windows libraries, per architecture
lib/        Linux and macOS libraries
```

Each library folder holds the same three libraries, and **they are not
interchangeable**:

| File | Who needs it |
| --- | --- |
| `keynub_licdongle` | the core library — .NET, Python, Java, Node.js, Ruby, Lua, Julia, Nim, Go load it; C, C++, Rust and Zig link it |
| `keynub_licdongle_flat` | the flat companion API — LabVIEW, VBA, COBOL, Fortran and Perl |
| `KeyNub.dll` | the COM server — Visual Basic 6, twinBASIC, VBScript |

Import libraries (`.lib`) and a static library (`_static.lib` / `_static.a`) ship
alongside every architecture, for the bindings that link rather than load.

The Windows archive carries `x64/`, `x86/` and `arm64/`. On Windows on ARM the
choice between the last two is the same host-process question as everywhere else:
a native ARM64 application wants `arm64/`, while an x64 application running under
emulation wants `x64/`.

Pointing a flat-API binding at the core library, or the other way round, reports a
missing symbol (`licdf_*` or `licd_*`) rather than anything that says "wrong
library" — so it is worth checking the name if a first run fails that way.

**Match the architecture of your host process, not of your machine.** A 32-bit
application on 64-bit Windows needs the x86 library. This is the single most
common integration problem, and its symptoms are unhelpful: a
`DllNotFoundException`, a `BadImageFormatException`, or from COM the misleading
*"class not registered"*.

## Two kinds of binding

**Loaded at run time** — .NET, Python, Java, Node.js, Ruby, PHP, Perl, Lua,
Julia, Nim, Go. Put the shared library where the runtime will find it:

- alongside your executable or entry script (simplest, and works everywhere)
- or in a directory on `PATH` (Windows) / `LD_LIBRARY_PATH` (Linux) /
  `DYLD_LIBRARY_PATH` (macOS)
- or wherever your binding's README says it looks, if it looks somewhere specific

**Compiled against** — C, C++, Rust, Fortran, COBOL, Zig, LabVIEW, and the flat
API. These need [`include/licdongle.h`](include/licdongle.h) (in this repository)
at compile time and the library at link time. Point your build at the extracted
`include/` and library directory in the usual way for your toolchain.

## The COM server

`KeyNub.dll` in the release is the COM server used by Visual Basic 6, twinBASIC
and VBScript — a different file from `keynub_licdongle.dll`. Register it once with
the `regsvr32` matching its architecture:

```
C:\Windows\SysWOW64\regsvr32.exe KeyNub.dll     :: 32-bit, e.g. for VB6
C:\Windows\System32\regsvr32.exe KeyNub.dll     :: 64-bit
```

The type library is embedded as a resource, so there is one file to deploy and
registration-free activation also works. An unelevated `regsvr32` falls back to a
per-user registration rather than failing.

## Verifying what you downloaded

Each release publishes SHA-256 checksums. Check them before shipping a native
library inside your product — you are about to make it part of your licensing, so
it is worth thirty seconds:

```
sha256sum -c keynub-sdk-<version>-SHA256SUMS      # Linux / macOS
certutil -hashfile keynub_licdongle.dll SHA256    # Windows
```

## The trust root

`verify_genuine` validates the dongle's certificate chain against the KeyNub
production root CA, and these builds have it **compiled in**. So there is nothing
to configure: your application supplies no certificate, manages no root, and a
first run verifies a genuine dongle as it comes.

`licd_set_trust_root` (or its equivalent on your binding) overrides the built-in
root. Shipping an application never needs it. A library built with no root
embedded at all fails closed with `LICD_E_CERT_INVALID` rather than accepting any
device.

## Building it yourself

The core library's source is not part of this repository. If you have a
requirement that needs it — an unusual platform, a regulated build process that
forbids third-party binaries, source escrow — contact us through
<https://www.keynub.com/#contact> and we will sort something out.
