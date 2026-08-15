/* KeyNub License Dongle SDK - LabVIEW import header.
 *
 * The same functions as bindings/flat/licd_flat.h, restated with nothing in them
 * that LabVIEW's "Import Shared Library" wizard has to guess at: no #include, no
 * __declspec, no macros in the signatures, no typedefs of our own. Point the
 * wizard at this file and keynub_licdongle_flat.dll and it can generate the
 * Call Library Function Nodes for you.
 *
 * This file must stay in step with licd_flat.h; packaging/check_flat_bindings.py
 * matches it, because a silently diverged parameter list here is a
 * crash in a customer's VI rather than a compile error anywhere.
 *
 * See README.md in this folder for the per-parameter node configuration, and
 * docs/integration-security.md before deciding where the check goes.
 */

#ifndef LICD_LABVIEW_H
#define LICD_LABVIEW_H

#include <stdint.h>

/* --- status codes (0 = success, everything else negative) ----------------- */
#define LICD_OK 0
#define LICD_E_INVALID_ARG -1
#define LICD_E_NO_DEVICE -2
#define LICD_E_ACCESS_DENIED -3
#define LICD_E_IO -4
#define LICD_E_TIMEOUT -5
#define LICD_E_PROTOCOL -6
#define LICD_E_NOT_GENUINE -7
#define LICD_E_CERT_INVALID -8
#define LICD_E_SESSION_EXPIRED -9
#define LICD_E_TAG_MISMATCH -10
#define LICD_E_RANGE -11
#define LICD_E_STORAGE_FULL -12
#define LICD_E_BUSY -13
#define LICD_E_NOT_FOUND -14
#define LICD_E_AUTH_REQUIRED -15
#define LICD_E_FW_INCOMPATIBLE -16
#define LICD_E_SDK_TOO_OLD -17
#define LICD_E_CANCELLED -18
#define LICD_E_NOT_IMPLEMENTED -19
#define LICD_E_INTERNAL -20

/* --- flags in the licdf_get_info bitmask --------------------------------- */
#define LICDF_FLAG_SE_READY 0x01
#define LICDF_FLAG_PROVISIONED 0x02
#define LICDF_FLAG_WATCHDOG_REBOOT 0x04
#define LICDF_FLAG_ISOLATED 0x08
#define LICDF_FLAG_WRITEAUTH_ROTATED 0x10

/* --- buffer sizes -------------------------------------------------------- */
#define LICDF_SERIAL_SIZE 15
#define LICDF_PATH_SIZE 512
#define LICDF_ERROR_SIZE 256

/* --- version ------------------------------------------------------------- */
int32_t licdf_version(int32_t *out_major, int32_t *out_minor, int32_t *out_patch);
int32_t licdf_strerror(int32_t status, char *out, int32_t out_size);

/* --- discovery ----------------------------------------------------------- */
int32_t licdf_device_count(int32_t *out_count);
int32_t licdf_device_serial(int32_t index, char *out, int32_t out_size);
int32_t licdf_device_path(int32_t index, char *out, int32_t out_size);

/* --- open / close (licdf_open returns a positive handle, or a status) ----- */
int32_t licdf_open(const char *serial_or_empty);
int32_t licdf_open_path(const char *path);
int32_t licdf_close(int32_t handle);
int32_t licdf_set_trust_root(int32_t handle, const uint8_t *der, int32_t der_len);

/* --- plaintext info ------------------------------------------------------ */
int32_t licdf_get_serial(int32_t handle, char *out, int32_t out_size);
int32_t licdf_get_info(int32_t handle, int32_t *out_proto_major, int32_t *out_proto_minor,
                       int32_t *out_fw_major, int32_t *out_fw_minor, int32_t *out_fw_patch,
                       int32_t *out_flags, int32_t *out_capacity, int32_t *out_free);
int32_t licdf_verify_genuine(int32_t handle, int32_t *out_genuine, char *out_serial,
                             int32_t serial_size, char *out_provisioned_date,
                             int32_t date_size);

/* --- session ------------------------------------------------------------- */
int32_t licdf_session_open(int32_t handle);
int32_t licdf_session_close(int32_t handle);
int32_t licdf_write_auth(int32_t handle, const uint8_t *der, int32_t der_len);
int32_t licdf_write_auth_rotate(int32_t handle, const uint8_t *der, int32_t der_len);

/* --- records ------------------------------------------------------------- */
int32_t licdf_record_count(int32_t handle, int32_t *out_count);
int32_t licdf_record_name(int32_t handle, int32_t index, char *out, int32_t out_size,
                          int32_t *out_record_size);
int32_t licdf_record_size(int32_t handle, const char *name, int32_t *out_size);
int32_t licdf_record_read(int32_t handle, const char *name, uint8_t *out, int32_t out_cap,
                          int32_t *out_len);
int32_t licdf_record_write(int32_t handle, const char *name, const uint8_t *data,
                           int32_t data_len);
int32_t licdf_record_erase(int32_t handle, const char *name);
int32_t licdf_record_erase_all(int32_t handle);

/* --- counters ------------------------------------------------------------ */
int32_t licdf_counter_read(int32_t handle, int32_t counter_id, int32_t *out_value);
int32_t licdf_counter_increment(int32_t handle, int32_t counter_id, int32_t *out_value);

/* --- app-data envelope encryption --------------------------------------- */
int32_t licdf_app_encrypt(int32_t handle, int32_t scope, const uint8_t *plaintext,
                          int32_t plaintext_len, uint8_t *out, int32_t out_cap,
                          int32_t *out_len);
int32_t licdf_app_decrypt(int32_t handle, const uint8_t *packed, int32_t packed_len,
                          uint8_t *out, int32_t out_cap, int32_t *out_len);

/* --- errors -------------------------------------------------------------- */
int32_t licdf_last_error(int32_t handle, char *out, int32_t out_size);

#endif /* LICD_LABVIEW_H */
