// KeyNub SDK - C sample: enumerate a dongle, verify authenticity, open an
// encrypted session, read a "license" record, and round-trip app-data
// encryption. Targets real hardware; prints guidance and exits 0 when no
// dongle is attached.
//
// Build it with the CMakeLists.txt beside this file (cmake -S . -B build &&
// cmake --build build), or compile it straight against the prebuilt library:
//
//   cc verify_and_read.c -Iinclude -Lnatives/<platform> -lkeynub_licdongle -o verify_and_read

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "licdongle.h"

int main(void) {
    int maj = 0, min = 0, pat = 0;
    licd_version(&maj, &min, &pat);
    printf("KeyNub SDK %d.%d.%d\n", maj, min, pat);

    licd_ctx *ctx = NULL;
    if (licd_init(&ctx) != LICD_OK) {
        fprintf(stderr, "licd_init failed\n");
        return 1;
    }

    licd_device_info *list = NULL;
    size_t count = 0;
    if (licd_enumerate(ctx, &list, &count) != LICD_OK) {
        fprintf(stderr, "enumerate failed\n");
        licd_free(ctx);
        return 1;
    }
    printf("Dongles found: %zu\n", count);
    if (count == 0) {
        printf("Connect a KeyNub dongle and re-run.\n");
        licd_free_device_list(list, count);
        licd_free(ctx);
        return 0;
    }

    const char *serial = list[0].serial[0] != '\0' ? list[0].serial : NULL;
    licd_device *dev = NULL;
    int rc = licd_open(ctx, serial, &dev);
    licd_free_device_list(list, count);
    if (rc != LICD_OK) {
        fprintf(stderr, "open: %s\n", licd_strerror(rc));
        licd_free(ctx);
        return 1;
    }

    licd_info info;
    if (licd_get_info(dev, &info) == LICD_OK) {
        printf("protocol %u.%u, firmware %u.%u.%u, capacity %u bytes\n",
               info.proto_version_major, info.proto_version_minor, info.fw_version_major,
               info.fw_version_minor, info.fw_version_patch, info.data_capacity);
    }

    char hex[LICD_SERIAL_HEX_LEN + 1];
    if (licd_get_serial(dev, hex, sizeof(hex)) == LICD_OK) {
        printf("serial %s\n", hex);
    }

    // Authenticity: cert chain to the trusted root + a live challenge-response.
    licd_genuine_result g;
    memset(&g, 0, sizeof(g));
    rc = licd_verify_genuine(dev, &g);
    if (rc != LICD_OK) {
        fprintf(stderr, "verify_genuine: %s (%s)\n", licd_strerror(rc), licd_error_detail(ctx));
        licd_close(dev);
        licd_free(ctx);
        return 2;
    }
    printf("genuine: yes, cert serial %s\n", g.serial);

    // Encrypted session for the data + app-crypto operations.
    if (licd_session_open(dev) != LICD_OK) {
        fprintf(stderr, "session_open: %s (%s)\n", licd_strerror(rc), licd_error_detail(ctx));
        licd_close(dev);
        licd_free(ctx);
        return 3;
    }

    uint8_t buf[512];
    uint32_t got = 0, total = 0;
    rc = licd_record_read(dev, "license", 0, buf, sizeof(buf), &got, &total, NULL, NULL);
    if (rc == LICD_OK) {
        printf("license record: %u bytes\n", total);
    } else if (rc == LICD_E_NOT_FOUND) {
        printf("no 'license' record on this dongle\n");
    } else {
        printf("record_read: %s\n", licd_strerror(rc));
    }

    // App-data envelope encryption: the blob only decrypts with this dongle.
    const char *secret = "hello-keynub";
    uint32_t slen = (uint32_t)strlen(secret);
    uint8_t *packed = NULL, *plain = NULL;
    uint32_t plen = 0, dlen = 0;
    if (licd_app_encrypt(dev, LICD_SCOPE_DEVICE, secret, slen, &packed, &plen) == LICD_OK) {
        if (licd_app_decrypt(dev, packed, plen, &plain, &dlen) == LICD_OK && dlen == slen &&
            memcmp(plain, secret, dlen) == 0) {
            printf("app-crypto round-trip OK (%u plaintext -> %u packed bytes)\n", slen, plen);
        } else {
            printf("app-crypto round-trip FAILED\n");
        }
        licd_free_buffer(packed);
        licd_free_buffer(plain);
    }

    licd_session_close(dev);
    licd_close(dev);
    licd_free(ctx);
    return 0;
}
