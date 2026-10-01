//// KeyNub License Dongle: verify that a dongle is genuine, read and write the
//// license records it holds, use its hardware counters and encrypt data so that
//// only a dongle can decrypt it.
////
//// ```gleam
//// import keynub/licdongle
////
//// use d <- licdongle.with_dongle(option.None)  // first dongle, or Some("serial")
//// use _ <- result.try(licdongle.verify_genuine(d))
//// use <- licdongle.with_session(d)            // closed on every exit path
//// licdongle.app_decrypt(d, sealed)            // <- build the licence check on this
//// ```
////
//// Calls go to the `keynub_licdongle` Hex package, whose small NIF loads the
//// SDK's native library at run time; nothing is linked.

import gleam/option.{type Option}

/// The SDK's status codes (`licd_status`); `Unknown` carries a code this
/// package does not know.
pub type Status {
  InvalidArg
  NoDevice
  AccessDenied
  Io
  Timeout
  Protocol
  NotGenuine
  CertInvalid
  SessionExpired
  TagMismatch
  Range
  StorageFull
  Busy
  NotFound
  AuthRequired
  FirmwareIncompatible
  SdkTooOld
  Cancelled
  NotImplemented
  Internal
  Unknown(code: Int)
}

/// A failed call. `CallError`: the status, the raw code, the operation (the
/// flat API function) and the library's detail text, which may be empty.
/// `LibraryError`: the native library could not be loaded, or does not fit.
pub type DongleError {
  CallError(status: Status, code: Int, operation: String, detail: String)
  LibraryError(message: String)
}

/// The native library's version.
pub type LibraryVersion {
  LibraryVersion(major: Int, minor: Int, patch: Int)
}

/// An attached dongle.
pub type Device {
  Device(serial: String, path: String)
}

/// Plaintext device information. `watchdog_reboot`: the previous boot ended in
/// a watchdog reset. `write_auth_rotated`: the write-auth key has been rotated
/// away from the factory one.
pub type Info {
  Info(
    protocol_major: Int,
    protocol_minor: Int,
    firmware_major: Int,
    firmware_minor: Int,
    firmware_patch: Int,
    secure_element_ready: Bool,
    provisioned: Bool,
    watchdog_reboot: Bool,
    isolated: Bool,
    write_auth_rotated: Bool,
    data_capacity: Int,
    data_free: Int,
  )
}

/// The result of a successful `verify_genuine`. `provisioned_date` is
/// "YYYY-MM-DD", or empty when the dongle reports none; informational.
pub type Genuine {
  Genuine(serial: String, provisioned_date: String)
}

/// A record on the dongle.
pub type DongleRecord {
  DongleRecord(name: String, size: Int)
}

/// Who can decrypt data sealed with `app_encrypt`: this dongle only
/// (`DeviceScope`), or any dongle issued by the same developer
/// (`DeveloperScope`).
pub type Scope {
  DeviceScope
  DeveloperScope
}

/// An open dongle, from `open` or `with_dongle`.
pub type Dongle

/// The status for a raw code.
pub fn status_from_code(code: Int) -> Status {
  case code {
    -1 -> InvalidArg
    -2 -> NoDevice
    -3 -> AccessDenied
    -4 -> Io
    -5 -> Timeout
    -6 -> Protocol
    -7 -> NotGenuine
    -8 -> CertInvalid
    -9 -> SessionExpired
    -10 -> TagMismatch
    -11 -> Range
    -12 -> StorageFull
    -13 -> Busy
    -14 -> NotFound
    -15 -> AuthRequired
    -16 -> FirmwareIncompatible
    -17 -> SdkTooOld
    -18 -> Cancelled
    -19 -> NotImplemented
    -20 -> Internal
    _ -> Unknown(code)
  }
}

// ---- the library -------------------------------------------------------------

/// Names the native library file to load. Call it before the first dongle call.
pub fn set_library_path(path: String) -> Result(Nil, DongleError) {
  call("set_library_path", [arg(path)])
}

/// The path of the loaded library; `None` before the first call.
@external(erlang, "keynub_licdongle_ffi", "loaded_library_path")
pub fn loaded_library_path() -> Option(String)

/// The native library's version.
@external(erlang, "keynub_licdongle_ffi", "library_version")
pub fn library_version() -> Result(LibraryVersion, DongleError)

/// Human-readable text for a status code; needs no dongle.
pub fn status_text(code: Int) -> String {
  call_value("status_text", [arg(code)])
}

/// The attached dongles.
pub fn devices() -> Result(List(Device), DongleError) {
  call("devices", [])
}

// ---- open and close ------------------------------------------------------------

/// Opens the dongle with this serial, or the first one found with `None`.
/// `close` it, or use `with_dongle`.
@external(erlang, "keynub_licdongle_ffi", "open")
pub fn open(serial: Option(String)) -> Result(Dongle, DongleError)

/// Opens the dongle at this device path (from `devices`).
pub fn open_path(path: String) -> Result(Dongle, DongleError) {
  call("open_path", [arg(path)])
}

/// Closes the dongle. Further calls fail with `InvalidArg`.
pub fn close(dongle: Dongle) -> Result(Nil, DongleError) {
  call("close", [arg(dongle)])
}

/// Opens a dongle (by serial, or the first one with `None`), runs `body` with
/// it and closes it on every exit path. Returns what `body` returns, or the
/// error from opening.
@external(erlang, "keynub_licdongle_ffi", "with_dongle")
pub fn with_dongle(
  serial: Option(String),
  body: fn(Dongle) -> Result(value, DongleError),
) -> Result(value, DongleError)

// ---- plaintext info --------------------------------------------------------------

/// The dongle's serial number (14 hex digits).
pub fn serial(dongle: Dongle) -> Result(String, DongleError) {
  call("serial", [arg(dongle)])
}

/// Plaintext device information.
pub fn info(dongle: Dongle) -> Result(Info, DongleError) {
  call("info", [arg(dongle)])
}

/// Proves the dongle is genuine: certificate chain to the trusted root plus a
/// live challenge-response. `Ok` only when it is.
pub fn verify_genuine(dongle: Dongle) -> Result(Genuine, DongleError) {
  call("verify_genuine", [arg(dongle)])
}

/// The boolean form for a gate: `True` only when `verify_genuine` succeeds.
/// Fails closed: every failure gives `False`.
pub fn is_genuine(dongle: Dongle) -> Bool {
  call_value("genuine?", [arg(dongle)])
}

/// Overrides the CA root that `verify_genuine` checks against (DER).
pub fn set_trust_root(
  dongle: Dongle,
  der: BitArray,
) -> Result(Nil, DongleError) {
  call("set_trust_root", [arg(dongle), arg(der)])
}

// ---- session ---------------------------------------------------------------------

/// Opens an authenticated session; records, counters and app crypto need one.
pub fn session_open(dongle: Dongle) -> Result(Nil, DongleError) {
  call("session_open", [arg(dongle)])
}

/// Closes the session.
pub fn session_close(dongle: Dongle) -> Result(Nil, DongleError) {
  call("session_close", [arg(dongle)])
}

/// Opens a session, runs `body` and closes the session on every exit path.
/// Returns what `body` returns, or the error from opening the session.
@external(erlang, "keynub_licdongle_ffi", "with_session")
pub fn with_session(
  dongle: Dongle,
  body: fn() -> Result(value, DongleError),
) -> Result(value, DongleError)

/// Elevates the session to the write role with a write-auth key (P-256 PKCS#8
/// DER). Belongs in licence-issuing tooling, not in the application your users
/// run.
pub fn authorize_write(
  dongle: Dongle,
  key: BitArray,
) -> Result(Nil, DongleError) {
  call("authorize_write", [arg(dongle), arg(key)])
}

/// Replaces the dongle's write-auth key with `key` (P-256 PKCS#8 DER). Call
/// `authorize_write` first. From the next session on, only the new key
/// elevates.
pub fn rotate_write_key(
  dongle: Dongle,
  key: BitArray,
) -> Result(Nil, DongleError) {
  call("rotate_write_key", [arg(dongle), arg(key)])
}

// ---- records -----------------------------------------------------------------------

/// The records on the dongle.
pub fn records(dongle: Dongle) -> Result(List(DongleRecord), DongleError) {
  call("records", [arg(dongle)])
}

/// The content of a record.
pub fn read_record(
  dongle: Dongle,
  name: String,
) -> Result(BitArray, DongleError) {
  call("read_record", [arg(dongle), arg(name)])
}

/// Writes a record, replacing one of the same name. Needs the write role.
pub fn write_record(
  dongle: Dongle,
  name: String,
  data: BitArray,
) -> Result(Nil, DongleError) {
  call("write_record", [arg(dongle), arg(name), arg(data)])
}

/// Erases one record. Needs the write role.
pub fn erase_record(dongle: Dongle, name: String) -> Result(Nil, DongleError) {
  call("erase_record", [arg(dongle), arg(name)])
}

/// Erases every record. Separate from `erase_record` so that an accidentally
/// empty name cannot wipe the dongle.
pub fn erase_all_records(dongle: Dongle) -> Result(Nil, DongleError) {
  call("erase_all_records", [arg(dongle)])
}

// ---- counters ----------------------------------------------------------------------

/// The value of a hardware monotonic counter.
pub fn read_counter(
  dongle: Dongle,
  counter_id: Int,
) -> Result(Int, DongleError) {
  call("read_counter", [arg(dongle), arg(counter_id)])
}

/// Increments a counter and returns the new value. Needs the write role.
pub fn increment_counter(
  dongle: Dongle,
  counter_id: Int,
) -> Result(Int, DongleError) {
  call("increment_counter", [arg(dongle), arg(counter_id)])
}

// ---- app-data envelope encryption ------------------------------------------------

/// Seals data so that only a dongle can open it: this one (`DeviceScope`) or
/// any dongle issued by the same developer (`DeveloperScope`). Build the licence check
/// on this pair: put something the program needs through it, so removing the
/// check removes the data.
pub fn app_encrypt(
  dongle: Dongle,
  scope: Scope,
  plaintext: BitArray,
) -> Result(BitArray, DongleError) {
  let scope = case scope {
    DeviceScope -> "device"
    DeveloperScope -> "developer"
  }
  call("app_encrypt", [arg(dongle), arg(to_atom(scope)), arg(plaintext)])
}

/// Opens data sealed with `app_encrypt`.
pub fn app_decrypt(
  dongle: Dongle,
  packed: BitArray,
) -> Result(BitArray, DongleError) {
  call("app_decrypt", [arg(dongle), arg(packed)])
}

/// Diagnostic detail for the most recent failure on this dongle; may be empty.
pub fn last_error_detail(dongle: Dongle) -> String {
  call_value("last_error_detail", [arg(dongle)])
}

// ---- the bridge ----------------------------------------------------------------------

type Argument

@external(erlang, "gleam_stdlib", "identity")
fn arg(value: a) -> Argument

type Atom

@external(erlang, "erlang", "binary_to_atom")
fn to_atom(name: String) -> Atom

@external(erlang, "keynub_licdongle_ffi", "call")
fn call(function: String, arguments: List(Argument)) -> a

@external(erlang, "keynub_licdongle_ffi", "call_value")
fn call_value(function: String, arguments: List(Argument)) -> a
