// A stand-in for the KeyNub C ABI, for testing the Julia binding without a dongle.
//
// It implements every function of include/licdongle.h with one imaginary device
// held in memory: fixed device info, records, two counters and a write role that
// a fixed key elevates to. No cryptography, no USB. app_encrypt/app_decrypt only
// pack the data with a check byte, so tampering is detected but nothing is
// protected. The test suite compiles this file with the C compiler on the path
// and points the binding at the result.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "licdongle.h"

#define STUB_SERIAL "04A1B2C3D4E5F6"
#define STUB_PATH "stub:0"
#define STUB_DATE "2026-08-15"
#define MAX_RECORDS 8
#define MAX_RECORD_SIZE 4096
#define MAX_KEY 64
#define CHUNK 512

static const uint8_t FACTORY_KEY[] = {0x30, 0x10, 0x01, 0x02, 0x03};

struct licd_ctx {
    int root_rejects; // a trust root was installed that rejects the device
};

typedef struct {
    char name[33];
    uint32_t size;
    uint8_t data[MAX_RECORD_SIZE];
} record;

struct licd_device {
    licd_ctx *ctx;
    int session;
    int write_role;
    int rotated;
    uint8_t key[MAX_KEY];
    size_t key_len;
    record records[MAX_RECORDS];
    int used[MAX_RECORDS];
    uint32_t counters[2];
};

static char detail[256];

static int fail(int status, const char *text) {
    strncpy(detail, text, sizeof(detail) - 1);
    detail[sizeof(detail) - 1] = 0;
    return status;
}

static int ok(void) {
    detail[0] = 0;
    return LICD_OK;
}

void licd_version(int *major, int *minor, int *patch) {
    if (major) *major = 9;
    if (minor) *minor = 8;
    if (patch) *patch = 7;
}

// Sizes of the plain structures as the C compiler lays them out.
LICD_API void licd_stub_sizes(int *info, int *device_info, int *genuine_result) {
    *info = (int)sizeof(licd_info);
    *device_info = (int)sizeof(licd_device_info);
    *genuine_result = (int)sizeof(licd_genuine_result);
}

int licd_init(licd_ctx **out_ctx) {
    if (!out_ctx) return fail(LICD_E_INVALID_ARG, "out_ctx is null");
    *out_ctx = (licd_ctx *)calloc(1, sizeof(licd_ctx));
    return *out_ctx ? ok() : fail(LICD_E_INTERNAL, "out of memory");
}

void licd_free(licd_ctx *ctx) { free(ctx); }

void licd_set_log_callback(licd_ctx *ctx, licd_log_cb cb, void *user) {
    (void)ctx; (void)cb; (void)user;
}

int licd_set_trust_root(licd_ctx *ctx, const uint8_t *der, size_t len) {
    if (!ctx || !der || len == 0) return fail(LICD_E_INVALID_ARG, "empty trust root");
    // A DER certificate starts with a SEQUENCE tag; anything else cannot be a root.
    if (der[0] != 0x30) return fail(LICD_E_CERT_INVALID, "not a DER certificate");
    // A root other than the device's issuer makes the device fail verification.
    ctx->root_rejects = (len < 8 || der[4] == 0xAB);
    return ok();
}

int licd_enumerate(licd_ctx *ctx, licd_device_info **out_list, size_t *out_count) {
    if (!ctx || !out_list || !out_count) return fail(LICD_E_INVALID_ARG, "null argument");
    licd_device_info *list = (licd_device_info *)calloc(1, sizeof(licd_device_info));
    if (!list) return fail(LICD_E_INTERNAL, "out of memory");
    strcpy(list[0].serial, STUB_SERIAL);
    strcpy(list[0].path, STUB_PATH);
    list[0].vendor_id = 0x1234;
    list[0].product_id = 0xABCD;
    *out_list = list;
    *out_count = 1;
    return ok();
}

void licd_free_device_list(licd_device_info *list, size_t count) {
    (void)count;
    free(list);
}

static int open_device(licd_ctx *ctx, licd_device **out_dev) {
    licd_device *dev = (licd_device *)calloc(1, sizeof(licd_device));
    if (!dev) return fail(LICD_E_INTERNAL, "out of memory");
    dev->ctx = ctx;
    memcpy(dev->key, FACTORY_KEY, sizeof(FACTORY_KEY));
    dev->key_len = sizeof(FACTORY_KEY);
    *out_dev = dev;
    return ok();
}

int licd_open(licd_ctx *ctx, const char *serial_or_null, licd_device **out_dev) {
    if (!ctx || !out_dev) return fail(LICD_E_INVALID_ARG, "null argument");
    if (serial_or_null && strcmp(serial_or_null, STUB_SERIAL) != 0)
        return fail(LICD_E_NO_DEVICE, "no dongle with that serial");
    return open_device(ctx, out_dev);
}

int licd_open_path(licd_ctx *ctx, const char *path, licd_device **out_dev) {
    if (!ctx || !path || !out_dev) return fail(LICD_E_INVALID_ARG, "null argument");
    if (strcmp(path, STUB_PATH) != 0) return fail(LICD_E_NO_DEVICE, "no dongle at that path");
    return open_device(ctx, out_dev);
}

void licd_close(licd_device *dev) { free(dev); }

int licd_get_info(licd_device *dev, licd_info *out_info) {
    if (!dev || !out_info) return fail(LICD_E_INVALID_ARG, "null argument");
    memset(out_info, 0, sizeof(*out_info));
    out_info->proto_version_major = 1;
    out_info->proto_version_minor = 0;
    out_info->fw_version_major = 2;
    out_info->fw_version_minor = 3;
    out_info->fw_version_patch = 4;
    out_info->se_ready = 1;
    out_info->provisioned = 1;
    out_info->data_capacity = 1024 * 1024;
    out_info->data_free = 1000000;
    out_info->watchdog_reboot = 0;
    out_info->isolated = 1;
    out_info->writeauth_rotated = dev->rotated;
    return ok();
}

int licd_get_serial(licd_device *dev, char *out_serial, size_t serial_size) {
    if (!dev || !out_serial) return fail(LICD_E_INVALID_ARG, "null argument");
    if (serial_size < sizeof(STUB_SERIAL)) return fail(LICD_E_RANGE, "serial buffer too small");
    strcpy(out_serial, STUB_SERIAL);
    return ok();
}

int licd_verify_genuine(licd_device *dev, licd_genuine_result *out_result) {
    if (!dev || !out_result) return fail(LICD_E_INVALID_ARG, "null argument");
    memset(out_result, 0, sizeof(*out_result));
    if (dev->ctx->root_rejects) return fail(LICD_E_CERT_INVALID, "certificate does not chain to the trust root");
    out_result->genuine = 1;
    strcpy(out_result->serial, STUB_SERIAL);
    strcpy(out_result->provisioned_date, STUB_DATE);
    return ok();
}

int licd_session_open(licd_device *dev) {
    if (!dev) return fail(LICD_E_INVALID_ARG, "null device");
    dev->session = 1;
    dev->write_role = 0;
    return ok();
}

int licd_session_close(licd_device *dev) {
    if (!dev) return fail(LICD_E_INVALID_ARG, "null device");
    dev->session = 0;
    dev->write_role = 0;
    return ok();
}

static int need_session(licd_device *dev) {
    if (!dev) return fail(LICD_E_INVALID_ARG, "null device");
    if (!dev->session) return fail(LICD_E_SESSION_EXPIRED, "no session");
    return LICD_OK;
}

static int need_write_role(licd_device *dev) {
    int rc = need_session(dev);
    if (rc) return rc;
    if (!dev->write_role) return fail(LICD_E_AUTH_REQUIRED, "the write role is required");
    return LICD_OK;
}

int licd_write_auth(licd_device *dev, const uint8_t *master_key_der, size_t len) {
    int rc = need_session(dev);
    if (rc) return rc;
    if (!master_key_der || len == 0) return fail(LICD_E_INVALID_ARG, "empty key");
    if (len != dev->key_len || memcmp(master_key_der, dev->key, len) != 0)
        return fail(LICD_E_NOT_GENUINE, "the key does not elevate on this dongle");
    dev->write_role = 1;
    return ok();
}

int licd_write_auth_rotate(licd_device *dev, const uint8_t *new_key_der, size_t len) {
    int rc = need_write_role(dev);
    if (rc) return rc;
    if (!new_key_der || len == 0 || len > MAX_KEY) return fail(LICD_E_INVALID_ARG, "bad key length");
    memcpy(dev->key, new_key_der, len);
    dev->key_len = len;
    dev->rotated = 1;
    return ok();
}

static record *find_record(licd_device *dev, const char *name) {
    for (int i = 0; i < MAX_RECORDS; i++)
        if (dev->used[i] && strcmp(dev->records[i].name, name) == 0) return &dev->records[i];
    return NULL;
}

int licd_record_list(licd_device *dev, char ***out_names, uint32_t **out_sizes, size_t *out_count) {
    int rc = need_session(dev);
    if (rc) return rc;
    if (!out_names || !out_sizes || !out_count) return fail(LICD_E_INVALID_ARG, "null argument");
    size_t n = 0;
    for (int i = 0; i < MAX_RECORDS; i++) n += dev->used[i] ? 1 : 0;
    *out_names = NULL;
    *out_sizes = NULL;
    *out_count = n;
    if (n == 0) return ok();
    char **names = (char **)calloc(n, sizeof(char *));
    uint32_t *sizes = (uint32_t *)calloc(n, sizeof(uint32_t));
    size_t k = 0;
    for (int i = 0; i < MAX_RECORDS && names && sizes; i++) {
        if (!dev->used[i]) continue;
        names[k] = (char *)malloc(strlen(dev->records[i].name) + 1);
        strcpy(names[k], dev->records[i].name);
        sizes[k] = dev->records[i].size;
        k++;
    }
    *out_names = names;
    *out_sizes = sizes;
    return ok();
}

void licd_free_record_list(char **names, uint32_t *sizes, size_t count) {
    if (names)
        for (size_t i = 0; i < count; i++) free(names[i]);
    free(names);
    free(sizes);
}

static int report(licd_progress_cb progress, void *user, uint32_t done, uint32_t total) {
    if (progress && !progress(done, total, user)) return fail(LICD_E_CANCELLED, "cancelled by the caller");
    return LICD_OK;
}

int licd_record_read(licd_device *dev, const char *name, uint32_t offset, void *buf,
                     uint32_t buf_size, uint32_t *out_len, uint32_t *out_total,
                     licd_progress_cb progress, void *user) {
    int rc = need_session(dev);
    if (rc) return rc;
    if (!name || !buf || !out_len || !out_total) return fail(LICD_E_INVALID_ARG, "null argument");
    record *r = find_record(dev, name);
    if (!r) return fail(LICD_E_NOT_FOUND, "no such record");
    if (offset > r->size) return fail(LICD_E_RANGE, "offset beyond the record");
    uint32_t want = r->size - offset;
    if (want > buf_size) want = buf_size;
    uint32_t done = 0;
    while (done < want) {
        uint32_t step = want - done < CHUNK ? want - done : CHUNK;
        memcpy((uint8_t *)buf + done, r->data + offset + done, step);
        done += step;
        rc = report(progress, user, done, want);
        if (rc) return rc;
    }
    *out_len = done;
    *out_total = r->size;
    return ok();
}

int licd_record_write(licd_device *dev, const char *name, const void *data, uint32_t len,
                      licd_progress_cb progress, void *user) {
    int rc = need_write_role(dev);
    if (rc) return rc;
    if (!name || (!data && len)) return fail(LICD_E_INVALID_ARG, "null argument");
    if (strlen(name) == 0 || strlen(name) > 32) return fail(LICD_E_INVALID_ARG, "bad record name");
    if (len > MAX_RECORD_SIZE) return fail(LICD_E_RANGE, "record too large");
    record *r = find_record(dev, name);
    if (!r) {
        for (int i = 0; i < MAX_RECORDS && !r; i++)
            if (!dev->used[i]) {
                dev->used[i] = 1;
                r = &dev->records[i];
                strcpy(r->name, name);
            }
        if (!r) return fail(LICD_E_STORAGE_FULL, "no room for another record");
    }
    uint32_t done = 0;
    while (done < len) {
        uint32_t step = len - done < CHUNK ? len - done : CHUNK;
        done += step;
        rc = report(progress, user, done, len);
        if (rc) return rc;
    }
    if (len) memcpy(r->data, data, len);
    r->size = len;
    return ok();
}

int licd_record_erase(licd_device *dev, const char *name) {
    int rc = need_write_role(dev);
    if (rc) return rc;
    if (!name) {
        memset(dev->used, 0, sizeof(dev->used));
        return ok();
    }
    for (int i = 0; i < MAX_RECORDS; i++)
        if (dev->used[i] && strcmp(dev->records[i].name, name) == 0) {
            dev->used[i] = 0;
            return ok();
        }
    return fail(LICD_E_NOT_FOUND, "no such record");
}

int licd_counter_read(licd_device *dev, uint8_t counter_id, uint32_t *out_value) {
    int rc = need_session(dev);
    if (rc) return rc;
    if (!out_value) return fail(LICD_E_INVALID_ARG, "null argument");
    if (counter_id > 1) return fail(LICD_E_RANGE, "no such counter");
    *out_value = dev->counters[counter_id];
    return ok();
}

int licd_counter_increment(licd_device *dev, uint8_t counter_id, uint32_t *out_value) {
    int rc = need_write_role(dev);
    if (rc) return rc;
    if (!out_value) return fail(LICD_E_INVALID_ARG, "null argument");
    if (counter_id > 1) return fail(LICD_E_RANGE, "no such counter");
    *out_value = ++dev->counters[counter_id];
    return ok();
}

// Packed form: scope, length (4 bytes, little-endian), the bytes each XOR 0x5A,
// then one check byte: the XOR of everything before it.
int licd_app_encrypt(licd_device *dev, licd_scope scope, const void *plaintext, uint32_t len,
                     uint8_t **out, uint32_t *out_len) {
    int rc = need_session(dev);
    if (rc) return rc;
    if (!out || !out_len || (!plaintext && len)) return fail(LICD_E_INVALID_ARG, "null argument");
    uint32_t total = 5 + len + 1;
    uint8_t *p = (uint8_t *)malloc(total);
    if (!p) return fail(LICD_E_INTERNAL, "out of memory");
    p[0] = (uint8_t)scope;
    p[1] = (uint8_t)len; p[2] = (uint8_t)(len >> 8); p[3] = (uint8_t)(len >> 16); p[4] = (uint8_t)(len >> 24);
    for (uint32_t i = 0; i < len; i++) p[5 + i] = ((const uint8_t *)plaintext)[i] ^ 0x5A;
    uint8_t check = 0;
    for (uint32_t i = 0; i < total - 1; i++) check ^= p[i];
    p[total - 1] = check;
    *out = p;
    *out_len = total;
    return ok();
}

int licd_app_decrypt(licd_device *dev, const void *packed, uint32_t packed_len, uint8_t **out,
                     uint32_t *out_len) {
    int rc = need_session(dev);
    if (rc) return rc;
    if (!packed || !out || !out_len) return fail(LICD_E_INVALID_ARG, "null argument");
    if (packed_len < 6) return fail(LICD_E_INVALID_ARG, "packed data too short");
    const uint8_t *p = (const uint8_t *)packed;
    uint32_t len = p[1] | (p[2] << 8) | (p[3] << 16) | ((uint32_t)p[4] << 24);
    if (5 + len + 1 != packed_len) return fail(LICD_E_PROTOCOL, "length field disagrees with the data");
    uint8_t check = 0;
    for (uint32_t i = 0; i < packed_len - 1; i++) check ^= p[i];
    if (check != p[packed_len - 1]) return fail(LICD_E_TAG_MISMATCH, "check byte does not match");
    uint8_t *plain = (uint8_t *)malloc(len ? len : 1);
    if (!plain) return fail(LICD_E_INTERNAL, "out of memory");
    for (uint32_t i = 0; i < len; i++) plain[i] = p[5 + i] ^ 0x5A;
    *out = plain;
    *out_len = len;
    return ok();
}

void licd_free_buffer(uint8_t *buf) { free(buf); }

const char *licd_strerror(int status) {
    switch (status) {
    case LICD_OK: return "success";
    case LICD_E_INVALID_ARG: return "invalid argument";
    case LICD_E_NO_DEVICE: return "no device";
    case LICD_E_ACCESS_DENIED: return "access denied";
    case LICD_E_IO: return "I/O error";
    case LICD_E_TIMEOUT: return "timeout";
    case LICD_E_PROTOCOL: return "protocol error";
    case LICD_E_NOT_GENUINE: return "not genuine";
    case LICD_E_CERT_INVALID: return "certificate invalid";
    case LICD_E_SESSION_EXPIRED: return "session expired";
    case LICD_E_TAG_MISMATCH: return "tag mismatch";
    case LICD_E_RANGE: return "out of range";
    case LICD_E_STORAGE_FULL: return "storage full";
    case LICD_E_BUSY: return "busy";
    case LICD_E_NOT_FOUND: return "not found";
    case LICD_E_AUTH_REQUIRED: return "authorization required";
    case LICD_E_FW_INCOMPATIBLE: return "firmware incompatible";
    case LICD_E_SDK_TOO_OLD: return "SDK too old";
    case LICD_E_CANCELLED: return "cancelled";
    case LICD_E_NOT_IMPLEMENTED: return "not implemented";
    case LICD_E_INTERNAL: return "internal error";
    default: return "unknown status";
    }
}

const char *licd_error_detail(licd_ctx *ctx) {
    (void)ctx;
    return detail;
}
