/* KeyNub License Dongle: the foreign module of the SWI-Prolog pack.
 *
 * Loads the SDK's flat C API (keynub_licdongle_flat) at run time with
 * LoadLibraryW/GetProcAddress or dlopen/dlsym and makes each licdf_* function
 * a predicate that returns the status code and the values the call produces.
 * Nothing is linked against the KeyNub library. prolog/keynub_licdongle.pl
 * chooses the file, turns status codes into exceptions and is the interface
 * to use.
 *
 * Text crosses as UTF-8. Byte data comes in as a code list, string or atom
 * whose characters are all below 256, and goes out as a code list. A dongle
 * is a blob of type keynub_dongle that holds the flat API's handle; it is
 * closed by licd_close/2, or when the blob is garbage collected.
 */

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#include <SWI-Stream.h>
#include <SWI-Prolog.h>

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Buffer sizes of the flat API (LICDF_SERIAL_SIZE, LICDF_DATE_SIZE,
 * LICDF_PATH_SIZE, LICDF_ERROR_SIZE), and one for a record name. */
#define SERIAL_SIZE 15
#define DATE_SIZE 11
#define PATH_SIZE 512
#define ERROR_SIZE 256
#define NAME_SIZE 256

#define STATUS_RANGE (-11)

#ifndef BUF_STACK
#define BUF_STACK BUF_RING
#endif

/* ---- the flat API ------------------------------------------------------- */

typedef struct {
    int32_t (*version)(int32_t *, int32_t *, int32_t *);
    int32_t (*device_count)(int32_t *);
    int32_t (*device_serial)(int32_t, char *, int32_t);
    int32_t (*device_path)(int32_t, char *, int32_t);
    int32_t (*open)(const char *);
    int32_t (*open_path)(const char *);
    int32_t (*close)(int32_t);
    int32_t (*set_trust_root)(int32_t, const uint8_t *, int32_t);
    int32_t (*get_serial)(int32_t, char *, int32_t);
    int32_t (*get_info)(int32_t, int32_t *, int32_t *, int32_t *, int32_t *, int32_t *,
                        int32_t *, int32_t *, int32_t *);
    int32_t (*verify_genuine)(int32_t, int32_t *, char *, int32_t, char *, int32_t);
    int32_t (*session_open)(int32_t);
    int32_t (*session_close)(int32_t);
    int32_t (*write_auth)(int32_t, const uint8_t *, int32_t);
    int32_t (*write_auth_rotate)(int32_t, const uint8_t *, int32_t);
    int32_t (*record_count)(int32_t, int32_t *);
    int32_t (*record_name)(int32_t, int32_t, char *, int32_t, int32_t *);
    int32_t (*record_size)(int32_t, const char *, int32_t *);
    int32_t (*record_read)(int32_t, const char *, uint8_t *, int32_t, int32_t *);
    int32_t (*record_write)(int32_t, const char *, const uint8_t *, int32_t);
    int32_t (*record_erase)(int32_t, const char *);
    int32_t (*record_erase_all)(int32_t);
    int32_t (*counter_read)(int32_t, int32_t, int32_t *);
    int32_t (*counter_increment)(int32_t, int32_t, int32_t *);
    int32_t (*app_encrypt)(int32_t, int32_t, const uint8_t *, int32_t, uint8_t *, int32_t,
                           int32_t *);
    int32_t (*app_decrypt)(int32_t, const uint8_t *, int32_t, uint8_t *, int32_t, int32_t *);
    int32_t (*strerror)(int32_t, char *, int32_t);
    int32_t (*last_error)(int32_t, char *, int32_t);
} flat_api;

static flat_api api;
static volatile int api_loaded = 0;
static char *loaded_path = NULL;

#define ENTRY(name) { "licdf_" #name, offsetof(flat_api, name) }

static const struct {
    const char *symbol;
    size_t offset;
} entries[] = {
    ENTRY(version),        ENTRY(device_count),      ENTRY(device_serial),
    ENTRY(device_path),    ENTRY(open),              ENTRY(open_path),
    ENTRY(close),          ENTRY(set_trust_root),    ENTRY(get_serial),
    ENTRY(get_info),       ENTRY(verify_genuine),    ENTRY(session_open),
    ENTRY(session_close),  ENTRY(write_auth),        ENTRY(write_auth_rotate),
    ENTRY(record_count),   ENTRY(record_name),       ENTRY(record_size),
    ENTRY(record_read),    ENTRY(record_write),      ENTRY(record_erase),
    ENTRY(record_erase_all), ENTRY(counter_read),    ENTRY(counter_increment),
    ENTRY(app_encrypt),    ENTRY(app_decrypt),       ENTRY(strerror),
    ENTRY(last_error),
};

#define ENTRY_COUNT (sizeof(entries) / sizeof(entries[0]))

/* ---- loading the library ------------------------------------------------ */

#ifdef _WIN32

typedef HMODULE library_handle;

static library_handle open_library(const char *path, char *reason, size_t reason_size) {
    int wide_length = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
    if (wide_length <= 0) {
        snprintf(reason, reason_size, "the path is not valid UTF-8");
        return NULL;
    }
    wchar_t *wide = malloc((size_t)wide_length * sizeof(wchar_t));
    if (wide == NULL) {
        snprintf(reason, reason_size, "out of memory");
        return NULL;
    }
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, wide_length);
    DWORD flags = (strchr(path, '\\') != NULL || strchr(path, '/') != NULL)
                      ? LOAD_WITH_ALTERED_SEARCH_PATH
                      : 0;
    HMODULE module = LoadLibraryExW(wide, NULL, flags);
    free(wide);
    if (module == NULL) {
        DWORD code = GetLastError();
        char text[256] = "";
        DWORD n = FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL,
                                 code, 0, text, sizeof(text), NULL);
        while (n > 0 && (text[n - 1] == '\n' || text[n - 1] == '\r' || text[n - 1] == ' ' ||
                         text[n - 1] == '.')) {
            text[--n] = '\0';
        }
        snprintf(reason, reason_size, "error %lu: %s", (unsigned long)code, text);
    }
    return module;
}

static void *find_symbol(library_handle library, const char *symbol) {
    return (void *)GetProcAddress(library, symbol);
}

static void close_library(library_handle library) {
    FreeLibrary(library);
}

#else

typedef void *library_handle;

static library_handle open_library(const char *path, char *reason, size_t reason_size) {
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        const char *text = dlerror();
        snprintf(reason, reason_size, "%s", text != NULL ? text : "dlopen failed");
    }
    return library;
}

static void *find_symbol(library_handle library, const char *symbol) {
    return dlsym(library, symbol);
}

static void close_library(library_handle library) {
    dlclose(library);
}

#endif

/* ---- helpers -------------------------------------------------------------- */

static int raise_library_error(const char *text) {
    term_t ex = PL_new_term_ref();
    return PL_unify_term(ex, PL_FUNCTOR_CHARS, "error", 2,
                             PL_FUNCTOR_CHARS, "keynub_library_error", 1,
                               PL_UTF8_STRING, text,
                             PL_VARIABLE) &&
           PL_raise_exception(ex);
}

#define REQUIRE_LIBRARY()                                                \
    do {                                                                 \
        if (!api_loaded) {                                               \
            return raise_library_error("the KeyNub library is not loaded"); \
        }                                                                \
    } while (0)

/* Text in: an atom, string, code list or character list, as UTF-8. */
static int get_text(term_t t, char **text) {
    return PL_get_chars(t, text,
                        CVT_ATOM | CVT_STRING | CVT_LIST | REP_UTF8 | CVT_EXCEPTION | BUF_STACK);
}

/* Bytes in: a code list, string or atom whose characters are all below 256. */
static int get_bytes(term_t t, const uint8_t **data, int32_t *length) {
    size_t n = 0;
    char *s = NULL;
    if (!PL_get_nchars(t, &n, &s,
                       CVT_ATOM | CVT_STRING | CVT_LIST | REP_ISO_LATIN_1 | CVT_EXCEPTION |
                           BUF_STACK)) {
        return FALSE;
    }
    if (n > 0x7fffffff) {
        return PL_representation_error("int32_length");
    }
    *data = (const uint8_t *)s;
    *length = (int32_t)n;
    return TRUE;
}

static int get_int32(term_t t, int32_t *value) {
    int v = 0;
    if (!PL_get_integer_ex(t, &v)) {
        return FALSE;
    }
    *value = (int32_t)v;
    return TRUE;
}

/* Text out: the text before the first NUL of a buffer, as a string. */
static int unify_text(term_t t, char *buffer, size_t size) {
    buffer[size - 1] = '\0';
    return PL_unify_chars(t, PL_STRING | REP_UTF8, (size_t)-1, buffer);
}

/* Bytes out: a code list. */
static int unify_bytes(term_t t, const uint8_t *data, int32_t length) {
    return PL_unify_chars(t, PL_CODE_LIST | REP_ISO_LATIN_1, (size_t)length,
                          length > 0 ? (const char *)data : "");
}

static int unify_status(term_t t, int32_t rc) {
    return PL_unify_integer(t, rc);
}

/* ---- the dongle blob ------------------------------------------------------ */

typedef struct {
    int32_t handle; /* 0 once closed */
} dongle_ref;

static int release_dongle(atom_t a) {
    dongle_ref **slot = PL_blob_data(a, NULL, NULL);
    dongle_ref *ref = *slot;
    if (ref != NULL) {
        if (ref->handle > 0 && api_loaded) {
            api.close(ref->handle);
        }
        ref->handle = 0;
        free(ref);
    }
    return TRUE;
}

static int write_dongle(IOSTREAM *s, atom_t a, int flags) {
    (void)flags;
    dongle_ref **slot = PL_blob_data(a, NULL, NULL);
    dongle_ref *ref = *slot;
    if (ref != NULL && ref->handle > 0) {
        Sfprintf(s, "<keynub_dongle>(%d)", (int)ref->handle);
    } else {
        Sfprintf(s, "<keynub_dongle>(closed)");
    }
    return TRUE;
}

static PL_blob_t dongle_blob = {
    .magic = PL_BLOB_MAGIC,
    .flags = PL_BLOB_UNIQUE,
    .name = "keynub_dongle",
    .release = release_dongle,
    .write = write_dongle,
};

static int is_dongle(term_t t, dongle_ref **ref) {
    void *data = NULL;
    PL_blob_t *type = NULL;
    if (PL_get_blob(t, &data, NULL, &type) && type == &dongle_blob) {
        *ref = *(dongle_ref **)data;
        return TRUE;
    }
    return FALSE;
}

static int get_dongle(term_t t, int32_t *handle) {
    dongle_ref *ref = NULL;
    if (!is_dongle(t, &ref)) {
        return PL_type_error("keynub_dongle", t);
    }
    *handle = ref->handle;
    return TRUE;
}

static int unify_dongle(term_t t, int32_t handle) {
    dongle_ref *ref = malloc(sizeof(*ref));
    if (ref == NULL) {
        api.close(handle);
        return PL_resource_error("memory");
    }
    ref->handle = handle;
    return PL_unify_blob(t, &ref, sizeof(ref), &dongle_blob);
}

/* The two-call convention: ask with a capacity of 0, then read into a buffer
 * of the size the library reported. */
typedef int32_t (*sized_call)(const void *context, uint8_t *out, int32_t capacity,
                              int32_t *length);

static int32_t read_sized(sized_call call, const void *context, uint8_t **data,
                          int32_t *length) {
    uint8_t probe[1];
    int32_t needed = 0;
    *data = NULL;
    *length = 0;
    int32_t rc = call(context, probe, 0, &needed);
    if (rc == 0 || rc != STATUS_RANGE) {
        return rc;
    }
    uint8_t *buffer = malloc(needed > 0 ? (size_t)needed : 1);
    if (buffer == NULL) {
        return STATUS_RANGE;
    }
    int32_t written = 0;
    rc = call(context, buffer, needed, &written);
    if (rc != 0) {
        free(buffer);
        return rc;
    }
    *data = buffer;
    *length = written;
    return 0;
}

static int unify_sized_result(term_t rc_term, term_t out, int32_t rc, uint8_t *data,
                              int32_t length) {
    int ok = unify_status(rc_term, rc) && (rc != 0 || unify_bytes(out, data, length));
    free(data);
    return ok;
}

/* ---- predicates: the library ------------------------------------------ */

/* licd_load_library(+OsPath, +Path, -Result): Result is true when the
 * library at OsPath exports every function and is now in use, otherwise a
 * string with the reason. Path is what licd_loaded_path/1 reports. */
static foreign_t pl_load_library(term_t os_path, term_t path, term_t result) {
    char *file = NULL;
    char *shown = NULL;
    if (!get_text(os_path, &file) || !get_text(path, &shown)) {
        return FALSE;
    }
    if (api_loaded) {
        return PL_unify_atom_chars(result, "true");
    }
    char reason[512] = "";
    library_handle library = open_library(file, reason, sizeof(reason));
    if (library == NULL) {
        return PL_unify_chars(result, PL_STRING | REP_UTF8, (size_t)-1, reason);
    }
    flat_api table;
    memset(&table, 0, sizeof(table));
    for (size_t i = 0; i < ENTRY_COUNT; i++) {
        void *symbol = find_symbol(library, entries[i].symbol);
        if (symbol == NULL) {
            close_library(library);
            snprintf(reason, sizeof(reason), "does not export %s", entries[i].symbol);
            return PL_unify_chars(result, PL_STRING | REP_UTF8, (size_t)-1, reason);
        }
        memcpy((char *)&table + entries[i].offset, &symbol, sizeof(symbol));
    }
    char *copy = malloc(strlen(shown) + 1);
    if (copy == NULL) {
        close_library(library);
        return PL_resource_error("memory");
    }
    strcpy(copy, shown);
    api = table;
    loaded_path = copy;
    api_loaded = 1;
    return PL_unify_atom_chars(result, "true");
}

/* licd_loaded_path(-Path): fails when no library is loaded. */
static foreign_t pl_loaded_path(term_t path) {
    if (!api_loaded) {
        return FALSE;
    }
    return PL_unify_chars(path, PL_ATOM | REP_UTF8, (size_t)-1, loaded_path);
}

static foreign_t pl_is_dongle(term_t t) {
    dongle_ref *ref = NULL;
    return is_dongle(t, &ref);
}

/* licd_dongle_handle(+Dongle, -Handle): 0 once closed. */
static foreign_t pl_dongle_handle(term_t d, term_t handle) {
    int32_t h = 0;
    return get_dongle(d, &h) && PL_unify_integer(handle, h);
}

/* ---- predicates: version, discovery, open and close ------------------- */

static foreign_t pl_version(term_t rc, term_t major, term_t minor, term_t patch) {
    REQUIRE_LIBRARY();
    int32_t a = 0, b = 0, c = 0;
    int32_t status = api.version(&a, &b, &c);
    return unify_status(rc, status) &&
           (status != 0 || (PL_unify_integer(major, a) && PL_unify_integer(minor, b) &&
                            PL_unify_integer(patch, c)));
}

static foreign_t pl_device_count(term_t rc, term_t count) {
    REQUIRE_LIBRARY();
    int32_t n = 0;
    int32_t status = api.device_count(&n);
    return unify_status(rc, status) && (status != 0 || PL_unify_integer(count, n));
}

static foreign_t pl_device_serial(term_t index, term_t rc, term_t text) {
    REQUIRE_LIBRARY();
    int32_t i = 0;
    if (!get_int32(index, &i)) {
        return FALSE;
    }
    char buffer[PATH_SIZE] = "";
    int32_t status = api.device_serial(i, buffer, PATH_SIZE);
    return unify_status(rc, status) && (status != 0 || unify_text(text, buffer, PATH_SIZE));
}

static foreign_t pl_device_path(term_t index, term_t rc, term_t text) {
    REQUIRE_LIBRARY();
    int32_t i = 0;
    if (!get_int32(index, &i)) {
        return FALSE;
    }
    char buffer[PATH_SIZE] = "";
    int32_t status = api.device_path(i, buffer, PATH_SIZE);
    return unify_status(rc, status) && (status != 0 || unify_text(text, buffer, PATH_SIZE));
}

static foreign_t pl_open(term_t serial, term_t rc, term_t dongle) {
    REQUIRE_LIBRARY();
    char *s = NULL;
    if (!get_text(serial, &s)) {
        return FALSE;
    }
    int32_t handle = api.open(s);
    if (handle < 0) {
        return unify_status(rc, handle);
    }
    return unify_status(rc, 0) && unify_dongle(dongle, handle);
}

static foreign_t pl_open_path(term_t path, term_t rc, term_t dongle) {
    REQUIRE_LIBRARY();
    char *s = NULL;
    if (!get_text(path, &s)) {
        return FALSE;
    }
    int32_t handle = api.open_path(s);
    if (handle < 0) {
        return unify_status(rc, handle);
    }
    return unify_status(rc, 0) && unify_dongle(dongle, handle);
}

/* licd_close(+Dongle, -Rc): 0 for a dongle that is closed already. */
static foreign_t pl_close(term_t d, term_t rc) {
    dongle_ref *ref = NULL;
    if (!is_dongle(d, &ref)) {
        return PL_type_error("keynub_dongle", d);
    }
    int32_t handle = ref->handle;
    if (handle <= 0) {
        return unify_status(rc, 0);
    }
    REQUIRE_LIBRARY();
    ref->handle = 0;
    return unify_status(rc, api.close(handle));
}

/* ---- predicates: information and authenticity ------------------------- */

static foreign_t pl_set_trust_root(term_t d, term_t der, term_t rc) {
    int32_t h = 0, n = 0;
    const uint8_t *data = NULL;
    if (!get_dongle(d, &h) || !get_bytes(der, &data, &n)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    return unify_status(rc, api.set_trust_root(h, data, n));
}

static foreign_t pl_get_serial(term_t d, term_t rc, term_t serial) {
    int32_t h = 0;
    if (!get_dongle(d, &h)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    char buffer[SERIAL_SIZE] = "";
    int32_t status = api.get_serial(h, buffer, SERIAL_SIZE);
    return unify_status(rc, status) && (status != 0 || unify_text(serial, buffer, SERIAL_SIZE));
}

/* licd_get_info(+Dongle, -Rc, -info(PMajor, PMinor, FMajor, FMinor, FPatch,
 * Flags, Capacity, Free)) */
static foreign_t pl_get_info(term_t d, term_t rc, term_t info) {
    int32_t h = 0;
    if (!get_dongle(d, &h)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    int32_t v[8] = {0};
    int32_t status = api.get_info(h, &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]);
    if (!unify_status(rc, status)) {
        return FALSE;
    }
    if (status != 0) {
        return TRUE;
    }
    return PL_unify_term(info, PL_FUNCTOR_CHARS, "info", 8,
                         PL_INT, (int)v[0], PL_INT, (int)v[1], PL_INT, (int)v[2],
                         PL_INT, (int)v[3], PL_INT, (int)v[4], PL_INT, (int)v[5],
                         PL_INT, (int)v[6], PL_INT, (int)v[7]);
}

static foreign_t pl_verify_genuine(term_t d, term_t rc, term_t genuine, term_t serial,
                                   term_t date) {
    int32_t h = 0;
    if (!get_dongle(d, &h)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    int32_t g = 0;
    char serial_buffer[SERIAL_SIZE] = "";
    char date_buffer[DATE_SIZE] = "";
    int32_t status =
        api.verify_genuine(h, &g, serial_buffer, SERIAL_SIZE, date_buffer, DATE_SIZE);
    return unify_status(rc, status) &&
           (status != 0 || (PL_unify_integer(genuine, g) &&
                            unify_text(serial, serial_buffer, SERIAL_SIZE) &&
                            unify_text(date, date_buffer, DATE_SIZE)));
}

static foreign_t pl_last_error(term_t d, term_t rc, term_t text) {
    int32_t h = 0;
    if (!get_dongle(d, &h)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    char buffer[ERROR_SIZE] = "";
    int32_t status = api.last_error(h, buffer, ERROR_SIZE);
    return unify_status(rc, status) && (status != 0 || unify_text(text, buffer, ERROR_SIZE));
}

static foreign_t pl_strerror(term_t code, term_t rc, term_t text) {
    REQUIRE_LIBRARY();
    int32_t c = 0;
    if (!get_int32(code, &c)) {
        return FALSE;
    }
    char buffer[ERROR_SIZE] = "";
    int32_t status = api.strerror(c, buffer, ERROR_SIZE);
    return unify_status(rc, status) && (status != 0 || unify_text(text, buffer, ERROR_SIZE));
}

/* ---- predicates: sessions and the write role ---------------------------- */

static foreign_t pl_session_open(term_t d, term_t rc) {
    int32_t h = 0;
    if (!get_dongle(d, &h)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    return unify_status(rc, api.session_open(h));
}

static foreign_t pl_session_close(term_t d, term_t rc) {
    int32_t h = 0;
    if (!get_dongle(d, &h)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    return unify_status(rc, api.session_close(h));
}

static foreign_t pl_write_auth(term_t d, term_t key, term_t rc) {
    int32_t h = 0, n = 0;
    const uint8_t *data = NULL;
    if (!get_dongle(d, &h) || !get_bytes(key, &data, &n)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    return unify_status(rc, api.write_auth(h, data, n));
}

static foreign_t pl_write_auth_rotate(term_t d, term_t key, term_t rc) {
    int32_t h = 0, n = 0;
    const uint8_t *data = NULL;
    if (!get_dongle(d, &h) || !get_bytes(key, &data, &n)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    return unify_status(rc, api.write_auth_rotate(h, data, n));
}

/* ---- predicates: records -------------------------------------------------- */

static foreign_t pl_record_count(term_t d, term_t rc, term_t count) {
    int32_t h = 0;
    if (!get_dongle(d, &h)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    int32_t n = 0;
    int32_t status = api.record_count(h, &n);
    return unify_status(rc, status) && (status != 0 || PL_unify_integer(count, n));
}

static foreign_t pl_record_name(term_t d, term_t index, term_t rc, term_t name,
                                term_t size) {
    int32_t h = 0, i = 0;
    if (!get_dongle(d, &h) || !get_int32(index, &i)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    char buffer[NAME_SIZE] = "";
    int32_t n = 0;
    int32_t status = api.record_name(h, i, buffer, NAME_SIZE, &n);
    return unify_status(rc, status) &&
           (status != 0 || (unify_text(name, buffer, NAME_SIZE) && PL_unify_integer(size, n)));
}

static foreign_t pl_record_size(term_t d, term_t name, term_t rc, term_t size) {
    int32_t h = 0;
    char *s = NULL;
    if (!get_dongle(d, &h) || !get_text(name, &s)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    int32_t n = 0;
    int32_t status = api.record_size(h, s, &n);
    return unify_status(rc, status) && (status != 0 || PL_unify_integer(size, n));
}

typedef struct {
    int32_t handle;
    const char *name;
} record_read_context;

static int32_t call_record_read(const void *context, uint8_t *out, int32_t capacity,
                                int32_t *length) {
    const record_read_context *c = context;
    return api.record_read(c->handle, c->name, out, capacity, length);
}

static foreign_t pl_record_read(term_t d, term_t name, term_t rc, term_t out) {
    record_read_context c = {0, NULL};
    char *s = NULL;
    if (!get_dongle(d, &c.handle) || !get_text(name, &s)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    c.name = s;
    uint8_t *data = NULL;
    int32_t length = 0;
    int32_t status = read_sized(call_record_read, &c, &data, &length);
    return unify_sized_result(rc, out, status, data, length);
}

static foreign_t pl_record_write(term_t d, term_t name, term_t bytes, term_t rc) {
    int32_t h = 0, n = 0;
    char *s = NULL;
    const uint8_t *data = NULL;
    if (!get_dongle(d, &h) || !get_text(name, &s) || !get_bytes(bytes, &data, &n)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    return unify_status(rc, api.record_write(h, s, data, n));
}

static foreign_t pl_record_erase(term_t d, term_t name, term_t rc) {
    int32_t h = 0;
    char *s = NULL;
    if (!get_dongle(d, &h) || !get_text(name, &s)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    return unify_status(rc, api.record_erase(h, s));
}

static foreign_t pl_record_erase_all(term_t d, term_t rc) {
    int32_t h = 0;
    if (!get_dongle(d, &h)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    return unify_status(rc, api.record_erase_all(h));
}

/* ---- predicates: counters ------------------------------------------------- */

static foreign_t pl_counter_read(term_t d, term_t id, term_t rc, term_t value) {
    int32_t h = 0, i = 0;
    if (!get_dongle(d, &h) || !get_int32(id, &i)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    int32_t v = 0;
    int32_t status = api.counter_read(h, i, &v);
    return unify_status(rc, status) && (status != 0 || PL_unify_integer(value, v));
}

static foreign_t pl_counter_increment(term_t d, term_t id, term_t rc, term_t value) {
    int32_t h = 0, i = 0;
    if (!get_dongle(d, &h) || !get_int32(id, &i)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    int32_t v = 0;
    int32_t status = api.counter_increment(h, i, &v);
    return unify_status(rc, status) && (status != 0 || PL_unify_integer(value, v));
}

/* ---- predicates: app-data encryption -------------------------------------- */

typedef struct {
    int32_t handle;
    int32_t scope;
    const uint8_t *input;
    int32_t input_length;
} app_context;

static int32_t call_app_encrypt(const void *context, uint8_t *out, int32_t capacity,
                                int32_t *length) {
    const app_context *c = context;
    return api.app_encrypt(c->handle, c->scope, c->input, c->input_length, out, capacity,
                           length);
}

static int32_t call_app_decrypt(const void *context, uint8_t *out, int32_t capacity,
                                int32_t *length) {
    const app_context *c = context;
    return api.app_decrypt(c->handle, c->input, c->input_length, out, capacity, length);
}

/* licd_app_encrypt(+Dongle, +Scope, +Plaintext, -Rc, -Sealed): Scope is 0
 * (this dongle) or 1 (any dongle of the same developer). */
static foreign_t pl_app_encrypt(term_t d, term_t scope, term_t plaintext, term_t rc,
                                term_t out) {
    app_context c = {0, 0, NULL, 0};
    if (!get_dongle(d, &c.handle) || !get_int32(scope, &c.scope) ||
        !get_bytes(plaintext, &c.input, &c.input_length)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    uint8_t *data = NULL;
    int32_t length = 0;
    int32_t status = read_sized(call_app_encrypt, &c, &data, &length);
    return unify_sized_result(rc, out, status, data, length);
}

static foreign_t pl_app_decrypt(term_t d, term_t packed, term_t rc, term_t out) {
    app_context c = {0, 0, NULL, 0};
    if (!get_dongle(d, &c.handle) || !get_bytes(packed, &c.input, &c.input_length)) {
        return FALSE;
    }
    REQUIRE_LIBRARY();
    uint8_t *data = NULL;
    int32_t length = 0;
    int32_t status = read_sized(call_app_decrypt, &c, &data, &length);
    return unify_sized_result(rc, out, status, data, length);
}

/* ---- registration --------------------------------------------------------- */

#if !defined(_WIN32) && defined(__GNUC__)
__attribute__((visibility("default")))
#endif
install_t install_keynub_licdongle4pl(void) {
    PL_register_foreign("licd_load_library", 3, pl_load_library, 0);
    PL_register_foreign("licd_loaded_path", 1, pl_loaded_path, 0);
    PL_register_foreign("licd_is_dongle", 1, pl_is_dongle, 0);
    PL_register_foreign("licd_dongle_handle", 2, pl_dongle_handle, 0);
    PL_register_foreign("licd_version", 4, pl_version, 0);
    PL_register_foreign("licd_device_count", 2, pl_device_count, 0);
    PL_register_foreign("licd_device_serial", 3, pl_device_serial, 0);
    PL_register_foreign("licd_device_path", 3, pl_device_path, 0);
    PL_register_foreign("licd_open", 3, pl_open, 0);
    PL_register_foreign("licd_open_path", 3, pl_open_path, 0);
    PL_register_foreign("licd_close", 2, pl_close, 0);
    PL_register_foreign("licd_set_trust_root", 3, pl_set_trust_root, 0);
    PL_register_foreign("licd_get_serial", 3, pl_get_serial, 0);
    PL_register_foreign("licd_get_info", 3, pl_get_info, 0);
    PL_register_foreign("licd_verify_genuine", 5, pl_verify_genuine, 0);
    PL_register_foreign("licd_last_error", 3, pl_last_error, 0);
    PL_register_foreign("licd_strerror", 3, pl_strerror, 0);
    PL_register_foreign("licd_session_open", 2, pl_session_open, 0);
    PL_register_foreign("licd_session_close", 2, pl_session_close, 0);
    PL_register_foreign("licd_write_auth", 3, pl_write_auth, 0);
    PL_register_foreign("licd_write_auth_rotate", 3, pl_write_auth_rotate, 0);
    PL_register_foreign("licd_record_count", 3, pl_record_count, 0);
    PL_register_foreign("licd_record_name", 5, pl_record_name, 0);
    PL_register_foreign("licd_record_size", 4, pl_record_size, 0);
    PL_register_foreign("licd_record_read", 4, pl_record_read, 0);
    PL_register_foreign("licd_record_write", 4, pl_record_write, 0);
    PL_register_foreign("licd_record_erase", 3, pl_record_erase, 0);
    PL_register_foreign("licd_record_erase_all", 2, pl_record_erase_all, 0);
    PL_register_foreign("licd_counter_read", 4, pl_counter_read, 0);
    PL_register_foreign("licd_counter_increment", 4, pl_counter_increment, 0);
    PL_register_foreign("licd_app_encrypt", 5, pl_app_encrypt, 0);
    PL_register_foreign("licd_app_decrypt", 4, pl_app_decrypt, 0);
}
