# Nimble manifest.
#
# Publishing to Nimble is a pull request against nim-lang/packages adding a name,
# a URL and a method -- there is no upload. Nimble then resolves versions from the
# repository's git tags, so the tag is the release.
#
# The binding lives in a subdirectory of the SDK repository, so `srcDir` points at
# it relative to this file and the packages entry must give the repository URL
# with this directory as the package root.
#
# Apache-2.0 alone is correct: the package contains only the Nim source. The
# native keynub_licdongle library is loaded at run time, is not bundled here, and
# its terms are stated separately in BINARY-LICENSE.txt.

version       = "1.1.1"
author        = "KeyNub"
description   = "Nim binding for the KeyNub USB-C license dongle (driverless on Windows, Linux and macOS)"
license       = "Apache-2.0"
srcDir        = "."

# No dependencies beyond the compiler. dynlib is part of the standard library,
# which is the right shape for a licensing binding: nothing a customer could
# substitute in the path of the check.
requires "nim >= 1.6.0"

task test, "Run the end-to-end test":
  exec "nim c -r tests/test_end_to_end.nim"
