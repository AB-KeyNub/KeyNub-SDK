// A single C entry point for gating MATLAB Coder / Simulink Coder generated code
// on a KeyNub dongle. See keynub_gate.c for why this shim exists.

#ifndef KEYNUB_GATE_H
#define KEYNUB_GATE_H

#ifdef __cplusplus
extern "C" {
#endif

// Opens the first attached dongle, proves it is genuine, and decrypts `blob`
// (produced by licd_app_encrypt / keynub.Session.appEncrypt) into `out`.
//
// Returns 0 on success, or the negative licd_status that failed. -11
// (LICD_E_RANGE) means `out_cap` was too small for the plaintext.
//
// Deliberately does everything in one call: generated code has nowhere natural
// to keep a handle across steps, and holding the dongle open for the lifetime of
// a real-time application blocks every other process from using it.
int keynub_unlock(const unsigned char *blob, unsigned int blob_len, unsigned char *out,
                  unsigned int out_cap, unsigned int *out_len);

#ifdef __cplusplus
}
#endif

#endif // KEYNUB_GATE_H
