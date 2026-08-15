## KeyNub License Dongle — Nim binding.
##
## .. code-block:: nim
##   import keynub_licdongle
##
##   let ctx = newContext()
##   defer: ctx.close()
##   let dongle = ctx.open()                 # first dongle, or ctx.open("serial")
##   discard dongle.verifyGenuine()          # raises unless genuine
##   let session = dongle.openSession()
##   defer: session.close()
##   let data = session.appDecrypt(blob)     # <- build the licence check on this
##
## No dependencies: `importc` is part of the language. The library is resolved at
## run time through `dynlib`, so nothing needs to be linked.
##
## The library name is a compile-time define (`-d:keynubLib=...`), so a build can
## be pointed at a specific library without the source knowing about it.
##
## Read docs/integration-security.md before writing the check. `if not
## dongle.isGenuine(): quit()` compiles to a conditional jump, and patching one of
## those in a release binary is a beginner exercise. Route something the program
## needs through appEncrypt/appDecrypt, so removing the check removes the data.

import std/[strutils, strformat]

const keynubLib* {.strdefine.} = "keynub_licdongle"
  ## The native library, resolved at run time. Override with `-d:keynubLib=...`.

{.push dynlib: keynubLib, cdecl.}

# --- status codes ------------------------------------------------------------

type Status* = enum
  ## Why an operation failed. Mirrors `licd_status`.
  sInternal = -20
  sNotImplemented = -19
  sCancelled = -18
  sSdkTooOld = -17
  sFirmwareIncompatible = -16
  sAuthRequired = -15
  sNotFound = -14
  sBusy = -13
  sStorageFull = -12
  sRange = -11
  sTagMismatch = -10
  sSessionExpired = -9
  sCertificateInvalid = -8
  sNotGenuine = -7
  sProtocol = -6
  sTimeout = -5
  sIo = -4
  sAccessDenied = -3
  sNoDevice = -2
  sInvalidArgument = -1
  sOk = 0

type Scope* = enum
  ## Who can decrypt data produced by `appEncrypt`.
  scopeDevice = 0    ## only this one physical dongle
  scopeDeveloper = 1 ## any dongle issued by the same developer

# --- opaque handles and structs ----------------------------------------------

type
  LicdCtx = object
  LicdDevice = object
  CtxPtr = ptr LicdCtx
  DevicePtr = ptr LicdDevice

  LicdInfo {.bycopy.} = object
    protoMajor, protoMinor: uint8
    fwMajor, fwMinor, fwPatch: uint8
    seReady, provisioned: cint
    dataCapacity, dataFree: uint32
    watchdogReboot: cint
    isolated: cint
    writeauthRotated: cint

  LicdGenuineResult {.bycopy.} = object
    genuine: cint
    serial: array[15, char]
    provisionedDate: array[11, char]

  LicdDeviceInfo {.bycopy.} = object
    serial: array[15, char]
    path: array[512, char]
    vendorId, productId: uint16

  ProgressCb = proc (done, total: uint32; user: pointer): cint {.cdecl.}

# --- C prototypes ------------------------------------------------------------

proc licd_version(major, minor, patch: var cint) {.importc.}
proc licd_init(outCtx: var CtxPtr): cint {.importc.}
proc licd_free(ctx: CtxPtr) {.importc.}
proc licd_set_trust_root(ctx: CtxPtr; der: ptr uint8; len: csize_t): cint {.importc.}

proc licd_enumerate(ctx: CtxPtr; outList: var ptr LicdDeviceInfo;
                    outCount: var csize_t): cint {.importc.}
proc licd_free_device_list(list: ptr LicdDeviceInfo; count: csize_t) {.importc.}
proc licd_open(ctx: CtxPtr; serial: cstring; outDev: var DevicePtr): cint {.importc.}
proc licd_open_path(ctx: CtxPtr; path: cstring; outDev: var DevicePtr): cint {.importc.}
proc licd_close(dev: DevicePtr) {.importc.}

proc licd_get_info(dev: DevicePtr; outInfo: var LicdInfo): cint {.importc.}
proc licd_get_serial(dev: DevicePtr; outSerial: ptr char; size: csize_t): cint {.importc.}

proc licd_verify_genuine(dev: DevicePtr; outResult: var LicdGenuineResult): cint {.importc.}
proc licd_session_open(dev: DevicePtr): cint {.importc.}
proc licd_session_close(dev: DevicePtr): cint {.importc.}
proc licd_write_auth(dev: DevicePtr; der: ptr uint8; len: csize_t): cint {.importc.}
proc licd_write_auth_rotate(dev: DevicePtr; der: ptr uint8; len: csize_t): cint {.importc.}

proc licd_record_list(dev: DevicePtr; outNames: var ptr cstring;
                      outSizes: var ptr uint32; outCount: var csize_t): cint {.importc.}
proc licd_free_record_list(names: ptr cstring; sizes: ptr uint32;
                           count: csize_t) {.importc.}
proc licd_record_read(dev: DevicePtr; name: cstring; offset: uint32; buf: pointer;
                      bufSize: uint32; outLen, outTotal: var uint32;
                      progress: ProgressCb; user: pointer): cint {.importc.}
proc licd_record_write(dev: DevicePtr; name: cstring; data: pointer; len: uint32;
                       progress: ProgressCb; user: pointer): cint {.importc.}
proc licd_record_erase(dev: DevicePtr; name: cstring): cint {.importc.}

proc licd_counter_read(dev: DevicePtr; id: uint8; outValue: var uint32): cint {.importc.}
proc licd_counter_increment(dev: DevicePtr; id: uint8;
                            outValue: var uint32): cint {.importc.}

proc licd_app_encrypt(dev: DevicePtr; scope: cint; plaintext: pointer; len: uint32;
                      outBuf: var ptr uint8; outLen: var uint32): cint {.importc.}
proc licd_app_decrypt(dev: DevicePtr; packed: pointer; packedLen: uint32;
                      outBuf: var ptr uint8; outLen: var uint32): cint {.importc.}
proc licd_free_buffer(buf: ptr uint8) {.importc.}

proc licd_strerror(status: cint): cstring {.importc.}
proc licd_error_detail(ctx: CtxPtr): cstring {.importc.}

{.pop.}

# --- errors ------------------------------------------------------------------

type
  LicenseDongleError* = object of CatchableError
    ## Raised when a dongle operation fails.
    status*: Status      ## which failure this is
    operation*: string   ## the C function that failed
    detail*: string      ## the SDK's diagnostic text; log it, do not parse it

  NotGenuineError* = object of LicenseDongleError
  CertificateInvalidError* = object of LicenseDongleError
  WriteAuthorizationRequiredError* = object of LicenseDongleError
  SessionExpiredError* = object of LicenseDongleError
  DeviceNotFoundError* = object of LicenseDongleError
  RecordNotFoundError* = object of LicenseDongleError
  OperationCancelledError* = object of LicenseDongleError

proc statusText*(status: Status): string =
  ## Human-readable text for a status code, from the SDK itself.
  $licd_strerror(status.cint)

proc raiseStatus(status: Status; operation, detail: string) {.noreturn.} =
  let message =
    if detail.len > 0: &"{operation}: {statusText(status)} ({detail})"
    else: &"{operation}: {statusText(status)}"
  template fail(T: typedesc) =
    var e = newException(T, message)
    e.status = status
    e.operation = operation
    e.detail = detail
    raise e
  case status
  of sNotGenuine: fail(NotGenuineError)
  of sCertificateInvalid: fail(CertificateInvalidError)
  of sAuthRequired: fail(WriteAuthorizationRequiredError)
  of sSessionExpired: fail(SessionExpiredError)
  of sNoDevice: fail(DeviceNotFoundError)
  of sNotFound: fail(RecordNotFoundError)
  of sCancelled: fail(OperationCancelledError)
  else: fail(LicenseDongleError)

# --- plain results -----------------------------------------------------------

type
  Version* = tuple[major, minor, patch: int]

  DeviceInfo* = object
    serial*: string
    path*: string  ## opaque; pass to `openPath`
    vendorId*: uint16
    productId*: uint16

  Info* = object
    protocolVersion*: tuple[major, minor: int]
    firmwareVersion*: tuple[major, minor, patch: int]
    seReady*: bool
    provisioned*: bool
    dataCapacity*: uint32
    dataFree*: uint32
    watchdogReboot*: bool
      ## The dongle's *previous* boot ended in a watchdog timeout: the firmware
      ## hung and reset itself. The only trace a field hang leaves behind, and a
      ## power cycle clears it — worth logging.
    isolated*: bool
      ## Whether the dongle confirmed at boot that its USB and parsing code is fenced off
      ## from keys and storage. Anything that is not a dongle reports false.
    writeauthRotated*: bool
      ## Whether the write-auth key has been rotated away from the factory one. That key
      ## is public, so a dongle reporting false accepts writes from anyone holding it.

  GenuineResult* = object
    genuine*: bool
    serial*: string
    provisionedDate*: string

  RecordInfo* = object
    name*: string
    size*: uint32

  ProgressProc* = proc (done, total: int): bool
    ## Return false to cancel the transfer, which raises `OperationCancelledError`.

proc fromFixed(bytes: openArray[char]): string =
  ## A Nim string from a NUL-terminated fixed-size C char array.
  result = ""
  for c in bytes:
    if c == '\0': break
    result.add(c)

# --- Context -----------------------------------------------------------------

type
  Context* = ref object
    ## The library context: the entry point for finding and opening dongles.
    handle: CtxPtr

  Dongle* = ref object
    ## An open connection to a dongle. Stored data needs a `Session`.
    handle: DevicePtr
    ctx: Context

  Session* = ref object
    ## An open encrypted session: records, counters and app-crypto.
    dongle: Dongle
    isOpenFlag: bool

proc libraryVersion*(): Version =
  ## The native core's semantic version.
  var major, minor, patch: cint
  licd_version(major, minor, patch)
  (major.int, minor.int, patch.int)

proc newContext*(): Context =
  ## Creates a context. `close` it when done, after the dongles it opened.
  var handle: CtxPtr
  let rc = licd_init(handle)
  if rc != 0:
    raiseStatus(Status(rc), "licd_init", "")
  Context(handle: handle)

proc isOpen*(ctx: Context): bool = ctx.handle != nil

proc close*(ctx: Context) =
  ## Releases the context. Safe to call more than once.
  if ctx.handle != nil:
    let handle = ctx.handle
    ctx.handle = nil
    licd_free(handle)

proc checkedHandle(ctx: Context): CtxPtr =
  if ctx.handle == nil:
    raiseStatus(sInvalidArgument, "context", "the context has been closed")
  ctx.handle

proc lastErrorDetail*(ctx: Context): string =
  ## The SDK's diagnostic detail for the most recent failure on this thread.
  $licd_error_detail(ctx.checkedHandle())

proc check(ctx: Context; rc: cint; operation: string) =
  if rc != 0:
    let detail = if ctx.handle != nil: ctx.lastErrorDetail() else: ""
    raiseStatus(Status(rc), operation, detail)

proc setTrustRoot*(ctx: Context; der: openArray[uint8]) =
  ## Overrides the CA root that `verifyGenuine` checks against. Applications do not
  ## need this: a release build embeds the KeyNub production root. It exists for
  ## dongles provisioned against a different CA, and for vendor tooling.
  let p = if der.len > 0: cast[ptr uint8](der[0].unsafeAddr) else: nil
  ctx.check(licd_set_trust_root(ctx.checkedHandle(), p, der.len.csize_t),
            "licd_set_trust_root")

proc enumerateDongles*(ctx: Context): seq[DeviceInfo] =
  ## Connected dongles. An empty sequence means none are attached, which is normal.
  var list: ptr LicdDeviceInfo
  var count: csize_t
  ctx.check(licd_enumerate(ctx.checkedHandle(), list, count), "licd_enumerate")
  result = @[]
  if list != nil:
    let entries = cast[ptr UncheckedArray[LicdDeviceInfo]](list)
    for i in 0 ..< count.int:
      result.add(DeviceInfo(
        serial: fromFixed(entries[i].serial),
        path: fromFixed(entries[i].path),
        vendorId: entries[i].vendorId,
        productId: entries[i].productId))
    licd_free_device_list(list, count)

proc open*(ctx: Context; serial: string = ""): Dongle =
  ## Opens the dongle with this serial, or the first one found when empty.
  var handle: DevicePtr
  let name = if serial.len > 0: serial.cstring else: nil
  ctx.check(licd_open(ctx.checkedHandle(), name, handle), "licd_open")
  Dongle(handle: handle, ctx: ctx)

proc openPath*(ctx: Context; path: string): Dongle =
  ## Opens a specific dongle by the path from `enumerateDongles`.
  var handle: DevicePtr
  ctx.check(licd_open_path(ctx.checkedHandle(), path.cstring, handle), "licd_open_path")
  Dongle(handle: handle, ctx: ctx)

proc adopt*(ctx: Context; handle: pointer): Dongle =
  ## Takes ownership of a device opened through the C ABI directly, so this binding
  ## can be introduced into existing code a call at a time.
  Dongle(handle: cast[DevicePtr](handle), ctx: ctx)

proc rawHandle*(ctx: Context): pointer = cast[pointer](ctx.checkedHandle())
  ## The underlying handle, for mixing this binding with direct `importc` calls.

# --- Dongle ------------------------------------------------------------------

proc isOpen*(dongle: Dongle): bool = dongle.handle != nil

proc close*(dongle: Dongle) =
  ## Releases the dongle. Safe to call more than once.
  if dongle.handle != nil:
    let handle = dongle.handle
    dongle.handle = nil
    licd_close(handle)

proc checkedHandle(dongle: Dongle): DevicePtr =
  if dongle.handle == nil:
    raiseStatus(sInvalidArgument, "dongle", "the dongle has been closed")
  dongle.handle

proc getInfo*(dongle: Dongle): Info =
  ## Reads the plaintext device info.
  var raw: LicdInfo
  dongle.ctx.check(licd_get_info(dongle.checkedHandle(), raw), "licd_get_info")
  Info(
    protocolVersion: (raw.protoMajor.int, raw.protoMinor.int),
    firmwareVersion: (raw.fwMajor.int, raw.fwMinor.int, raw.fwPatch.int),
    seReady: raw.seReady != 0,
    provisioned: raw.provisioned != 0,
    dataCapacity: raw.dataCapacity,
    dataFree: raw.dataFree,
    watchdogReboot: raw.watchdogReboot != 0,
    isolated: raw.isolated != 0,
    writeauthRotated: raw.writeauthRotated != 0)

proc getSerial*(dongle: Dongle): string =
  ## Reads the dongle serial as hex.
  var buffer: array[15, char]
  dongle.ctx.check(
    licd_get_serial(dongle.checkedHandle(), addr buffer[0], buffer.len.csize_t),
    "licd_get_serial")
  fromFixed(buffer)

proc verifyGenuine*(dongle: Dongle): GenuineResult =
  ## Proves authenticity: the certificate chain to the trusted root plus a live
  ## ECDSA challenge-response. Raises unless the dongle is genuine.
  var raw: LicdGenuineResult
  dongle.ctx.check(licd_verify_genuine(dongle.checkedHandle(), raw), "licd_verify_genuine")
  GenuineResult(
    genuine: raw.genuine != 0,
    serial: fromFixed(raw.serial),
    provisionedDate: fromFixed(raw.provisionedDate))

proc isGenuine*(dongle: Dongle): bool =
  ## The non-raising form, for a licence gate. Fails closed: a missing dongle, an
  ## I/O error and an invalid certificate all return false.
  try:
    dongle.verifyGenuine().genuine
  except CatchableError:
    false

proc openSession*(dongle: Dongle): Session =
  ## Opens an encrypted session (P-256 ECDH, HKDF-SHA256, AES-256-GCM).
  dongle.ctx.check(licd_session_open(dongle.checkedHandle()), "licd_session_open")
  Session(dongle: dongle, isOpenFlag: true)

# --- Session -----------------------------------------------------------------

proc isOpen*(s: Session): bool = s.isOpenFlag

proc close*(s: Session) =
  ## Ends the session, zeroizing the session keys on the dongle. Never raises.
  if s.isOpenFlag:
    s.isOpenFlag = false
    if s.dongle.isOpen():
      discard licd_session_close(s.dongle.handle)

proc device(s: Session): DevicePtr =
  if not s.isOpenFlag:
    raiseStatus(sSessionExpired, "session", "the session has been closed")
  s.dongle.checkedHandle()

proc check(s: Session; rc: cint; operation: string) = s.dongle.ctx.check(rc, operation)

proc requireName(name: string) =
  if name.len == 0:
    raise newException(ValueError, "the record name must not be empty")

proc authorizeWrite*(s: Session; masterKeyDer: openArray[uint8]) =
  ## Elevates to the write role with the developer master key (a DER EC private
  ## key). This belongs in your licence-issuing tooling; never ship
  ## that key in the application your users run.
  let p = if masterKeyDer.len > 0: cast[ptr uint8](masterKeyDer[0].unsafeAddr) else: nil
  s.check(licd_write_auth(s.device(), p, masterKeyDer.len.csize_t), "licd_write_auth")

proc rotateWriteKey*(s: Session; newKeyDer: openArray[uint8]) =
  ## Replaces the dongle's write-auth key with your own (a DER EC private key).
  ## Call `authorizeWrite` with the current key first. From the next session on,
  ## only the new key elevates.
  let p = if newKeyDer.len > 0: cast[ptr uint8](newKeyDer[0].unsafeAddr) else: nil
  s.check(licd_write_auth_rotate(s.device(), p, newKeyDer.len.csize_t),
          "licd_write_auth_rotate")

proc listRecords*(s: Session): seq[RecordInfo] =
  ## Records stored on the dongle.
  var names: ptr cstring
  var sizes: ptr uint32
  var count: csize_t
  s.check(licd_record_list(s.device(), names, sizes, count), "licd_record_list")
  result = @[]
  if names != nil:
    let nameArray = cast[ptr UncheckedArray[cstring]](names)
    let sizeArray = cast[ptr UncheckedArray[uint32]](sizes)
    for i in 0 ..< count.int:
      result.add(RecordInfo(name: $nameArray[i], size: sizeArray[i]))
    licd_free_record_list(names, sizes, count)

# The progress callback travels through a module-level slot: Nim closures are not
# plain C function pointers, and the `user` parameter cannot carry a GC'd value
# across the boundary safely.
var activeProgress {.threadvar.}: ProgressProc
var progressRaised {.threadvar.}: ref CatchableError

proc progressShim(done, total: uint32; user: pointer): cint {.cdecl.} =
  if activeProgress == nil or progressRaised != nil:
    return 1
  try:
    # Anything but an explicit false continues.
    return (if activeProgress(done.int, total.int): 1 else: 0)
  except CatchableError as e:
    # Raising through the C frames would skip the SDK's own cleanup and strand the
    # device mid-transfer. Hold it and cancel; the caller re-raises.
    progressRaised = e
    return 0

template withProgress(progress: ProgressProc; body: untyped): untyped =
  ## Installs `progress` for the duration of `body`, then re-raises anything it
  ## raised. `cb` is the C callback to hand to the SDK, or nil.
  let previous = activeProgress
  activeProgress = progress
  progressRaised = nil
  let cb {.inject.} = if progress != nil: progressShim else: nil
  try:
    let status = body
    if progressRaised != nil:
      let e = progressRaised
      progressRaised = nil
      raise e
    status
  finally:
    activeProgress = previous

proc readRecord*(s: Session; name: string; progress: ProgressProc = nil): seq[uint8] =
  ## Reads a record. `progress` may return false to cancel.
  requireName(name)
  let dev = s.device()
  var got, total: uint32

  # Probe for the size first, so progress runs monotonically from 0 to total.
  var probe: array[1, uint8]
  s.check(licd_record_read(dev, name.cstring, 0, addr probe[0], 1, got, total, nil, nil),
          "licd_record_read")
  if total == 0:
    return @[]

  result = newSeq[uint8](total.int)
  let rc = withProgress(progress):
    licd_record_read(dev, name.cstring, 0, addr result[0], total, got, total, cb, nil)
  s.check(rc, "licd_record_read")
  result.setLen(got.int)

proc writeRecord*(s: Session; name: string; data: openArray[uint8];
                  progress: ProgressProc = nil) =
  ## Atomically replaces a record. Requires the write role.
  requireName(name)
  let dev = s.device()
  let p = if data.len > 0: cast[pointer](data[0].unsafeAddr) else: nil
  let rc = withProgress(progress):
    licd_record_write(dev, name.cstring, p, data.len.uint32, cb, nil)
  s.check(rc, "licd_record_write")

proc writeRecord*(s: Session; name, data: string; progress: ProgressProc = nil) =
  ## Convenience overload for text payloads.
  writeRecord(s, name, cast[seq[uint8]](@(data.toOpenArrayByte(0, data.high))), progress)

proc eraseRecord*(s: Session; name: string) =
  ## Erases one record. Requires the write role.
  # A nil name means "erase everything" to the C API; that is `eraseAllRecords`
  # here, so an empty string cannot wipe the dongle.
  requireName(name)
  s.check(licd_record_erase(s.device(), name.cstring), "licd_record_erase")

proc eraseAllRecords*(s: Session) =
  ## Erases every record. Requires the write role.
  s.check(licd_record_erase(s.device(), nil), "licd_record_erase")

proc readCounter*(s: Session; counterId: uint8): uint32 =
  ## Reads a hardware monotonic counter.
  var value: uint32
  s.check(licd_counter_read(s.device(), counterId, value), "licd_counter_read")
  value

proc incrementCounter*(s: Session; counterId: uint8): uint32 =
  ## Increments a counter and returns the new value. Irreversible: it is monotonic
  ## in hardware. Requires the write role.
  var value: uint32
  s.check(licd_counter_increment(s.device(), counterId, value), "licd_counter_increment")
  value

proc takeBuffer(buf: ptr uint8; len: uint32): seq[uint8] =
  if buf == nil:
    return @[]
  result = newSeq[uint8](len.int)
  if len > 0:
    copyMem(addr result[0], buf, len.int)
  licd_free_buffer(buf)

proc appEncrypt*(s: Session; scope: Scope; plaintext: openArray[uint8]): seq[uint8] =
  ## Encrypts so that only a dongle of `scope` can decrypt. This is the pair to
  ## build a licence check on: put something the program genuinely needs through
  ## it, so removing the check removes the data.
  var outBuf: ptr uint8
  var outLen: uint32
  let p = if plaintext.len > 0: cast[pointer](plaintext[0].unsafeAddr) else: nil
  s.check(licd_app_encrypt(s.device(), scope.cint, p, plaintext.len.uint32,
                           outBuf, outLen), "licd_app_encrypt")
  takeBuffer(outBuf, outLen)

proc appDecrypt*(s: Session; packed: openArray[uint8]): seq[uint8] =
  ## Decrypts a blob produced by `appEncrypt`, using the dongle.
  var outBuf: ptr uint8
  var outLen: uint32
  let p = if packed.len > 0: cast[pointer](packed[0].unsafeAddr) else: nil
  s.check(licd_app_decrypt(s.device(), p, packed.len.uint32, outBuf, outLen),
          "licd_app_decrypt")
  takeBuffer(outBuf, outLen)
