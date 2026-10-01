use v6.d;
use NativeCall;

#| The SDK's flat C API (bindings/flat/licd_flat.h): one native sub per C
#| function, resolved from the library file in $library-file on its first call.
unit module KeyNub::LicDongle::Flat;

#| Bits in the flags value of licdf_get_info.
our constant FLAG-SECURE-ELEMENT-READY = 0x01;
our constant FLAG-PROVISIONED          = 0x02;
our constant FLAG-WATCHDOG-REBOOT      = 0x04;
our constant FLAG-ISOLATED             = 0x08;
our constant FLAG-WRITE-AUTH-ROTATED   = 0x10;

#| Buffer sizes (LICDF_SERIAL_SIZE, LICDF_DATE_SIZE, LICDF_PATH_SIZE,
#| LICDF_ERROR_SIZE), and one for a record name.
our constant SERIAL-SIZE = 15;
our constant DATE-SIZE   = 11;
our constant PATH-SIZE   = 512;
our constant ERROR-SIZE  = 256;
our constant NAME-SIZE   = 256;

#| The C symbols of the flat API, in header order.
our constant SYMBOLS = <
    licdf_version licdf_device_count licdf_device_serial licdf_device_path
    licdf_open licdf_open_path licdf_close licdf_set_trust_root
    licdf_get_serial licdf_get_info licdf_verify_genuine
    licdf_session_open licdf_session_close licdf_write_auth licdf_write_auth_rotate
    licdf_record_count licdf_record_name licdf_record_size licdf_record_read
    licdf_record_write licdf_record_erase licdf_record_erase_all
    licdf_counter_read licdf_counter_increment
    licdf_app_encrypt licdf_app_decrypt
    licdf_strerror licdf_last_error
>;

#| The library file the native subs load; set before the first call.
our $library-file;

sub library() { $library-file }

our sub licdf_version(int32 is rw, int32 is rw, int32 is rw --> int32) is native(&library) { * }

our sub licdf_device_count(int32 is rw --> int32) is native(&library) { * }
our sub licdf_device_serial(int32, Blob, int32 --> int32) is native(&library) { * }
our sub licdf_device_path(int32, Blob, int32 --> int32) is native(&library) { * }

our sub licdf_open(Str --> int32) is native(&library) { * }
our sub licdf_open_path(Str --> int32) is native(&library) { * }
our sub licdf_close(int32 --> int32) is native(&library) { * }
our sub licdf_set_trust_root(int32, Blob, int32 --> int32) is native(&library) { * }

our sub licdf_get_serial(int32, Blob, int32 --> int32) is native(&library) { * }
our sub licdf_get_info(int32, int32 is rw, int32 is rw, int32 is rw, int32 is rw,
        int32 is rw, int32 is rw, int32 is rw, int32 is rw --> int32) is native(&library) { * }
our sub licdf_verify_genuine(int32, int32 is rw, Blob, int32, Blob, int32 --> int32)
        is native(&library) { * }

our sub licdf_session_open(int32 --> int32) is native(&library) { * }
our sub licdf_session_close(int32 --> int32) is native(&library) { * }
our sub licdf_write_auth(int32, Blob, int32 --> int32) is native(&library) { * }
our sub licdf_write_auth_rotate(int32, Blob, int32 --> int32) is native(&library) { * }

our sub licdf_record_count(int32, int32 is rw --> int32) is native(&library) { * }
our sub licdf_record_name(int32, int32, Blob, int32, int32 is rw --> int32) is native(&library) { * }
our sub licdf_record_size(int32, Str, int32 is rw --> int32) is native(&library) { * }
our sub licdf_record_read(int32, Str, Blob, int32, CArray[int32] --> int32) is native(&library) { * }
our sub licdf_record_write(int32, Str, Blob, int32 --> int32) is native(&library) { * }
our sub licdf_record_erase(int32, Str --> int32) is native(&library) { * }
our sub licdf_record_erase_all(int32 --> int32) is native(&library) { * }

our sub licdf_counter_read(int32, int32, int32 is rw --> int32) is native(&library) { * }
our sub licdf_counter_increment(int32, int32, int32 is rw --> int32) is native(&library) { * }

our sub licdf_app_encrypt(int32, int32, Blob, int32, Blob, int32, CArray[int32] --> int32)
        is native(&library) { * }
our sub licdf_app_decrypt(int32, Blob, int32, Blob, int32, CArray[int32] --> int32)
        is native(&library) { * }

our sub licdf_strerror(int32, Blob, int32 --> int32) is native(&library) { * }
our sub licdf_last_error(int32, Blob, int32 --> int32) is native(&library) { * }
