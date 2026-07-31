## KeyNub dongle check from Nim: enumerate -> open -> verify -> session ->
## read a record -> app-crypto round trip.
##
##   nim c --path:../../bindings/nim -d:keynubLib=keynub_licdongle -r verify_and_read.nim
##
## No dependencies: `importc` is part of the language and the library is resolved
## at run time through `dynlib`, so nothing needs to be linked.
##
## Targets real hardware: with no dongle attached it prints guidance and exits 0.
##
## READ FIRST: docs/integration-security.md. This sample prints whether the dongle
## is genuine, which is the one thing a real licence check must not do — a printed
## boolean is a deleted line away from nothing. `protectSomething` shows the shape
## that actually protects something.

import std/[strformat, strutils]
import keynub_licdongle

proc report(dongle: Dongle) =
  let i = dongle.getInfo()
  echo &"Protocol v{i.protocolVersion.major}.{i.protocolVersion.minor}, " &
       &"firmware v{i.firmwareVersion.major}.{i.firmwareVersion.minor}." &
       &"{i.firmwareVersion.patch}, {i.dataFree} of {i.dataCapacity} bytes free."

  if i.watchdogReboot:
    # The only trace a firmware hang leaves behind. Worth reporting to support.
    echo "WARNING: this dongle's previous boot ended in a watchdog reset."

  let r = dongle.verifyGenuine()
  echo &"Genuine: {r.genuine} (serial {r.serial}, batch {r.batch})"

proc readRecords(s: Session) =
  let records = s.listRecords()
  echo &"{records.len} record(s) on the dongle:"
  for rec in records:
    echo "  " & rec.name.alignLeft(16) & ($rec.size).align(6) & " bytes"

  # A missing record is a normal state, not an error.
  for rec in records:
    if rec.name == "license":
      let data = s.readRecord("license")
      echo &"Read {data.len} bytes from the license record."
      break

## The part that actually protects something. At licence-issue time you would call
## appEncrypt once, with a developer dongle, and ship only the blob; the program then
## cannot proceed without a dongle, because it holds no other copy of the data.
## Developer scope lets any dongle from your batch decrypt it, so one file serves
## every customer; Device scope locks it to one dongle.
proc protectSomething(s: Session) =
  const text = "the data this program cannot run without"
  let needed = @(text.toOpenArrayByte(0, text.high))

  let sealed = s.appEncrypt(scopeDeveloper, needed)
  let recovered = s.appDecrypt(sealed)

  let outcome = if recovered == needed: "recovered intact" else: "MISMATCH"
  echo &"App-crypto round trip: {needed.len} bytes -> {sealed.len} sealed -> {outcome}"

proc run() =
  let ctx = newContext()
  defer: ctx.close()

  let devices = ctx.enumerateDongles()
  echo &"Found {devices.len} KeyNub dongle(s)."
  for i, d in devices:
    echo &"  [{i}] serial {d.serial} (VID {d.vendorId.toHex(4)} PID {d.productId.toHex(4)})"
  if devices.len == 0:
    echo "No dongle attached; nothing to do."
    return

  # No serial = first dongle found; pass one to pick a specific dongle.
  let dongle = ctx.open()
  defer: dongle.close()
  report(dongle)

  let session = dongle.openSession()
  defer: session.close()
  readRecords(session)
  protectSomething(session)

when isMainModule:
  let v = libraryVersion()
  echo &"KeyNub SDK {v.major}.{v.minor}.{v.patch}"

  try:
    run()
  except LicenseDongleError as e:
    # The exception carries the SDK's diagnostic detail, which is what tells
    # "no dongle" from "certificate rejected".
    stderr.writeLine &"KeyNub error: {e.msg}"
    quit(1)
