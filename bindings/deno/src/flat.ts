// The SDK's flat C API (bindings/flat/licd_flat.h): one entry per C function,
// with the parameter and result types Deno.dlopen needs.

/** Bits in the flags value of licdf_get_info. */
export const FLAG_SECURE_ELEMENT_READY = 0x01;
export const FLAG_PROVISIONED = 0x02;
export const FLAG_WATCHDOG_REBOOT = 0x04;
export const FLAG_ISOLATED = 0x08;
export const FLAG_WRITE_AUTH_ROTATED = 0x10;

/** Buffer sizes (LICDF_SERIAL_SIZE, LICDF_DATE_SIZE, LICDF_PATH_SIZE, LICDF_ERROR_SIZE), and one for a record name. */
export const SERIAL_SIZE = 15;
export const DATE_SIZE = 11;
export const PATH_SIZE = 512;
export const ERROR_SIZE = 256;
export const NAME_SIZE = 256;

const i32 = "i32" as const;
const buf = "buffer" as const;

export const SYMBOLS = {
  licdf_version: { parameters: [buf, buf, buf], result: i32 },
  licdf_device_count: { parameters: [buf], result: i32 },
  licdf_device_serial: { parameters: [i32, buf, i32], result: i32 },
  licdf_device_path: { parameters: [i32, buf, i32], result: i32 },
  licdf_open: { parameters: [buf], result: i32 },
  licdf_open_path: { parameters: [buf], result: i32 },
  licdf_close: { parameters: [i32], result: i32 },
  licdf_set_trust_root: { parameters: [i32, buf, i32], result: i32 },
  licdf_get_serial: { parameters: [i32, buf, i32], result: i32 },
  licdf_get_info: { parameters: [i32, buf, buf, buf, buf, buf, buf, buf, buf], result: i32 },
  licdf_verify_genuine: { parameters: [i32, buf, buf, i32, buf, i32], result: i32 },
  licdf_session_open: { parameters: [i32], result: i32 },
  licdf_session_close: { parameters: [i32], result: i32 },
  licdf_write_auth: { parameters: [i32, buf, i32], result: i32 },
  licdf_write_auth_rotate: { parameters: [i32, buf, i32], result: i32 },
  licdf_record_count: { parameters: [i32, buf], result: i32 },
  licdf_record_name: { parameters: [i32, i32, buf, i32, buf], result: i32 },
  licdf_record_size: { parameters: [i32, buf, buf], result: i32 },
  licdf_record_read: { parameters: [i32, buf, buf, i32, buf], result: i32 },
  licdf_record_write: { parameters: [i32, buf, buf, i32], result: i32 },
  licdf_record_erase: { parameters: [i32, buf], result: i32 },
  licdf_record_erase_all: { parameters: [i32], result: i32 },
  licdf_counter_read: { parameters: [i32, i32, buf], result: i32 },
  licdf_counter_increment: { parameters: [i32, i32, buf], result: i32 },
  licdf_app_encrypt: { parameters: [i32, i32, buf, i32, buf, i32, buf], result: i32 },
  licdf_app_decrypt: { parameters: [i32, buf, i32, buf, i32, buf], result: i32 },
  licdf_strerror: { parameters: [i32, buf, i32], result: i32 },
  licdf_last_error: { parameters: [i32, buf, i32], result: i32 },
} as const;

/** The loaded library's functions. */
export type Api = Deno.DynamicLibrary<typeof SYMBOLS>["symbols"];
