# frozen_string_literal: true

# KeyNub License Dongle — Ruby binding.
#
#   require 'keynub_licdongle'
#
#   KeyNubLicDongle::Context.open do |ctx|
#     dongle = ctx.open              # first dongle, or ctx.open(serial)
#     dongle.verify_genuine!         # raises unless genuine
#     dongle.session do |session|
#       data = session.app_decrypt(blob)   # <- build the licence check on this
#     end
#   end
#
# No gems: the FFI layer is Ruby's own Fiddle. Every call is synchronous — a
# dongle round trip is a millisecond or two of USB HID.
#
# Read docs/integration-security.md before deciding where the check goes.
# `exit unless licensed?` is one line to delete, and Ruby ships as source. What
# cannot be deleted is data the program needs and only the dongle can decrypt.

require_relative 'keynub_licdongle/version'
require_relative 'keynub_licdongle/native'
require_relative 'keynub_licdongle/errors'

module KeyNubLicDongle
  # Who can decrypt data produced by Session#app_encrypt.
  module Scope
    DEVICE = 0    # only this one physical dongle
    DEVELOPER = 1 # any dongle from the same developer batch
    ALL = [DEVICE, DEVELOPER].freeze
  end

  SERIAL_BUFFER = 19 # LICD_SERIAL_HEX_LEN + 1
  private_constant :SERIAL_BUFFER

  # The library context: the entry point for finding and opening dongles.
  class Context
    # Yields a context and closes it afterwards, whatever happens.
    def self.open
      ctx = new
      begin
        yield ctx
      ensure
        ctx.close
      end
    end

    # The native core's version, as [major, minor, patch].
    def self.library_version
      parts = Array.new(3) { Native.out_int32 }
      Native.call(:licd_version, *parts)
      parts.map { |p| Native.read_int32(p) }
    end

    def initialize
      out = Native.out_pointer
      KeyNubLicDongle.check(Native.call(:licd_init, out), 'licd_init')
      @handle = out.ptr
      @closed = false
    end

    def closed?
      @closed
    end

    def close
      return if @closed

      @closed = true
      Native.call(:licd_free, @handle)
      @handle = nil
    end

    # The raw handle, for mixing this binding with direct Fiddle calls.
    def handle
      raise Error.new(Status::INVALID_ARGUMENT, 'the context has been closed') if @closed

      @handle
    end

    # The SDK's diagnostic detail for the most recent failure on this thread.
    def last_error_detail
      Native.read_c_string(Native.call(:licd_error_detail, handle))
    end

    # Overrides the CA root that Dongle#verify_genuine checks against.
    #
    # Applications do not need this: a release build embeds the KeyNub production
    # root. It exists for dongles provisioned against a different CA, and for
    # vendor tooling.
    def trust_root=(der)
      bytes = der.to_s.b
      check(Native.call(:licd_set_trust_root, handle, bytes, bytes.bytesize),
            'licd_set_trust_root')
    end

    # Connected dongles, as an array of hashes. Empty when none are attached,
    # which is a normal result rather than an error.
    def enumerate
      list = Native.out_pointer
      count_ptr = Native.out_size_t
      check(Native.call(:licd_enumerate, handle, list, count_ptr), 'licd_enumerate')
      count = Native.read_size_t(count_ptr)
      base = list.ptr
      return [] if count.zero? || base.to_i.zero?

      begin
        stride = Types::DeviceInfo.size
        Array.new(count) do |i|
          entry = Types::DeviceInfo.new(base + (i * stride))
          {
            serial: Native.read_fixed_string(entry.serial.pack('c*')),
            path: Native.read_fixed_string(entry.path.pack('c*')),
            vendor_id: entry.vendor_id,
            product_id: entry.product_id
          }
        end
      ensure
        Native.call(:licd_free_device_list, base, count)
      end
    end

    # Opens the dongle with this serial, or the first one found.
    def open(serial = nil)
      out = Native.out_pointer
      check(Native.call(:licd_open, handle, Native.c_string(serial), out), 'licd_open')
      Dongle.new(self, out.ptr)
    end

    # Opens a specific dongle by the +:path+ from #enumerate.
    def open_path(path)
      out = Native.out_pointer
      check(Native.call(:licd_open_path, handle, Native.c_string(path), out), 'licd_open_path')
      Dongle.new(self, out.ptr)
    end

    # Adopts a device opened through the C ABI directly. Lets this binding be
    # introduced into existing Fiddle code a call at a time, and is how the test
    # harness wraps a simulated device.
    def adopt(device_handle)
      Dongle.new(self, device_handle)
    end

    def check(status, operation) # :nodoc:
      KeyNubLicDongle.check(status, operation, @closed ? nil : @handle)
    end
  end

  # An open connection to a dongle. Plaintext operations here; stored data needs
  # a Session.
  class Dongle
    def initialize(context, handle)
      @context = context
      @handle = handle
      @closed = false
    end

    attr_reader :context

    def closed?
      @closed
    end

    def close
      return if @closed

      @closed = true
      Native.call(:licd_close, @handle)
      @handle = nil
    end

    def handle
      raise Error.new(Status::INVALID_ARGUMENT, 'the dongle has been closed') if @closed

      @handle
    end

    # Plaintext device info, as a hash.
    #
    # +:watchdog_reboot+ reports that the dongle's *previous* boot ended in a
    # watchdog timeout — the firmware hung and reset itself. It is the only trace
    # a field hang leaves behind, and a power cycle clears it, so log it.
    #
    # +:isolated+ reports that the dongle confirmed at boot that its USB and parsing code is fenced off
    # from keys and storage. The software simulator reports false.
    def info
      raw = Types::Info.malloc(Fiddle::RUBY_FREE)
      @context.check(Native.call(:licd_get_info, handle, raw), 'licd_get_info')
      {
        protocol_version: [raw.proto_version_major, raw.proto_version_minor],
        firmware_version: [raw.fw_version_major, raw.fw_version_minor, raw.fw_version_patch],
        se_ready: !raw.se_ready.zero?,
        provisioned: !raw.provisioned.zero?,
        data_capacity: raw.data_capacity,
        data_free: raw.data_free,
        watchdog_reboot: !raw.watchdog_reboot.zero?,
        isolated: !raw.isolated.zero?
      }
    end

    # The dongle serial as hex.
    def serial
      buffer = Native.buffer(SERIAL_BUFFER)
      @context.check(Native.call(:licd_get_serial, handle, buffer, SERIAL_BUFFER),
                     'licd_get_serial')
      Native.read_fixed_string(buffer[0, SERIAL_BUFFER])
    end

    # Proves authenticity: the certificate chain to the trusted root plus a live
    # ECDSA challenge-response. Raises unless the dongle is genuine.
    def verify_genuine!
      raw = Types::GenuineResult.malloc(Fiddle::RUBY_FREE)
      @context.check(Native.call(:licd_verify_genuine, handle, raw), 'licd_verify_genuine')
      {
        genuine: !raw.genuine.zero?,
        serial: Native.read_fixed_string(raw.serial.pack('c*')),
        batch: Native.read_fixed_string(raw.batch.pack('c*')),
        provisioned_date: Native.read_fixed_string(raw.provisioned_date.pack('c*'))
      }
    end

    # The non-raising form, for a licence gate. Fails closed: a missing dongle, an
    # I/O error and an invalid certificate all return false.
    def genuine?
      verify_genuine![:genuine]
    rescue Error
      false
    end

    # Opens an encrypted session (P-256 ECDH, HKDF-SHA256, AES-256-GCM). With a
    # block, closes it afterwards.
    def session
      @context.check(Native.call(:licd_session_open, handle), 'licd_session_open')
      session = Session.new(self)
      return session unless block_given?

      begin
        yield session
      ensure
        session.close
      end
    end
    alias open_session session
  end

  # An open encrypted session: records, counters and app-crypto.
  class Session
    def initialize(dongle)
      @dongle = dongle
      @closed = false
    end

    def closed?
      @closed
    end

    # Ends the session, zeroizing the session keys on the dongle. Never raises:
    # teardown is local state, and this runs from ensure blocks.
    def close
      return if @closed

      @closed = true
      Native.call(:licd_session_close, @dongle.handle) unless @dongle.closed?
    end

    # Elevates to the write role with the developer master key (a DER EC private
    # key). Vendor tooling only — never ship that key in an application.
    def authorize_write(master_key_der)
      bytes = master_key_der.to_s.b
      check(Native.call(:licd_write_auth, device, bytes, bytes.bytesize), 'licd_write_auth')
    end

    # Records stored on the dongle, as an array of {name:, size:} hashes.
    def list_records
      names = Native.out_pointer
      sizes = Native.out_pointer
      count_ptr = Native.out_size_t
      check(Native.call(:licd_record_list, device, names, sizes, count_ptr), 'licd_record_list')
      count = Native.read_size_t(count_ptr)
      name_base = names.ptr
      size_base = sizes.ptr
      return [] if count.zero? || name_base.to_i.zero?

      begin
        Array.new(count) do |i|
          name_ptr = name_base[i * Native::PTR_SIZE, Native::PTR_SIZE].unpack1(Native::SIZE_T_PACK)
          {
            name: Native.read_c_string(name_ptr),
            size: size_base[i * 4, 4].unpack1('L')
          }
        end
      ensure
        Native.call(:licd_free_record_list, name_base, size_base, count)
      end
    end

    # Reads a record. A block is called as +progress(done, total)+; return false
    # from it to cancel, which raises OperationCancelledError.
    def read_record(name, &progress)
      require_name(name)
      cname = Native.c_string(name)

      # Probe for the size first, so progress runs monotonically from 0 to total.
      got = Native.out_int32
      total = Native.out_int32
      probe = Native.buffer(1)
      check(Native.call(:licd_record_read, device, cname, 0, probe, 1, got, total, nil, nil),
            'licd_record_read')
      size = Native.read_uint32(total)
      return String.new(encoding: Encoding::BINARY) if size.zero?

      buffer = Native.buffer(size)
      status = with_progress(progress) do |callback|
        Native.call(:licd_record_read, device, cname, 0, buffer, size, got, total, callback, nil)
      end
      check(status, 'licd_record_read')
      buffer[0, Native.read_uint32(got)].dup.force_encoding(Encoding::BINARY)
    end

    # Atomically replaces a record. Requires the write role.
    def write_record(name, data, &progress)
      require_name(name)
      bytes = data.to_s.b
      status = with_progress(progress) do |callback|
        Native.call(:licd_record_write, device, Native.c_string(name), bytes, bytes.bytesize,
                    callback, nil)
      end
      check(status, 'licd_record_write')
      nil
    end

    # Erases one record. Requires the write role.
    def erase_record(name)
      # A nil name means "erase everything" to the C API; that is #erase_all_records
      # here, so an empty string cannot wipe the dongle.
      require_name(name)
      check(Native.call(:licd_record_erase, device, Native.c_string(name)), 'licd_record_erase')
    end

    # Erases every record. Requires the write role.
    def erase_all_records
      check(Native.call(:licd_record_erase, device, nil), 'licd_record_erase')
    end

    # Reads a hardware monotonic counter.
    def read_counter(counter_id)
      value = Native.out_int32
      check(Native.call(:licd_counter_read, device, counter_id, value), 'licd_counter_read')
      Native.read_uint32(value)
    end

    # Increments a counter and returns the new value. Irreversible: the counter is
    # monotonic in hardware. Requires the write role.
    def increment_counter(counter_id)
      value = Native.out_int32
      check(Native.call(:licd_counter_increment, device, counter_id, value),
            'licd_counter_increment')
      Native.read_uint32(value)
    end

    # Encrypts so that only a dongle of +scope+ can decrypt.
    #
    # This is the pair to build a licence check on: put something the program
    # genuinely needs through it, so removing the check removes the data.
    def app_encrypt(scope, plaintext)
      unless Scope::ALL.include?(scope)
        raise ArgumentError, "scope must be Scope::DEVICE or Scope::DEVELOPER, got #{scope.inspect}"
      end

      bytes = plaintext.to_s.b
      out = Native.out_pointer
      out_len = Native.out_int32
      check(Native.call(:licd_app_encrypt, device, scope, bytes, bytes.bytesize, out, out_len),
            'licd_app_encrypt')
      Native.take_buffer(out, Native.read_uint32(out_len))
    end

    # Decrypts a blob produced by #app_encrypt, using the dongle.
    def app_decrypt(packed)
      bytes = packed.to_s.b
      out = Native.out_pointer
      out_len = Native.out_int32
      check(Native.call(:licd_app_decrypt, device, bytes, bytes.bytesize, out, out_len),
            'licd_app_decrypt')
      Native.take_buffer(out, Native.read_uint32(out_len))
    end

    private

    def device
      raise SessionExpiredError.new(Status::SESSION_EXPIRED, 'the session has been closed') if @closed

      @dongle.handle
    end

    def check(status, operation)
      @dongle.context.check(status, operation)
    end

    def require_name(name)
      return unless name.nil? || name.to_s.empty?

      raise ArgumentError, 'the record name must not be empty'
    end

    # Wraps a Ruby block as a C progress callback and returns the native status.
    #
    # An exception raised inside the block is held until the SDK has unwound its
    # own transfer, then re-raised: letting it escape through the C frames would
    # skip that cleanup and strand the device mid-transfer. It takes precedence
    # over the resulting LICD_E_CANCELLED, because the callback's failure is the
    # cause and the cancellation is only its consequence.
    def with_progress(progress)
      return yield(nil) if progress.nil?

      raised = nil
      callback = Fiddle::Closure::BlockCaller.new(
        Fiddle::TYPE_INT, [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP]
      ) do |done, total, _user|
        if raised
          0
        else
          begin
            # Anything but an explicit false continues, so a callback that only
            # draws a progress bar is safe.
            progress.call(done, total) == false ? 0 : 1
          rescue StandardError => e
            raised = e
            0
          end
        end
      end

      # Held in an ivar, not just a local, so the closure cannot be collected while
      # C holds a pointer to it.
      @active_callback = callback
      begin
        status = yield(callback)
        raise raised if raised

        status
      ensure
        @active_callback = nil
      end
    end
  end
end
