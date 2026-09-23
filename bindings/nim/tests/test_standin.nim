## Every call of the binding against the C ABI stand-in:
## bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory,
## which tests/test_standin.nims compiles into the temp directory and points
## the binding at. No dongle and no native library needed:
##
## .. code-block::
##   nim c -r tests/test_standin.nim
##
## The stand-in keeps records, counters and the write key per opened device, so
## each test starts from a fresh dongle.

import std/[algorithm, sequtils, unittest]
import ../keynub_licdongle

const serial = "04A1B2C3D4E5F6"
const factoryKey = @[0x30'u8, 0x10, 0x01, 0x02, 0x03]
const replacementKey = @[0x30'u8, 0x11, 0x09, 0x08, 0x07, 0x06]

# The stand-in's own opener, for adopt.
proc licd_open(ctx: pointer; serial: cstring; outDev: var pointer): cint
  {.importc, dynlib: keynubLib, cdecl.}

proc bytes(text: string): seq[uint8] = text.mapIt(it.uint8)

template fails(T: typedesc; wanted: Status; body: untyped) =
  try:
    body
    checkpoint("no failure")
    fail()
  except T as e:
    check e.status == wanted

suite "KeyNub Nim binding against the ABI stand-in":

  test "version, devices and open":
    check libraryVersion() == (9, 8, 7)
    check statusText(sNoDevice) == "no device"

    let ctx = newContext()
    defer: ctx.close()
    check ctx.enumerateDongles() == @[DeviceInfo(serial: serial, path: "stub:0",
                                                 vendorId: 0x1234, productId: 0xABCD)]
    try:
      discard ctx.open("nope")
      fail()
    except DeviceNotFoundError as e:
      check e.status == sNoDevice
      check e.operation == "licd_open"
      check e.detail == "no dongle with that serial"
      check e.msg == "licd_open: no device (no dongle with that serial)"
    check ctx.lastErrorDetail() == "no dongle with that serial"
    fails(DeviceNotFoundError, sNoDevice):
      discard ctx.openPath("stub:9")

    for d in [ctx.open(), ctx.open(serial), ctx.openPath("stub:0")]:
      check d.getSerial() == serial
      d.close()

  test "info and genuine":
    let ctx = newContext()
    defer: ctx.close()
    let d = ctx.open()
    defer: d.close()
    check d.getInfo() == Info(protocolVersion: (1, 0), firmwareVersion: (2, 3, 4),
                              seReady: true, provisioned: true,
                              dataCapacity: 1024 * 1024, dataFree: 1_000_000,
                              watchdogReboot: false, isolated: true, writeauthRotated: false)
    check d.verifyGenuine() == GenuineResult(genuine: true, serial: serial,
                                             provisionedDate: "2026-08-15")
    check d.isGenuine()

  test "trust root":
    let ctx = newContext()
    defer: ctx.close()
    let d = ctx.open()
    defer: d.close()
    fails(CertificateInvalidError, sCertificateInvalid):
      ctx.setTrustRoot([0x02'u8, 0x01, 0x00])
    fails(LicenseDongleError, sInvalidArgument):
      ctx.setTrustRoot(newSeq[uint8]())

    var root = @[0x30'u8, 0x82, 0x01, 0x00] & newSeqWith(128, 0xAB'u8)
    ctx.setTrustRoot(root)
    fails(CertificateInvalidError, sCertificateInvalid):
      discard d.verifyGenuine()
    check not d.isGenuine() # fails closed

    for k in 4 ..< root.len: root[k] = 0x01
    ctx.setTrustRoot(root)
    check d.isGenuine()

  test "records and the write role":
    let ctx = newContext()
    defer: ctx.close()
    let d = ctx.open()
    defer: d.close()
    let s = d.openSession()
    defer: s.close()

    let payload = bytes("license-blob-0123456789")
    fails(WriteAuthorizationRequiredError, sAuthRequired):
      s.writeRecord("lic", payload)
    fails(WriteAuthorizationRequiredError, sAuthRequired):
      s.eraseRecord("lic")
    fails(WriteAuthorizationRequiredError, sAuthRequired):
      s.eraseAllRecords()
    fails(WriteAuthorizationRequiredError, sAuthRequired):
      discard s.incrementCounter(0)
    fails(NotGenuineError, sNotGenuine):
      s.authorizeWrite([0x30'u8, 0x00])

    s.authorizeWrite(factoryKey)
    s.writeRecord("lic", payload)
    check s.readRecord("lic") == payload
    s.writeRecord("cfg", "cfgdata")
    let records = s.listRecords()
    check records.mapIt(it.name).sorted() == @["cfg", "lic"]
    check RecordInfo(name: "lic", size: payload.len.uint32) in records
    check s.readRecord("cfg") == bytes("cfgdata")
    fails(RecordNotFoundError, sNotFound):
      discard s.readRecord("nope")
    fails(RecordNotFoundError, sNotFound):
      s.eraseRecord("nope")

    # An empty name is refused by the binding, never passed on as "erase everything".
    expect ValueError:
      s.eraseRecord("")
    expect ValueError:
      discard s.readRecord("")
    expect ValueError:
      s.writeRecord("", payload)
    check s.listRecords().len == 2
    s.eraseRecord("cfg")
    check s.listRecords() == @[RecordInfo(name: "lic", size: payload.len.uint32)]

    s.writeRecord("empty", newSeq[uint8]())
    check s.readRecord("empty").len == 0

    # Bigger than one transfer chunk, with progress, cancellation and a raising callback.
    let big = toSeq(0 ..< 3000).mapIt(uint8((it * 31 + 5) mod 256))
    var last = 0
    s.writeRecord("big", big, proc (done, total: int): bool =
      last = done
      true)
    check last == 3000
    last = 0
    check s.readRecord("big", proc (done, total: int): bool =
      last = done
      true) == big
    check last == 3000
    fails(OperationCancelledError, sCancelled):
      discard s.readRecord("big", proc (done, total: int): bool = false)
    expect IOError:
      discard s.readRecord("big", proc (done, total: int): bool =
        raise newException(IOError, "from the callback"))
    check s.readRecord("big") == big

    s.eraseAllRecords()
    check s.listRecords().len == 0

  test "counters":
    let ctx = newContext()
    defer: ctx.close()
    let d = ctx.open()
    defer: d.close()
    let s = d.openSession()
    defer: s.close()
    s.authorizeWrite(factoryKey)

    let before = s.readCounter(0)
    check s.incrementCounter(0) == before + 1
    check s.readCounter(0) == before + 1
    check s.readCounter(1) == 0
    fails(LicenseDongleError, sRange):
      discard s.readCounter(7)
    fails(LicenseDongleError, sRange):
      discard s.incrementCounter(7)

  test "app encrypt and decrypt":
    let ctx = newContext()
    defer: ctx.close()
    let d = ctx.open()
    defer: d.close()
    let s = d.openSession()
    defer: s.close()

    let secret = toSeq(0 ..< 100).mapIt(uint8((3 * it + 7) mod 256))
    for scope in [scopeDevice, scopeDeveloper]:
      let blob = s.appEncrypt(scope, secret)
      check blob.len > secret.len
      check blob[0] == scope.ord.uint8
      check s.appDecrypt(blob) == secret
      var tampered = blob
      tampered[^1] = tampered[^1] xor 1
      fails(LicenseDongleError, sTagMismatch):
        discard s.appDecrypt(tampered)
    check s.appDecrypt(s.appEncrypt(scopeDevice, newSeq[uint8]())).len == 0

  test "write-key rotation":
    let ctx = newContext()
    defer: ctx.close()
    let d = ctx.open()
    defer: d.close()

    block:
      let s = d.openSession()
      defer: s.close()
      fails(WriteAuthorizationRequiredError, sAuthRequired):
        s.rotateWriteKey(replacementKey)
      s.authorizeWrite(factoryKey)
      s.rotateWriteKey(replacementKey)
      s.writeRecord("lic", "still-writable") # the session keeps its role
    check d.getInfo().writeauthRotated

    let s = d.openSession()
    defer: s.close()
    fails(NotGenuineError, sNotGenuine):
      s.authorizeWrite(factoryKey)
    s.authorizeWrite(replacementKey)
    s.writeRecord("lic", "new-key-writes")
    check s.readRecord("lic") == bytes("new-key-writes")

  test "session and close semantics":
    let ctx = newContext()
    let d = ctx.open()

    # Closing one session ends the device's session, so the other one is refused by the device.
    let stale = d.openSession()
    let s = d.openSession()
    check s.isOpen()
    s.close()
    fails(SessionExpiredError, sSessionExpired):
      discard stale.listRecords()
    stale.close()
    s.close() # idempotent
    check not s.isOpen()
    fails(SessionExpiredError, sSessionExpired):
      discard s.readCounter(0)

    let orphan = d.openSession()
    check d.isOpen()
    d.close()
    d.close() # idempotent
    check not d.isOpen()
    fails(LicenseDongleError, sInvalidArgument):
      discard d.getSerial()
    fails(LicenseDongleError, sInvalidArgument):
      discard orphan.readCounter(0)
    orphan.close()

    # adopt takes over a device handle opened through the C ABI.
    var dev: pointer
    check licd_open(ctx.rawHandle(), nil, dev) == 0
    let adopted = ctx.adopt(dev)
    check adopted.getSerial() == serial
    adopted.close()

    check ctx.isOpen()
    ctx.close()
    ctx.close() # idempotent
    check not ctx.isOpen()
    fails(LicenseDongleError, sInvalidArgument):
      discard ctx.enumerateDongles()
