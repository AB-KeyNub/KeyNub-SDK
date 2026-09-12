# KeyNub License Dongle SDK

Host SDK for the [KeyNub](https://www.keynub.com) USB-C license dongle — language
bindings and samples over one core C library (`keynub_licdongle`, prefix `licd_`)
with a stable C ABI. Windows, Linux and macOS, with **no driver to install**: the
dongle is a vendor-defined USB HID device.

[![NuGet](https://img.shields.io/nuget/v/KeyNub.LicenseDongle?label=NuGet)](https://www.nuget.org/packages/KeyNub.LicenseDongle)
[![PyPI](https://img.shields.io/pypi/v/keynub-licdongle?label=PyPI)](https://pypi.org/project/keynub-licdongle/)
[![npm](https://img.shields.io/npm/v/%40keynub%2Flicdongle?label=npm)](https://www.npmjs.com/package/@keynub/licdongle)
[![crates.io](https://img.shields.io/crates/v/keynub-licdongle?label=crates.io)](https://crates.io/crates/keynub-licdongle)
[![RubyGems](https://img.shields.io/gem/v/keynub_licdongle?label=RubyGems)](https://rubygems.org/gems/keynub_licdongle)
[![LuaRocks](https://img.shields.io/luarocks/v/ab-tools/keynub-licdongle?label=LuaRocks)](https://luarocks.org/modules/ab-tools/keynub-licdongle)
[![Packagist](https://img.shields.io/packagist/v/keynub/licdongle?label=Packagist)](https://packagist.org/packages/keynub/licdongle)
[![Maven Central](https://img.shields.io/maven-central/v/com.keynub/keynub-licdongle?label=Maven%20Central)](https://central.sonatype.com/artifact/com.keynub/keynub-licdongle)
[![Go module](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fproxy.golang.org%2Fgithub.com%2F!a!b-!key!nub%2F!key!nub-!s!d!k%2Fbindings%2Fgo%2F%40latest&query=%24.Version&label=Go%20module&logo=go)](https://pkg.go.dev/github.com/AB-KeyNub/KeyNub-SDK/bindings/go)
[![CMake package](https://img.shields.io/github/v/tag/AB-KeyNub/KeyNub-SDK?label=CMake%20package)](NATIVES.md)
[![NuGet](https://img.shields.io/nuget/v/KeyNub.LicenseDongle.Native?label=NuGet%20native)](https://www.nuget.org/packages/KeyNub.LicenseDongle.Native)

> **Before you write your licensing check, read
> [`docs/integration-security.md`](docs/integration-security.md).** The dongle
> proves a genuine device is attached; it cannot stop an attacker patching the
> application that asks. An integration that branches on a boolean is bypassed
> trivially — feed something your application actually needs through
> `app_encrypt`/`app_decrypt` instead. That document is short, and it is the
> difference between real protection and a speed bump.

## Getting started

1. **Pick the native library** for your platform from [`natives/`](natives/) —
   [`NATIVES.md`](NATIVES.md) says which file is which.
2. **Install the binding** for your language, or drop its source into your project.
3. Enumerate, verify, open a session, read your licence data. Each binding's
   README shows the whole flow in a dozen lines.

The API surface is the same everywhere, because every binding is a thin layer over
the same ABI — declared in [`include/licdongle.h`](include/licdongle.h). Learn it
once.

## Languages

| Language | Binding | Sample | Package |
| --- | --- | --- | --- |
| C | [`include/licdongle.h`](include/licdongle.h) — CMake target `keynub::licdongle` | [`samples/c`](samples/c) | [![CMake package](https://img.shields.io/github/v/tag/AB-KeyNub/KeyNub-SDK?label=CMake%20package)](NATIVES.md) [![NuGet](https://img.shields.io/nuget/v/KeyNub.LicenseDongle.Native?label=NuGet%20native)](https://www.nuget.org/packages/KeyNub.LicenseDongle.Native) |
| C++ | [`bindings/cpp`](bindings/cpp) — header-only RAII, C++11, CMake target `keynub::licdongle_cpp` | [`samples/cpp`](samples/cpp) | [![CMake package](https://img.shields.io/github/v/tag/AB-KeyNub/KeyNub-SDK?label=CMake%20package)](NATIVES.md) [![NuGet](https://img.shields.io/nuget/v/KeyNub.LicenseDongle.Native?label=NuGet%20native)](https://www.nuget.org/packages/KeyNub.LicenseDongle.Native) |
| flat API | [`bindings/flat`](bindings/flat) — integer handles, no callbacks | [`samples/flat`](samples/flat) | — |
| C# / VB.NET / F# | [`bindings/dotnet`](bindings/dotnet) — `KeyNub.LicenseDongle` | [`samples/csharp`](samples/csharp), [`samples/vbnet`](samples/vbnet), [`samples/fsharp`](samples/fsharp) | [![NuGet](https://img.shields.io/nuget/v/KeyNub.LicenseDongle?label=NuGet)](https://www.nuget.org/packages/KeyNub.LicenseDongle) |
| Python | [`bindings/python`](bindings/python) — `keynub-licdongle`, ctypes, plus the `licd-tool` CLI | [`samples/python`](samples/python) | [![PyPI](https://img.shields.io/pypi/v/keynub-licdongle?label=PyPI)](https://pypi.org/project/keynub-licdongle/) |
| Java | [`bindings/java`](bindings/java) — JNA, Java 17+ | [`samples/java`](samples/java) | [![Maven Central](https://img.shields.io/maven-central/v/com.keynub/keynub-licdongle?label=Maven%20Central)](https://central.sonatype.com/artifact/com.keynub/keynub-licdongle) |
| Delphi / Free Pascal | [`bindings/delphi`](bindings/delphi) | [`samples/delphi`](samples/delphi) | — |
| Visual Basic 6 / VBScript | [`bindings/com`](bindings/com) — COM object `KeyNub.Dongle` | [`samples/vb6`](samples/vb6) | — |
| twinBASIC | [`bindings/com`](bindings/com) | [`samples/twinbasic`](samples/twinbasic) | — |
| Excel / VBA | [`bindings/vba`](bindings/vba) | [`samples/vba`](samples/vba) | — |
| MATLAB / Simulink | [`bindings/matlab`](bindings/matlab) — MEX gateway, incl. MATLAB Coder output | [`samples/matlab`](samples/matlab), [`samples/simulink`](samples/simulink) | — |
| LabVIEW | [`bindings/labview`](bindings/labview) | [`samples/labview`](samples/labview) | — |
| Node.js / Electron | [`bindings/nodejs`](bindings/nodejs) — `@keynub/licdongle` | [`samples/nodejs`](samples/nodejs) | [![npm](https://img.shields.io/npm/v/%40keynub%2Flicdongle?label=npm)](https://www.npmjs.com/package/@keynub/licdongle) |
| Go | [`bindings/go`](bindings/go) — cgo, `errors.Is` sentinels | [`samples/go`](samples/go) | [![Go module](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fproxy.golang.org%2Fgithub.com%2F!a!b-!key!nub%2F!key!nub-!s!d!k%2Fbindings%2Fgo%2F%40latest&query=%24.Version&label=Go%20module&logo=go)](https://pkg.go.dev/github.com/AB-KeyNub/KeyNub-SDK/bindings/go) |
| Rust | [`bindings/rust`](bindings/rust) — `keynub-licdongle`, no dependencies | [`samples/rust`](samples/rust) | [![crates.io](https://img.shields.io/crates/v/keynub-licdongle?label=crates.io)](https://crates.io/crates/keynub-licdongle) |
| Ruby | [`bindings/ruby`](bindings/ruby) — stdlib Fiddle, no gems | [`samples/ruby`](samples/ruby) | [![RubyGems](https://img.shields.io/gem/v/keynub_licdongle?label=RubyGems)](https://rubygems.org/gems/keynub_licdongle) |
| PHP | [`bindings/php`](bindings/php) — bundled FFI, no PECL module | [`samples/php`](samples/php) | [![Packagist](https://img.shields.io/packagist/v/keynub/licdongle?label=Packagist)](https://packagist.org/packages/keynub/licdongle) |
| Perl | [`bindings/perl`](bindings/perl) — `FFI::Platypus` | [`samples/perl`](samples/perl) | — |
| Lua | [`bindings/lua`](bindings/lua) — LuaJIT FFI | [`samples/lua`](samples/lua) | [![LuaRocks](https://img.shields.io/luarocks/v/ab-tools/keynub-licdongle?label=LuaRocks)](https://luarocks.org/modules/ab-tools/keynub-licdongle) |
| Fortran | [`bindings/fortran`](bindings/fortran) — F2003 `iso_c_binding` | [`samples/fortran`](samples/fortran) | — |
| COBOL | [`bindings/cobol`](bindings/cobol) — copybook, GnuCOBOL | [`samples/cobol`](samples/cobol) | — |
| Zig | [`bindings/zig`](bindings/zig) — `@cImport` compiles the real header | [`samples/zig`](samples/zig) | — |
| Julia | [`bindings/julia`](bindings/julia) — `ccall`, no packages | [`samples/julia`](samples/julia) | — |
| Nim | [`bindings/nim`](bindings/nim) — `importc` over `dynlib` | [`samples/nim`](samples/nim) | — |

Every sample carries the exact command that builds and runs it in its header
comment, including which native library it wants. All of them except **Excel/VBA**
and **LabVIEW** were compiled and run against a software dongle before release;
those two need Excel and a licensed LabVIEW respectively, so they are written
against the API and reviewed rather than executed. LabVIEW ships wiring
instructions rather than a `.vi`, and Excel a `.bas` rather than an `.xlsm`,
because neither binary format can be reviewed in a diff.

Environments that cannot express the core ABI — LabVIEW, VBA, COBOL — go through
a **flat companion API** ([`bindings/flat`](bindings/flat)): one self-contained
library with integer handles, caller-allocated buffers and no callbacks.

Visual Basic 6 gets a COM object rather than `Declare` statements for a specific
reason: VB6's `Declare` emits **stdcall** while the flat API is **cdecl**. That is
harmless in a 64-bit process and a stack-drifting mismatch in a 32-bit one, and
VB6 is 32-bit only. Going through an object removes the question — and adds a
handle that closes itself and failures that raise with a real `Err.Description`.

## Where the licence check belongs

The shortest useful version of `docs/integration-security.md`:

```
// Weak — one patched branch defeats it, in any language.
if (dongle.IsGenuine) enableFeature();

// Strong — the data your program needs only exists with the dongle present.
coefficients = dongle.AppDecrypt(blobShippedWithYourInstaller);
```

Encrypt the constants, tables, thresholds or key material your application
genuinely cannot compute. Ship them encrypted. Decrypt them through the dongle at
run time. Then removing the check does not unlock the feature — it removes the
feature's input.

## Trust root

`verify_genuine` validates the device certificate chain against the KeyNub
production root CA, whose public certificate is compiled into the released library —
so a substituted device fails verification and your application supplies nothing and
manages no root. `licd_set_trust_root` (or the equivalent on your binding) overrides
the built-in root, which only vendor tooling needs.

## Licence

Everything in this repository — the bindings, the samples and the C ABI
header — is Apache-2.0. See [`LICENSE`](LICENSE), [`NOTICE`](NOTICE) and
[`THIRD-PARTY-NOTICES.txt`](THIRD-PARTY-NOTICES.txt) for the dependency licence
elections.

The prebuilt native libraries in [`natives/`](natives/) are not covered by that
licence; their terms are in [`BINARY-LICENSE.txt`](BINARY-LICENSE.txt). You can
use them from an Apache-2.0 binding in a closed-source application either way —
that is what they are for.

Security reports: [`SECURITY.md`](SECURITY.md).

## Linux

Install [`packaging/linux/99-keynub-dongle.rules`](packaging/linux/99-keynub-dongle.rules)
into `/etc/udev/rules.d/` so the device is reachable without root. It is a
permission rule, **not** a driver — nothing is compiled or loaded into the kernel.
