# The SDK's flat C API (`bindings/flat/licd_flat.h`): the function table the
# loader fills from the library, one proc per C function.
module KeyNub::LicDongle
  # Bits in the flags value of licdf_get_info.
  FLAG_SECURE_ELEMENT_READY = 0x01
  FLAG_PROVISIONED          = 0x02
  FLAG_WATCHDOG_REBOOT      = 0x04
  FLAG_ISOLATED             = 0x08
  FLAG_WRITE_AUTH_ROTATED   = 0x10

  # Buffer sizes (LICDF_SERIAL_SIZE, LICDF_DATE_SIZE, LICDF_PATH_SIZE,
  # LICDF_ERROR_SIZE), and one for a record name.
  SERIAL_SIZE =  15
  DATE_SIZE   =  11
  PATH_SIZE   = 512
  ERROR_SIZE  = 256
  NAME_SIZE   = 256

  # :nodoc:
  module Flat
    # The 28 functions of the flat API: the table's field, the C symbol it is
    # resolved from, and the C signature as a proc type.
    macro define_api(*functions)
      struct Api
        {% for f in functions %}
          getter {{ f[0].id }} : {{ f[2] }}
        {% end %}

        def initialize(
          {% for f in functions %}
            @{{ f[0].id }} : {{ f[2] }},
          {% end %}
        )
        end

        # Resolves every symbol through the block, which returns the
        # address or a null pointer; the name of the first missing symbol
        # instead of a table when one is missing.
        def self.resolve(& : String -> Void*) : Api | String
          {% for f in functions %}
            %address{f[0]} = yield {{ f[1] }}
            return {{ f[1] }} if %address{f[0]}.null?
          {% end %}
          new(
            {% for f in functions %}
              {{ f[2] }}.new(%address{f[0]}, Pointer(Void).null),
            {% end %}
          )
        end
      end
    end

    define_api(
      {version, "licdf_version", Proc(Int32*, Int32*, Int32*, Int32)},
      {device_count, "licdf_device_count", Proc(Int32*, Int32)},
      {device_serial, "licdf_device_serial", Proc(Int32, UInt8*, Int32, Int32)},
      {device_path, "licdf_device_path", Proc(Int32, UInt8*, Int32, Int32)},
      {open, "licdf_open", Proc(UInt8*, Int32)},
      {open_path, "licdf_open_path", Proc(UInt8*, Int32)},
      {close, "licdf_close", Proc(Int32, Int32)},
      {set_trust_root, "licdf_set_trust_root", Proc(Int32, UInt8*, Int32, Int32)},
      {get_serial, "licdf_get_serial", Proc(Int32, UInt8*, Int32, Int32)},
      {get_info, "licdf_get_info", Proc(Int32, Int32*, Int32*, Int32*, Int32*, Int32*, Int32*, Int32*, Int32*, Int32)},
      {verify_genuine, "licdf_verify_genuine", Proc(Int32, Int32*, UInt8*, Int32, UInt8*, Int32, Int32)},
      {session_open, "licdf_session_open", Proc(Int32, Int32)},
      {session_close, "licdf_session_close", Proc(Int32, Int32)},
      {write_auth, "licdf_write_auth", Proc(Int32, UInt8*, Int32, Int32)},
      {write_auth_rotate, "licdf_write_auth_rotate", Proc(Int32, UInt8*, Int32, Int32)},
      {record_count, "licdf_record_count", Proc(Int32, Int32*, Int32)},
      {record_name, "licdf_record_name", Proc(Int32, Int32, UInt8*, Int32, Int32*, Int32)},
      {record_size, "licdf_record_size", Proc(Int32, UInt8*, Int32*, Int32)},
      {record_read, "licdf_record_read", Proc(Int32, UInt8*, UInt8*, Int32, Int32*, Int32)},
      {record_write, "licdf_record_write", Proc(Int32, UInt8*, UInt8*, Int32, Int32)},
      {record_erase, "licdf_record_erase", Proc(Int32, UInt8*, Int32)},
      {record_erase_all, "licdf_record_erase_all", Proc(Int32, Int32)},
      {counter_read, "licdf_counter_read", Proc(Int32, Int32, Int32*, Int32)},
      {counter_increment, "licdf_counter_increment", Proc(Int32, Int32, Int32*, Int32)},
      {app_encrypt, "licdf_app_encrypt", Proc(Int32, Int32, UInt8*, Int32, UInt8*, Int32, Int32*, Int32)},
      {app_decrypt, "licdf_app_decrypt", Proc(Int32, UInt8*, Int32, UInt8*, Int32, Int32*, Int32)},
      {strerror, "licdf_strerror", Proc(Int32, UInt8*, Int32, Int32)},
      {last_error, "licdf_last_error", Proc(Int32, UInt8*, Int32, Int32)},
    )
  end
end
