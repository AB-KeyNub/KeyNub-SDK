# KeyNub SDK - Crystal sample: take ownership of a new dongle.
#
# A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
# so that from the next session onward only your key can write records, erase
# them or increment counters. Run it once per dongle, when it arrives.
#
# Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
#
#     openssl ecparam -name prime256v1 -genkey -noout |
#       openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
#
#     crystal run samples/crystal/rotate_write_key.cr -- keys/keynub-shipping-writeauth.key.der my-key.der
#
# Targets real hardware: with no dongle attached it prints guidance and exits 0.
#
# The replacement key is worth what your licence-signing key is worth. It
# cannot be recovered from the dongle, and a unit rotated to a key you have
# lost has to come back to be re-provisioned.
require "../../bindings/crystal/src/keynub_licdongle"

alias LD = KeyNub::LicDongle

if ARGV.size != 2
  puts "usage: rotate_write_key <current-key.der> <new-key.der>"
  exit 2
end

begin
  current = File.open(ARGV[0], "rb", &.getb_to_end)
  replacement = File.open(ARGV[1], "rb", &.getb_to_end)
  if LD.devices.empty?
    puts "Connect a KeyNub dongle and re-run."
    exit 0
  end
  LD.open do |d|
    puts "Dongle #{d.serial}"
    if d.info.write_auth_rotated
      puts "This dongle's write key has already been rotated away from the factory one."
    end
    d.session do
      d.authorize_write(current)      # the key the dongle accepts today
      d.rotate_write_key(replacement) # from the next session: only the new one
    end
    puts "Write key rotated: #{d.info.write_auth_rotated ? "yes" : "no"}"
  end
rescue e : LD::Error | LD::LibraryError | IO::Error | File::Error
  puts "KeyNub error: #{e.message}"
  exit 1
end
