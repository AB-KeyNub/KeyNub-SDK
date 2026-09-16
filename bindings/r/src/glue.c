// KeyNub License Dongle: the R package's C layer.
//
// A thin bridge between R and the SDK's C ABI (licdongle.h). The native library
// is loaded at run time from the path the R side resolves, so the package
// installs and checks on a machine that has no library, and the choice of
// library is made once per process. Every entry point hands the SDK's status
// code back to R as a classed integer, and R turns it into a condition; nothing
// here raises an R error for anything the SDK reports.
//
// Contexts and dongles are external pointers with finalizers. A dongle keeps its
// context reachable, and a context that goes away closes the dongles still open
// on it, so the order in which the collector finalizes the two does not matter.

#define R_NO_REMAP
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "licdongle.h"

#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  define NOGDI
#  include <windows.h>
typedef HMODULE lib_handle;
#else
#  include <dlfcn.h>
typedef void *lib_handle;
#endif

// --- the library ------------------------------------------------------------

typedef struct {
    void (*version)(int *, int *, int *);
    int (*init)(licd_ctx **);
    void (*free_ctx)(licd_ctx *);
    int (*set_trust_root)(licd_ctx *, const uint8_t *, size_t);
    int (*enumerate)(licd_ctx *, licd_device_info **, size_t *);
    void (*free_device_list)(licd_device_info *, size_t);
    int (*open)(licd_ctx *, const char *, licd_device **);
    int (*open_path)(licd_ctx *, const char *, licd_device **);
    void (*close)(licd_device *);
    int (*get_info)(licd_device *, licd_info *);
    int (*get_serial)(licd_device *, char *, size_t);
    int (*verify_genuine)(licd_device *, licd_genuine_result *);
    int (*session_open)(licd_device *);
    int (*session_close)(licd_device *);
    int (*write_auth)(licd_device *, const uint8_t *, size_t);
    int (*write_auth_rotate)(licd_device *, const uint8_t *, size_t);
    int (*record_list)(licd_device *, char ***, uint32_t **, size_t *);
    void (*free_record_list)(char **, uint32_t *, size_t);
    int (*record_read)(licd_device *, const char *, uint32_t, void *, uint32_t, uint32_t *,
                       uint32_t *, licd_progress_cb, void *);
    int (*record_write)(licd_device *, const char *, const void *, uint32_t, licd_progress_cb,
                        void *);
    int (*record_erase)(licd_device *, const char *);
    int (*counter_read)(licd_device *, uint8_t, uint32_t *);
    int (*counter_increment)(licd_device *, uint8_t, uint32_t *);
    int (*app_encrypt)(licd_device *, licd_scope, const void *, uint32_t, uint8_t **, uint32_t *);
    int (*app_decrypt)(licd_device *, const void *, uint32_t, uint8_t **, uint32_t *);
    void (*free_buffer)(uint8_t *);
    const char *(*status_text)(int);
    const char *(*error_detail)(licd_ctx *);
} api_t;

static api_t api;
static lib_handle lib = NULL;
static char lib_path[4096];

typedef void (*any_fn)(void);

static any_fn lookup(lib_handle h, const char *name) {
#ifdef _WIN32
    return (any_fn)GetProcAddress(h, name);
#else
    // dlsym hands back an object pointer; ISO C has no cast for it, so it is
    // copied, which every platform this runs on lays out identically.
    void *p = dlsym(h, name);
    any_fn f = NULL;
    if (p) memcpy(&f, &p, sizeof f);
    return f;
#endif
}

static void unload(lib_handle h) {
#ifdef _WIN32
    FreeLibrary(h);
#else
    dlclose(h);
#endif
}

// One function pointer copied into another of the exact type: no cast, so no
// dialect has anything to say about it.
#define BIND(field, name)                                   \
    do {                                                    \
        any_fn p = lookup(h, name);                         \
        if (!p) return name;                                \
        memcpy(&api.field, &p, sizeof p);                   \
    } while (0)

// Binds every function; returns the name of the first one missing, or NULL.
static const char *bind_all(lib_handle h) {
    BIND(version, "licd_version");
    BIND(init, "licd_init");
    BIND(free_ctx, "licd_free");
    BIND(set_trust_root, "licd_set_trust_root");
    BIND(enumerate, "licd_enumerate");
    BIND(free_device_list, "licd_free_device_list");
    BIND(open, "licd_open");
    BIND(open_path, "licd_open_path");
    BIND(close, "licd_close");
    BIND(get_info, "licd_get_info");
    BIND(get_serial, "licd_get_serial");
    BIND(verify_genuine, "licd_verify_genuine");
    BIND(session_open, "licd_session_open");
    BIND(session_close, "licd_session_close");
    BIND(write_auth, "licd_write_auth");
    BIND(write_auth_rotate, "licd_write_auth_rotate");
    BIND(record_list, "licd_record_list");
    BIND(free_record_list, "licd_free_record_list");
    BIND(record_read, "licd_record_read");
    BIND(record_write, "licd_record_write");
    BIND(record_erase, "licd_record_erase");
    BIND(counter_read, "licd_counter_read");
    BIND(counter_increment, "licd_counter_increment");
    BIND(app_encrypt, "licd_app_encrypt");
    BIND(app_decrypt, "licd_app_decrypt");
    BIND(free_buffer, "licd_free_buffer");
    BIND(status_text, "licd_strerror");
    BIND(error_detail, "licd_error_detail");
    return NULL;
}

static void need_lib(void) {
    if (!lib) Rf_error("the KeyNub library is not loaded");
}

static const char *utf8(SEXP s, const char *what) {
    if (TYPEOF(s) != STRSXP || Rf_length(s) != 1 || STRING_ELT(s, 0) == NA_STRING)
        Rf_error("%s must be a single string", what);
    return Rf_translateCharUTF8(STRING_ELT(s, 0));
}

static SEXP utf8_string(const char *s) {
    SEXP out = PROTECT(Rf_allocVector(STRSXP, 1));
    SET_STRING_ELT(out, 0, Rf_mkCharCE(s ? s : "", CE_UTF8));
    UNPROTECT(1);
    return out;
}

SEXP C_load(SEXP path) {
    const char *p = utf8(path, "the library path");
    if (lib) {
        if (strcmp(p, lib_path) != 0)
            Rf_error("the KeyNub library is already loaded from '%s'; a process loads it once",
                     lib_path);
        return utf8_string(lib_path);
    }
    if (strlen(p) >= sizeof lib_path) Rf_error("the library path is too long");
#ifdef _WIN32
    lib_handle h = LoadLibraryA(p);
    if (!h)
        Rf_error("could not load the KeyNub library '%s' (Windows error %lu)", p,
                 (unsigned long)GetLastError());
#else
    lib_handle h = dlopen(p, RTLD_NOW | RTLD_LOCAL);
    if (!h) Rf_error("could not load the KeyNub library '%s': %s", p, dlerror());
#endif
    const char *missing = bind_all(h);
    if (missing) {
        unload(h);
        Rf_error("'%s' is not the KeyNub core library: %s is missing", p, missing);
    }
    strcpy(lib_path, p);
    lib = h;
    return utf8_string(lib_path);
}

// --- status values ----------------------------------------------------------

// A failed call returns its status as an integer of class "licd_status" carrying
// the SDK's detail text, which is thread-local in the library and so is read at
// once, before any other call overwrites it.
static SEXP fail_text(int rc, const char *detail) {
    SEXP out = PROTECT(Rf_ScalarInteger(rc));
    SEXP text = PROTECT(utf8_string(detail));
    Rf_setAttrib(out, Rf_install("detail"), text);
    SEXP cls = PROTECT(utf8_string("licd_status"));
    Rf_setAttrib(out, R_ClassSymbol, cls);
    UNPROTECT(3);
    return out;
}

static SEXP fail(int rc, licd_ctx *ctx) {
    return fail_text(rc, ctx ? api.error_detail(ctx) : "");
}

SEXP C_version(void) {
    need_lib();
    int major = 0, minor = 0, patch = 0;
    api.version(&major, &minor, &patch);
    SEXP out = PROTECT(Rf_allocVector(INTSXP, 3));
    INTEGER(out)[0] = major;
    INTEGER(out)[1] = minor;
    INTEGER(out)[2] = patch;
    UNPROTECT(1);
    return out;
}

SEXP C_strerror(SEXP status) {
    need_lib();
    if (TYPEOF(status) != INTSXP || Rf_length(status) != 1) Rf_error("status must be one integer");
    return utf8_string(api.status_text(INTEGER(status)[0]));
}

// --- handles ------------------------------------------------------------------

typedef struct glue_dev glue_dev;

typedef struct {
    licd_ctx *ctx;
    glue_dev *devs; // the dongles open on this context
} glue_ctx;

struct glue_dev {
    licd_device *dev; // NULL once closed
    glue_ctx *owner;  // NULL once detached from its context
    glue_dev *next;
};

// Closes the device and takes it off its context's list. Idempotent.
static void detach_dev(glue_dev *d) {
    if (d->owner) {
        glue_dev **pp = &d->owner->devs;
        while (*pp && *pp != d) pp = &(*pp)->next;
        if (*pp) *pp = d->next;
        d->owner = NULL;
    }
    if (d->dev) {
        api.close(d->dev);
        d->dev = NULL;
    }
}

static void release_ctx(glue_ctx *c) {
    while (c->devs) detach_dev(c->devs);
    if (c->ctx) api.free_ctx(c->ctx);
    free(c);
}

static void ctx_finalizer(SEXP xp) {
    glue_ctx *c = (glue_ctx *)R_ExternalPtrAddr(xp);
    if (!c) return;
    R_ClearExternalPtr(xp);
    release_ctx(c);
}

static void dev_finalizer(SEXP xp) {
    glue_dev *d = (glue_dev *)R_ExternalPtrAddr(xp);
    if (!d) return;
    R_ClearExternalPtr(xp);
    detach_dev(d);
    free(d);
}

static glue_ctx *get_ctx(SEXP xp) {
    if (TYPEOF(xp) != EXTPTRSXP) Rf_error("not a KeyNub context handle");
    glue_ctx *c = (glue_ctx *)R_ExternalPtrAddr(xp);
    if (!c) Rf_error("the KeyNub context has been closed");
    need_lib();
    return c;
}

static glue_dev *get_dev(SEXP xp) {
    if (TYPEOF(xp) != EXTPTRSXP) Rf_error("not a KeyNub dongle handle");
    glue_dev *d = (glue_dev *)R_ExternalPtrAddr(xp);
    if (!d || !d->dev || !d->owner) Rf_error("the dongle has been closed");
    need_lib();
    return d;
}

SEXP C_ctx_new(void) {
    need_lib();
    glue_ctx *c = (glue_ctx *)calloc(1, sizeof *c);
    if (!c) Rf_error("out of memory");
    int rc = api.init(&c->ctx);
    if (rc != LICD_OK) {
        free(c);
        return fail_text(rc, "");
    }
    SEXP xp = PROTECT(R_MakeExternalPtr(c, R_NilValue, R_NilValue));
    R_RegisterCFinalizerEx(xp, ctx_finalizer, TRUE);
    UNPROTECT(1);
    return xp;
}

SEXP C_ctx_close(SEXP xp) {
    if (TYPEOF(xp) != EXTPTRSXP) Rf_error("not a KeyNub context handle");
    ctx_finalizer(xp);
    return R_NilValue;
}

SEXP C_ctx_is_open(SEXP xp) {
    return Rf_ScalarLogical(TYPEOF(xp) == EXTPTRSXP && R_ExternalPtrAddr(xp) != NULL);
}

SEXP C_error_detail(SEXP xp) {
    glue_ctx *c = get_ctx(xp);
    return utf8_string(api.error_detail(c->ctx));
}

static const uint8_t *raw_arg(SEXP x, const char *what, size_t *len) {
    if (TYPEOF(x) != RAWSXP) Rf_error("%s must be a raw vector", what);
    *len = (size_t)Rf_xlength(x);
    return RAW(x);
}

SEXP C_set_trust_root(SEXP xp, SEXP der) {
    glue_ctx *c = get_ctx(xp);
    size_t len;
    const uint8_t *p = raw_arg(der, "the trust root", &len);
    int rc = api.set_trust_root(c->ctx, len ? p : NULL, len);
    return rc == LICD_OK ? R_NilValue : fail(rc, c->ctx);
}

SEXP C_enumerate(SEXP xp) {
    glue_ctx *c = get_ctx(xp);
    licd_device_info *list = NULL;
    size_t count = 0;
    int rc = api.enumerate(c->ctx, &list, &count);
    if (rc != LICD_OK) return fail(rc, c->ctx);
    const char *names[] = {"serial", "path", "vendor_id", "product_id", ""};
    SEXP out = PROTECT(Rf_mkNamed(VECSXP, names));
    SEXP serial = SET_VECTOR_ELT(out, 0, Rf_allocVector(STRSXP, (R_xlen_t)count));
    SEXP path = SET_VECTOR_ELT(out, 1, Rf_allocVector(STRSXP, (R_xlen_t)count));
    SEXP vid = SET_VECTOR_ELT(out, 2, Rf_allocVector(INTSXP, (R_xlen_t)count));
    SEXP pid = SET_VECTOR_ELT(out, 3, Rf_allocVector(INTSXP, (R_xlen_t)count));
    for (size_t i = 0; i < count; i++) {
        SET_STRING_ELT(serial, (R_xlen_t)i, Rf_mkCharCE(list[i].serial, CE_UTF8));
        SET_STRING_ELT(path, (R_xlen_t)i, Rf_mkCharCE(list[i].path, CE_UTF8));
        INTEGER(vid)[i] = list[i].vendor_id;
        INTEGER(pid)[i] = list[i].product_id;
    }
    api.free_device_list(list, count);
    UNPROTECT(1);
    return out;
}

static SEXP wrap_dev(SEXP ctx_xp, glue_ctx *c, licd_device *dev) {
    glue_dev *d = (glue_dev *)calloc(1, sizeof *d);
    if (!d) {
        api.close(dev);
        Rf_error("out of memory");
    }
    d->dev = dev;
    d->owner = c;
    d->next = c->devs;
    c->devs = d;
    // The context handle sits in the protected slot: a reachable dongle keeps
    // its context alive.
    SEXP xp = PROTECT(R_MakeExternalPtr(d, R_NilValue, ctx_xp));
    R_RegisterCFinalizerEx(xp, dev_finalizer, TRUE);
    UNPROTECT(1);
    return xp;
}

SEXP C_open(SEXP xp, SEXP serial) {
    glue_ctx *c = get_ctx(xp);
    const char *s = Rf_isNull(serial) ? NULL : utf8(serial, "the serial");
    licd_device *dev = NULL;
    int rc = api.open(c->ctx, s, &dev);
    if (rc != LICD_OK) return fail(rc, c->ctx);
    return wrap_dev(xp, c, dev);
}

SEXP C_open_path(SEXP xp, SEXP path) {
    glue_ctx *c = get_ctx(xp);
    const char *p = utf8(path, "the path");
    licd_device *dev = NULL;
    int rc = api.open_path(c->ctx, p, &dev);
    if (rc != LICD_OK) return fail(rc, c->ctx);
    return wrap_dev(xp, c, dev);
}

SEXP C_dev_close(SEXP xp) {
    if (TYPEOF(xp) != EXTPTRSXP) Rf_error("not a KeyNub dongle handle");
    glue_dev *d = (glue_dev *)R_ExternalPtrAddr(xp);
    if (d) detach_dev(d);
    return R_NilValue;
}

SEXP C_dev_is_open(SEXP xp) {
    if (TYPEOF(xp) != EXTPTRSXP) return Rf_ScalarLogical(FALSE);
    glue_dev *d = (glue_dev *)R_ExternalPtrAddr(xp);
    return Rf_ScalarLogical(d != NULL && d->dev != NULL);
}

// --- plaintext info -------------------------------------------------------------

SEXP C_get_info(SEXP xp) {
    glue_dev *d = get_dev(xp);
    licd_info info;
    memset(&info, 0, sizeof info);
    int rc = api.get_info(d->dev, &info);
    if (rc != LICD_OK) return fail(rc, d->owner->ctx);
    const char *names[] = {"protocol_version", "firmware_version", "se_ready", "provisioned",
                           "data_capacity", "data_free", "watchdog_reboot", "isolated",
                           "writeauth_rotated", ""};
    SEXP out = PROTECT(Rf_mkNamed(VECSXP, names));
    SEXP proto = SET_VECTOR_ELT(out, 0, Rf_allocVector(INTSXP, 2));
    INTEGER(proto)[0] = info.proto_version_major;
    INTEGER(proto)[1] = info.proto_version_minor;
    SEXP fw = SET_VECTOR_ELT(out, 1, Rf_allocVector(INTSXP, 3));
    INTEGER(fw)[0] = info.fw_version_major;
    INTEGER(fw)[1] = info.fw_version_minor;
    INTEGER(fw)[2] = info.fw_version_patch;
    SET_VECTOR_ELT(out, 2, Rf_ScalarLogical(info.se_ready != 0));
    SET_VECTOR_ELT(out, 3, Rf_ScalarLogical(info.provisioned != 0));
    SET_VECTOR_ELT(out, 4, Rf_ScalarReal((double)info.data_capacity));
    SET_VECTOR_ELT(out, 5, Rf_ScalarReal((double)info.data_free));
    SET_VECTOR_ELT(out, 6, Rf_ScalarLogical(info.watchdog_reboot != 0));
    SET_VECTOR_ELT(out, 7, Rf_ScalarLogical(info.isolated != 0));
    SET_VECTOR_ELT(out, 8, Rf_ScalarLogical(info.writeauth_rotated != 0));
    UNPROTECT(1);
    return out;
}

SEXP C_get_serial(SEXP xp) {
    glue_dev *d = get_dev(xp);
    char serial[LICD_SERIAL_HEX_LEN + 1];
    memset(serial, 0, sizeof serial);
    int rc = api.get_serial(d->dev, serial, sizeof serial);
    if (rc != LICD_OK) return fail(rc, d->owner->ctx);
    return utf8_string(serial);
}

SEXP C_verify_genuine(SEXP xp) {
    glue_dev *d = get_dev(xp);
    licd_genuine_result result;
    memset(&result, 0, sizeof result);
    int rc = api.verify_genuine(d->dev, &result);
    if (rc != LICD_OK) return fail(rc, d->owner->ctx);
    const char *names[] = {"genuine", "serial", "provisioned_date", ""};
    SEXP out = PROTECT(Rf_mkNamed(VECSXP, names));
    SET_VECTOR_ELT(out, 0, Rf_ScalarLogical(result.genuine != 0));
    SET_VECTOR_ELT(out, 1, utf8_string(result.serial));
    SET_VECTOR_ELT(out, 2, utf8_string(result.provisioned_date));
    UNPROTECT(1);
    return out;
}

// --- session ----------------------------------------------------------------------

SEXP C_session_open(SEXP xp) {
    glue_dev *d = get_dev(xp);
    int rc = api.session_open(d->dev);
    return rc == LICD_OK ? R_NilValue : fail(rc, d->owner->ctx);
}

SEXP C_session_close(SEXP xp) {
    glue_dev *d = get_dev(xp);
    int rc = api.session_close(d->dev);
    return rc == LICD_OK ? R_NilValue : fail(rc, d->owner->ctx);
}

SEXP C_write_auth(SEXP xp, SEXP key) {
    glue_dev *d = get_dev(xp);
    size_t len;
    const uint8_t *p = raw_arg(key, "the key", &len);
    int rc = api.write_auth(d->dev, len ? p : NULL, len);
    return rc == LICD_OK ? R_NilValue : fail(rc, d->owner->ctx);
}

SEXP C_write_auth_rotate(SEXP xp, SEXP key) {
    glue_dev *d = get_dev(xp);
    size_t len;
    const uint8_t *p = raw_arg(key, "the key", &len);
    int rc = api.write_auth_rotate(d->dev, len ? p : NULL, len);
    return rc == LICD_OK ? R_NilValue : fail(rc, d->owner->ctx);
}

// --- progress callbacks --------------------------------------------------------

// The R function is called as progress(done, total). Returning FALSE cancels. An
// error inside it also cancels: the transfer stops and the error is reported
// after the C frames have unwound, never through them.
typedef struct {
    SEXP fn;
    int failed;
} progress_state;

static int progress_shim(uint32_t done, uint32_t total, void *user) {
    progress_state *st = (progress_state *)user;
    SEXP a = PROTECT(Rf_ScalarReal((double)done));
    SEXP b = PROTECT(Rf_ScalarReal((double)total));
    SEXP call = PROTECT(Rf_lang3(st->fn, a, b));
    int err = 0;
    SEXP res = R_tryEvalSilent(call, R_GlobalEnv, &err);
    int go = 1;
    if (err) {
        st->failed = 1;
        go = 0;
    } else if (TYPEOF(res) == LGLSXP && Rf_length(res) >= 1 && LOGICAL(res)[0] == 0) {
        go = 0;
    }
    UNPROTECT(3);
    return go;
}

static SEXP transfer_failed(int rc, const progress_state *st, licd_ctx *ctx) {
    if (rc == LICD_E_CANCELLED && st->failed)
        return fail_text(rc, "the progress function signalled an error");
    return fail(rc, ctx);
}

// --- records --------------------------------------------------------------------

SEXP C_record_list(SEXP xp) {
    glue_dev *d = get_dev(xp);
    char **names = NULL;
    uint32_t *sizes = NULL;
    size_t count = 0;
    int rc = api.record_list(d->dev, &names, &sizes, &count);
    if (rc != LICD_OK) return fail(rc, d->owner->ctx);
    const char *cols[] = {"name", "size", ""};
    SEXP out = PROTECT(Rf_mkNamed(VECSXP, cols));
    SEXP name = SET_VECTOR_ELT(out, 0, Rf_allocVector(STRSXP, (R_xlen_t)count));
    SEXP size = SET_VECTOR_ELT(out, 1, Rf_allocVector(REALSXP, (R_xlen_t)count));
    for (size_t i = 0; i < count; i++) {
        SET_STRING_ELT(name, (R_xlen_t)i, Rf_mkCharCE(names[i] ? names[i] : "", CE_UTF8));
        REAL(size)[i] = (double)sizes[i];
    }
    api.free_record_list(names, sizes, count);
    UNPROTECT(1);
    return out;
}

SEXP C_record_read(SEXP xp, SEXP name, SEXP progress) {
    glue_dev *d = get_dev(xp);
    const char *n = utf8(name, "the record name");
    licd_ctx *ctx = d->owner->ctx;
    // Probe for the size first, so that progress runs from 0 to the total once.
    uint8_t probe[1];
    uint32_t got = 0, total = 0;
    int rc = api.record_read(d->dev, n, 0, probe, 1, &got, &total, NULL, NULL);
    if (rc != LICD_OK) return fail(rc, ctx);
    SEXP out = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)total));
    if (total > 0) {
        progress_state st = {progress, 0};
        int use_cb = !Rf_isNull(progress);
        rc = api.record_read(d->dev, n, 0, RAW(out), total, &got, &total,
                             use_cb ? progress_shim : NULL, use_cb ? &st : NULL);
        if (rc != LICD_OK) {
            UNPROTECT(1);
            return transfer_failed(rc, &st, ctx);
        }
        if (got < (uint32_t)Rf_xlength(out)) out = Rf_xlengthgets(out, (R_xlen_t)got);
    }
    UNPROTECT(1);
    return out;
}

SEXP C_record_write(SEXP xp, SEXP name, SEXP data, SEXP progress) {
    glue_dev *d = get_dev(xp);
    const char *n = utf8(name, "the record name");
    size_t len;
    const uint8_t *p = raw_arg(data, "the data", &len);
    if (len > UINT32_MAX) Rf_error("the data is too large for a record");
    progress_state st = {progress, 0};
    int use_cb = !Rf_isNull(progress);
    int rc = api.record_write(d->dev, n, len ? p : NULL, (uint32_t)len,
                              use_cb ? progress_shim : NULL, use_cb ? &st : NULL);
    return rc == LICD_OK ? R_NilValue : transfer_failed(rc, &st, d->owner->ctx);
}

// A NULL name erases every record; the R side only passes NULL from the function
// whose name says so.
SEXP C_record_erase(SEXP xp, SEXP name) {
    glue_dev *d = get_dev(xp);
    const char *n = Rf_isNull(name) ? NULL : utf8(name, "the record name");
    int rc = api.record_erase(d->dev, n);
    return rc == LICD_OK ? R_NilValue : fail(rc, d->owner->ctx);
}

// --- counters ---------------------------------------------------------------------

static uint8_t counter_arg(SEXP id) {
    if (TYPEOF(id) != INTSXP || Rf_length(id) != 1 || INTEGER(id)[0] < 0 || INTEGER(id)[0] > 255)
        Rf_error("the counter id must be an integer from 0 to 255");
    return (uint8_t)INTEGER(id)[0];
}

SEXP C_counter_read(SEXP xp, SEXP id) {
    glue_dev *d = get_dev(xp);
    uint32_t value = 0;
    int rc = api.counter_read(d->dev, counter_arg(id), &value);
    return rc == LICD_OK ? Rf_ScalarReal((double)value) : fail(rc, d->owner->ctx);
}

SEXP C_counter_increment(SEXP xp, SEXP id) {
    glue_dev *d = get_dev(xp);
    uint32_t value = 0;
    int rc = api.counter_increment(d->dev, counter_arg(id), &value);
    return rc == LICD_OK ? Rf_ScalarReal((double)value) : fail(rc, d->owner->ctx);
}

// --- app-data envelope encryption ------------------------------------------------

static SEXP take_buffer(uint8_t *buf, uint32_t len) {
    SEXP out = PROTECT(Rf_allocVector(RAWSXP, (R_xlen_t)len));
    if (len) memcpy(RAW(out), buf, len);
    api.free_buffer(buf);
    UNPROTECT(1);
    return out;
}

SEXP C_app_encrypt(SEXP xp, SEXP scope, SEXP data) {
    glue_dev *d = get_dev(xp);
    if (TYPEOF(scope) != INTSXP || Rf_length(scope) != 1) Rf_error("the scope must be one integer");
    size_t len;
    const uint8_t *p = raw_arg(data, "the data", &len);
    if (len > UINT32_MAX) Rf_error("the data is too large");
    uint8_t *out = NULL;
    uint32_t out_len = 0;
    int rc = api.app_encrypt(d->dev, (licd_scope)INTEGER(scope)[0], len ? p : NULL,
                             (uint32_t)len, &out, &out_len);
    if (rc != LICD_OK) return fail(rc, d->owner->ctx);
    return take_buffer(out, out_len);
}

SEXP C_app_decrypt(SEXP xp, SEXP packed) {
    glue_dev *d = get_dev(xp);
    size_t len;
    const uint8_t *p = raw_arg(packed, "the packed data", &len);
    if (len > UINT32_MAX) Rf_error("the packed data is too large");
    uint8_t *out = NULL;
    uint32_t out_len = 0;
    int rc = api.app_decrypt(d->dev, len ? p : NULL, (uint32_t)len, &out, &out_len);
    if (rc != LICD_OK) return fail(rc, d->owner->ctx);
    return take_buffer(out, out_len);
}

// --- registration -----------------------------------------------------------------

static const R_CallMethodDef calls[] = {
    {"C_load", (DL_FUNC)&C_load, 1},
    {"C_version", (DL_FUNC)&C_version, 0},
    {"C_strerror", (DL_FUNC)&C_strerror, 1},
    {"C_ctx_new", (DL_FUNC)&C_ctx_new, 0},
    {"C_ctx_close", (DL_FUNC)&C_ctx_close, 1},
    {"C_ctx_is_open", (DL_FUNC)&C_ctx_is_open, 1},
    {"C_error_detail", (DL_FUNC)&C_error_detail, 1},
    {"C_set_trust_root", (DL_FUNC)&C_set_trust_root, 2},
    {"C_enumerate", (DL_FUNC)&C_enumerate, 1},
    {"C_open", (DL_FUNC)&C_open, 2},
    {"C_open_path", (DL_FUNC)&C_open_path, 2},
    {"C_dev_close", (DL_FUNC)&C_dev_close, 1},
    {"C_dev_is_open", (DL_FUNC)&C_dev_is_open, 1},
    {"C_get_info", (DL_FUNC)&C_get_info, 1},
    {"C_get_serial", (DL_FUNC)&C_get_serial, 1},
    {"C_verify_genuine", (DL_FUNC)&C_verify_genuine, 1},
    {"C_session_open", (DL_FUNC)&C_session_open, 1},
    {"C_session_close", (DL_FUNC)&C_session_close, 1},
    {"C_write_auth", (DL_FUNC)&C_write_auth, 2},
    {"C_write_auth_rotate", (DL_FUNC)&C_write_auth_rotate, 2},
    {"C_record_list", (DL_FUNC)&C_record_list, 1},
    {"C_record_read", (DL_FUNC)&C_record_read, 3},
    {"C_record_write", (DL_FUNC)&C_record_write, 4},
    {"C_record_erase", (DL_FUNC)&C_record_erase, 2},
    {"C_counter_read", (DL_FUNC)&C_counter_read, 2},
    {"C_counter_increment", (DL_FUNC)&C_counter_increment, 2},
    {"C_app_encrypt", (DL_FUNC)&C_app_encrypt, 3},
    {"C_app_decrypt", (DL_FUNC)&C_app_decrypt, 2},
    {NULL, NULL, 0}};

void R_init_KeyNubLicDongle(DllInfo *dll) {
    R_registerRoutines(dll, NULL, calls, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
