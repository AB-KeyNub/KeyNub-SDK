/* KeyNub dongle check through the FLAT companion API: enumerate -> open ->
 * verify -> session -> read a record -> app-crypto round trip.
 *
 * Build it with the SDK's CMake project (-DLICD_BUILD_SAMPLES=ON), or compile it
 * straight against a release archive:
 *
 *   cc verify_and_read.c -Iinclude -Lx64 -lkeynub_licdongle_flat -o verify_and_read
 *
 * This is the API for callers that cannot express the core ABI: integer handles
 * instead of opaque pointers, caller-provided buffers instead of library-allocated
 * ones, and no callbacks anywhere. LabVIEW, VBA, COBOL and Fortran all go through
 * it. The sample is in C because that is the language the contract is written in —
 * if you are wiring up a Call Library Function node or a Declare statement, this is
 * the shape you are reproducing.
 *
 * Targets real hardware: with no dongle attached it prints guidance and exits 0.
 *
 * READ FIRST: docs/integration-security.md. This sample prints whether the dongle
 * is genuine, which is the one thing a real licence check must not do — a printed
 * flag is a deleted line away from nothing. protect_something() shows the shape
 * that actually protects something.
 */

#include <licd_flat.h>

#include <stdio.h>
#include <string.h>

/* The flat API takes the scope as a plain int32_t and documents 0 and 1 in a
 * comment rather than exporting an enum — deliberately, because half the callers
 * it exists for have no enum type to import. Naming them locally is the habit
 * worth copying into whichever environment you are wiring up. */
#define KEYNUB_SCOPE_DEVICE 0
#define KEYNUB_SCOPE_DEVELOPER 1

/* Every call that returns variable-length data follows one rule: pass a capacity
 * and an out-length. Ask with a capacity of zero to learn the size it needs. */
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

static void report(int32_t handle) {
    int32_t pmaj = 0, pmin = 0, fmaj = 0, fmin = 0, fpatch = 0;
    int32_t flags = 0, capacity = 0, freebytes = 0;
    int32_t genuine = 0;
    char serial[LICDF_SERIAL_SIZE] = {0};
    int32_t rc;

    rc = licdf_get_info(handle, &pmaj, &pmin, &fmaj, &fmin, &fpatch, &flags, &capacity,
                        &freebytes);
    if (rc == LICD_OK) {
        printf("Protocol v%d.%d, firmware v%d.%d.%d, %d of %d bytes free.\n", pmaj, pmin,
               fmaj, fmin, fpatch, freebytes, capacity);
        if ((flags & LICDF_FLAG_WATCHDOG_REBOOT) != 0) {
            /* The only trace a firmware hang leaves behind. Report it to support. */
            printf("WARNING: this dongle's previous boot ended in a watchdog reset.\n");
        }
    }

    char provisioned[LICDF_DATE_SIZE];
    rc = licdf_verify_genuine(handle, &genuine, serial, (int32_t)sizeof serial, provisioned,
                              (int32_t)sizeof provisioned);
    if (rc != LICD_OK) {
        show_error(handle, "verify_genuine", rc);
        return;
    }
    printf("Genuine: %s (serial %s)\n", genuine ? "true" : "false", serial);
    /* Informational only. Empty on a dongle that reports no date, so print it
       that way rather than pretending to a value. */
    printf("Personalised: %s\n", provisioned[0] != '\0' ? provisioned : "(not reported)");
}

static void read_records(int32_t handle) {
    int32_t count = 0, i, rc;

    rc = licdf_record_count(handle, &count);
    if (rc != LICD_OK) {
        show_error(handle, "record_count", rc);
        return;
    }
    printf("%d record(s) on the dongle:\n", count);
    for (i = 0; i < count; ++i) {
        char name[64] = {0};
        int32_t size = 0;
        if (licdf_record_name(handle, i, name, (int32_t)sizeof name, &size) == LICD_OK) {
            printf("  %-16s %6d bytes\n", name, size);
        }
    }

    /* The two-call shape: ask for the size, then read into a buffer that fits. A
     * missing record is a normal state, not an error worth reporting. */
    {
        int32_t needed = 0;
        if (licdf_record_size(handle, "license", &needed) == LICD_OK && needed >= 0) {
            unsigned char buffer[512];
            int32_t got = 0;
            int32_t cap = needed < (int32_t)sizeof buffer ? needed : (int32_t)sizeof buffer;
            if (licdf_record_read(handle, "license", buffer, cap, &got) == LICD_OK) {
                printf("Read %d bytes from the license record.\n", got);
            }
        }
    }
}

/* The part that actually protects something. At licence-issue time you would call
 * licdf_app_encrypt once, with a developer dongle, and ship only the blob; the
 * application then cannot proceed without a dongle, because it holds no other copy
 * of the data. Developer scope lets any dongle you have issued decrypt it, so one
 * file serves every customer; device scope locks it to one dongle. */
static void protect_something(int32_t handle) {
    static const char text[] = "the data this program cannot run without";
    const int32_t needed_len = (int32_t)(sizeof text - 1);
    unsigned char sealed[256];
    unsigned char recovered[256];
    int32_t sealed_len = 0, recovered_len = 0, rc;

    rc = licdf_app_encrypt(handle, KEYNUB_SCOPE_DEVELOPER, (const unsigned char *)text,
                           needed_len, sealed, (int32_t)sizeof sealed, &sealed_len);
    if (rc != LICD_OK) {
        show_error(handle, "app_encrypt", rc);
        return;
    }

    rc = licdf_app_decrypt(handle, sealed, sealed_len, recovered, (int32_t)sizeof recovered,
                           &recovered_len);
    if (rc != LICD_OK) {
        show_error(handle, "app_decrypt", rc);
        return;
    }

    printf("App-crypto round trip: %d bytes -> %d sealed -> %s\n", needed_len, sealed_len,
           (recovered_len == needed_len && memcmp(recovered, text, (size_t)needed_len) == 0)
               ? "recovered intact"
               : "MISMATCH");
}

int main(void) {
    int32_t major = 0, minor = 0, patch = 0;
    int32_t count = 0, i, handle, rc;

    licdf_version(&major, &minor, &patch);
    printf("KeyNub SDK %d.%d.%d\n", major, minor, patch);

    rc = licdf_device_count(&count);
    if (rc != LICD_OK) {
        show_error(0, "device_count", rc);
        return 1;
    }
    printf("Found %d KeyNub dongle(s).\n", count);
    for (i = 0; i < count; ++i) {
        char serial[LICDF_SERIAL_SIZE] = {0};
        if (licdf_device_serial(i, serial, (int32_t)sizeof serial) == LICD_OK) {
            printf("  [%d] serial %s\n", i, serial);
        }
    }
    if (count == 0) {
        printf("No dongle attached; nothing to do.\n");
        return 0;
    }

    /* An empty string means the first dongle found. Unlike the core API this
     * returns a positive handle rather than filling in an out-parameter, which is
     * what makes it callable from environments with no pointer type. */
    handle = licdf_open("");
    if (handle <= 0) {
        show_error(0, "open", handle);
        return 1;
    }

    report(handle);

    rc = licdf_session_open(handle);
    if (rc != LICD_OK) {
        show_error(handle, "session_open", rc);
    } else {
        read_records(handle);
        protect_something(handle);
        licdf_session_close(handle);
    }

    licdf_close(handle);
    return 0;
}
