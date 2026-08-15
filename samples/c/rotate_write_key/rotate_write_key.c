// KeyNub SDK - C sample: take ownership of a new dongle.
//
// A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
// that from the next session onward only your key can write records, erase them or
// increment counters. Run it once per dongle, when it arrives.
//
// Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
//
//   openssl ecparam -name prime256v1 -genkey -noout |
//     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
//
// Build it with the SDK's CMake project (-DLICD_BUILD_SAMPLES=ON), or compile it
// straight against a release archive:
//
//   cc rotate_write_key.c -Iinclude -Lx64 -lkeynub_licdongle -o rotate_write_key
//   ./rotate_write_key ../../../keys/keynub-shipping-writeauth.key.der my-key.der
//
// Targets real hardware; prints guidance and exits 0 when no dongle is attached.
//
// The replacement key is worth what your licence-signing key is worth. It cannot be
// recovered from the dongle, and a unit rotated to a key you have lost has to come
// back to be re-provisioned.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "licdongle.h"

#define MAX_KEY 4096

static uint8_t *read_key(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        fprintf(stderr, "cannot open %s\n", path);
        return NULL;
    }
    uint8_t *buf = (uint8_t *)malloc(MAX_KEY);
    if (buf == NULL) {
        fclose(f);
        return NULL;
    }
    *out_len = fread(buf, 1, MAX_KEY, f);
    fclose(f);
    if (*out_len == 0) {
        fprintf(stderr, "%s is empty\n", path);
        free(buf);
        return NULL;
    }
    return buf;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <current-key.der> <new-key.der>\n", argv[0]);
        return 2;
    }

    size_t current_len = 0, replacement_len = 0;
    uint8_t *current = read_key(argv[1], &current_len);
    uint8_t *replacement = current ? read_key(argv[2], &replacement_len) : NULL;
    if (current == NULL || replacement == NULL) {
        free(current);
        free(replacement);
        return 2;
    }

    int status = 1;
    licd_ctx *ctx = NULL;
    licd_device *dev = NULL;
    licd_device_info *list = NULL;
    size_t count = 0;

    if (licd_init(&ctx) != LICD_OK) {
        fprintf(stderr, "licd_init failed\n");
        goto done;
    }
    if (licd_enumerate(ctx, &list, &count) != LICD_OK) {
        fprintf(stderr, "enumerate failed\n");
        goto done;
    }
    if (count == 0) {
        printf("Connect a KeyNub dongle and re-run.\n");
        status = 0;
        goto done;
    }

    int rc = licd_open(ctx, NULL, &dev);
    if (rc != LICD_OK) {
        fprintf(stderr, "open failed: %s\n", licd_strerror(rc));
        goto done;
    }

    char serial[LICD_SERIAL_HEX_LEN + 1] = {0};
    if (licd_get_serial(dev, serial, sizeof(serial)) == LICD_OK) {
        printf("dongle %s\n", serial);
    }

    if ((rc = licd_session_open(dev)) != LICD_OK ||
        (rc = licd_write_auth(dev, current, current_len)) != LICD_OK ||
        (rc = licd_write_auth_rotate(dev, replacement, replacement_len)) != LICD_OK) {
        fprintf(stderr, "rotation failed: %s (%s)\n", licd_strerror(rc), licd_error_detail(ctx));
        goto done;
    }
    printf("rotated: this dongle now answers only to your key\n");
    licd_session_close(dev);

    // A fresh session is the only place the change is observable: the session
    // above keeps the role it was already granted.
    if ((rc = licd_session_open(dev)) != LICD_OK) {
        fprintf(stderr, "re-opening the session failed: %s\n", licd_strerror(rc));
        goto done;
    }
    if (licd_write_auth(dev, current, current_len) == LICD_OK) {
        fprintf(stderr, "WARNING: the old key still works -- do not ship this unit\n");
        goto done;
    }
    printf("confirmed: the old key no longer elevates\n");
    if ((rc = licd_write_auth(dev, replacement, replacement_len)) != LICD_OK) {
        fprintf(stderr, "the new key does not elevate: %s\n", licd_strerror(rc));
        goto done;
    }
    printf("confirmed: your key elevates\n");
    licd_session_close(dev);

    printf("\nKeep the replacement key safe. Every future write to this dongle needs it.\n");
    status = 0;

done:
    if (dev != NULL) {
        licd_close(dev);
    }
    if (list != NULL) {
        licd_free_device_list(list, count);
    }
    if (ctx != NULL) {
        licd_free(ctx);
    }
    free(current);
    free(replacement);
    return status;
}
