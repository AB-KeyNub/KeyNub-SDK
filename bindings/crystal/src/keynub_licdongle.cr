# KeyNub License Dongle: verify that a dongle is genuine, read and write the
# license records it holds, use its hardware counters and encrypt data so that
# only a dongle can decrypt it. Calls the SDK's flat C API through a library
# loaded at run time (see `library.cr`); nothing is linked.
require "./keynub_licdongle/library"

module KeyNub::LicDongle
  VERSION = "1.1.1"

  # The SDK's status codes (`licd_status`).
  enum Status
    Ok                   =   0
    InvalidArg           =  -1
    NoDevice             =  -2
    AccessDenied         =  -3
    Io                   =  -4
    Timeout              =  -5
    Protocol             =  -6
    NotGenuine           =  -7
    CertInvalid          =  -8
    SessionExpired       =  -9
    TagMismatch          = -10
    Range                = -11
    StorageFull          = -12
    Busy                 = -13
    NotFound             = -14
    AuthRequired         = -15
    FirmwareIncompatible = -16
    SdkTooOld            = -17
    Cancelled            = -18
    NotImplemented       = -19
    Internal             = -20
  end

  # The name of a status code; `"Unknown"` for one this binding does not know.
  def self.status_name(code : Int32) : String
    Status.from_value?(code).try(&.to_s) || "Unknown"
  end

  # A failed dongle call: the status (nil for a code this binding does not
  # know), the raw code, the operation (the flat API function) and the
  # library's detail text, which may be empty.
  class Error < Exception
    getter status : Status?
    getter code : Int32
    getter operation : String
    getter detail : String

    def initialize(@operation : String, @code : Int32, @detail : String = "")
      @status = Status.from_value?(@code)
      text = "#{@operation}: #{LicDongle.status_name(@code)} (#{@code})"
      text += ": #{@detail}" unless @detail.empty?
      super(text)
    end
  end

  # The native library's version.
  record LibraryVersion, major : Int32, minor : Int32, patch : Int32

  # An attached dongle.
  record Device, serial : String, path : String

  # Plaintext device information. `watchdog_reboot`: the previous boot ended
  # in a watchdog reset. `write_auth_rotated`: the write-auth key has been
  # rotated away from the factory one.
  record Info,
    protocol_major : Int32,
    protocol_minor : Int32,
    firmware_major : Int32,
    firmware_minor : Int32,
    firmware_patch : Int32,
    secure_element_ready : Bool,
    provisioned : Bool,
    watchdog_reboot : Bool,
    isolated : Bool,
    write_auth_rotated : Bool,
    data_capacity : Int32,
    data_free : Int32

  # The result of a successful `Dongle#verify_genuine`. `provisioned_date` is
  # "YYYY-MM-DD", or empty when the dongle reports none; informational.
  record Genuine, serial : String, provisioned_date : String

  # A record on the dongle.
  record Record, name : String, size : Int32

  # Who can decrypt data sealed with `Dongle#app_encrypt`.
  enum Scope
    # This dongle only.
    Device = 0
    # Any dongle issued by the same developer.
    Developer = 1
  end

  # The native library's version.
  def self.library_version : LibraryVersion
    major = minor = patch = 0
    check("licdf_version", 0, api.version.call(pointerof(major), pointerof(minor), pointerof(patch)))
    LibraryVersion.new(major, minor, patch)
  end

  # Human-readable text for a status code; needs no dongle.
  def self.status_text(code : Int32) : String
    text = Bytes.new(ERROR_SIZE)
    return status_name(code) if api.strerror.call(code, text.to_unsafe, ERROR_SIZE) != 0
    c_string(text)
  end

  # The attached dongles.
  def self.devices : Array(Device)
    a = api
    count = 0
    check("licdf_device_count", 0, a.device_count.call(pointerof(count)))
    Array.new(count) do |i|
      text = Bytes.new(PATH_SIZE)
      check("licdf_device_serial", 0, a.device_serial.call(i, text.to_unsafe, PATH_SIZE))
      serial = c_string(text)
      check("licdf_device_path", 0, a.device_path.call(i, text.to_unsafe, PATH_SIZE))
      Device.new(serial, c_string(text))
    end
  end

  # :nodoc:
  def self.check(operation : String, handle : Int32, rc : Int32) : Nil
    raise Error.new(operation, rc, handle > 0 ? detail_of(handle) : "") if rc != 0
  end

  # :nodoc:
  def self.detail_of(handle : Int32) : String
    text = Bytes.new(ERROR_SIZE)
    api.last_error.call(handle, text.to_unsafe, ERROR_SIZE) == 0 ? c_string(text) : ""
  rescue
    ""
  end

  # :nodoc:
  def self.c_string(buffer : Bytes) : String
    length = buffer.index(0_u8) || buffer.size
    String.new(buffer[0, length])
  end

  @@empty = Bytes.new(1)

  # :nodoc:
  # A pointer the library can read even for empty data.
  def self.pointer_of(data : Bytes) : UInt8*
    data.empty? ? @@empty.to_unsafe : data.to_unsafe
  end

  # :nodoc:
  def self.length_of(data : Bytes) : Int32
    if data.size > Int32::MAX
      raise Error.new("argument", Status::InvalidArg.value, "more than 2 GiB of data")
    end
    data.size.to_i32
  end

  # An open dongle. `close` it, or use the block form of `open`, which closes
  # it on every exit path.
  class Dongle
    @handle : Int32

    private def initialize(@handle : Int32)
    end

    # Opens the dongle with this serial, or the first one found when `serial`
    # is nil or empty.
    def self.open(serial : String? = nil) : Dongle
      handle = LicDongle.api.open.call((serial || "").to_unsafe)
      raise Error.new("licdf_open", handle) if handle < 0
      new(handle)
    end

    # Opens the dongle, yields it and closes it on every exit path. Returns
    # what the block returns.
    def self.open(serial : String? = nil, &)
      dongle = open(serial)
      begin
        yield dongle
      ensure
        dongle.close_quietly
      end
    end

    # Opens the dongle at this device path (from `KeyNub::LicDongle.devices`).
    def self.open_path(path : String) : Dongle
      handle = LicDongle.api.open_path.call(path.to_unsafe)
      raise Error.new("licdf_open_path", handle) if handle < 0
      new(handle)
    end

    # Opens the dongle at this device path, yields it and closes it on every
    # exit path. Returns what the block returns.
    def self.open_path(path : String, &)
      dongle = open_path(path)
      begin
        yield dongle
      ensure
        dongle.close_quietly
      end
    end

    def finalize
      close_quietly
    end

    # Whether `close` has not been called yet.
    def open? : Bool
      @handle > 0
    end

    # Closes the dongle. Further calls fail with `Status::InvalidArg`.
    def close : Nil
      return if @handle <= 0
      handle = @handle
      @handle = 0
      LicDongle.check("licdf_close", handle, LicDongle.api.close.call(handle))
    end

    # :nodoc:
    def close_quietly : Nil
      close
    rescue
    end

    # The dongle's serial number (14 hex digits).
    def serial : String
      text = Bytes.new(SERIAL_SIZE)
      check("licdf_get_serial", api.get_serial.call(@handle, text.to_unsafe, SERIAL_SIZE))
      LicDongle.c_string(text)
    end

    # Plaintext device information.
    def info : Info
      pa = pb = fa = fb = fc = flags = capacity = free = 0
      check("licdf_get_info", api.get_info.call(@handle, pointerof(pa), pointerof(pb), pointerof(fa),
        pointerof(fb), pointerof(fc), pointerof(flags), pointerof(capacity), pointerof(free)))
      Info.new(
        protocol_major: pa, protocol_minor: pb,
        firmware_major: fa, firmware_minor: fb, firmware_patch: fc,
        secure_element_ready: flags & FLAG_SECURE_ELEMENT_READY != 0,
        provisioned: flags & FLAG_PROVISIONED != 0,
        watchdog_reboot: flags & FLAG_WATCHDOG_REBOOT != 0,
        isolated: flags & FLAG_ISOLATED != 0,
        write_auth_rotated: flags & FLAG_WRITE_AUTH_ROTATED != 0,
        data_capacity: capacity, data_free: free)
    end

    # Proves the dongle is genuine: certificate chain to the trusted root plus
    # a live challenge-response. Returns only when it is; raises otherwise.
    def verify_genuine : Genuine
      genuine = 0
      serial_text = Bytes.new(SERIAL_SIZE)
      date_text = Bytes.new(DATE_SIZE)
      check("licdf_verify_genuine", api.verify_genuine.call(@handle, pointerof(genuine),
        serial_text.to_unsafe, SERIAL_SIZE, date_text.to_unsafe, DATE_SIZE))
      raise Error.new("licdf_verify_genuine", Status::NotGenuine.value) if genuine == 0
      Genuine.new(LicDongle.c_string(serial_text), LicDongle.c_string(date_text))
    end

    # The boolean form for a gate: true only when `verify_genuine` succeeds.
    # Fails closed: every failure gives false.
    def genuine? : Bool
      verify_genuine
      true
    rescue
      false
    end

    # Overrides the CA root that `verify_genuine` checks against (DER).
    def trust_root=(der : Bytes) : Bytes
      check("licdf_set_trust_root", api.set_trust_root.call(@handle, LicDongle.pointer_of(der), LicDongle.length_of(der)))
      der
    end

    # Opens an authenticated session; records, counters and app crypto need one.
    def session_open : Nil
      check("licdf_session_open", api.session_open.call(@handle))
    end

    # Closes the session.
    def session_close : Nil
      check("licdf_session_close", api.session_close.call(@handle))
    end

    # Opens a session, yields and closes the session on every exit path.
    # Returns what the block returns.
    def session(&)
      session_open
      begin
        yield
      ensure
        begin
          session_close
        rescue
        end
      end
    end

    # Elevates the session to the write role with a write-auth key (P-256
    # PKCS#8 DER). Belongs in licence-issuing tooling, not in the application
    # your users run.
    def authorize_write(key : Bytes) : Nil
      check("licdf_write_auth", api.write_auth.call(@handle, LicDongle.pointer_of(key), LicDongle.length_of(key)))
    end

    # Replaces the dongle's write-auth key with `key` (P-256 PKCS#8 DER). Call
    # `authorize_write` first. From the next session on, only the new key
    # elevates.
    def rotate_write_key(key : Bytes) : Nil
      check("licdf_write_auth_rotate", api.write_auth_rotate.call(@handle, LicDongle.pointer_of(key), LicDongle.length_of(key)))
    end

    # The records on the dongle.
    def records : Array(Record)
      a = api
      count = 0
      check("licdf_record_count", a.record_count.call(@handle, pointerof(count)))
      Array.new(count) do |i|
        text = Bytes.new(NAME_SIZE)
        size = 0
        check("licdf_record_name", a.record_name.call(@handle, i, text.to_unsafe, NAME_SIZE, pointerof(size)))
        Record.new(LicDongle.c_string(text), size)
      end
    end

    # The content of a record.
    def read_record(name : String) : Bytes
      a = api
      read_bytes("licdf_record_read") do |data, capacity, length|
        a.record_read.call(@handle, name.to_unsafe, data, capacity, length)
      end
    end

    # Writes a record, replacing one of the same name. Needs the write role.
    def write_record(name : String, data : Bytes) : Nil
      check("licdf_record_write", api.record_write.call(@handle, name.to_unsafe, LicDongle.pointer_of(data), LicDongle.length_of(data)))
    end

    # Erases one record. Needs the write role.
    def erase_record(name : String) : Nil
      check("licdf_record_erase", api.record_erase.call(@handle, name.to_unsafe))
    end

    # Erases every record. Separate from `erase_record` so that an
    # accidentally empty name cannot wipe the dongle.
    def erase_all_records : Nil
      check("licdf_record_erase_all", api.record_erase_all.call(@handle))
    end

    # The value of a hardware monotonic counter.
    def read_counter(counter_id : Int32) : Int32
      value = 0
      check("licdf_counter_read", api.counter_read.call(@handle, counter_id, pointerof(value)))
      value
    end

    # Increments a counter and returns the new value. Needs the write role.
    def increment_counter(counter_id : Int32) : Int32
      value = 0
      check("licdf_counter_increment", api.counter_increment.call(@handle, counter_id, pointerof(value)))
      value
    end

    # Seals data so that only a dongle can open it: this one (`Scope::Device`)
    # or any dongle issued by the same developer (`Scope::Developer`). Build
    # the licence check on this pair: put something the program needs through
    # it, so removing the check removes the data.
    def app_encrypt(scope : Scope, plaintext : Bytes) : Bytes
      a = api
      length = LicDongle.length_of(plaintext)
      read_bytes("licdf_app_encrypt") do |data, capacity, out_length|
        a.app_encrypt.call(@handle, scope.value, LicDongle.pointer_of(plaintext), length, data, capacity, out_length)
      end
    end

    # Opens data sealed with `app_encrypt`.
    def app_decrypt(packed : Bytes) : Bytes
      a = api
      length = LicDongle.length_of(packed)
      read_bytes("licdf_app_decrypt") do |data, capacity, out_length|
        a.app_decrypt.call(@handle, LicDongle.pointer_of(packed), length, data, capacity, out_length)
      end
    end

    # Diagnostic detail for the most recent failure on this dongle; may be empty.
    def last_error_detail : String
      LicDongle.detail_of(@handle)
    end

    private def api
      LicDongle.api
    end

    private def check(operation : String, rc : Int32) : Nil
      LicDongle.check(operation, @handle, rc)
    end

    # The two-call convention: ask for the size, then read into a buffer of it.
    private def read_bytes(operation : String, & : UInt8*, Int32, Int32* -> Int32) : Bytes
      needed = 0
      probe = 0_u8
      rc = yield pointerof(probe), 0, pointerof(needed)
      return Bytes.empty if rc == 0
      raise Error.new(operation, rc, last_error_detail) if rc != Status::Range.value
      data = Bytes.new(needed > 0 ? needed : 1)
      length = 0
      rc = yield data.to_unsafe, needed, pointerof(length)
      raise Error.new(operation, rc, last_error_detail) if rc != 0
      data[0, length]
    end
  end

  # Opens the first dongle (or the one with `serial`), yields it and closes it
  # on every exit path. Returns what the block returns.
  def self.open(serial : String? = nil, &)
    Dongle.open(serial) { |dongle| yield dongle }
  end
end
