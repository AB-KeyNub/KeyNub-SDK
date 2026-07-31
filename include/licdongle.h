// KeyNub License Dongle SDK — public C ABI.
//
// One core C library; thin per-language bindings sit on top of this header.
// Stable C ABI: opaque handles, integer status codes (never exceptions across
// the boundary), all multi-byte protocol values handled internally.
//
// Wire protocol version 1.
//
// Threading: a licd_ctx is thread-safe; a licd_device must be used by one
// thread at a time (bindings may add their own per-device lock).

#ifndef LICDONGLE_H
#define LICDONGLE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- Export / calling convention -------------------------------------------
#if defined(_WIN32)
#  if defined(LICD_BUILD_SHARED)
#    define LICD_API __declspec(dllexport)
#  elif defined(LICD_USE_SHARED)
#    define LICD_API __declspec(dllimport)
#  else
#    define LICD_API
#  endif
#else
#  if defined(LICD_BUILD_SHARED)
#    define LICD_API __attribute__((visibility("default")))
#  else
#    define LICD_API
#  endif
#endif

// --- Status codes ------------------------------------------------------------
// 0 = success; all errors are negative. Map to idiomatic errors in bindings.
typedef enum {
    LICD_OK = 0,
    LICD_E_INVALID_ARG = -1,   // bad argument from the caller
    LICD_E_NO_DEVICE = -2,     // no matching dongle found / not present
    LICD_E_ACCESS_DENIED = -3, // OS denied device access (see error detail: udev/TCC)
    LICD_E_IO = -4,            // transport read/write failure
    LICD_E_TIMEOUT = -5,       // device did not respond in time
    LICD_E_PROTOCOL = -6,      // malformed/unexpected protocol response
    LICD_E_NOT_GENUINE = -7,   // authenticity check failed
    LICD_E_CERT_INVALID = -8,  // device certificate/chain invalid
    LICD_E_SESSION_EXPIRED = -9, // no/expired session for an encrypted op
    LICD_E_TAG_MISMATCH = -10, // AEAD tag / MAC verification failed
    LICD_E_RANGE = -11,        // offset/length out of range
    LICD_E_STORAGE_FULL = -12, // dongle data area exhausted
    LICD_E_BUSY = -13,         // device busy with a prior operation
    LICD_E_NOT_FOUND = -14,    // named record does not exist
    LICD_E_AUTH_REQUIRED = -15, // operation needs a session / the write role
    LICD_E_FW_INCOMPATIBLE = -16, // firmware protocol newer than this SDK
    LICD_E_SDK_TOO_OLD = -17,  // alias of FW_INCOMPATIBLE from the SDK's view
    LICD_E_CANCELLED = -18,    // cancelled via progress callback
    LICD_E_NOT_IMPLEMENTED = -19, // declared but not implemented in this build
    LICD_E_INTERNAL = -20,     // internal/unknown error
} licd_status;

// App-data encryption scope (see licd_app_encrypt).
typedef enum {
    LICD_SCOPE_DEVICE = 0,    // only this physical dongle can decrypt
    LICD_SCOPE_DEVELOPER = 1, // any dongle from the same developer batch
} licd_scope;

// Log levels for the optional diagnostic callback.
typedef enum {
    LICD_LOG_ERROR = 0,
    LICD_LOG_WARN = 1,
    LICD_LOG_INFO = 2,
    LICD_LOG_DEBUG = 3,
} licd_log_level;

// --- Opaque handles ----------------------------------------------------------
typedef struct licd_ctx licd_ctx;       // library context (thread-safe)
typedef struct licd_device licd_device; // an open dongle connection

// --- Plain data structures ---------------------------------------------------
#define LICD_SERIAL_HEX_LEN 18 // secure element 9-byte serial as hex, no NUL

// One discovered dongle (from licd_enumerate). `path` is an opaque,
// platform-specific string accepted by licd_open_path.
typedef struct {
    char serial[LICD_SERIAL_HEX_LEN + 1]; // NUL-terminated; "" if unavailable
    char path[512];                       // NUL-terminated platform path
    uint16_t vendor_id;
    uint16_t product_id;
} licd_device_info;

// Plaintext device info (licd_get_info).
typedef struct {
    uint8_t proto_version_major;
    uint8_t proto_version_minor;
    uint8_t fw_version_major;
    uint8_t fw_version_minor;
    uint8_t fw_version_patch;
    int se_ready;    // secure element responded
    int provisioned;    // factory provisioning complete
    uint32_t data_capacity; // bytes
    uint32_t data_free;     // bytes
    // Nonzero if the dongle's *previous* boot ended in a watchdog timeout, i.e.
    // the firmware hung and reset itself. Normal operation and a requested reboot
    // both leave this clear, so a set flag is worth reporting: it is the only
    // trace a field hang leaves behind. Cleared by a power cycle.
    int watchdog_reboot;
} licd_info;

// Result of licd_verify_genuine (populated from the verified device cert).
typedef struct {
    int genuine;                          // nonzero if authenticity proven
    char serial[LICD_SERIAL_HEX_LEN + 1]; // device serial from the certificate
    char batch[64];                       // batch/issuer label (NUL-terminated)
    char provisioned_date[11];            // "YYYY-MM-DD" or "" (NUL-terminated)
} licd_genuine_result;

// Optional callbacks.
typedef void (*licd_log_cb)(licd_log_level level, const char *msg, void *user);
// Return nonzero to continue, zero to cancel the transfer.
typedef int (*licd_progress_cb)(uint32_t done, uint32_t total, void *user);

// ============================================================================
// Context / version
// ============================================================================

// SDK version (semantic). Always available.
LICD_API void licd_version(int *major, int *minor, int *patch);

// Create/destroy a library context. Returns LICD_OK or a negative status.
LICD_API int licd_init(licd_ctx **out_ctx);
LICD_API void licd_free(licd_ctx *ctx);

// Optional diagnostic log callback (set once, before other calls ideally).
LICD_API void licd_set_log_callback(licd_ctx *ctx, licd_log_cb cb, void *user);

// Override the trust root (DER-encoded X.509 CA certificate) that
// licd_verify_genuine checks the device certificate chain against. The buffer is
// copied, so the caller may free it. A NULL pointer or zero length is rejected
// with LICD_E_INVALID_ARG; calling it again replaces the previous root.
//
// Applications do NOT need this: a release build embeds the KeyNub production
// root, and verify_genuine uses it by default. It exists for vendor tooling that
// has to verify dongles issued under a CA other than the one this build embeds.
//
// This is not a security boundary. Host code runs on hardware the attacker
// controls, so an attacker who could call this could equally replace the whole
// library — see docs/integration-security.md. What protects you is that the
// dongle holds a key you need, not that the host insists on a particular root.
//
// A build configured without -DLICD_TRUST_ROOT embeds no root at all, and then
// verification fails closed with LICD_E_CERT_INVALID ("no trust root configured")
// until a caller supplies one here. Released builds embed the production root, so
// an application never meets that state.
LICD_API int licd_set_trust_root(licd_ctx *ctx, const uint8_t *der, size_t len);

// ============================================================================
// Enumeration / open / close
// ============================================================================

// Enumerate connected dongles. On success allocates *out_list (free with
// licd_free_device_list) and sets *out_count. *out_count may be 0.
LICD_API int licd_enumerate(licd_ctx *ctx, licd_device_info **out_list, size_t *out_count);
LICD_API void licd_free_device_list(licd_device_info *list, size_t count);

// Open the dongle with the given serial, or the first one if serial is NULL.
LICD_API int licd_open(licd_ctx *ctx, const char *serial_or_null, licd_device **out_dev);
// Open a specific dongle by the path from licd_device_info.
LICD_API int licd_open_path(licd_ctx *ctx, const char *path, licd_device **out_dev);
LICD_API void licd_close(licd_device *dev);

// ============================================================================
// Info (plaintext, no session required)
// ============================================================================

LICD_API int licd_get_info(licd_device *dev, licd_info *out_info);
// out_serial buffer must hold >= LICD_SERIAL_HEX_LEN + 1 bytes.
LICD_API int licd_get_serial(licd_device *dev, char *out_serial, size_t serial_size);

// ============================================================================
// Authenticity + session  (implemented in the crypto increment)
// ============================================================================

LICD_API int licd_verify_genuine(licd_device *dev, licd_genuine_result *out_result);
LICD_API int licd_session_open(licd_device *dev);
LICD_API int licd_session_close(licd_device *dev);
// Elevate the session to the write role using the developer master key
// (DER-encoded EC private key). Vendor/provisioning tools only.
LICD_API int licd_write_auth(licd_device *dev, const uint8_t *master_key_der, size_t len);

// ============================================================================
// License data records  (session required; write/erase need the write role)
// ============================================================================

// List record names + sizes. Allocates *out_names (array of NUL-terminated
// strings) and *out_sizes; free with licd_free_record_list.
LICD_API int licd_record_list(licd_device *dev, char ***out_names, uint32_t **out_sizes,
                              size_t *out_count);
LICD_API void licd_free_record_list(char **names, uint32_t *sizes, size_t count);

// Ranged read of a record into buf; sets *out_len (bytes copied) and
// *out_total (full record size). progress may be NULL.
LICD_API int licd_record_read(licd_device *dev, const char *name, uint32_t offset,
                              void *buf, uint32_t buf_size, uint32_t *out_len,
                              uint32_t *out_total, licd_progress_cb progress, void *user);
LICD_API int licd_record_write(licd_device *dev, const char *name, const void *data,
                               uint32_t len, licd_progress_cb progress, void *user);
LICD_API int licd_record_erase(licd_device *dev, const char *name); // NULL name = erase all

// ============================================================================
// Monotonic counters (session required; increment needs the write role)
// ============================================================================

LICD_API int licd_counter_read(licd_device *dev, uint8_t counter_id, uint32_t *out_value);
LICD_API int licd_counter_increment(licd_device *dev, uint8_t counter_id, uint32_t *out_value);

// ============================================================================
// App-data envelope encryption (session required; read role)
// ============================================================================

// Encrypt `plaintext` so it can only be decrypted with a dongle of the given
// scope. Bulk crypto stays on the host; only a small key is wrapped by the
// dongle. Allocates *out (free with licd_free_buffer) and sets *out_len.
LICD_API int licd_app_encrypt(licd_device *dev, licd_scope scope, const void *plaintext,
                              uint32_t len, uint8_t **out, uint32_t *out_len);
LICD_API int licd_app_decrypt(licd_device *dev, const void *packed, uint32_t packed_len,
                              uint8_t **out, uint32_t *out_len);
LICD_API void licd_free_buffer(uint8_t *buf);

// ============================================================================
// Errors
// ============================================================================

// Static human-readable string for a status code.
LICD_API const char *licd_strerror(int status);
// Thread-local detail for the most recent failure on this thread (or "").
LICD_API const char *licd_error_detail(licd_ctx *ctx);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // LICDONGLE_H
