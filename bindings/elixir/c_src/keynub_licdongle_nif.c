// KeyNub License Dongle SDK - Elixir NIF over the flat companion API.
//
// Loads keynub_licdongle_flat at run time (dlopen / LoadLibrary), resolves
// every function by name and exposes each one to KeyNub.LicDongle.Nif with
// the flat API's own shape: an int32 status, caller-sized buffers, integer
// handles. Every call that reaches the dongle runs on a dirty I/O scheduler.

#include <erl_nif.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
typedef HMODULE lib_t;
#define lib_open(p) LoadLibraryA(p)
#define lib_sym(l, n) ((void *)GetProcAddress((l), (n)))
#define lib_close(l) FreeLibrary(l)
#else
#include <dlfcn.h>
typedef void *lib_t;
#define lib_open(p) dlopen((p), RTLD_NOW)
#define lib_sym(l, n) dlsym((l), (n))
#define lib_close(l) dlclose(l)
#endif

#define SERIAL_SIZE 15
#define DATE_SIZE 11
#define PATH_SIZE 512
#define ERROR_SIZE 256

typedef int32_t (*f_version)(int32_t *, int32_t *, int32_t *);
typedef int32_t (*f_count)(int32_t *);
typedef int32_t (*f_index_str)(int32_t, char *, int32_t);
typedef int32_t (*f_open)(const char *);
typedef int32_t (*f_handle)(int32_t);
typedef int32_t (*f_handle_bytes)(int32_t, const uint8_t *, int32_t);
typedef int32_t (*f_info)(int32_t, int32_t *, int32_t *, int32_t *, int32_t *, int32_t *, int32_t *,
                          int32_t *, int32_t *);
typedef int32_t (*f_genuine)(int32_t, int32_t *, char *, int32_t, char *, int32_t);
typedef int32_t (*f_handle_count)(int32_t, int32_t *);
typedef int32_t (*f_record_name)(int32_t, int32_t, char *, int32_t, int32_t *);
typedef int32_t (*f_record_size)(int32_t, const char *, int32_t *);
typedef int32_t (*f_record_read)(int32_t, const char *, uint8_t *, int32_t, int32_t *);
typedef int32_t (*f_record_write)(int32_t, const char *, const uint8_t *, int32_t);
typedef int32_t (*f_handle_name)(int32_t, const char *);
typedef int32_t (*f_counter)(int32_t, int32_t, int32_t *);
typedef int32_t (*f_encrypt)(int32_t, int32_t, const uint8_t *, int32_t, uint8_t *, int32_t,
                             int32_t *);
typedef int32_t (*f_decrypt)(int32_t, const uint8_t *, int32_t, uint8_t *, int32_t, int32_t *);

static struct {
    lib_t lib;
    char path[PATH_SIZE * 2];
    f_version version;
    f_count device_count;
    f_index_str device_serial;
    f_index_str device_path;
    f_open open_;
    f_open open_path;
    f_handle close;
    f_handle_bytes set_trust_root;
    f_index_str get_serial;
    f_info get_info;
    f_genuine verify_genuine;
    f_handle session_open;
    f_handle session_close;
    f_handle_bytes write_auth;
    f_handle_bytes write_auth_rotate;
    f_handle_count record_count;
    f_record_name record_name;
    f_record_size record_size;
    f_record_read record_read;
    f_record_write record_write;
    f_handle_name record_erase;
    f_handle record_erase_all;
    f_counter counter_read;
    f_counter counter_increment;
    f_encrypt app_encrypt;
    f_decrypt app_decrypt;
    f_index_str strerror;
    f_index_str last_error;
} api;

static ErlNifMutex *api_lock;

// ---- terms -------------------------------------------------------------------

static ERL_NIF_TERM atom(ErlNifEnv *env, const char *name) { return enif_make_atom(env, name); }

static ERL_NIF_TERM bin_from_cstr(ErlNifEnv *env, const char *s) {
    size_t n = strlen(s);
    ERL_NIF_TERM t;
    unsigned char *p = enif_make_new_binary(env, n, &t);
    if (n) memcpy(p, s, n);
    return t;
}

static ERL_NIF_TERM error_str(ErlNifEnv *env, const char *msg) {
    return enif_make_tuple2(env, atom(env, "error"), bin_from_cstr(env, msg));
}

static ERL_NIF_TERM int_pair(ErlNifEnv *env, int32_t rc, int32_t v) {
    return enif_make_tuple2(env, enif_make_int(env, rc), enif_make_int(env, v));
}

static ERL_NIF_TERM rc_str(ErlNifEnv *env, int32_t rc, const char *s) {
    return enif_make_tuple2(env, enif_make_int(env, rc), bin_from_cstr(env, rc == 0 ? s : ""));
}

// A binary as a NUL-terminated C string (malloc'd; the caller frees).
static char *cstr_of(ErlNifEnv *env, ERL_NIF_TERM t) {
    ErlNifBinary b;
    if (!enif_inspect_binary(env, t, &b)) return NULL;
    char *s = (char *)malloc(b.size + 1);
    if (!s) return NULL;
    if (b.size) memcpy(s, b.data, b.size);
    s[b.size] = 0;
    return s;
}

static int get_i32(ErlNifEnv *env, ERL_NIF_TERM t, int32_t *out) {
    int v;
    if (!enif_get_int(env, t, &v)) return 0;
    *out = (int32_t)v;
    return 1;
}

// Byte input: an empty binary may carry a null data pointer; the flat API
// gets a valid pointer with length 0 instead.
static const uint8_t *bytes_of(ErlNifBinary *b) {
    static const uint8_t none = 0;
    return b->size ? (const uint8_t *)b->data : &none;
}

static int loaded(void) { return api.lib != NULL; }

static ERL_NIF_TERM not_loaded(ErlNifEnv *env) {
    return enif_raise_exception(env, atom(env, "keynub_library_not_loaded"));
}

#define NEED_API()                                                                                  \
    do {                                                                                            \
        if (!loaded()) return not_loaded(env);                                                     \
    } while (0)

#define ARG_I32(idx, var)                                                                           \
    int32_t var;                                                                                    \
    if (!get_i32(env, argv[idx], &var)) return enif_make_badarg(env)

#define ARG_BIN(idx, var)                                                                           \
    ErlNifBinary var;                                                                               \
    if (!enif_inspect_binary(env, argv[idx], &var)) return enif_make_badarg(env)

#define ARG_CSTR(idx, var)                                                                          \
    char *var = cstr_of(env, argv[idx]);                                                            \
    if (!var) return enif_make_badarg(env)

// ---- bytes of unknown length ----------------------------------------------------
//
// The caller passes the capacity it wants to try (0 to ask for the size). On
// success: {0, binary}. Otherwise: {status, length_needed_or_0}.

typedef int32_t (*byte_call)(void *ctx, uint8_t *out, int32_t cap, int32_t *len);

static ERL_NIF_TERM read_bytes(ErlNifEnv *env, int32_t cap, byte_call call, void *ctx) {
    ErlNifBinary out;
    int32_t len = 0;
    uint8_t none = 0;
    if (cap < 0) cap = 0;
    if (!enif_alloc_binary((size_t)cap, &out)) return enif_raise_exception(env, atom(env, "enomem"));
    int32_t rc = call(ctx, cap ? (uint8_t *)out.data : &none, cap, &len);
    if (rc == 0) {
        if (len < 0) len = 0;
        if ((size_t)len != out.size && !enif_realloc_binary(&out, (size_t)len)) {
            enif_release_binary(&out);
            return enif_raise_exception(env, atom(env, "enomem"));
        }
        return enif_make_tuple2(env, enif_make_int(env, 0), enif_make_binary(env, &out));
    }
    enif_release_binary(&out);
    return int_pair(env, rc, len);
}

// ---- loading -------------------------------------------------------------------

#define RESOLVE(field, name)                                                                        \
    do {                                                                                            \
        api.field = (void *)lib_sym(lib, name);                                                     \
        if (!api.field) {                                                                           \
            lib_close(lib);                                                                         \
            enif_mutex_unlock(api_lock);                                                            \
            snprintf(msg, sizeof msg, "%s does not export %s", path, name);                        \
            free(path);                                                                             \
            return error_str(env, msg);                                                             \
        }                                                                                           \
    } while (0)

static ERL_NIF_TERM nif_load(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    char msg[PATH_SIZE * 2 + 160];
    ARG_CSTR(0, path);
    enif_mutex_lock(api_lock);
    if (loaded()) {
        int same = strcmp(api.path, path) == 0;
        enif_mutex_unlock(api_lock);
        if (same) {
            free(path);
            return atom(env, "ok");
        }
        snprintf(msg, sizeof msg, "the KeyNub library is already loaded from %s; a process loads it once",
                 api.path);
        free(path);
        return error_str(env, msg);
    }
    lib_t lib = lib_open(path);
    if (!lib) {
        enif_mutex_unlock(api_lock);
        snprintf(msg, sizeof msg, "cannot load %s", path);
        free(path);
        return error_str(env, msg);
    }
    RESOLVE(version, "licdf_version");
    RESOLVE(device_count, "licdf_device_count");
    RESOLVE(device_serial, "licdf_device_serial");
    RESOLVE(device_path, "licdf_device_path");
    RESOLVE(open_, "licdf_open");
    RESOLVE(open_path, "licdf_open_path");
    RESOLVE(close, "licdf_close");
    RESOLVE(set_trust_root, "licdf_set_trust_root");
    RESOLVE(get_serial, "licdf_get_serial");
    RESOLVE(get_info, "licdf_get_info");
    RESOLVE(verify_genuine, "licdf_verify_genuine");
    RESOLVE(session_open, "licdf_session_open");
    RESOLVE(session_close, "licdf_session_close");
    RESOLVE(write_auth, "licdf_write_auth");
    RESOLVE(write_auth_rotate, "licdf_write_auth_rotate");
    RESOLVE(record_count, "licdf_record_count");
    RESOLVE(record_name, "licdf_record_name");
    RESOLVE(record_size, "licdf_record_size");
    RESOLVE(record_read, "licdf_record_read");
    RESOLVE(record_write, "licdf_record_write");
    RESOLVE(record_erase, "licdf_record_erase");
    RESOLVE(record_erase_all, "licdf_record_erase_all");
    RESOLVE(counter_read, "licdf_counter_read");
    RESOLVE(counter_increment, "licdf_counter_increment");
    RESOLVE(app_encrypt, "licdf_app_encrypt");
    RESOLVE(app_decrypt, "licdf_app_decrypt");
    RESOLVE(strerror, "licdf_strerror");
    RESOLVE(last_error, "licdf_last_error");
    snprintf(api.path, sizeof api.path, "%s", path);
    api.lib = lib;
    enif_mutex_unlock(api_lock);
    free(path);
    return atom(env, "ok");
}

static ERL_NIF_TERM nif_loaded_path(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    return loaded() ? bin_from_cstr(env, api.path) : atom(env, "nil");
}

// ---- version, discovery, errors -------------------------------------------------

static ERL_NIF_TERM nif_version(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    NEED_API();
    int32_t a = 0, b = 0, c = 0;
    int32_t rc = api.version(&a, &b, &c);
    return enif_make_tuple2(env, enif_make_int(env, rc),
                            enif_make_tuple3(env, enif_make_int(env, a), enif_make_int(env, b),
                                             enif_make_int(env, c)));
}

static ERL_NIF_TERM nif_device_count(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    (void)argv;
    NEED_API();
    int32_t n = 0;
    int32_t rc = api.device_count(&n);
    return int_pair(env, rc, n);
}

static ERL_NIF_TERM nif_device_serial(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, index);
    char buf[PATH_SIZE] = {0};
    return rc_str(env, api.device_serial(index, buf, sizeof buf), buf);
}

static ERL_NIF_TERM nif_device_path(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, index);
    char buf[PATH_SIZE] = {0};
    return rc_str(env, api.device_path(index, buf, sizeof buf), buf);
}

static ERL_NIF_TERM nif_strerror(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, code);
    char buf[ERROR_SIZE] = {0};
    api.strerror(code, buf, sizeof buf);
    return bin_from_cstr(env, buf);
}

static ERL_NIF_TERM nif_last_error(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, h);
    char buf[ERROR_SIZE] = {0};
    if (api.last_error(h, buf, sizeof buf) != 0) buf[0] = 0;
    return bin_from_cstr(env, buf);
}

// ---- open / close ---------------------------------------------------------------

static ERL_NIF_TERM nif_open(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_CSTR(0, serial);
    int32_t h = api.open_(serial);
    free(serial);
    return enif_make_int(env, h);
}

static ERL_NIF_TERM nif_open_path(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_CSTR(0, path);
    int32_t h = api.open_path(path);
    free(path);
    return enif_make_int(env, h);
}

#define HANDLE_ONLY(fname, field)                                                                   \
    static ERL_NIF_TERM fname(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {                \
        (void)argc;                                                                                 \
        NEED_API();                                                                                 \
        ARG_I32(0, h);                                                                              \
        return enif_make_int(env, api.field(h));                                                    \
    }

HANDLE_ONLY(nif_close, close)
HANDLE_ONLY(nif_session_open, session_open)
HANDLE_ONLY(nif_session_close, session_close)
HANDLE_ONLY(nif_record_erase_all, record_erase_all)

#define HANDLE_BYTES(fname, field)                                                                  \
    static ERL_NIF_TERM fname(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {                \
        (void)argc;                                                                                 \
        NEED_API();                                                                                 \
        ARG_I32(0, h);                                                                              \
        ARG_BIN(1, data);                                                                           \
        return enif_make_int(env, api.field(h, bytes_of(&data), (int32_t)data.size));              \
    }

HANDLE_BYTES(nif_set_trust_root, set_trust_root)
HANDLE_BYTES(nif_write_auth, write_auth)
HANDLE_BYTES(nif_write_auth_rotate, write_auth_rotate)

// ---- plaintext info -------------------------------------------------------------

static ERL_NIF_TERM nif_get_serial(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, h);
    char buf[SERIAL_SIZE] = {0};
    return rc_str(env, api.get_serial(h, buf, sizeof buf), buf);
}

static ERL_NIF_TERM nif_get_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, h);
    int32_t v[8] = {0};
    int32_t rc = api.get_info(h, &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]);
    ERL_NIF_TERM t[8];
    for (int i = 0; i < 8; i++) t[i] = enif_make_int(env, v[i]);
    return enif_make_tuple2(env, enif_make_int(env, rc), enif_make_tuple_from_array(env, t, 8));
}

static ERL_NIF_TERM nif_verify_genuine(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, h);
    int32_t genuine = 0;
    char serial[SERIAL_SIZE] = {0};
    char date[DATE_SIZE] = {0};
    int32_t rc = api.verify_genuine(h, &genuine, serial, sizeof serial, date, sizeof date);
    return enif_make_tuple4(env, enif_make_int(env, rc), enif_make_int(env, genuine),
                            bin_from_cstr(env, serial), bin_from_cstr(env, date));
}

// ---- records --------------------------------------------------------------------

static ERL_NIF_TERM nif_record_count(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, h);
    int32_t n = 0;
    int32_t rc = api.record_count(h, &n);
    return int_pair(env, rc, n);
}

static ERL_NIF_TERM nif_record_name(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, h);
    ARG_I32(1, index);
    char buf[PATH_SIZE] = {0};
    int32_t size = 0;
    int32_t rc = api.record_name(h, index, buf, sizeof buf, &size);
    return enif_make_tuple3(env, enif_make_int(env, rc), bin_from_cstr(env, rc == 0 ? buf : ""),
                            enif_make_int(env, size));
}

static ERL_NIF_TERM nif_record_size(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, h);
    ARG_CSTR(1, name);
    int32_t size = 0;
    int32_t rc = api.record_size(h, name, &size);
    free(name);
    return int_pair(env, rc, size);
}

struct read_ctx {
    int32_t h;
    const char *name;
};

static int32_t call_record_read(void *p, uint8_t *out, int32_t cap, int32_t *len) {
    struct read_ctx *c = (struct read_ctx *)p;
    return api.record_read(c->h, c->name, out, cap, len);
}

static ERL_NIF_TERM nif_record_read(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, h);
    ARG_CSTR(1, name);
    ARG_I32(2, cap);
    struct read_ctx c = {h, name};
    ERL_NIF_TERM r = read_bytes(env, cap, call_record_read, &c);
    free(name);
    return r;
}

static ERL_NIF_TERM nif_record_write(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, h);
    ARG_CSTR(1, name);
    ErlNifBinary data;
    if (!enif_inspect_binary(env, argv[2], &data)) {
        free(name);
        return enif_make_badarg(env);
    }
    int32_t rc = api.record_write(h, name, bytes_of(&data), (int32_t)data.size);
    free(name);
    return enif_make_int(env, rc);
}

static ERL_NIF_TERM nif_record_erase(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, h);
    ARG_CSTR(1, name);
    int32_t rc = api.record_erase(h, name);
    free(name);
    return enif_make_int(env, rc);
}

// ---- counters -------------------------------------------------------------------

static ERL_NIF_TERM nif_counter_read(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, h);
    ARG_I32(1, id);
    int32_t v = 0;
    int32_t rc = api.counter_read(h, id, &v);
    return int_pair(env, rc, v);
}

static ERL_NIF_TERM nif_counter_increment(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, h);
    ARG_I32(1, id);
    int32_t v = 0;
    int32_t rc = api.counter_increment(h, id, &v);
    return int_pair(env, rc, v);
}

// ---- app-data envelope encryption --------------------------------------------

struct crypt_ctx {
    int32_t h;
    int32_t scope;
    const uint8_t *in;
    int32_t in_len;
};

static int32_t call_encrypt(void *p, uint8_t *out, int32_t cap, int32_t *len) {
    struct crypt_ctx *c = (struct crypt_ctx *)p;
    return api.app_encrypt(c->h, c->scope, c->in, c->in_len, out, cap, len);
}

static int32_t call_decrypt(void *p, uint8_t *out, int32_t cap, int32_t *len) {
    struct crypt_ctx *c = (struct crypt_ctx *)p;
    return api.app_decrypt(c->h, c->in, c->in_len, out, cap, len);
}

static ERL_NIF_TERM nif_app_encrypt(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, h);
    ARG_I32(1, scope);
    ARG_BIN(2, plain);
    ARG_I32(3, cap);
    struct crypt_ctx c = {h, scope, bytes_of(&plain), (int32_t)plain.size};
    return read_bytes(env, cap, call_encrypt, &c);
}

static ERL_NIF_TERM nif_app_decrypt(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    (void)argc;
    NEED_API();
    ARG_I32(0, h);
    ARG_BIN(1, packed);
    ARG_I32(2, cap);
    struct crypt_ctx c = {h, 0, bytes_of(&packed), (int32_t)packed.size};
    return read_bytes(env, cap, call_decrypt, &c);
}

// ---- module ---------------------------------------------------------------------

static int on_load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
    (void)env;
    (void)priv;
    (void)info;
    if (!api_lock) api_lock = enif_mutex_create("keynub_licdongle_api");
    return api_lock ? 0 : 1;
}

static int on_upgrade(ErlNifEnv *env, void **priv, void **old_priv, ERL_NIF_TERM info) {
    (void)env;
    (void)priv;
    (void)old_priv;
    (void)info;
    return 0;
}

#define IO ERL_NIF_DIRTY_JOB_IO_BOUND

static ErlNifFunc funcs[] = {
    {"load", 1, nif_load, 0},
    {"loaded_path", 0, nif_loaded_path, 0},
    {"version", 0, nif_version, 0},
    {"device_count", 0, nif_device_count, IO},
    {"device_serial", 1, nif_device_serial, 0},
    {"device_path", 1, nif_device_path, 0},
    {"strerror", 1, nif_strerror, 0},
    {"last_error", 1, nif_last_error, 0},
    {"open", 1, nif_open, IO},
    {"open_path", 1, nif_open_path, IO},
    {"close", 1, nif_close, IO},
    {"set_trust_root", 2, nif_set_trust_root, 0},
    {"get_serial", 1, nif_get_serial, IO},
    {"get_info", 1, nif_get_info, IO},
    {"verify_genuine", 1, nif_verify_genuine, IO},
    {"session_open", 1, nif_session_open, IO},
    {"session_close", 1, nif_session_close, IO},
    {"write_auth", 2, nif_write_auth, IO},
    {"write_auth_rotate", 2, nif_write_auth_rotate, IO},
    {"record_count", 1, nif_record_count, IO},
    {"record_name", 2, nif_record_name, IO},
    {"record_size", 2, nif_record_size, IO},
    {"record_read", 3, nif_record_read, IO},
    {"record_write", 3, nif_record_write, IO},
    {"record_erase", 2, nif_record_erase, IO},
    {"record_erase_all", 1, nif_record_erase_all, IO},
    {"counter_read", 2, nif_counter_read, IO},
    {"counter_increment", 2, nif_counter_increment, IO},
    {"app_encrypt", 4, nif_app_encrypt, IO},
    {"app_decrypt", 3, nif_app_decrypt, IO},
};

ERL_NIF_INIT(Elixir.KeyNub.LicDongle.Nif, funcs, on_load, NULL, on_upgrade, NULL)
