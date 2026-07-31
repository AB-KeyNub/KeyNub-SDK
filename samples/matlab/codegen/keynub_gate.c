// Licence gate for MATLAB Coder / Simulink Coder generated code.
//
// The +keynub MATLAB binding is a MEX file, so it exists only inside MATLAB: a
// MATLAB Function block calling it must run in interpreted mode, and generated C
// cannot use it at all. Generated code, though, is *C* — so it can call the SDK's
// C ABI directly. This file is the whole bridge, and it is written so that a
// MATLAB Coder entry point needs one coder.ceval and no opaque types.
//
// What it deliberately does NOT provide is a boolean "is a dongle present"
// function. A generated model that branches on a boolean loses its licence check
// to a one-line patch of the generated source, which the customer has. Instead
// this decrypts data the model needs (coefficients, tables, calibration), so
// removing the check removes the data. See docs/integration-security.md.
//
// Build: compile against the SDK's public header and link keynub_licdongle_static (plus
// its platform libraries). build_codegen_demo.m wires that into codegen.

#include "keynub_gate.h"

#include <string.h>

#include "licdongle.h"

int keynub_unlock(const unsigned char *blob, unsigned int blob_len, unsigned char *out,
                  unsigned int out_cap, unsigned int *out_len) {
    if (blob == NULL || out == NULL || out_len == NULL) {
        return LICD_E_INVALID_ARG;
    }
    *out_len = 0;

    licd_ctx *ctx = NULL;
    int rc = licd_init(&ctx);
    if (rc != LICD_OK) {
        return rc;
    }

    licd_device *dev = NULL;
    rc = licd_open(ctx, NULL, &dev); // NULL = the first dongle attached
    if (rc != LICD_OK) {
        licd_free(ctx);
        return rc;
    }

    // Prove the device is genuine before trusting it with anything. This needs a
    // trust root: builds that embed one verify against it, and the published
    // binaries do not, so call licd_set_trust_root before getting here or
    // verify_genuine fails closed with LICD_E_CERT_INVALID.
    licd_genuine_result genuine;
    memset(&genuine, 0, sizeof(genuine));
    rc = licd_verify_genuine(dev, &genuine);
    if (rc == LICD_OK && genuine.genuine == 0) {
        rc = LICD_E_NOT_GENUINE;
    }

    if (rc == LICD_OK) {
        rc = licd_session_open(dev);
    }

    if (rc == LICD_OK) {
        uint8_t *plain = NULL;
        uint32_t plain_len = 0;
        rc = licd_app_decrypt(dev, blob, blob_len, &plain, &plain_len);
        if (rc == LICD_OK) {
            if (plain_len > out_cap) {
                rc = LICD_E_RANGE;
            } else {
                memcpy(out, plain, plain_len);
                *out_len = plain_len;
            }
            licd_free_buffer(plain);
        }
        licd_session_close(dev);
    }

    licd_close(dev);
    licd_free(ctx);
    return rc;
}
