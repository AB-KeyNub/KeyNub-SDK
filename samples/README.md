# KeyNub SDK samples

Each `verify_and_read` sample runs the same flow: enumerate a dongle, verify its
authenticity, open an encrypted session, read a `license` record (if present),
and round-trip app-data encryption. All target **real hardware** — with no dongle
attached they print guidance and exit 0.

| Language | Path | Consumes |
|---|---|---|
| C#  | [`csharp/verify_and_read`](csharp/verify_and_read) | the .NET binding (`KeyNub.LicenseDongle`) |
| C   | [`c/verify_and_read`](c/verify_and_read) | the core `licdongle.h` ABI + static lib |
| Python | [`python/verify_and_read.py`](python/verify_and_read.py) | the Python binding (`keynub-licdongle`) |
| Java | [`java/VerifyAndRead.java`](java/VerifyAndRead.java) | the Java binding (JNA) |
| Delphi | [`delphi/VerifyAndRead.dpr`](delphi/VerifyAndRead.dpr) | `LicDongle.pas` + the shared library |
| MATLAB | [`matlab/verify_and_read.m`](matlab/verify_and_read.m) | the MATLAB binding (`+keynub`) |
| Node.js | [`nodejs/verify_and_read.js`](nodejs/verify_and_read.js) | the Node binding (`@keynub/licdongle`) |
| VB.NET | [`vbnet/verify_and_read`](vbnet/verify_and_read) | the .NET binding, from Visual Basic |
| F# | [`fsharp/verify_and_read`](fsharp/verify_and_read) | the .NET binding, from F# |
| Ruby | [`ruby/verify_and_read.rb`](ruby/verify_and_read.rb) | the Ruby binding (`keynub_licdongle`) |
| VB6 | [`vb6/KeyNubDemo.vbp`](vb6/KeyNubDemo.vbp) | the COM server (`KeyNub.Dongle`) |
| twinBASIC | [`twinbasic/KeyNubDemo.twin`](twinbasic/KeyNubDemo.twin) | the COM server, 32- or 64-bit |
| C++ | [`cpp/verify_and_read`](cpp/verify_and_read) | the header-only C++ binding |
| Rust | [`rust/verify_and_read`](rust/verify_and_read) | the Rust crate (`keynub-licdongle`) |
| Go | [`go/verify_and_read`](go/verify_and_read) | the Go binding (cgo) |
| Zig | [`zig/verify_and_read.zig`](zig/verify_and_read.zig) | the Zig binding (`@cImport`) |
| Fortran | [`fortran/verify_and_read`](fortran/verify_and_read) | the Fortran 2003 module, over the flat API |
| COBOL | [`cobol/verify-and-read.cbl`](cobol/verify-and-read.cbl) | the COBOL copybook, over the flat API |
| PHP | [`php/verify_and_read.php`](php/verify_and_read.php) | the PHP binding (bundled FFI) |
| Perl | [`perl/verify_and_read.pl`](perl/verify_and_read.pl) | the Perl binding (`FFI::Platypus`), over the flat API |
| Lua | [`lua/verify_and_read.lua`](lua/verify_and_read.lua) | the Lua binding (LuaJIT FFI) |
| Julia | [`julia/verify_and_read.jl`](julia/verify_and_read.jl) | the Julia binding (`ccall`) |
| Nim | [`nim/verify_and_read.nim`](nim/verify_and_read.nim) | the Nim binding (`importc`) |
| Excel / VBA | [`vba/verify_and_read.bas`](vba/verify_and_read.bas) | the VBA module, over the flat API |
| LabVIEW | [`labview/README.md`](labview/README.md) | Call Library Function nodes, over the flat API |
| flat API | [`flat/verify_and_read.c`](flat/verify_and_read.c) | the flat companion API directly |

There is no separate VB or F# binding: `KeyNub.LicenseDongle` is a .NET assembly, so
C#, VB and F# all consume the same package. Those two samples exist because the call
style differs enough to be worth showing. VB needs `Using` blocks, no `var`, and
`Option Strict On`, which is what you want for interop. F# replaces the nested
`Using` blocks with `use` bindings, the `Catch` ladder with pattern matching on the
exception type, and — because F# arrays compare structurally — the app-crypto
byte-comparison loop with a single `=`.

The VB6 and twinBASIC samples both drive the **COM** binding
([`../bindings/com`](../bindings/com)), so they need `KeyNub.dll` registered once with
the `regsvr32` matching their bitness — VB6 is 32-bit only, twinBASIC can build
either. The interface, type library, marshalling and error numbering they depend on
are tested on every push, on both architectures.

Every sample above except **Excel/VBA** and **LabVIEW** has been compiled (where it
compiles) and run against the software dongle on the development machine. VBA needs
Excel and LabVIEW needs a licensed install, neither of which is available here, so
those two are written against the real API and reviewed rather than executed.

LabVIEW gets **wiring instructions rather than a `.vi`**, and Excel gets a `.bas`
rather than an `.xlsm`, on purpose: both binary formats are unreviewable in a diff,
and a `.vi` would pin the sample to one LabVIEW version.

Each sample's header comment carries the exact command that builds and runs it,
including the environment variable that points at the native library — which differs
by binding. The ones over the flat companion API (Fortran, COBOL, Perl, VBA, LabVIEW)
want `keynub_licdongle_flat`, not the core `keynub_licdongle`; getting that wrong
reports a missing `licdf_*` symbol rather than anything about the library.

Two samples go beyond the common flow, because for MATLAB and Simulink the
interesting question is not "can I talk to the dongle" but "where does the check
go so that removing it costs something":

| Sample | Shows |
|---|---|
| [`matlab/licence_protected_parameters.m`](matlab/licence_protected_parameters.m) | gating on data the code needs (plant coefficients through `appEncrypt`/`appDecrypt`) instead of on a boolean |
| [`simulink/keynub_license_gate.m`](simulink/keynub_license_gate.m) | builds a dongle-gated Simulink model in code (no binary `.slx` to version) |
| [`matlab/codegen/`](matlab/codegen) | carries the licence check into **MATLAB Coder / Simulink Coder generated C**, where the MEX binding cannot go |

## C#

```
dotnet run --project samples/csharp/verify_and_read
```

The project references the binding directly and copies the native from the CMake
build output (`SDK/build`, override with `-p:KeynubNativeDir=...`). A real
application would instead `dotnet add package KeyNub.LicenseDongle`, which brings
the native automatically.

## C

Compile it against a release archive:

```
cc verify_and_read.c -Iinclude -Lx64 -lkeynub_licdongle -o verify_and_read
```

Building the SDK from source instead? `-DLICD_BUILD_SAMPLES=ON` produces the same
program as the `sample_verify_and_read` target.

## MATLAB / Simulink

```matlab
addpath('bindings/matlab');   % needs the MEX gateway — see that folder's README
verify_and_read
licence_protected_parameters
keynub_license_gate               % builds and opens the Simulink demo model
```

The MEX gateway these samples call is covered by the SDK's own test suite, and
`keynub_gate.c` (the codegen shim) is compiled as part of the samples build. See
[`../bindings/matlab/README.md`](../bindings/matlab/README.md) for the MEX gateway
build.

> The full flow (genuine → session → records → app-crypto) is exercised without
> hardware by the binding's test suite and the C test suite, both of which drive
> the in-process software dongle. These samples are usage examples for real dongles.
