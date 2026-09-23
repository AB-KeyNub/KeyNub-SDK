# Every call of the binding against a stand-in for the flat C API: the SDK's
# flat layer compiled together with the C ABI stand-in
# (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory)
# into one shared library, with a C compiler from the path (cc, gcc, clang,
# zig cc or cl). KEYNUB_LICDONGLE_FLAT_LIBRARY naming an already compiled
# stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the
# test does not run inside a clone. Exit code 0 when every check passed.
#
#     crystal run bindings/crystal/test/standin_test.cr      (from the repository root)
require "../src/keynub_licdongle"

include KeyNub::LicDongle

SERIAL          = "04A1B2C3D4E5F6"
FACTORY_KEY     = Bytes[0x30, 0x10, 0x01, 0x02, 0x03]
REPLACEMENT_KEY = Bytes[0x30, 0x11, 0x09, 0x08, 0x07, 0x06]

module Tally
  class_property failures = 0
end

def check(condition, what)
  return if condition
  Tally.failures += 1
  puts "  FAIL  #{what}"
end

def fails(status : Status, what : String, &)
  yield
  check(false, "#{what}: no failure")
rescue e : KeyNub::LicDongle::Error
  check(e.status == status, "#{what}: #{KeyNub::LicDongle.status_name(e.code)}")
end

def bytes(text : String) : Bytes
  text.to_slice.dup
end

# ---- the stand-in ----------------------------------------------------------

def sdk_root : String
  if (given = ENV["KEYNUB_SDK_ROOT"]?) && !given.empty?
    return given
  end
  dir = Dir.current
  loop do
    return dir if File.file?(File.join(dir, "bindings", "flat", "licd_flat.c"))
    parent = File.dirname(dir)
    break if parent == dir
    dir = parent
  end
  puts "the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT"
  exit 1
end

def build_stand_in : String
  root = sdk_root
  windows = {{ flag?(:win32) }}
  tmp = Dir.tempdir
  # Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf
  # name even for an absolute-path dlopen, and a build tree on that path holds
  # the real library under that name.
  output = File.join(tmp, windows ? "keynub_flat_standin.dll" : "libkeynub_flat_standin.so")
  include_dir = File.file?(File.join(root, "core", "include", "licdongle.h")) ? File.join(root, "core", "include") : File.join(root, "include")
  flat_dir = File.join(root, "bindings", "flat")
  sources = [File.join(flat_dir, "licd_flat.c"), File.join(root, "bindings", "julia", "test", "stub", "licd_stub.c")]
  gcc_args = ["-shared", "-O1", "-DLICD_BUILD_SHARED", "-DLICDF_BUILD_SHARED", "-I" + include_dir, "-I" + flat_dir, "-o", output] + sources
  gcc_args << "-fPIC" unless windows
  cl_args = ["/nologo", "/LD", "/O1", "/DLICD_BUILD_SHARED", "/DLICDF_BUILD_SHARED", "/I" + include_dir, "/I" + flat_dir, "/Fe:" + output] + sources
  commands = [{"cc", gcc_args}, {"gcc", gcc_args}, {"clang", gcc_args}, {"zig", ["cc"] + gcc_args}, {"cl", cl_args}]
  commands.each do |command, args|
    begin
      status = Process.run(command, args, chdir: tmp, output: Process::Redirect::Close, error: Process::Redirect::Close)
      return output if status.success?
    rescue
    end
  end
  puts "the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path"
  exit 1
end

def stand_in : String
  if (given = ENV[LIBRARY_ENVIRONMENT_VARIABLE]?) && !given.empty?
    return given
  end
  build_stand_in
end

# ---- the checks -------------------------------------------------------------

KeyNub::LicDongle.library_path = stand_in

check(KeyNub::LicDongle.library_version == LibraryVersion.new(9, 8, 7), "library version")
check(KeyNub::LicDongle.status_text(-2) == "no device", "status text")

check(KeyNub::LicDongle.devices == [Device.new(SERIAL, "stub:0")], "devices")
fails(Status::NoDevice, "open by unknown serial") { Dongle.open("nope") }
fails(Status::NoDevice, "open by unknown path") { Dongle.open_path("stub:9") }

d = Dongle.open
check(d.open?, "open")
check(d.serial == SERIAL, "serial")
i = d.info
check(i.protocol_major == 1 && i.protocol_minor == 0, "protocol version")
check(i.firmware_major == 2 && i.firmware_minor == 3 && i.firmware_patch == 4, "firmware version")
check(i.secure_element_ready && i.provisioned && i.isolated, "flags set")
check(!i.watchdog_reboot && !i.write_auth_rotated, "flags clear")
check(i.data_capacity == 1024 * 1024 && i.data_free == 1_000_000, "capacity")
g = d.verify_genuine
check(g.serial == SERIAL && g.provisioned_date == "2026-08-15", "genuine")
check(d.genuine?, "genuine?")

fails(Status::CertInvalid, "malformed trust root") { d.trust_root = Bytes[0x02, 0x01, 0x00] }
root = Bytes.new(132, 0xAB_u8)
root[0] = 0x30_u8
root[1] = 0x82_u8
root[2] = 0x01_u8
root[3] = 0x00_u8
d.trust_root = root
fails(Status::CertInvalid, "verify against a foreign root") { d.verify_genuine }
check(!d.genuine?, "genuine? fails closed")
(4...root.size).each { |k| root[k] = 0x01_u8 }
d.trust_root = root
check(d.genuine?, "genuine? after the right root")

fails(Status::SessionExpired, "records without a session") { d.records }
d.session_open
payload = bytes("license-blob-0123456789")
fails(Status::AuthRequired, "write before the write role") { d.write_record("lic", payload) }
fails(Status::NotGenuine, "write role with a bad key") { d.authorize_write(Bytes[0x30, 0x00]) }
d.authorize_write(FACTORY_KEY)
d.write_record("lic", payload)
check(d.read_record("lic") == payload, "read back")
d.write_record("cfg", bytes("cfgdata"))
recs = d.records
check(recs.map(&.name).sort == ["cfg", "lic"], "record names")
check(recs.any? { |r| r.name == "lic" && r.size == payload.size }, "record size")
check(d.read_record("cfg") == bytes("cfgdata"), "second record")
fails(Status::NotFound, "read a missing record") { d.read_record("nope") }
fails(Status::InvalidArg, "erase with an empty name") { d.erase_record("") }
check(d.records.size == 2, "two records")
d.erase_record("cfg")
check(d.records.map(&.name) == ["lic"], "one record left")
d.write_record("empty", Bytes.empty)
check(d.read_record("empty").empty?, "empty record")

before = d.read_counter(0)
check(d.increment_counter(0) == before + 1, "increment")
check(d.read_counter(0) == before + 1 && d.read_counter(1) == 0, "counters")
fails(Status::Range, "counter out of range") { d.read_counter(7) }

secret = Bytes.new(100) { |k| ((3 * k + 7) % 256).to_u8 }
[Scope::Device, Scope::Developer].each do |scope|
  blob = d.app_encrypt(scope, secret)
  check(blob.size > secret.size, "sealed data is longer, #{scope}")
  check(blob[0] == scope.value, "scope byte, #{scope}")
  check(d.app_decrypt(blob) == secret, "round trip, #{scope}")
  tampered = blob.dup
  tampered[-1] ^= 1_u8
  fails(Status::TagMismatch, "tampered blob, #{scope}") { d.app_decrypt(tampered) }
end

d.erase_all_records
check(d.records.empty?, "erase all")

d.rotate_write_key(REPLACEMENT_KEY)
d.write_record("lic", bytes("still-writable"))
d.session_close
check(d.info.write_auth_rotated, "rotated flag")
d.session_open
fails(Status::NotGenuine, "factory key after rotation") { d.authorize_write(FACTORY_KEY) }
d.authorize_write(REPLACEMENT_KEY)
d.write_record("lic", bytes("new-key-writes"))
check(d.read_record("lic") == bytes("new-key-writes"), "write with the new key")
d.session_close
d.close
check(!d.open?, "closed")
fails(Status::InvalidArg, "serial after close") { d.serial }

via_block = KeyNub::LicDongle.open { |dd| dd.serial }
check(via_block == SERIAL, "open with a block")
# records needs a session, so a value back proves session opened one.
count = Dongle.open(SERIAL) { |dd| dd.session { dd.records.size } }
check(count >= 0, "session with a block")
closed = Dongle.open { |dd| dd }
check(!closed.open?, "closed after the block")
check(KeyNub::LicDongle.loaded_library_path == KeyNub::LicDongle.library_path, "loaded path")

if Tally.failures > 0
  puts "#{Tally.failures} check(s) failed"
  exit 1
end
puts "keynub_licdongle: every call passed against the ABI stand-in"
