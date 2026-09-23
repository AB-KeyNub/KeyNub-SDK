# KeyNub SDK - Crystal sample: verify a dongle and read what it holds.
#
#     crystal run samples/crystal/verify_and_read.cr      (from the repository root)
#
# Targets real hardware: with no dongle attached it prints guidance and exits 0.
# In your own project, after `shards install`: require "keynub_licdongle"
require "../../bindings/crystal/src/keynub_licdongle"

alias LD = KeyNub::LicDongle

def report(d : LD::Dongle)
  i = d.info
  puts "Protocol v#{i.protocol_major}.#{i.protocol_minor}, firmware " \
       "v#{i.firmware_major}.#{i.firmware_minor}.#{i.firmware_patch}, " \
       "#{i.data_free} of #{i.data_capacity} bytes free."
  # The only trace a firmware hang leaves behind. Worth reporting to support.
  puts "WARNING: this dongle's previous boot ended in a watchdog reset." if i.watchdog_reboot
  g = d.verify_genuine
  puts "Genuine: yes (serial #{g.serial}, provisioned #{g.provisioned_date})"
end

def read_records(d : LD::Dongle)
  recs = d.records
  puts "#{recs.size} record(s) on the dongle:"
  recs.each { |r| puts "  #{r.name.ljust(16)} #{r.size} bytes" }
  # A missing record is a normal state, not an error.
  if recs.any? { |r| r.name == "license" }
    puts "Read #{d.read_record("license").size} bytes from the license record."
  end
end

# The part that protects something. At licence-issue time you would
# call app_encrypt once, with a developer dongle, and ship only the sealed data;
# the program then cannot proceed without a dongle, because it holds no other
# copy. Scope::Developer lets any dongle you have issued decrypt it, so one file
# serves every customer; Scope::Device locks it to one dongle.
def protect_something(d : LD::Dongle)
  needed = "the data this program cannot run without".to_slice
  sealed = d.app_encrypt(LD::Scope::Developer, needed)
  recovered = d.app_decrypt(sealed)
  puts "App-crypto round trip: #{needed.size} bytes -> #{sealed.size} sealed -> " \
       "#{recovered == needed ? "recovered intact" : "MISMATCH"}"
end

begin
  v = LD.library_version
  puts "KeyNub library v#{v.major}.#{v.minor}.#{v.patch}"
  if LD.devices.empty?
    puts "Connect a KeyNub dongle and re-run."
    exit 0
  end
  LD.open do |d| # first dongle, or LD.open("serial")
    report(d)
    d.session do # closed on every exit path
      read_records(d)
      protect_something(d)
    end
  end
rescue e : LD::Error | LD::LibraryError
  puts "KeyNub error: #{e.message}"
  exit 1
end
