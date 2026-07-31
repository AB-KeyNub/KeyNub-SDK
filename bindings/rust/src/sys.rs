//! Raw declarations of the KeyNub C ABI (``include/licdongle.h`).
//!
//! Hand-written rather than bindgen-generated: bindgen would add a build
//! dependency on libclang for every downstream user of a licensing crate, to
//! restate a frozen, twenty-eight-function ABI. The cost is that nothing checks
//! these against the header at compile time, which is why every one of them is
//! exercised by the crate's test suite.
//!
//! Nothing here is part of the public API; use the safe wrapper in `lib.rs`.

#![allow(non_camel_case_types)]
// The module is documented as a whole above; restating each of twenty-eight C
// prototypes in rustdoc would only paraphrase licdongle.h, which is the authority.
#![allow(missing_docs)]

use core::ffi::{c_char, c_int, c_void};

pub const LICD_OK: c_int = 0;
pub const LICD_E_INVALID_ARG: c_int = -1;
pub const LICD_E_NO_DEVICE: c_int = -2;
pub const LICD_E_ACCESS_DENIED: c_int = -3;
pub const LICD_E_IO: c_int = -4;
pub const LICD_E_TIMEOUT: c_int = -5;
pub const LICD_E_PROTOCOL: c_int = -6;
pub const LICD_E_NOT_GENUINE: c_int = -7;
pub const LICD_E_CERT_INVALID: c_int = -8;
pub const LICD_E_SESSION_EXPIRED: c_int = -9;
pub const LICD_E_TAG_MISMATCH: c_int = -10;
pub const LICD_E_RANGE: c_int = -11;
pub const LICD_E_STORAGE_FULL: c_int = -12;
pub const LICD_E_BUSY: c_int = -13;
pub const LICD_E_NOT_FOUND: c_int = -14;
pub const LICD_E_AUTH_REQUIRED: c_int = -15;
pub const LICD_E_FW_INCOMPATIBLE: c_int = -16;
pub const LICD_E_SDK_TOO_OLD: c_int = -17;
pub const LICD_E_CANCELLED: c_int = -18;
pub const LICD_E_NOT_IMPLEMENTED: c_int = -19;
pub const LICD_E_INTERNAL: c_int = -20;

pub const LICD_SERIAL_HEX_LEN: usize = 18;

/// Opaque; only ever handled behind a pointer.
#[repr(C)]
pub struct licd_ctx {
    _private: [u8; 0],
}

#[repr(C)]
pub struct licd_device {
    _private: [u8; 0],
}

#[repr(C)]
pub struct licd_device_info {
    pub serial: [c_char; LICD_SERIAL_HEX_LEN + 1],
    pub path: [c_char; 512],
    pub vendor_id: u16,
    pub product_id: u16,
}

#[repr(C)]
#[derive(Default)]
pub struct licd_info {
    pub proto_version_major: u8,
    pub proto_version_minor: u8,
    pub fw_version_major: u8,
    pub fw_version_minor: u8,
    pub fw_version_patch: u8,
    pub se_ready: c_int,
    pub provisioned: c_int,
    pub data_capacity: u32,
    pub data_free: u32,
    pub watchdog_reboot: c_int,
    pub isolated: c_int,
}

#[repr(C)]
pub struct licd_genuine_result {
    pub genuine: c_int,
    pub serial: [c_char; LICD_SERIAL_HEX_LEN + 1],
    pub batch: [c_char; 64],
    pub provisioned_date: [c_char; 11],
}

impl Default for licd_genuine_result {
    fn default() -> Self {
        Self {
            genuine: 0,
            serial: [0; LICD_SERIAL_HEX_LEN + 1],
            batch: [0; 64],
            provisioned_date: [0; 11],
        }
    }
}

pub type licd_progress_cb =
    Option<unsafe extern "C" fn(done: u32, total: u32, user: *mut c_void) -> c_int>;
pub type licd_log_cb =
    Option<unsafe extern "C" fn(level: c_int, msg: *const c_char, user: *mut c_void)>;

extern "C" {
    pub fn licd_version(major: *mut c_int, minor: *mut c_int, patch: *mut c_int);
    pub fn licd_init(out_ctx: *mut *mut licd_ctx) -> c_int;
    pub fn licd_free(ctx: *mut licd_ctx);
    pub fn licd_set_log_callback(ctx: *mut licd_ctx, cb: licd_log_cb, user: *mut c_void);
    pub fn licd_set_trust_root(ctx: *mut licd_ctx, der: *const u8, len: usize) -> c_int;

    pub fn licd_enumerate(
        ctx: *mut licd_ctx,
        out_list: *mut *mut licd_device_info,
        out_count: *mut usize,
    ) -> c_int;
    pub fn licd_free_device_list(list: *mut licd_device_info, count: usize);
    pub fn licd_open(
        ctx: *mut licd_ctx,
        serial_or_null: *const c_char,
        out_dev: *mut *mut licd_device,
    ) -> c_int;
    pub fn licd_open_path(
        ctx: *mut licd_ctx,
        path: *const c_char,
        out_dev: *mut *mut licd_device,
    ) -> c_int;
    pub fn licd_close(dev: *mut licd_device);

    pub fn licd_get_info(dev: *mut licd_device, out_info: *mut licd_info) -> c_int;
    pub fn licd_get_serial(dev: *mut licd_device, out: *mut c_char, size: usize) -> c_int;

    pub fn licd_verify_genuine(
        dev: *mut licd_device,
        out_result: *mut licd_genuine_result,
    ) -> c_int;
    pub fn licd_session_open(dev: *mut licd_device) -> c_int;
    pub fn licd_session_close(dev: *mut licd_device) -> c_int;
    pub fn licd_write_auth(dev: *mut licd_device, der: *const u8, len: usize) -> c_int;

    pub fn licd_record_list(
        dev: *mut licd_device,
        out_names: *mut *mut *mut c_char,
        out_sizes: *mut *mut u32,
        out_count: *mut usize,
    ) -> c_int;
    pub fn licd_free_record_list(names: *mut *mut c_char, sizes: *mut u32, count: usize);
    #[allow(clippy::too_many_arguments)]
    pub fn licd_record_read(
        dev: *mut licd_device,
        name: *const c_char,
        offset: u32,
        buf: *mut c_void,
        buf_size: u32,
        out_len: *mut u32,
        out_total: *mut u32,
        progress: licd_progress_cb,
        user: *mut c_void,
    ) -> c_int;
    pub fn licd_record_write(
        dev: *mut licd_device,
        name: *const c_char,
        data: *const c_void,
        len: u32,
        progress: licd_progress_cb,
        user: *mut c_void,
    ) -> c_int;
    pub fn licd_record_erase(dev: *mut licd_device, name: *const c_char) -> c_int;

    pub fn licd_counter_read(dev: *mut licd_device, id: u8, out_value: *mut u32) -> c_int;
    pub fn licd_counter_increment(dev: *mut licd_device, id: u8, out_value: *mut u32) -> c_int;

    pub fn licd_app_encrypt(
        dev: *mut licd_device,
        scope: c_int,
        plaintext: *const c_void,
        len: u32,
        out: *mut *mut u8,
        out_len: *mut u32,
    ) -> c_int;
    pub fn licd_app_decrypt(
        dev: *mut licd_device,
        packed: *const c_void,
        packed_len: u32,
        out: *mut *mut u8,
        out_len: *mut u32,
    ) -> c_int;
    pub fn licd_free_buffer(buf: *mut u8);

    pub fn licd_strerror(status: c_int) -> *const c_char;
    pub fn licd_error_detail(ctx: *mut licd_ctx) -> *const c_char;
}
