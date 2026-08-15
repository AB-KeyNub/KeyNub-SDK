/* KeyNub SDK - flat-API sample: take ownership of a new dongle.
 *
 * A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
 * that from the next session onward only your key can write records, erase them or
 * increment counters. Run it once per dongle, when it arrives.
 *
 * Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
 *
 *   openssl ecparam -name prime256v1 -genkey -noout |
 *     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
 *
 * Build it with the SDK's CMake project (-DLICD_BUILD_SAMPLES=ON), or compile it
 * straight against a release archive:
 *
 *   cc rotate_write_key.c -Iinclude -Lx64 -lkeynub_licdongle_flat -o rotate_write_key
 *   ./rotate_write_key ../../keys/keynub-shipping-writeauth.key.der my-key.der
 *
 * This is the shape LabVIEW, VBA, COBOL and Fortran reproduce: integer handles,
 * caller-provided buffers, no callbacks. The key is passed as a byte array and its
 * length, which every one of those environments can express.
 *
 * Targets real hardware: with no dongle attached it prints guidance and exits 0.
 *
 * The replacement key is worth what your licence-signing key is worth. It cannot be
 * recovered from the dongle, and a unit rotated to a key you have lost has to come
 * back to be re-provisioned.
 */

#include <licd_flat.h>

#include <stdio.h>

#define MAX_KEY 4096

static void show_error(int32_t handle, const char *operation, int32_t status) {
    char text[LICDF_ERROR_SIZE] = {0};
    char detail[LICDF_ERROR_SIZE] = {0};
    licdf_strerror(status, text, (int32_t)sizeof text);
    licdf_last_error(handle, detail, (int32_t)sizeof detail);
    fprintf(stderr, "KeyNub error in %s: %s\n", operation, text);
    if (detail[0] != '\0') {
        fprintf(stderr, "  detail: %s\n", detail);
    }
}

static int32_t read_key(const char *path, uint8_t *buffer, int32_t capacity) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        fprintf(stderr, "cannot open %s\n", path);
        return 0;
    }
    size_t got = fread(buffer, 1, (size_t)capacity, f);
    fclose(f);
    if (got == 0) {
        fprintf(stderr, "%s is empty\n", path);
    }
    return (int32_t)got;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <current-key.der> <new-key.der>\n", argv[0]);
        return 2;
    }

    uint8_t current[MAX_KEY], replacement[MAX_KEY];
    int32_t current_len = read_key(argv[1], current, (int32_t)sizeof current);
    int32_t replacement_len = read_key(argv[2], replacement, (int32_t)sizeof replacement);
    if (current_len == 0 || replacement_len == 0) {
        return 2;
    }

    int32_t count = 0;
    int32_t status = licdf_device_count(&count);
    if (status != LICD_OK) {
        show_error(0, "licdf_device_count", status);
        return 1;
    }
    if (count == 0) {
        printf("Connect a KeyNub dongle and re-run.\n");
        return 0;
    }

    int32_t handle = licdf_open(NULL); /* first dongle; pass a serial to choose */
    if (handle <= 0) {
        show_error(0, "licdf_open", handle);
        return 1;
    }

    char serial[LICDF_SERIAL_SIZE] = {0};
    if (licdf_get_serial(handle, serial, (int32_t)sizeof serial) == LICD_OK) {
        printf("dongle %s\n", serial);
    }

    int result = 1;
    if ((status = licdf_session_open(handle)) != LICD_OK) {
        show_error(handle, "licdf_session_open", status);
        goto done;
    }
    if ((status = licdf_write_auth(handle, current, current_len)) != LICD_OK) {
        show_error(handle, "licdf_write_auth", status);
        goto done;
    }
    if ((status = licdf_write_auth_rotate(handle, replacement, replacement_len)) != LICD_OK) {
        show_error(handle, "licdf_write_auth_rotate", status);
        goto done;
    }
    printf("rotated: this dongle now answers only to your key\n");
    licdf_session_close(handle);

    /* A fresh session is the only place the change is observable: the session
     * above keeps the role it was already granted. */
    if ((status = licdf_session_open(handle)) != LICD_OK) {
        show_error(handle, "licdf_session_open", status);
        goto done;
    }
    if (licdf_write_auth(handle, current, current_len) == LICD_OK) {
        fprintf(stderr, "WARNING: the old key still works -- do not ship this unit\n");
        goto done;
    }
    printf("confirmed: the old key no longer elevates\n");
    if ((status = licdf_write_auth(handle, replacement, replacement_len)) != LICD_OK) {
        show_error(handle, "licdf_write_auth", status);
        goto done;
    }
    printf("confirmed: your key elevates\n");
    licdf_session_close(handle);

    printf("\nKeep the replacement key safe. Every future write to this dongle needs it.\n");
    result = 0;

done:
    licdf_close(handle);
    return result;
}
