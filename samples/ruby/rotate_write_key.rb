#!/usr/bin/env ruby
# frozen_string_literal: true

# KeyNub SDK - Ruby sample: take ownership of a new dongle.
#
# A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
# that from the next session onward only your key can write records, erase them or
# increment counters. Run it once per dongle, when it arrives.
#
# Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
#
#   openssl ecparam -name prime256v1 -genkey -noout |
#     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
#
#   gem install keynub_licdongle
#   ruby rotate_write_key.rb ../../keys/keynub-shipping-writeauth.key.der my-key.der
#
# Targets real hardware: with no dongle attached it prints guidance and exits 0.
#
# The replacement key is worth what your licence-signing key is worth. It cannot be
# recovered from the dongle, and a unit rotated to a key you have lost has to come
# back to be re-provisioned.

begin
  require 'keynub_licdongle'
rescue LoadError
  # Running from a checkout, where the gem is not installed.
  $LOAD_PATH.unshift(File.expand_path('../../bindings/ruby/lib', __dir__))
  require 'keynub_licdongle'
end

def main(argv)
  if argv.length != 2
    warn 'usage: rotate_write_key.rb <current-key.der> <new-key.der>'
    return 2
  end
  current = File.binread(argv[0])
  replacement = File.binread(argv[1])

  KeyNubLicDongle::Context.open do |ctx|
    if ctx.enumerate.empty?
      puts 'Connect a KeyNub dongle and re-run.'
      return 0
    end

    dongle = ctx.open
    begin
      puts "dongle #{dongle.serial}"

      dongle.session do |session|
        session.authorize_write(current)
        session.rotate_write_key(replacement)
        puts 'rotated: this dongle now answers only to your key'
      end

      # A fresh session is the only place the change is observable: the session
      # above keeps the role it was already granted.
      dongle.session do |session|
        begin
          session.authorize_write(current)
        rescue KeyNubLicDongle::Error
          puts 'confirmed: the old key no longer elevates'
        else
          warn 'WARNING: the old key still works -- do not ship this unit'
          return 1
        end
        session.authorize_write(replacement)
        puts 'confirmed: your key elevates'
      end
    ensure
      dongle.close
    end
  end

  puts
  puts 'Keep the replacement key safe. Every future write to this dongle needs it.'
  0
rescue KeyNubLicDongle::Error => e
  warn "KeyNub error: #{e.message}"
  warn "  detail: #{e.detail}" unless e.detail.empty?
  1
end

exit(main(ARGV)) if $PROGRAM_NAME == __FILE__
