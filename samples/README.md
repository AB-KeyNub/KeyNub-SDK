# KeyNub SDK samples

Each `verify_and_read` sample runs the same flow: enumerate a dongle, verify its
authenticity, open an encrypted session, read a `license` record (if present),
and round-trip app-data encryption. All target **real hardware** — with no dongle
attached they print guidance and exit 0.

## Taking ownership of a new dongle

A dongle ships holding KeyNub's write-auth key, and the first thing to do with a
delivery is replace it with your own — after which only your key can write
records, erase them or increment counters.

**There is a `rotate_write_key` sample in every language below**, listed in the
second column of the table. Each takes two file paths — the key the dongle holds
now and your replacement, both P-256 private keys in PKCS#8 DER — and runs the
same sequence: elevate with the current key, rotate to yours, then re-open a
session and confirm the old key is refused and the new one works. That
confirmation is the part worth copying: a rotation that returned success and
changed nothing looks identical without it.

The key a dongle arrives holding is **in this repository**, at
[`keys/keynub-shipping-writeauth.key.der`](../keys) — it is the same for every dongle
and every customer, so it is not a secret. [`keys/README.md`](../keys/README.md) says
what it does and does not grant; the short version is that an un-rotated dongle
takes writes from anyone holding it, including a rotation to a key you would not
have. Generate your replacement with:

```
openssl ecparam -name prime256v1 -genkey -noout |
  openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
```

Then check it took, across the whole delivery — `get_info` reports `writeauth_rotated`,
and a dongle reporting false is still on the published key.

[`python/rotate_write_key.py`](python/rotate_write_key.py) is the commented
reference, and the only one that will also generate the key for you
(`--generate`). The call is one method in every binding, named the way that
binding names things: `rotate_write_key`, `rotateWriteKey`, `RotateWriteKey`. It
needs the write role first, because holding it is what proves the key being
replaced was yours to replace.

**The replacement key is worth what your licence-signing key is worth.** It
cannot be recovered from a dongle, and a unit rotated to a key you have lost
needs to come back to be re-provisioned.

| Language | verify and read | take ownership | Consumes |
|---|---|---|---|
| C#  | [`csharp/verify_and_read`](csharp/verify_and_read) | [`csharp/rotate_write_key`](csharp/rotate_write_key) | the .NET binding (`KeyNub.LicenseDongle`) |
| C   | [`c/verify_and_read`](c/verify_and_read) | [`c/rotate_write_key`](c/rotate_write_key) | the core `licdongle.h` ABI + static lib |
| Python | [`python/verify_and_read.py`](python/verify_and_read.py) | [`python/rotate_write_key.py`](python/rotate_write_key.py) | the Python binding (`keynub-licdongle`) |
| Java | [`java/VerifyAndRead.java`](java/VerifyAndRead.java) | [`java/RotateWriteKey.java`](java/RotateWriteKey.java) | the Java binding (JNA) |
| Delphi | [`delphi/VerifyAndRead.dpr`](delphi/VerifyAndRead.dpr) | [`delphi/RotateWriteKey.dpr`](delphi/RotateWriteKey.dpr) | `LicDongle.pas` + the shared library |
| MATLAB | [`matlab/verify_and_read.m`](matlab/verify_and_read.m) | [`matlab/rotate_write_key.m`](matlab/rotate_write_key.m) | the MATLAB binding (`+keynub`) |
| Node.js | [`nodejs/verify_and_read.js`](nodejs/verify_and_read.js) | [`nodejs/rotate_write_key.js`](nodejs/rotate_write_key.js) | the Node binding (`@keynub/licdongle`) |
| VB.NET | [`vbnet/verify_and_read`](vbnet/verify_and_read) | [`vbnet/rotate_write_key`](vbnet/rotate_write_key) | the .NET binding, from Visual Basic |
| F# | [`fsharp/verify_and_read`](fsharp/verify_and_read) | [`fsharp/rotate_write_key`](fsharp/rotate_write_key) | the .NET binding, from F# |
| Ruby | [`ruby/verify_and_read.rb`](ruby/verify_and_read.rb) | [`ruby/rotate_write_key.rb`](ruby/rotate_write_key.rb) | the Ruby binding (`keynub_licdongle`) |
| VB6 | [`vb6/modMain.bas`](vb6/modMain.bas) | [`vb6/modRotate.bas`](vb6/modRotate.bas) | the COM server (`KeyNub.Dongle`) |
| twinBASIC | [`twinbasic/KeyNubDemo.twin`](twinbasic/KeyNubDemo.twin) | [`twinbasic/KeyNubRotate.twin`](twinbasic/KeyNubRotate.twin) | the COM server, 32- or 64-bit |
| C++ | [`cpp/verify_and_read`](cpp/verify_and_read) | [`cpp/rotate_write_key`](cpp/rotate_write_key) | the header-only C++ binding |
| Rust | [`rust/verify_and_read`](rust/verify_and_read) | [`rust/rotate_write_key`](rust/rotate_write_key) | the Rust crate (`keynub-licdongle`) |
| Go | [`go/verify_and_read`](go/verify_and_read) | [`go/rotate_write_key`](go/rotate_write_key) | the Go binding (cgo) |
| Zig | [`zig/verify_and_read.zig`](zig/verify_and_read.zig) | [`zig/rotate_write_key.zig`](zig/rotate_write_key.zig) | the Zig binding (`@cImport`) |
| Fortran | [`fortran/verify_and_read`](fortran/verify_and_read) | [`fortran/rotate_write_key`](fortran/rotate_write_key) | the Fortran 2003 module, over the flat API |
| COBOL | [`cobol/verify-and-read.cbl`](cobol/verify-and-read.cbl) | [`cobol/rotate-write-key.cbl`](cobol/rotate-write-key.cbl) | the COBOL copybook, over the flat API |
| PHP | [`php/verify_and_read.php`](php/verify_and_read.php) | [`php/rotate_write_key.php`](php/rotate_write_key.php) | the PHP binding (bundled FFI) |
| Perl | [`perl/verify_and_read.pl`](perl/verify_and_read.pl) | [`perl/rotate_write_key.pl`](perl/rotate_write_key.pl) | the Perl binding (`FFI::Platypus`), over the flat API |
| Lua | [`lua/verify_and_read.lua`](lua/verify_and_read.lua) | [`lua/rotate_write_key.lua`](lua/rotate_write_key.lua) | the Lua binding (LuaJIT FFI) |
| Julia | [`julia/verify_and_read.jl`](julia/verify_and_read.jl) | [`julia/rotate_write_key.jl`](julia/rotate_write_key.jl) | the Julia binding (`ccall`) |
| Nim | [`nim/verify_and_read.nim`](nim/verify_and_read.nim) | [`nim/rotate_write_key.nim`](nim/rotate_write_key.nim) | the Nim binding (`importc`) |
| Excel / VBA | [`vba/verify_and_read.bas`](vba/verify_and_read.bas) | [`vba/rotate_write_key.bas`](vba/rotate_write_key.bas) | the VBA module, over the flat API |
| LabVIEW | [`labview/README.md`](labview/README.md) | [`labview/README.md`](labview/README.md#taking-ownership-of-a-new-dongle) | Call Library Function nodes, over the flat API |
| flat API | [`flat/verify_and_read.c`](flat/verify_and_read.c) | [`flat/rotate_write_key.c`](flat/rotate_write_key.c) | the flat companion API directly |

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
either.

LabVIEW gets **wiring instructions rather than a `.vi`**, and Excel gets a `.bas`
rather than an `.xlsm`, on purpose: both binary formats are unreviewable in a diff,
and a `.vi` would pin the sample to one LabVIEW version.

Each sample's header comment carries the exact command that builds and runs it.

**Nothing points them at the native library.** A clone carries one per platform under
[`natives/`](../natives), and every binding that loads its library at run time looks
there by itself — .NET, Python, Node.js, PHP, Ruby, Lua and Julia samples run from a
checkout with nothing set. `KEYNUB_LICDONGLE_LIBRARY` still overrides it, which is
what the flat-API samples use when they want `keynub_licdongle_flat` instead of the
core library: Fortran, COBOL, Perl, VBA and LabVIEW go through the flat companion,
and pointing one at the core library reports a missing `licdf_*` symbol rather than
anything about the library.

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
dotnet run --project samples/csharp/rotate_write_key -- keys/keynub-shipping-writeauth.key.der my-key.der
```

The project references the binding directly and copies the native library beside the
sample, taking it from `natives/<rid>/` for the platform it is building for. A real
application would instead `dotnet add package KeyNub.LicenseDongle`, which brings
the native automatically. VB.NET and F# build the same way, with their own project
under `vbnet/` and `fsharp/`.

In Visual Studio, open the `.sln` beside the sample, not the project file. Each one
holds both the sample and the `KeyNub.LicenseDongle` project it references, which is
what Visual Studio restores from — a project reference to a project outside the open
solution carries no restore information. All six samples under `csharp/`, `fsharp/`
and `vbnet/` have one.

To build against a library from somewhere else — a release archive, or your own
build — set `KeynubNativeDir`, either as `-p:KeynubNativeDir=...` or as an
environment variable, which is the practical form for a build started from an IDE.
The build warns when neither that directory nor `natives/` holds a library: the
sample would otherwise compile and stop at its first call with
`DllNotFoundException`, which names nothing useful.

## C

Compile it against the libraries in this repository, or against a release archive:

```
cc verify_and_read.c   -Iinclude -Lnatives/linux-x64 -lkeynub_licdongle -o verify_and_read
cc rotate_write_key.c  -Iinclude -Lnatives/linux-x64 -lkeynub_licdongle -o rotate_write_key
```

Linking is not loading: the finished program looks for the shared library by name at
startup, on the operating system's search path. Copy it next to the executable, or
put `natives/<platform>` on `PATH` / `LD_LIBRARY_PATH` / `DYLD_LIBRARY_PATH` before
running. The bindings that load their library at run time have none of this to do —
they find `natives/` themselves.

Building the SDK from source instead? `-DLICD_BUILD_SAMPLES=ON` produces the same
programs as the `sample_verify_and_read` and `sample_rotate_write_key` targets,
along with the C++ and flat-API pair.

## MATLAB / Simulink

```matlab
addpath('bindings/matlab');   % needs the MEX gateway — see that folder's README
verify_and_read
rotate_write_key('keys/keynub-shipping-writeauth.key.der', 'my-key.der')
licence_protected_parameters
keynub_license_gate               % builds and opens the Simulink demo model
```

See [`../bindings/matlab/README.md`](../bindings/matlab/README.md) for the MEX
gateway build.
