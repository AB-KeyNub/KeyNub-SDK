#!/bin/sh
# Builds the crate with Alire, compiles the C ABI stand-in (the SDK's
# bindings/julia/test/stub/licd_stub.c) with cc, builds the test program and
# runs it against the stand-in. Exit code 0 when every check passed.
#
#   sh tests/run.sh          # from bindings/ada, with alr and gprbuild on the path
set -eu
here=$(cd "$(dirname "$0")" && pwd)
crate=$(dirname "$here")
root=$(cd "$crate/../.." && pwd)

stub_src="${KEYNUB_STUB_SOURCE:-$root/bindings/julia/test/stub/licd_stub.c}"
if [ -f "$root/include/licdongle.h" ]; then include="$root/include"; else include="$root/core/include"; fi
out=$(mktemp -d)
case "$(uname -s)" in
    Darwin) lib="$out/liblicd_stub.dylib" ;;
    *)      lib="$out/liblicd_stub.so" ;;
esac
cc -shared -fPIC -O1 -DLICD_BUILD_SHARED -I "$include" -o "$lib" "$stub_src"

cd "$crate"
alr -n build
# gprbuild from Alire's toolchain, the one the crate was configured for.
alr -n exec -- gprbuild -q -P tests/keynub_licdongle_tests.gpr
KEYNUB_LICDONGLE_LIBRARY="$lib" ./tests/bin/test_stub
