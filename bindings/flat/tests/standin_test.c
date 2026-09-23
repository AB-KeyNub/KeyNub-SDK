/* Every call of the flat C API (bindings/flat/licd_flat.h) against a stand-in
 * for the C ABI: licd_flat.c over bindings/julia/test/stub/licd_stub.c, one
 * imaginary dongle held in memory, all compiled into the same executable. Exit
 * code 0 when every check passed.
 *
 *     cmake -S bindings/flat/tests -B build-flat-standin && cmake --build build-flat-standin
 *     build-flat-standin/standin_test          (from the repository root)
 *
 * or with the compiler directly:
 *
 *     cc -std=c99 -DLICD_BUILD_SHARED -DLICDF_BUILD_SHARED -Iinclude -Ibindings/flat \
 *        bindings/flat/tests/standin_test.c bindings/flat/licd_flat.c \
 *        bindings/julia/test/stub/licd_stub.c -o standin_test
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "licd_flat.h"

static int failures = 0;

static void check(int condition, const char *what) {
    if (!condition) {
        failures++;
        printf("  FAIL  %s\n", what);
    }
}

static void expect(int32_t rc, int32_t status, const char *what) {
    if (rc != status) {
        failures++;
        printf("  FAIL  %s: %d, expected %d\n", what, (int)rc, (int)status);
    }
}

#define SERIAL "04A1B2C3D4E5F6"

static const uint8_t FACTORY_KEY[] = {0x30, 0x10, 0x01, 0x02, 0x03};
static const uint8_t REPLACEMENT_KEY[] = {0x30, 0x11, 0x09, 0x08, 0x07, 0x06};

/* The two-call convention: size first with a capacity of 0, then the data. */
static int32_t read_record(int32_t h, const char *name, uint8_t *out, int32_t cap, int32_t *len) {
    int32_t needed = 0;
    int32_t rc = licdf_record_read(h, name, NULL, 0, &needed);
    if (rc != LICD_OK && rc != LICD_E_RANGE) {
        return rc;
    }
    if (needed > cap) {
        return LICD_E_RANGE;
    }
    return licdf_record_read(h, name, out, needed, len);
}

int main(void) {
    int32_t major = 0, minor = 0, patch = 0;
    expect(licdf_version(&major, &minor, &patch), LICD_OK, "licdf_version");
    check(major == 9 && minor == 8 && patch == 7, "library version");

    char text[LICDF_ERROR_SIZE];
    expect(licdf_strerror(LICD_E_NO_DEVICE, text, sizeof(text)), LICD_OK, "licdf_strerror");
    check(strcmp(text, "no device") == 0, "status text");
    char tiny[3];
    expect(licdf_strerror(LICD_E_NO_DEVICE, tiny, sizeof(tiny)), LICD_E_RANGE, "status text too small");

    int32_t count = 0;
    expect(licdf_device_count(&count), LICD_OK, "licdf_device_count");
    check(count == 1, "one device");
    char serial[LICDF_SERIAL_SIZE];
    char path[LICDF_PATH_SIZE];
    expect(licdf_device_serial(0, serial, sizeof(serial)), LICD_OK, "licdf_device_serial");
    expect(licdf_device_path(0, path, sizeof(path)), LICD_OK, "licdf_device_path");
    check(strcmp(serial, SERIAL) == 0 && strcmp(path, "stub:0") == 0, "devices");
    expect(licdf_device_serial(1, serial, sizeof(serial)), LICD_E_RANGE, "device index out of range");
    expect(licdf_open("nope"), LICD_E_NO_DEVICE, "open by unknown serial");
    expect(licdf_open_path("stub:9"), LICD_E_NO_DEVICE, "open by unknown path");

    int32_t h = licdf_open("");
    check(h > 0, "open");
    expect(licdf_get_serial(h, serial, sizeof(serial)), LICD_OK, "licdf_get_serial");
    check(strcmp(serial, SERIAL) == 0, "serial");

    int32_t pa, pb, fa, fb, fc, flags, capacity, freeb;
    expect(licdf_get_info(h, &pa, &pb, &fa, &fb, &fc, &flags, &capacity, &freeb), LICD_OK, "licdf_get_info");
    check(pa == 1 && pb == 0, "protocol version");
    check(fa == 2 && fb == 3 && fc == 4, "firmware version");
    check((flags & LICDF_FLAG_SE_READY) && (flags & LICDF_FLAG_PROVISIONED) && (flags & LICDF_FLAG_ISOLATED),
          "flags set");
    check(!(flags & LICDF_FLAG_WATCHDOG_REBOOT) && !(flags & LICDF_FLAG_WRITEAUTH_ROTATED), "flags clear");
    check(capacity == 1024 * 1024 && freeb == 1000000, "capacity");

    int32_t genuine = 0;
    char date[LICDF_DATE_SIZE];
    expect(licdf_verify_genuine(h, &genuine, serial, sizeof(serial), date, sizeof(date)), LICD_OK,
           "licdf_verify_genuine");
    check(genuine == 1 && strcmp(serial, SERIAL) == 0 && strcmp(date, "2026-08-15") == 0, "genuine");

    const uint8_t bad_root[] = {0x02, 0x01, 0x00};
    expect(licdf_set_trust_root(h, bad_root, sizeof(bad_root)), LICD_E_CERT_INVALID, "malformed trust root");
    uint8_t root[132];
    memset(root, 0xAB, sizeof(root));
    root[0] = 0x30, root[1] = 0x82, root[2] = 0x01, root[3] = 0x00;
    expect(licdf_set_trust_root(h, root, sizeof(root)), LICD_OK, "foreign trust root");
    expect(licdf_verify_genuine(h, &genuine, serial, sizeof(serial), date, sizeof(date)), LICD_E_CERT_INVALID,
           "verify against a foreign root");
    memset(root + 4, 0x01, sizeof(root) - 4);
    expect(licdf_set_trust_root(h, root, sizeof(root)), LICD_OK, "right trust root");
    expect(licdf_verify_genuine(h, &genuine, serial, sizeof(serial), date, sizeof(date)), LICD_OK,
           "verify after the right root");

    expect(licdf_record_count(h, &count), LICD_E_SESSION_EXPIRED, "records without a session");
    expect(licdf_session_open(h), LICD_OK, "licdf_session_open");
    const char *payload = "license-blob-0123456789";
    const int32_t plen = (int32_t)strlen(payload);
    expect(licdf_record_write(h, "lic", (const uint8_t *)payload, plen), LICD_E_AUTH_REQUIRED,
           "write before the write role");
    const uint8_t bad_key[] = {0x30, 0x00};
    expect(licdf_write_auth(h, bad_key, sizeof(bad_key)), LICD_E_NOT_GENUINE, "write role with a bad key");
    expect(licdf_write_auth(h, FACTORY_KEY, sizeof(FACTORY_KEY)), LICD_OK, "licdf_write_auth");
    expect(licdf_record_write(h, "lic", (const uint8_t *)payload, plen), LICD_OK, "licdf_record_write");

    uint8_t buf[4096];
    int32_t len = 0;
    expect(read_record(h, "lic", buf, sizeof(buf), &len), LICD_OK, "licdf_record_read");
    check(len == plen && memcmp(buf, payload, (size_t)plen) == 0, "read back");
    int32_t size = 0;
    expect(licdf_record_size(h, "lic", &size), LICD_OK, "licdf_record_size");
    check(size == plen, "record size");
    expect(licdf_record_write(h, "cfg", (const uint8_t *)"cfgdata", 7), LICD_OK, "second record");
    expect(licdf_record_count(h, &count), LICD_OK, "licdf_record_count");
    check(count == 2, "two records");
    char name[64];
    int seen = 0;
    for (int32_t i = 0; i < count; i++) {
        expect(licdf_record_name(h, i, name, sizeof(name), &size), LICD_OK, "licdf_record_name");
        if (strcmp(name, "lic") == 0 && size == plen) {
            seen |= 1;
        }
        if (strcmp(name, "cfg") == 0 && size == 7) {
            seen |= 2;
        }
    }
    check(seen == 3, "record names and sizes");
    expect(read_record(h, "nope", buf, sizeof(buf), &len), LICD_E_NOT_FOUND, "read a missing record");
    expect(licdf_last_error(h, text, sizeof(text)), LICD_OK, "licdf_last_error");
    check(strcmp(text, "no such record") == 0, "error detail");
    expect(licdf_record_erase(h, ""), LICD_E_INVALID_ARG, "erase with an empty name");
    expect(licdf_record_erase(h, "cfg"), LICD_OK, "licdf_record_erase");
    expect(licdf_record_count(h, &count), LICD_OK, "licdf_record_count");
    check(count == 1, "one record left");
    expect(licdf_record_write(h, "empty", NULL, 0), LICD_OK, "empty record");
    expect(read_record(h, "empty", buf, sizeof(buf), &len), LICD_OK, "read the empty record");
    check(len == 0, "empty record length");

    int32_t before = 0, value = 0;
    expect(licdf_counter_read(h, 0, &before), LICD_OK, "licdf_counter_read");
    expect(licdf_counter_increment(h, 0, &value), LICD_OK, "licdf_counter_increment");
    check(value == before + 1, "increment");
    expect(licdf_counter_read(h, 1, &value), LICD_OK, "second counter");
    check(value == 0, "counters");
    expect(licdf_counter_read(h, 7, &value), LICD_E_RANGE, "counter out of range");

    uint8_t secret[100];
    for (int k = 0; k < 100; k++) {
        secret[k] = (uint8_t)((3 * k + 7) % 256);
    }
    for (int32_t scope = 0; scope <= 1; scope++) {
        uint8_t blob[256], plain[256];
        int32_t blen = 0, got = 0;
        expect(licdf_app_encrypt(h, scope, secret, 100, NULL, 0, &blen), LICD_E_RANGE, "sealed size");
        expect(licdf_app_encrypt(h, scope, secret, 100, blob, blen, &blen), LICD_OK, "licdf_app_encrypt");
        check(blen > 100 && blob[0] == scope, "sealed data and scope byte");
        expect(licdf_app_decrypt(h, blob, blen, plain, sizeof(plain), &got), LICD_OK, "licdf_app_decrypt");
        check(got == 100 && memcmp(plain, secret, 100) == 0, "round trip");
        blob[blen - 1] ^= 1;
        expect(licdf_app_decrypt(h, blob, blen, plain, sizeof(plain), &got), LICD_E_TAG_MISMATCH,
               "tampered blob");
    }
    expect(licdf_app_encrypt(h, 7, secret, 100, NULL, 0, &len), LICD_E_INVALID_ARG, "unknown scope");

    expect(licdf_record_erase_all(h), LICD_OK, "licdf_record_erase_all");
    expect(licdf_record_count(h, &count), LICD_OK, "licdf_record_count");
    check(count == 0, "erase all");

    expect(licdf_write_auth_rotate(h, REPLACEMENT_KEY, sizeof(REPLACEMENT_KEY)), LICD_OK, "licdf_write_auth_rotate");
    expect(licdf_record_write(h, "lic", (const uint8_t *)"still-writable", 14), LICD_OK, "still writable");
    expect(licdf_session_close(h), LICD_OK, "licdf_session_close");
    expect(licdf_get_info(h, &pa, &pb, &fa, &fb, &fc, &flags, &capacity, &freeb), LICD_OK, "licdf_get_info");
    check((flags & LICDF_FLAG_WRITEAUTH_ROTATED) != 0, "rotated flag");
    expect(licdf_session_open(h), LICD_OK, "second session");
    expect(licdf_write_auth(h, FACTORY_KEY, sizeof(FACTORY_KEY)), LICD_E_NOT_GENUINE, "factory key after rotation");
    expect(licdf_write_auth(h, REPLACEMENT_KEY, sizeof(REPLACEMENT_KEY)), LICD_OK, "new key");
    expect(licdf_record_write(h, "lic", (const uint8_t *)"new-key-writes", 14), LICD_OK, "write with the new key");
    expect(read_record(h, "lic", buf, sizeof(buf), &len), LICD_OK, "read with the new key");
    check(len == 14 && memcmp(buf, "new-key-writes", 14) == 0, "new key content");
    expect(licdf_session_close(h), LICD_OK, "licdf_session_close");

    expect(licdf_close(h), LICD_OK, "licdf_close");
    expect(licdf_get_serial(h, serial, sizeof(serial)), LICD_E_INVALID_ARG, "serial after close");
    expect(licdf_close(h), LICD_E_INVALID_ARG, "close twice");
    expect(licdf_last_error(h, text, sizeof(text)), LICD_E_INVALID_ARG, "error detail after close");

    int32_t handles[40];
    int32_t opened = 0;
    for (int k = 0; k < 40; k++) {
        handles[k] = licdf_open(SERIAL);
        if (handles[k] > 0) {
            opened++;
        }
    }
    check(opened == 32, "32 handles at a time");
    for (int k = 0; k < 40; k++) {
        if (handles[k] > 0) {
            licdf_close(handles[k]);
        }
    }

    if (failures) {
        printf("%d check(s) failed\n", failures);
        return 1;
    }
    printf("licd_flat: every call passed against the ABI stand-in\n");
    return 0;
}
