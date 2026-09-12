# Getting the native library

Every binding in this repository is a thin layer over one native library, and it is
a **prebuilt binary** — you do not build it yourself.

## It is already here

A clone of this repository carries everything, per platform. There is nothing to
download separately and no release archive to look for:

```
natives/win-x64/      keynub_licdongle.dll   keynub_licdongle_flat.dll   KeyNub.dll
                      + the .lib import libraries, and keynub_licdongle_static.lib
natives/win-x86/                          "
natives/win-arm64/                        "
natives/linux-x64/    libkeynub_licdongle.so      libkeynub_licdongle_flat.so
                      libkeynub_licdongle_static.a
natives/linux-arm64/                      "
natives/osx-x64/      libkeynub_licdongle.dylib   libkeynub_licdongle_flat.dylib
                      libkeynub_licdongle_static.a   (universal binaries, both slices)
natives/osx-arm64/                        "
natives/MANIFEST.txt  the version, and a SHA-256 for every file above
```

The headers are in the repository too: [`include/licdongle.h`](include/licdongle.h)
for the core API, [`bindings/flat/licd_flat.h`](bindings/flat/licd_flat.h) for
the flat companion API, and
[`bindings/labview/licd_labview.h`](bindings/labview/licd_labview.h) for LabVIEW.

Every binding that loads its library at run time finds this directory by itself, so
the samples run from a clone with nothing set. The bindings that link at build time
find it too, where their build system can: point other toolchains at
`natives/<platform>` with the usual flag — `-Lnatives/linux-x64`, and so on.

`KEYNUB_LICDONGLE_LIBRARY` still overrides it everywhere, and still takes an
absolute path to one specific library.

The prebuilt libraries are under [`BINARY-LICENSE.txt`](BINARY-LICENSE.txt), not the
Apache-2.0 licence that covers the source in this repository.

The package registries are the other way to get them: the NuGet, PyPI and npm
packages carry the core library for every platform, so those bindings need
nothing from this folder.

## Which file

Each platform folder holds the same three libraries, and **they are not
interchangeable**:

| File | Who needs it |
| --- | --- |
| `keynub_licdongle` | the core library — .NET, Python, Java, Node.js, Ruby, Lua, Julia, Nim, Go load it; C, C++, Rust and Zig link it |
| `keynub_licdongle_flat` | the flat companion API — LabVIEW, VBA, COBOL, Fortran and Perl |
| `KeyNub.dll` | the COM server — Visual Basic 6, twinBASIC, VBScript (Windows only) |

Import libraries (`.lib`) and a static library (`_static.lib` / `_static.a`) sit
beside them for the bindings that link rather than load.

The Linux folders are x86_64 and aarch64; the macOS libraries are universal
binaries and serve Intel and Apple Silicon alike. On Windows on ARM the choice
between `win-arm64` and `win-x64` is the same host-process question as
everywhere else: a native ARM64 application wants `win-arm64`, while an x64
application running under emulation wants `win-x64`.

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
API. These need [`include/licdongle.h`](include/licdongle.h) (or the flat and
LabVIEW headers named above) at compile time and the library at link time:
`-Iinclude -Lnatives/<platform>`, or the equivalent for your toolchain. The
static library is there for the same toolchains when a single self-contained
executable is wanted. The Rust crate looks in `natives/` on its own
when it is built from a checkout.

One thing carries over from linking anywhere else: the finished executable loads
the shared library at **startup**, by name, from the operating system's search
path. Building against `natives/` does not put it there, so copy the library next
to the executable or add that directory to `PATH` / `LD_LIBRARY_PATH` /
`DYLD_LIBRARY_PATH` before running.

## The COM server

`KeyNub.dll` in each `natives/win-*` folder is the COM server used by Visual
Basic 6, twinBASIC and VBScript — a different file from `keynub_licdongle.dll`. Register it once with
the `regsvr32` matching its architecture:

```
C:\Windows\SysWOW64\regsvr32.exe KeyNub.dll     :: 32-bit, e.g. for VB6
C:\Windows\System32\regsvr32.exe KeyNub.dll     :: 64-bit
```

The type library is embedded as a resource, so there is one file to deploy and
registration-free activation also works. An unelevated `regsvr32` falls back to a
per-user registration rather than failing.

## Verifying what you have

`natives/MANIFEST.txt` lists a SHA-256 for every file in the folder, written by
the same tool that staged them from the build. Check it before shipping a native
library inside your product — you are about to make it part of your licensing, so
it is worth thirty seconds:

```
cd natives && grep -E '^[0-9a-f]{64} ' MANIFEST.txt | sha256sum -c     # Linux / macOS
certutil -hashfile natives\win-x64\keynub_licdongle.dll SHA256          # Windows: compare by eye
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
