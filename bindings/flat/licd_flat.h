// KeyNub License Dongle SDK — flat companion API.
//
// The same functionality as `include/licdongle.h`, expressed so that a
// language which can only call simple C functions can use it. LabVIEW's Call
// Library Function Node, Excel/VBA's Declare statement, Fortran's ISO_C_BINDING
// and most scripting-language FFIs all share the same three limitations, and this
// header removes all three:
//
//   * no opaque pointers            -> int32 handles from a table in the library
//   * no library-allocated memory   -> caller-allocated buffers everywhere, with
//                                      LICD_E_RANGE and the required size when
//                                      the buffer is too small
//   * no function pointers          -> no callbacks at all; no progress reporting
//
// It is a thin layer over the core, in its own shared library
// (keynub_licdongle_flat), so the core ABI keeps its exact shape. Prefer the core
// ABI, or one of the language bindings built on it, whenever your language can
// express it: this API cannot report progress or cancel a transfer, and it
// serializes calls.
//
// CONVENTIONS
//   * Every function returns int32: 0 (LICD_OK) on success, otherwise a negative
//     licd_status from licdongle.h. licdf_open is the exception — it returns a
//     positive handle, or a negative status.
//   * Strings are UTF-8 and NUL-terminated on return. An empty input string means
//     "not specified" wherever a null pointer would in the core API.
//   * Byte buffers: pass the capacity; on success *out_len is what was written. If
//     the buffer is too small the call returns LICD_E_RANGE and sets *out_len to
//     the size needed, so the usual pattern is to ask once with a capacity of 0.
//   * All out-parameters may be null if you do not want that value.
//   * Calls are serialized by a lock inside the library, so it is safe to call
//     from several threads — but two threads will not talk to two dongles at the
//     same time. Use the core ABI if that matters.
//
// Threading aside, the security notes in the core header apply unchanged, and so
// does docs/integration-security.md: gate on data the program needs
// (licdf_app_decrypt), not on a boolean.

#ifndef LICD_FLAT_H
#define LICD_FLAT_H

#include <stdint.h>

#include "licdongle.h" // status codes and LICD_SERIAL_HEX_LEN

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  if defined(LICDF_BUILD_SHARED)
#    define LICDF_API __declspec(dllexport)
#  elif defined(LICDF_USE_SHARED)
#    define LICDF_API __declspec(dllimport)
#  else
#    define LICDF_API
#  endif
#else
#  if defined(LICDF_BUILD_SHARED)
#    define LICDF_API __attribute__((visibility("default")))
#  else
#    define LICDF_API
#  endif
#endif

// Bits in the `flags` out-parameter of licdf_get_info.
#define LICDF_FLAG_SE_READY 0x01
#define LICDF_FLAG_PROVISIONED 0x02
#define LICDF_FLAG_WATCHDOG_REBOOT 0x04
#define LICDF_FLAG_ISOLATED 0x08

// Buffer sizes worth naming, so a caller in a language without sizeof can size
// its arrays.
#define LICDF_SERIAL_SIZE 19 // LICD_SERIAL_HEX_LEN + 1
#define LICDF_PATH_SIZE 512
#define LICDF_BATCH_SIZE 64
#define LICDF_ERROR_SIZE 256

// --- version ---------------------------------------------------------------
LICDF_API int32_t licdf_version(int32_t *out_major, int32_t *out_minor, int32_t *out_patch);

// --- discovery -------------------------------------------------------------
// Takes a snapshot of the attached dongles and reports how many there are. The
// snapshot is held in the library until the next licdf_device_count call, which is
// what makes licdf_device_serial/_path index-addressable without a handle.
LICDF_API int32_t licdf_device_count(int32_t *out_count);
LICDF_API int32_t licdf_device_serial(int32_t index, char *out, int32_t out_size);
LICDF_API int32_t licdf_device_path(int32_t index, char *out, int32_t out_size);

// --- open / close ----------------------------------------------------------
// Returns a positive handle, or a negative licd_status. An empty or null serial
// opens the first dongle found. Each handle owns its own library context.
LICDF_API int32_t licdf_open(const char *serial_or_empty);
LICDF_API int32_t licdf_open_path(const char *path);
LICDF_API int32_t licdf_close(int32_t handle);

// Overrides the CA root that licdf_verify_genuine checks against. Applications do
// not need this: a release build embeds the KeyNub production root.
LICDF_API int32_t licdf_set_trust_root(int32_t handle, const uint8_t *der, int32_t der_len);

// --- plaintext info --------------------------------------------------------
LICDF_API int32_t licdf_get_serial(int32_t handle, char *out, int32_t out_size);
// `out_flags` is a bitmask of the LICDF_FLAG_* values above.
LICDF_API int32_t licdf_get_info(int32_t handle, int32_t *out_proto_major,
                                 int32_t *out_proto_minor, int32_t *out_fw_major,
                                 int32_t *out_fw_minor, int32_t *out_fw_patch,
                                 int32_t *out_flags, int32_t *out_capacity,
                                 int32_t *out_free);

// Proves authenticity: certificate chain to the trusted root plus a live
// challenge-response. Returns LICD_OK only when the dongle is genuine.
LICDF_API int32_t licdf_verify_genuine(int32_t handle, int32_t *out_genuine, char *out_serial,
                                       int32_t serial_size, char *out_batch, int32_t batch_size);

// --- session ---------------------------------------------------------------
LICDF_API int32_t licdf_session_open(int32_t handle);
LICDF_API int32_t licdf_session_close(int32_t handle);
// Elevates to the write role with the developer master key. Vendor tooling only.
LICDF_API int32_t licdf_write_auth(int32_t handle, const uint8_t *der, int32_t der_len);

// --- records ---------------------------------------------------------------
// Records are addressed by index for listing, because this API cannot return an
// array of strings. The list is re-read on each call, so a record added between a
// _count and a _name call shifts the indices; read them back to back.
LICDF_API int32_t licdf_record_count(int32_t handle, int32_t *out_count);
LICDF_API int32_t licdf_record_name(int32_t handle, int32_t index, char *out, int32_t out_size,
                                    int32_t *out_record_size);
LICDF_API int32_t licdf_record_size(int32_t handle, const char *name, int32_t *out_size);
LICDF_API int32_t licdf_record_read(int32_t handle, const char *name, uint8_t *out,
                                    int32_t out_cap, int32_t *out_len);
LICDF_API int32_t licdf_record_write(int32_t handle, const char *name, const uint8_t *data,
                                     int32_t data_len);
LICDF_API int32_t licdf_record_erase(int32_t handle, const char *name);
// Separate from _erase so that an accidentally empty name cannot wipe the dongle.
LICDF_API int32_t licdf_record_erase_all(int32_t handle);

// --- counters --------------------------------------------------------------
// Hardware monotonic counters. The secure element's counters top out well below
// 2^31, so a signed int32 is a safe carrier.
LICDF_API int32_t licdf_counter_read(int32_t handle, int32_t counter_id, int32_t *out_value);
LICDF_API int32_t licdf_counter_increment(int32_t handle, int32_t counter_id,
                                          int32_t *out_value);

// --- app-data envelope encryption -----------------------------------------
// scope: 0 = this dongle only, 1 = any dongle from the same developer batch.
// This is the pair to build a licence check on: put something the program needs
// through it, so removing the check removes the data.
LICDF_API int32_t licdf_app_encrypt(int32_t handle, int32_t scope, const uint8_t *plaintext,
                                    int32_t plaintext_len, uint8_t *out, int32_t out_cap,
                                    int32_t *out_len);
LICDF_API int32_t licdf_app_decrypt(int32_t handle, const uint8_t *packed, int32_t packed_len,
                                    uint8_t *out, int32_t out_cap, int32_t *out_len);

// --- errors ----------------------------------------------------------------
// Human-readable text for a status code; needs no handle.
LICDF_API int32_t licdf_strerror(int32_t status, char *out, int32_t out_size);
// Diagnostic detail for the most recent failure on this handle (may be empty).
LICDF_API int32_t licdf_last_error(int32_t handle, char *out, int32_t out_size);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // LICD_FLAT_H
