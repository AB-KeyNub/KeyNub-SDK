// KeyNub License Dongle SDK — MATLAB/Simulink MEX gateway.
//
// One MEX entry point behind a command word:
//
//     result = licd_mex('command', args...)
//
// The MATLAB classes in +keynub are deliberately thin. Every argument check,
// every handle validation and all marshalling live *here*, in C, because this
// file is covered by a native test (the SDK test suite) that drives
// mexFunction through a minimal implementation of the mx/mex API. The .m files
// cannot be executed without MATLAB, so as little logic as possible sits there.
//
// Why MEX and not loadlibrary(): loadlibrary needs a supported C compiler *and*
// Perl to build a thunk on 64-bit platforms, and "loading libraries using header
// files is not supported in compiled applications" — so a MATLAB Compiler /
// MATLAB Runtime deployment (exactly where a licence check matters) would need a
// pre-generated prototype plus thunk DLL shipped alongside. A MEX file is a
// normal deployment dependency and needs no header parsing at run time.
//
// Handles crossing into MATLAB are uint64 ids into a registry here, never raw
// pointers: a MATLAB user can pass any number they like, and a bogus pointer
// would take the whole MATLAB process down with it. Ids are validated and never
// reused within a session.

#include <stdint.h>
#include <string.h>

#include "mex.h"

#include "licdongle.h"

#ifdef LICD_MEX_ENABLE_SIM
// Test-only entry points, exported by keynub_licdongle_sim and *not* by the
// shipping library. Compiled in only for the binding's own test suite.
extern int licd_open_simulated(licd_ctx *ctx, licd_device **out_dev);
extern void licd_test_get_master_key_der(const uint8_t **out_der, uint32_t *out_len);
#endif

// ============================================================================
// Errors
// ============================================================================

// MATLAB error identifiers, one per status code: `catch e` on
// e.identifier is how MATLAB code distinguishes failures, so these are API.
static const char *status_identifier(int status) {
    switch (status) {
    case LICD_E_INVALID_ARG:     return "KeyNub:licdongle:invalidArgument";
    case LICD_E_NO_DEVICE:       return "KeyNub:licdongle:noDevice";
    case LICD_E_ACCESS_DENIED:   return "KeyNub:licdongle:accessDenied";
    case LICD_E_IO:              return "KeyNub:licdongle:io";
    case LICD_E_TIMEOUT:         return "KeyNub:licdongle:timeout";
    case LICD_E_PROTOCOL:        return "KeyNub:licdongle:protocol";
    case LICD_E_NOT_GENUINE:     return "KeyNub:licdongle:notGenuine";
    case LICD_E_CERT_INVALID:    return "KeyNub:licdongle:certificateInvalid";
    case LICD_E_SESSION_EXPIRED: return "KeyNub:licdongle:sessionExpired";
    case LICD_E_TAG_MISMATCH:    return "KeyNub:licdongle:tagMismatch";
    case LICD_E_RANGE:           return "KeyNub:licdongle:range";
    case LICD_E_STORAGE_FULL:    return "KeyNub:licdongle:storageFull";
    case LICD_E_BUSY:            return "KeyNub:licdongle:busy";
    case LICD_E_NOT_FOUND:       return "KeyNub:licdongle:recordNotFound";
    case LICD_E_AUTH_REQUIRED:   return "KeyNub:licdongle:writeAuthorizationRequired";
    case LICD_E_FW_INCOMPATIBLE: return "KeyNub:licdongle:firmwareIncompatible";
    case LICD_E_SDK_TOO_OLD:     return "KeyNub:licdongle:sdkTooOld";
    case LICD_E_CANCELLED:       return "KeyNub:licdongle:cancelled";
    case LICD_E_NOT_IMPLEMENTED: return "KeyNub:licdongle:notImplemented";
    default:                     return "KeyNub:licdongle:internal";
    }
}

#define BAD_ARG "KeyNub:licdongle:invalidArgument"

// Never returns. Native resources must already be released by the caller.
static void fail_status(licd_ctx *ctx, int status, const char *op) {
    const char *detail = (ctx != NULL) ? licd_error_detail(ctx) : NULL;
    const char *msg = licd_strerror(status);
    if (detail != NULL && detail[0] != '\0') {
        mexErrMsgIdAndTxt(status_identifier(status), "%s: %s (%s)", op, msg, detail);
    } else {
        mexErrMsgIdAndTxt(status_identifier(status), "%s: %s", op, msg);
    }
}

// ============================================================================
// Handle registry
// ============================================================================

#define LICD_MEX_MAX_HANDLES 64

typedef enum { SLOT_FREE = 0, SLOT_CTX = 1, SLOT_DEV = 2 } slot_kind;

typedef struct {
    slot_kind kind;
    uint64_t id;
    void *ptr;       // licd_ctx* or licd_device*
    licd_ctx *ctx;   // owning context (== ptr for SLOT_CTX); for error detail
    uint64_t owner;  // SLOT_DEV: id of the owning context slot
} slot_t;

static slot_t g_slots[LICD_MEX_MAX_HANDLES];
static uint64_t g_next_id = 1;
static int g_locks;        // outstanding mexLock() calls (one per live handle)
static int g_atexit_set;
static int g_in_callback;  // set while a MATLAB progress callback may run

static slot_t *slot_find(uint64_t id, slot_kind kind) {
    if (id == 0) {
        return NULL;
    }
    for (int i = 0; i < LICD_MEX_MAX_HANDLES; i++) {
        if (g_slots[i].kind == kind && g_slots[i].id == id) {
            return &g_slots[i];
        }
    }
    return NULL;
}

static void slot_release(slot_t *s) {
    s->kind = SLOT_FREE;
    s->id = 0;
    s->ptr = NULL;
    s->ctx = NULL;
    s->owner = 0;
    if (g_locks > 0) {
        g_locks--;
        // Locked while handles are live so `clear licd_mex` cannot unload the
        // MEX (and orphan open dongles) underneath live MATLAB objects.
        mexUnlock();
    }
}

// Frees every native resource still held. Registered with mexAtExit, so a
// MATLAB exit or `clear mex` after the last handle is closed cannot leak the
// USB handles the OS would otherwise keep until the process dies.
static void licd_mex_cleanup(void) {
    for (int i = 0; i < LICD_MEX_MAX_HANDLES; i++) { // devices first
        if (g_slots[i].kind == SLOT_DEV) {
            licd_close((licd_device *)g_slots[i].ptr);
            slot_release(&g_slots[i]);
        }
    }
    for (int i = 0; i < LICD_MEX_MAX_HANDLES; i++) {
        if (g_slots[i].kind == SLOT_CTX) {
            licd_free((licd_ctx *)g_slots[i].ptr);
            slot_release(&g_slots[i]);
        }
    }
    g_in_callback = 0;
}

// Registers ptr and returns its id. Never returns 0.
static uint64_t slot_add(slot_kind kind, void *ptr, licd_ctx *ctx, uint64_t owner) {
    for (int i = 0; i < LICD_MEX_MAX_HANDLES; i++) {
        if (g_slots[i].kind == SLOT_FREE) {
            g_slots[i].kind = kind;
            g_slots[i].id = g_next_id++;
            g_slots[i].ptr = ptr;
            g_slots[i].ctx = ctx;
            g_slots[i].owner = owner;
            g_locks++;
            mexLock();
            return g_slots[i].id;
        }
    }
    return 0; // caller decides how to report (it must free ptr first)
}

// ============================================================================
// Argument helpers
// ============================================================================

static uint64_t arg_id(const mxArray *a, const char *what) {
    if (!mxIsUint64(a) || mxIsComplex(a) || mxGetNumberOfElements(a) != 1) {
        mexErrMsgIdAndTxt(BAD_ARG, "%s must be a uint64 scalar handle", what);
    }
    return *(const uint64_t *)mxGetData(a);
}

static slot_t *arg_ctx_slot(const mxArray *a) {
    uint64_t id = arg_id(a, "context handle");
    slot_t *s = slot_find(id, SLOT_CTX);
    if (s == NULL) {
        // The usual cause is a stale object surviving `clear licd_mex`.
        mexErrMsgIdAndTxt("KeyNub:licdongle:invalidHandle",
                          "not an open context handle (it may already be closed)");
    }
    return s;
}

static slot_t *arg_dev_slot(const mxArray *a) {
    uint64_t id = arg_id(a, "dongle handle");
    slot_t *s = slot_find(id, SLOT_DEV);
    if (s == NULL) {
        mexErrMsgIdAndTxt("KeyNub:licdongle:invalidHandle",
                          "not an open dongle handle (it may already be closed)");
    }
    return s;
}

// MATLAB-managed copy of a char row vector (freed automatically when the MEX
// call returns or errors). Empty input yields an empty string, not NULL.
static char *arg_string(const mxArray *a, const char *what) {
    if (!mxIsChar(a)) {
        mexErrMsgIdAndTxt(BAD_ARG, "%s must be a character vector", what);
    }
    if (mxGetNumberOfElements(a) == 0) {
        char *empty = (char *)mxMalloc(1);
        empty[0] = '\0';
        return empty;
    }
    if (mxGetM(a) > 1) {
        mexErrMsgIdAndTxt(BAD_ARG, "%s must be a single row of characters", what);
    }
    char *s = mxArrayToString(a);
    if (s == NULL) {
        mexErrMsgIdAndTxt(BAD_ARG, "%s could not be converted to a string", what);
    }
    return s;
}

static const char *arg_record_name(const mxArray *a) {
    char *name = arg_string(a, "the record name");
    if (name[0] == '\0') {
        mexErrMsgIdAndTxt(BAD_ARG, "the record name must not be empty");
    }
    return name;
}

// Byte-vector input. uint8 is used directly; char and integral double/single are
// converted, because in MATLAB a literal like [48 49] is a double and rejecting
// it outright would be needlessly hostile. Non-integral or out-of-range values
// are an error rather than a silent truncation — quietly mangling a key or a
// certificate is how you get a "the dongle is broken" support ticket.
static const uint8_t *arg_bytes(const mxArray *a, size_t *out_len, const char *what) {
    if (mxIsComplex(a)) {
        mexErrMsgIdAndTxt(BAD_ARG, "%s must be real, not complex", what);
    }
    size_t n = (size_t)mxGetNumberOfElements(a);
    *out_len = n;

    if (mxIsUint8(a) || mxIsInt8(a)) {
        return n == 0 ? NULL : (const uint8_t *)mxGetData(a);
    }
    if (n == 0) {
        if (mxIsChar(a) || mxIsDouble(a) || mxIsSingle(a)) {
            return NULL;
        }
        mexErrMsgIdAndTxt(BAD_ARG, "%s must be a uint8, char or numeric vector", what);
    }

    uint8_t *buf = (uint8_t *)mxMalloc(n);
    if (mxIsChar(a)) {
        const mxChar *src = mxGetChars(a);
        for (size_t i = 0; i < n; i++) {
            if (src[i] > 255) {
                mexErrMsgIdAndTxt(BAD_ARG,
                                  "%s contains a character above 255 at index %d; "
                                  "pass bytes as uint8", what, (int)(i + 1));
            }
            buf[i] = (uint8_t)src[i];
        }
        return buf;
    }
    if (mxIsDouble(a) || mxIsSingle(a)) {
        int is_double = mxIsDouble(a);
        const double *d = is_double ? (const double *)mxGetData(a) : NULL;
        const float *f = is_double ? NULL : (const float *)mxGetData(a);
        for (size_t i = 0; i < n; i++) {
            double v = is_double ? d[i] : (double)f[i];
            if (!(v >= 0.0 && v <= 255.0) || v != (double)(uint8_t)v) {
                mexErrMsgIdAndTxt(BAD_ARG,
                                  "%s must contain whole numbers in 0..255 "
                                  "(element %d is not); use uint8 for byte data",
                                  what, (int)(i + 1));
            }
            buf[i] = (uint8_t)v;
        }
        return buf;
    }
    mexErrMsgIdAndTxt(BAD_ARG, "%s must be a uint8, char or numeric vector", what);
    return NULL; // unreachable
}

static double arg_scalar(const mxArray *a, const char *what) {
    if (!mxIsNumeric(a) || mxIsComplex(a) || mxGetNumberOfElements(a) != 1) {
        mexErrMsgIdAndTxt(BAD_ARG, "%s must be a numeric scalar", what);
    }
    return mxGetScalar(a);
}

static uint8_t arg_counter_id(const mxArray *a) {
    double v = arg_scalar(a, "the counter index");
    if (!(v >= 0.0 && v <= 255.0) || v != (double)(uint8_t)v) {
        mexErrMsgIdAndTxt(BAD_ARG, "the counter index must be a whole number in 0..255");
    }
    return (uint8_t)v;
}

// ============================================================================
// Output helpers
// ============================================================================

static mxArray *out_id(uint64_t id) {
    mxArray *a = mxCreateNumericMatrix(1, 1, mxUINT64_CLASS, mxREAL);
    *(uint64_t *)mxGetData(a) = id;
    return a;
}

static mxArray *out_bytes(const uint8_t *data, size_t len) {
    mxArray *a = mxCreateNumericMatrix((mwSize)len, len == 0 ? 0 : 1, mxUINT8_CLASS, mxREAL);
    if (len != 0) {
        memcpy(mxGetData(a), data, len);
    }
    return a;
}

static mxArray *out_doubles(const double *v, size_t n) {
    mxArray *a = mxCreateDoubleMatrix(1, (mwSize)n, mxREAL);
    memcpy(mxGetData(a), v, n * sizeof(double));
    return a;
}

// ============================================================================
// Progress callbacks
// ============================================================================

// Bridges licd_progress_cb to a MATLAB function handle. An error inside the
// callback cancels the transfer and is rethrown afterwards: longjmp'ing out of
// mexErrMsgIdAndTxt while the core is mid-transfer would strand the device.
typedef struct {
    const mxArray *fn; // MATLAB function handle, or NULL for "no callback"
    int nlhs;          // 1 if the callback returns a value we can act on
    mxArray *err;      // trapped MException, owned here
} progress_bridge;

static int progress_trampoline(uint32_t done, uint32_t total, void *user) {
    progress_bridge *p = (progress_bridge *)user;
    if (p->err != NULL) {
        return 0; // already failed; keep cancelling
    }

    mxArray *args[3];
    mxArray *ret[1] = {NULL};
    args[0] = (mxArray *)p->fn;
    args[1] = mxCreateDoubleScalar((double)done);
    args[2] = mxCreateDoubleScalar((double)total);

    g_in_callback = 1;
    mxArray *err = mexCallMATLABWithTrap(p->nlhs, ret, 3, args, "feval");
    g_in_callback = 0;

    mxDestroyArray(args[1]);
    mxDestroyArray(args[2]);

    if (err != NULL) {
        p->err = err;
        return 0;
    }

    int keep_going = 1;
    if (ret[0] != NULL) {
        // false (logical or numeric zero) cancels; anything else continues, so a
        // callback that just draws a waitbar and returns nothing useful is safe.
        if (mxIsLogical(ret[0]) || mxIsNumeric(ret[0])) {
            if (mxGetNumberOfElements(ret[0]) == 1 && mxGetScalar(ret[0]) == 0.0) {
                keep_going = 0;
            }
        }
        mxDestroyArray(ret[0]);
    }
    return keep_going;
}

// Prepares the bridge from an optional trailing function-handle argument.
static void progress_init(progress_bridge *p, const mxArray *maybe_fn) {
    p->fn = NULL;
    p->nlhs = 0;
    p->err = NULL;
    if (maybe_fn == NULL || mxIsEmpty(maybe_fn)) {
        return;
    }
    if (!mxIsClass(maybe_fn, "function_handle")) {
        mexErrMsgIdAndTxt(BAD_ARG, "the progress argument must be a function handle or []");
    }
    p->fn = maybe_fn;

    // How many outputs may we ask for? Requesting one from a callback that
    // returns none is an error in MATLAB, and `@(d,t) fprintf(...)` (which does
    // return one) is just as likely as `function stop = cb(d,t)`. Ask MATLAB.
    mxArray *nargs[1] = {(mxArray *)maybe_fn};
    mxArray *ret[1] = {NULL};
    mxArray *err = mexCallMATLABWithTrap(1, ret, 1, nargs, "nargout");
    if (err != NULL) {
        mxDestroyArray(err);
        p->nlhs = 0; // can't tell: assume it returns nothing, so never cancel
    } else {
        double n = (ret[0] != NULL && mxGetNumberOfElements(ret[0]) == 1)
                       ? mxGetScalar(ret[0]) : 0.0;
        p->nlhs = (n != 0.0) ? 1 : 0; // negative = varargout, so also 1
    }
    if (ret[0] != NULL) {
        mxDestroyArray(ret[0]);
    }
}

static licd_progress_cb progress_cb(const progress_bridge *p) {
    return (p->fn != NULL) ? progress_trampoline : NULL;
}

// Rethrows a callback error, or maps the transfer status. Never returns unless
// the transfer succeeded.
static void progress_finish(progress_bridge *p, licd_ctx *ctx, int rc, const char *op) {
    if (p->err != NULL) {
        mxArray *err = p->err;
        p->err = NULL;
        mxArray *args[1] = {err};
        mexCallMATLAB(0, NULL, 1, args, "rethrow"); // does not return
        mexErrMsgIdAndTxt("KeyNub:licdongle:cancelled",
                          "%s was cancelled by its progress callback", op);
    }
    if (rc != LICD_OK) {
        fail_status(ctx, rc, op);
    }
}

// ============================================================================
// Commands
// ============================================================================

static void cmd_version(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs; (void)prhs;
    int major = 0, minor = 0, patch = 0;
    licd_version(&major, &minor, &patch);
    double v[3] = {(double)major, (double)minor, (double)patch};
    plhs[0] = out_doubles(v, 3);
}

static void cmd_init(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs; (void)prhs;
    licd_ctx *ctx = NULL;
    int rc = licd_init(&ctx);
    if (rc != LICD_OK) {
        fail_status(NULL, rc, "licd_init");
    }
    uint64_t id = slot_add(SLOT_CTX, ctx, ctx, 0);
    if (id == 0) {
        licd_free(ctx);
        mexErrMsgIdAndTxt("KeyNub:licdongle:tooManyHandles",
                          "more than %d open KeyNub handles; close some first",
                          LICD_MEX_MAX_HANDLES);
    }
    plhs[0] = out_id(id);
}

static void cmd_free(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)plhs; (void)nrhs;
    slot_t *s = arg_ctx_slot(prhs[1]);
    uint64_t ctx_id = s->id;
    // Close the dongles this context opened first. MATLAB destroys handle
    // objects in no particular order at `clear`, so the context can legitimately
    // go first — and freeing it under an open device would use freed memory.
    for (int i = 0; i < LICD_MEX_MAX_HANDLES; i++) {
        if (g_slots[i].kind == SLOT_DEV && g_slots[i].owner == ctx_id) {
            licd_close((licd_device *)g_slots[i].ptr);
            slot_release(&g_slots[i]);
        }
    }
    licd_free((licd_ctx *)s->ptr);
    slot_release(s);
}

static void cmd_set_trust_root(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)plhs; (void)nrhs;
    slot_t *s = arg_ctx_slot(prhs[1]);
    size_t len = 0;
    const uint8_t *der = arg_bytes(prhs[2], &len, "the trust root");
    int rc = licd_set_trust_root((licd_ctx *)s->ptr, der, len);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_set_trust_root");
    }
}

static void cmd_error_detail(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs;
    slot_t *s = arg_ctx_slot(prhs[1]);
    const char *detail = licd_error_detail((licd_ctx *)s->ptr);
    plhs[0] = mxCreateString(detail != NULL ? detail : "");
}

static const char *k_device_fields[] = {"serial", "path", "vendorId", "productId"};

static void cmd_enumerate(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs;
    slot_t *s = arg_ctx_slot(prhs[1]);
    licd_device_info *list = NULL;
    size_t count = 0;
    int rc = licd_enumerate((licd_ctx *)s->ptr, &list, &count);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_enumerate");
    }
    // 0x0 when empty, so isempty() is true but the fields still exist.
    mxArray *out = mxCreateStructMatrix(count == 0 ? 0 : 1, (mwSize)count, 4, k_device_fields);
    for (size_t i = 0; i < count; i++) {
        mxSetField(out, (mwIndex)i, "serial", mxCreateString(list[i].serial));
        mxSetField(out, (mwIndex)i, "path", mxCreateString(list[i].path));
        mxSetField(out, (mwIndex)i, "vendorId", mxCreateDoubleScalar((double)list[i].vendor_id));
        mxSetField(out, (mwIndex)i, "productId", mxCreateDoubleScalar((double)list[i].product_id));
    }
    licd_free_device_list(list, count);
    plhs[0] = out;
}

// Registers a freshly opened device against its context.
static void finish_open(slot_t *ctx_slot, licd_device *dev, mxArray *plhs[]) {
    uint64_t id = slot_add(SLOT_DEV, dev, ctx_slot->ctx, ctx_slot->id);
    if (id == 0) {
        licd_close(dev);
        mexErrMsgIdAndTxt("KeyNub:licdongle:tooManyHandles",
                          "more than %d open KeyNub handles; close some first",
                          LICD_MEX_MAX_HANDLES);
    }
    plhs[0] = out_id(id);
}

static void cmd_open(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs;
    slot_t *s = arg_ctx_slot(prhs[1]);
    const char *serial = NULL;
    if (nrhs > 2 && !mxIsEmpty(prhs[2])) {
        serial = arg_string(prhs[2], "the serial");
    }
    licd_device *dev = NULL;
    int rc = licd_open((licd_ctx *)s->ptr, serial, &dev);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_open");
    }
    finish_open(s, dev, plhs);
}

static void cmd_open_path(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs;
    slot_t *s = arg_ctx_slot(prhs[1]);
    const char *path = arg_string(prhs[2], "the device path");
    licd_device *dev = NULL;
    int rc = licd_open_path((licd_ctx *)s->ptr, path, &dev);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_open_path");
    }
    finish_open(s, dev, plhs);
}

static void cmd_close(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)plhs; (void)nrhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    licd_close((licd_device *)s->ptr);
    slot_release(s);
}

static const char *k_info_fields[] = {"protocolVersion", "firmwareVersion", "seReady",
                                      "provisioned",     "dataCapacity",    "dataFree",
                                      "watchdogReboot",  "isolated"};

static void cmd_get_info(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    licd_info info;
    memset(&info, 0, sizeof(info));
    int rc = licd_get_info((licd_device *)s->ptr, &info);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_get_info");
    }
    double proto[2] = {(double)info.proto_version_major, (double)info.proto_version_minor};
    double fw[3] = {(double)info.fw_version_major, (double)info.fw_version_minor,
                    (double)info.fw_version_patch};
    // Count derived from the array: a hardcoded 7 here is what broke when the
    // isolated field was added -- the name was present but unallocated.
    const int nfields = (int)(sizeof(k_info_fields) / sizeof(k_info_fields[0]));
    mxArray *out = mxCreateStructMatrix(1, 1, nfields, k_info_fields);
    mxSetField(out, 0, "protocolVersion", out_doubles(proto, 2));
    mxSetField(out, 0, "firmwareVersion", out_doubles(fw, 3));
    mxSetField(out, 0, "seReady", mxCreateLogicalScalar(info.se_ready != 0));
    mxSetField(out, 0, "provisioned", mxCreateLogicalScalar(info.provisioned != 0));
    mxSetField(out, 0, "dataCapacity", mxCreateDoubleScalar((double)info.data_capacity));
    mxSetField(out, 0, "dataFree", mxCreateDoubleScalar((double)info.data_free));
    mxSetField(out, 0, "watchdogReboot", mxCreateLogicalScalar(info.watchdog_reboot != 0));
    mxSetField(out, 0, "isolated", mxCreateLogicalScalar(info.isolated != 0));
    plhs[0] = out;
}

static void cmd_get_serial(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    char serial[LICD_SERIAL_HEX_LEN + 1];
    int rc = licd_get_serial((licd_device *)s->ptr, serial, sizeof(serial));
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_get_serial");
    }
    plhs[0] = mxCreateString(serial);
}

static const char *k_genuine_fields[] = {"genuine", "serial", "batch", "provisionedDate"};

static void cmd_verify_genuine(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    licd_genuine_result res;
    memset(&res, 0, sizeof(res));
    int rc = licd_verify_genuine((licd_device *)s->ptr, &res);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_verify_genuine");
    }
    mxArray *out = mxCreateStructMatrix(1, 1, 4, k_genuine_fields);
    mxSetField(out, 0, "genuine", mxCreateLogicalScalar(res.genuine != 0));
    mxSetField(out, 0, "serial", mxCreateString(res.serial));
    mxSetField(out, 0, "batch", mxCreateString(res.batch));
    mxSetField(out, 0, "provisionedDate", mxCreateString(res.provisioned_date));
    plhs[0] = out;
}

static void cmd_session_open(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)plhs; (void)nrhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    int rc = licd_session_open((licd_device *)s->ptr);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_session_open");
    }
}

static void cmd_session_close(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)plhs; (void)nrhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    // Teardown is local state; never raise, so cleanup paths stay simple.
    (void)licd_session_close((licd_device *)s->ptr);
}

static void cmd_write_auth(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)plhs; (void)nrhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    size_t len = 0;
    const uint8_t *der = arg_bytes(prhs[2], &len, "the master key");
    int rc = licd_write_auth((licd_device *)s->ptr, der, len);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_write_auth");
    }
}

static const char *k_record_fields[] = {"name", "size"};

static void cmd_record_list(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    char **names = NULL;
    uint32_t *sizes = NULL;
    size_t count = 0;
    int rc = licd_record_list((licd_device *)s->ptr, &names, &sizes, &count);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_record_list");
    }
    mxArray *out = mxCreateStructMatrix(count == 0 ? 0 : 1, (mwSize)count, 2, k_record_fields);
    for (size_t i = 0; i < count; i++) {
        mxSetField(out, (mwIndex)i, "name",
                   mxCreateString(names[i] != NULL ? names[i] : ""));
        mxSetField(out, (mwIndex)i, "size", mxCreateDoubleScalar((double)sizes[i]));
    }
    licd_free_record_list(names, sizes, count);
    plhs[0] = out;
}

static void cmd_record_read(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    const char *name = arg_record_name(prhs[2]);
    licd_device *dev = (licd_device *)s->ptr;

    // Probe for the size first (no progress on the probe), then read the whole
    // record, so reported progress runs monotonically from 0 to total.
    uint8_t probe_byte = 0;
    uint32_t got = 0, total = 0;
    int rc = licd_record_read(dev, name, 0, &probe_byte, 1, &got, &total, NULL, NULL);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_record_read");
    }

    progress_bridge pb;
    progress_init(&pb, nrhs > 3 ? prhs[3] : NULL);

    if (total == 0) {
        plhs[0] = out_bytes(NULL, 0);
        return;
    }

    // Allocated as the output array up front: no second copy, and MATLAB frees
    // it even if the read below throws.
    mxArray *out = mxCreateNumericMatrix((mwSize)total, 1, mxUINT8_CLASS, mxREAL);
    rc = licd_record_read(dev, name, 0, mxGetData(out), total, &got, &total,
                          progress_cb(&pb), &pb);
    if (rc != LICD_OK || pb.err != NULL) {
        mxDestroyArray(out);
        progress_finish(&pb, s->ctx, rc, "licd_record_read"); // does not return
    }
    if (got != total) {
        // Short read: hand back only what arrived rather than trailing zeros.
        mxArray *exact = out_bytes((const uint8_t *)mxGetData(out), got);
        mxDestroyArray(out);
        out = exact;
    }
    plhs[0] = out;
}

static void cmd_record_write(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)plhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    const char *name = arg_record_name(prhs[2]);
    size_t len = 0;
    const uint8_t *data = arg_bytes(prhs[3], &len, "the record data");
    if (len > 0xFFFFFFFFu) {
        mexErrMsgIdAndTxt(BAD_ARG, "the record data is too large");
    }
    progress_bridge pb;
    progress_init(&pb, nrhs > 4 ? prhs[4] : NULL);
    int rc = licd_record_write((licd_device *)s->ptr, name, data, (uint32_t)len,
                              progress_cb(&pb), &pb);
    progress_finish(&pb, s->ctx, rc, "licd_record_write");
}

static void cmd_record_erase(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)plhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    // No name (or []) erases every record — deliberately explicit at this layer;
    // +keynub exposes it as the separate eraseAllRecords method.
    const char *name = NULL;
    if (nrhs > 2 && !mxIsEmpty(prhs[2])) {
        name = arg_record_name(prhs[2]);
    }
    int rc = licd_record_erase((licd_device *)s->ptr, name);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_record_erase");
    }
}

static void cmd_counter_read(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    uint32_t value = 0;
    int rc = licd_counter_read((licd_device *)s->ptr, arg_counter_id(prhs[2]), &value);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_counter_read");
    }
    plhs[0] = mxCreateDoubleScalar((double)value);
}

static void cmd_counter_increment(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    uint32_t value = 0;
    int rc = licd_counter_increment((licd_device *)s->ptr, arg_counter_id(prhs[2]), &value);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_counter_increment");
    }
    plhs[0] = mxCreateDoubleScalar((double)value);
}

static void cmd_app_encrypt(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    double scope = arg_scalar(prhs[2], "the scope");
    if (scope != (double)LICD_SCOPE_DEVICE && scope != (double)LICD_SCOPE_DEVELOPER) {
        mexErrMsgIdAndTxt(BAD_ARG, "the scope must be 0 (device) or 1 (developer)");
    }
    size_t len = 0;
    const uint8_t *data = arg_bytes(prhs[3], &len, "the plaintext");
    if (len > 0xFFFFFFFFu) {
        mexErrMsgIdAndTxt(BAD_ARG, "the plaintext is too large");
    }
    uint8_t *out = NULL;
    uint32_t out_len = 0;
    int rc = licd_app_encrypt((licd_device *)s->ptr, (licd_scope)(int)scope, data,
                              (uint32_t)len, &out, &out_len);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_app_encrypt");
    }
    mxArray *result = out_bytes(out, out_len);
    licd_free_buffer(out);
    plhs[0] = result;
}

static void cmd_app_decrypt(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs;
    slot_t *s = arg_dev_slot(prhs[1]);
    size_t len = 0;
    const uint8_t *data = arg_bytes(prhs[2], &len, "the packed blob");
    if (len > 0xFFFFFFFFu) {
        mexErrMsgIdAndTxt(BAD_ARG, "the packed blob is too large");
    }
    uint8_t *out = NULL;
    uint32_t out_len = 0;
    int rc = licd_app_decrypt((licd_device *)s->ptr, data, (uint32_t)len, &out, &out_len);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_app_decrypt");
    }
    mxArray *result = out_bytes(out, out_len);
    licd_free_buffer(out);
    plhs[0] = result;
}

#ifdef LICD_MEX_ENABLE_SIM
static void cmd_open_simulated(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs;
    slot_t *s = arg_ctx_slot(prhs[1]);
    licd_device *dev = NULL;
    int rc = licd_open_simulated((licd_ctx *)s->ptr, &dev);
    if (rc != LICD_OK) {
        fail_status(s->ctx, rc, "licd_open_simulated");
    }
    finish_open(s, dev, plhs);
}

static void cmd_test_master_key(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    (void)nlhs; (void)nrhs; (void)prhs;
    const uint8_t *der = NULL;
    uint32_t len = 0;
    licd_test_get_master_key_der(&der, &len);
    plhs[0] = out_bytes(der, len);
}
#endif

// ============================================================================
// Dispatch
// ============================================================================

typedef void (*cmd_fn)(int, mxArray **, int, const mxArray **);

typedef struct {
    const char *name;
    cmd_fn fn;
    int min_rhs; // including the command word
    int max_rhs;
} command_t;

static const command_t k_commands[] = {
    {"version",           cmd_version,           1, 1},
    {"init",              cmd_init,              1, 1},
    {"free",              cmd_free,              2, 2},
    {"set_trust_root",    cmd_set_trust_root,    3, 3},
    {"error_detail",      cmd_error_detail,      2, 2},
    {"enumerate",         cmd_enumerate,         2, 2},
    {"open",              cmd_open,              2, 3},
    {"open_path",         cmd_open_path,         3, 3},
    {"close",             cmd_close,             2, 2},
    {"get_info",          cmd_get_info,          2, 2},
    {"get_serial",        cmd_get_serial,        2, 2},
    {"verify_genuine",    cmd_verify_genuine,    2, 2},
    {"session_open",      cmd_session_open,      2, 2},
    {"session_close",     cmd_session_close,     2, 2},
    {"write_auth",        cmd_write_auth,        3, 3},
    {"record_list",       cmd_record_list,       2, 2},
    {"record_read",       cmd_record_read,       3, 4},
    {"record_write",      cmd_record_write,      4, 5},
    {"record_erase",      cmd_record_erase,      2, 3},
    {"counter_read",      cmd_counter_read,      3, 3},
    {"counter_increment", cmd_counter_increment, 3, 3},
    {"app_encrypt",       cmd_app_encrypt,       4, 4},
    {"app_decrypt",       cmd_app_decrypt,       3, 3},
#ifdef LICD_MEX_ENABLE_SIM
    {"open_simulated",    cmd_open_simulated,    2, 2},
    {"test_master_key",   cmd_test_master_key,   1, 1},
#endif
};

#define LICD_MEX_COMMAND_COUNT ((int)(sizeof(k_commands) / sizeof(k_commands[0])))

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[]) {
    if (!g_atexit_set) {
        g_atexit_set = 1;
        mexAtExit(licd_mex_cleanup);
    }

    // A progress callback that calls back into licd_mex would re-enter the core
    // mid-transfer (and could close the very device being read).
    if (g_in_callback) {
        mexErrMsgIdAndTxt("KeyNub:licdongle:reentrantCall",
                          "licd_mex cannot be called from inside a progress callback");
    }

    if (nrhs < 1 || !mxIsChar(prhs[0])) {
        mexErrMsgIdAndTxt(BAD_ARG, "the first argument must be a command name");
    }
    char *cmd = arg_string(prhs[0], "the command name");

    for (int i = 0; i < LICD_MEX_COMMAND_COUNT; i++) {
        if (strcmp(cmd, k_commands[i].name) != 0) {
            continue;
        }
        if (nrhs < k_commands[i].min_rhs || nrhs > k_commands[i].max_rhs) {
            mexErrMsgIdAndTxt(BAD_ARG, "licd_mex('%s', ...) takes %d to %d arguments, got %d",
                              cmd, k_commands[i].min_rhs, k_commands[i].max_rhs, nrhs);
        }
        k_commands[i].fn(nlhs, plhs, nrhs, prhs);
        return;
    }
    mexErrMsgIdAndTxt("KeyNub:licdongle:unknownCommand", "unknown licd_mex command '%s'", cmd);
}
