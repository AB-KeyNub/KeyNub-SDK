#!/usr/bin/env ruby
# frozen_string_literal: true

# KeyNub dongle check from Ruby: enumerate -> open -> verify -> session -> read a
# record -> app-crypto round trip. The Ruby equivalent of
# samples/c/verify_and_read.
#
#   gem install keynub_licdongle
#   ruby verify_and_read.rb
#
# Targets real hardware: with no dongle attached it prints guidance and exits 0.
#
# NOTE what this sample is not: it prints whether the dongle is genuine, which is
# the one thing a real licence check must not do. The last section shows the shape
# that actually protects something. See docs/integration-security.md.

begin
  require 'keynub_licdongle'
rescue LoadError
  # Running from a checkout, where the gem is not installed.
  $LOAD_PATH.unshift(File.expand_path('../../bindings/ruby/lib', __dir__))
  require 'keynub_licdongle'
end

def main
  major, minor, patch = KeyNubLicDongle::Context.library_version
  puts "KeyNub SDK #{major}.#{minor}.#{patch}"

  KeyNubLicDongle::Context.open do |ctx|
    devices = ctx.enumerate
    puts "Found #{devices.length} KeyNub dongle(s)."
    devices.each_with_index do |device, i|
      puts format('  [%d] serial %s (VID %04X PID %04X)',
                  i, device[:serial], device[:vendor_id], device[:product_id])
    end
    if devices.empty?
      puts 'No dongle attached; nothing to do.'
      return 0
    end

    dongle = ctx.open # first dongle; pass a serial to pick a specific one
    begin
      info = dongle.info
      puts "Protocol v#{info[:protocol_version].join('.')}, " \
           "firmware v#{info[:firmware_version].join('.')}, " \
           "#{info[:data_free]} of #{info[:data_capacity]} bytes free."
      if info[:watchdog_reboot]
        # The only trace a firmware hang leaves behind. Worth reporting.
        warn "WARNING: this dongle's previous boot ended in a watchdog reset."
      end

      result = dongle.verify_genuine!
      puts "Genuine: #{result[:genuine]} (serial #{result[:serial]}, " \
           "provisioned #{result[:provisioned_date]})"

      dongle.session do |session|
        records = session.list_records
        puts "#{records.length} record(s) on the dongle:"
        records.each { |r| puts format('  %-16s %6d bytes', r[:name], r[:size]) }

        if records.any? { |r| r[:name] == 'license' }
          data = session.read_record('license') do |done, total|
            print "\r  reading license: #{done}/#{total}"
            true
          end
          puts
          puts "Read #{data.bytesize} bytes from the license record."
        end

        protect_something(session)
      end
    ensure
      dongle.close
    end
  end
  0
rescue KeyNubLicDongle::DeviceNotFoundError
  puts 'The dongle was disconnected while we were talking to it.'
  0
rescue KeyNubLicDongle::Error => e
  warn "KeyNub error: #{e.message}"
  warn "  detail: #{e.detail}" unless e.detail.empty?
  1
end

# At licence-issue time you would run app_encrypt once, with a developer dongle,
# and ship only the blob. At run time the application cannot proceed without a
# dongle, because it holds no other copy of the data.
def protect_something(session)
  needed = 'the data this program cannot run without'
  blob = session.app_encrypt(KeyNubLicDongle::Scope::DEVELOPER, needed)
  recovered = session.app_decrypt(blob)
  puts "App-crypto round trip: #{needed.bytesize} bytes -> #{blob.bytesize} sealed -> " \
       "#{recovered == needed.b ? 'recovered intact' : 'MISMATCH'}"
end

exit(main) if $PROGRAM_NAME == __FILE__
