# frozen_string_literal: true

# FFI layer: locates the native core and declares the C ABI
# (`include/licdongle.h`).
#
# Built on Fiddle, which is part of Ruby's standard library, so this binding needs
# **no gems at all** — not ffi, not a compiled extension. For a licensing library
# that matters twice: no build toolchain at the customer, and no third-party
# dependency in the path of the check.
#
# The cost is that these signatures are strings no compiler verifies, which is why
# so every one of them is written out by hand.

require 'fiddle'
require 'fiddle/import'
require 'rbconfig'

module KeyNubLicDongle
  # C struct layouts. Fiddle computes the padding, so the offsets are not
  # hand-maintained — getting one wrong reads a neighbouring field, and the
  # symptom is a plausible-looking wrong value rather than a crash.
  module Types
    extend Fiddle::Importer

    Info = struct [
      'unsigned char proto_version_major',
      'unsigned char proto_version_minor',
      'unsigned char fw_version_major',
      'unsigned char fw_version_minor',
      'unsigned char fw_version_patch',
      'int se_ready',
      'int provisioned',
      'unsigned int data_capacity',
      'unsigned int data_free',
      'int watchdog_reboot',
      'int isolated',
      'int writeauth_rotated'
    ]

    GenuineResult = struct [
      'int genuine',
      'char serial[15]',
      'char provisioned_date[11]'
    ]

    DeviceInfo = struct [
      'char serial[15]',
      'char path[512]',
      'unsigned short vendor_id',
      'unsigned short product_id'
    ]
  end

  # Not part of the public API.
  module Native
    BASENAMES = {
      'mswin' => 'keynub_licdongle.dll',
      'mingw' => 'keynub_licdongle.dll',
      'cygwin' => 'keynub_licdongle.dll',
      'darwin' => 'libkeynub_licdongle.dylib'
    }.freeze

    def self.default_basename
      host = RbConfig::CONFIG['host_os']
      BASENAMES.each { |key, name| return name if host.include?(key) }
      'libkeynub_licdongle.so'
    end

    # Where to look, in order. The environment override names a specific library
    # to point at the simulator library.
    def self.candidate_paths
      override = ENV['KEYNUB_LICDONGLE_LIBRARY']
      return [override] if override && !override.empty?

      here = File.dirname(__FILE__)
      [
        File.expand_path(File.join(here, '..', '..', 'vendor', default_basename)),
        # The prebuilt library a checkout of the SDK carries, per platform: what
        # makes a clone runnable with nothing set.
        File.expand_path(File.join(here, '..', '..', '..', '..', 'natives',
                                   repo_rid, default_basename)),
        File.expand_path(File.join(here, default_basename)),
        default_basename # system search path
      ]
    end

    # The natives/<rid> directory name for this Ruby.
    def self.repo_rid
      host = RbConfig::CONFIG['host_os']
      os = if host.include?('mswin') || host.include?('mingw') || host.include?('cygwin')
             'win'
           elsif host.include?('darwin')
             'osx'
           else
             'linux'
           end
      arch = case RbConfig::CONFIG['host_cpu']
             when 'x86_64', 'x64', 'amd64' then 'x64'
             when 'i386', 'i486', 'i586', 'i686', 'x86' then 'x86'
             when 'aarch64', 'arm64' then 'arm64'
             else 'unknown'
             end
      "#{os}-#{arch}"
    end

    def self.load_library
      errors = []
      candidate_paths.each do |path|
        return Fiddle.dlopen(path)
      rescue Fiddle::DLError => e
        errors << "#{path}: #{e.message}"
      end
      raise LoadError,
            "could not load the keynub_licdongle native library; tried:\n  #{errors.join("\n  ")}"
    end

    LIB = load_library

    INT = Fiddle::TYPE_INT
    VOIDP = Fiddle::TYPE_VOIDP
    SIZE_T = Fiddle::TYPE_SIZE_T
    U32 = Fiddle::TYPE_INT # uint32 by value: int is 32-bit everywhere the SDK runs
    VOID = Fiddle::TYPE_VOID

    SIGNATURES = {
      licd_version: [VOID, [VOIDP, VOIDP, VOIDP]],
      licd_init: [INT, [VOIDP]],
      licd_free: [VOID, [VOIDP]],
      licd_set_trust_root: [INT, [VOIDP, VOIDP, SIZE_T]],

      licd_enumerate: [INT, [VOIDP, VOIDP, VOIDP]],
      licd_free_device_list: [VOID, [VOIDP, SIZE_T]],
      licd_open: [INT, [VOIDP, VOIDP, VOIDP]],
      licd_open_path: [INT, [VOIDP, VOIDP, VOIDP]],
      licd_close: [VOID, [VOIDP]],

      licd_get_info: [INT, [VOIDP, VOIDP]],
      licd_get_serial: [INT, [VOIDP, VOIDP, SIZE_T]],

      licd_verify_genuine: [INT, [VOIDP, VOIDP]],
      licd_session_open: [INT, [VOIDP]],
      licd_session_close: [INT, [VOIDP]],
      licd_write_auth: [INT, [VOIDP, VOIDP, SIZE_T]],
      licd_write_auth_rotate: [INT, [VOIDP, VOIDP, SIZE_T]],

      licd_record_list: [INT, [VOIDP, VOIDP, VOIDP, VOIDP]],
      licd_free_record_list: [VOID, [VOIDP, VOIDP, SIZE_T]],
      licd_record_read: [INT, [VOIDP, VOIDP, U32, VOIDP, U32, VOIDP, VOIDP, VOIDP, VOIDP]],
      licd_record_write: [INT, [VOIDP, VOIDP, VOIDP, U32, VOIDP, VOIDP]],
      licd_record_erase: [INT, [VOIDP, VOIDP]],

      licd_counter_read: [INT, [VOIDP, INT, VOIDP]],
      licd_counter_increment: [INT, [VOIDP, INT, VOIDP]],

      licd_app_encrypt: [INT, [VOIDP, INT, VOIDP, U32, VOIDP, VOIDP]],
      licd_app_decrypt: [INT, [VOIDP, VOIDP, U32, VOIDP, VOIDP]],
      licd_free_buffer: [VOID, [VOIDP]],

      licd_strerror: [VOIDP, [INT]],
      licd_error_detail: [VOIDP, [VOIDP]]
    }.freeze

    BOUND = SIGNATURES.each_with_object({}) do |(name, (ret, args)), acc|
      acc[name] = Fiddle::Function.new(LIB[name.to_s], args, ret, name: name.to_s)
    end.freeze

    def self.call(name, *args)
      BOUND.fetch(name).call(*args)
    end

    # --- marshalling helpers ------------------------------------------------

    PTR_SIZE = Fiddle::SIZEOF_VOIDP
    SIZE_T_SIZE = Fiddle::SIZEOF_SIZE_T
    SIZE_T_PACK = SIZE_T_SIZE == 8 ? 'Q' : 'L'

    # A writable buffer, freed by Ruby's GC.
    def self.buffer(size)
      Fiddle::Pointer.malloc(size, Fiddle::RUBY_FREE)
    end

    def self.out_pointer
      buffer(PTR_SIZE)
    end

    def self.out_int32
      buffer(4)
    end

    def self.out_size_t
      buffer(SIZE_T_SIZE)
    end

    def self.read_int32(pointer)
      pointer[0, 4].unpack1('l')
    end

    def self.read_uint32(pointer)
      pointer[0, 4].unpack1('L')
    end

    def self.read_size_t(pointer)
      pointer[0, SIZE_T_SIZE].unpack1(SIZE_T_PACK)
    end

    # A NUL-terminated string out of a fixed-size buffer we own.
    def self.read_fixed_string(bytes)
      nul = bytes.index("\0")
      (nul ? bytes[0, nul] : bytes).dup.force_encoding(Encoding::UTF_8)
    end

    # A NUL-terminated string from a `char *` the library owns.
    def self.read_c_string(address)
      value = address.respond_to?(:to_i) ? address.to_i : address
      return '' if value.zero?

      Fiddle::Pointer.new(value).to_s.dup.force_encoding(Encoding::UTF_8)
    end

    # Copies `length` bytes out of a library-allocated buffer, then frees it.
    def self.take_buffer(out_ptr, length)
      address = out_ptr.ptr
      return String.new(encoding: Encoding::BINARY) if address.to_i.zero? || length.zero?

      begin
        # A pointer read out of another pointer has no size of its own; tell Fiddle
        # how much is really there so the read is in bounds.
        address.size = length
        address[0, length].dup.force_encoding(Encoding::BINARY)
      ensure
        call(:licd_free_buffer, address)
      end
    end

    # A NUL-terminated C string Fiddle can pass, or NULL for nil.
    def self.c_string(value)
      return nil if value.nil?

      "#{value}\0"
    end
  end
end
