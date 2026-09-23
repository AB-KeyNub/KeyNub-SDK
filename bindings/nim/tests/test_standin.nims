# Configuration for tests/test_standin.nim only: compiles the C ABI stand-in
# (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
# into the temp directory with the first C compiler found of cc, gcc, clang,
# zig cc and cl, and points the binding at it through -d:keynubLib. The test
# binary and the nimcache go to the temp directory as well. KEYNUB_SDK_ROOT
# names the SDK sources when the test does not run inside a clone.

import std/[os, strutils]

proc sdkRoot(): string =
  if existsEnv("KEYNUB_SDK_ROOT") and getEnv("KEYNUB_SDK_ROOT").len > 0:
    return getEnv("KEYNUB_SDK_ROOT")
  var dir = thisDir()
  while true:
    if fileExists(dir / "bindings" / "flat" / "licd_flat.c"):
      return dir
    let parent = parentDir(dir)
    if parent.len == 0 or parent == dir:
      break
    dir = parent
  echo "the SDK sources were not found above ", thisDir(), "; set KEYNUB_SDK_ROOT"
  quit(1)

let root = sdkRoot()
let tmp = (if defined(windows): getEnv("TEMP") else: getEnv("TMPDIR", "/tmp")) / "keynub-standin-nim"
mkDir(tmp)
# Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf name.
let output = tmp / (when defined(windows): "keynub_licdongle_standin.dll"
                    elif defined(macosx): "libkeynub_licdongle_standin.dylib"
                    else: "libkeynub_licdongle_standin.so")
let incDir = if fileExists(root / "core" / "include" / "licdongle.h"): root / "core" / "include"
              else: root / "include"
let source = root / "bindings" / "julia" / "test" / "stub" / "licd_stub.c"

let gccArgs = " -shared -O1 -DLICD_BUILD_SHARED -I" & quoteShell(incDir) & " -o " &
              quoteShell(output) & " " & quoteShell(source) &
              (when defined(windows): "" else: " -fPIC")
let clArgs = " /nologo /LD /O1 /DLICD_BUILD_SHARED /I" & quoteShell(incDir) &
             " /Fo" & quoteShell(tmp / "licd_stub.obj") & " /Fe:" & quoteShell(output) & " " & quoteShell(source)

var built = false
for command in ["cc" & gccArgs, "gcc" & gccArgs, "clang" & gccArgs, "zig cc" & gccArgs, "cl" & clArgs]:
  if gorgeEx(command).exitCode == 0 and fileExists(output):
    built = true
    break
if not built:
  echo "the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path"
  quit(1)

# Forward slashes: the define is a string literal in the binding.
switch("define", "keynubLib=" & output.replace('\\', '/'))
switch("outdir", tmp)
switch("nimcache", tmp / "nimcache")
