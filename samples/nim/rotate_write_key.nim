## KeyNub SDK - Nim sample: take ownership of a new dongle.
##
## A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
## that from the next session onward only your key can write records, erase them or
## increment counters. Run it once per dongle, when it arrives.
##
## Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
##
##   openssl ecparam -name prime256v1 -genkey -noout |
##     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
##
## .. code-block::
##   nim c --path:../../bindings/nim -r rotate_write_key.nim ../../keys/keynub-shipping-writeauth.key.der my-key.der
##
## Targets real hardware: with no dongle attached it prints guidance and exits 0.
##
## The replacement key is worth what your licence-signing key is worth. It cannot be
## recovered from the dongle, and a unit rotated to a key you have lost has to come
## back to be re-provisioned.

import std/[os, strformat]
import keynub_licdongle

proc readKey(path: string): seq[uint8] =
  let raw = readFile(path)
  result = newSeq[uint8](raw.len)
  if raw.len > 0:
    copyMem(addr result[0], unsafeAddr raw[0], raw.len)

proc run(): int =
  if paramCount() != 2:
    stderr.writeLine "usage: rotate_write_key <current-key.der> <new-key.der>"
    return 2
  let current = readKey(paramStr(1))
  let replacement = readKey(paramStr(2))

  let ctx = newContext()
  defer: ctx.close()

  if ctx.enumerateDongles().len == 0:
    echo "Connect a KeyNub dongle and re-run."
    return 0

  let dongle = ctx.open()
  defer: dongle.close()
  echo &"dongle {dongle.getSerial()}"

  block:
    let session = dongle.openSession()
    defer: session.close()
    session.authorizeWrite(current)
    session.rotateWriteKey(replacement)
    echo "rotated: this dongle now answers only to your key"

  # A fresh session is the only place the change is observable: the session above
  # keeps the role it was already granted.
  block:
    let session = dongle.openSession()
    defer: session.close()
    try:
      session.authorizeWrite(current)
      stderr.writeLine "WARNING: the old key still works -- do not ship this unit"
      return 1
    except LicenseDongleError:
      echo "confirmed: the old key no longer elevates"
    session.authorizeWrite(replacement)
    echo "confirmed: your key elevates"

  echo ""
  echo "Keep the replacement key safe. Every future write to this dongle needs it."
  return 0

when isMainModule:
  try:
    quit(run())
  except LicenseDongleError as err:
    stderr.writeLine &"KeyNub error: {err.msg}"
    quit(1)
