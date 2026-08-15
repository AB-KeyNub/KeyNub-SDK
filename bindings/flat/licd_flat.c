// Implementation of the flat companion API. See licd_flat.h for the conventions.
//
// Everything here is impedance matching: integer handles for opaque pointers,
// caller-owned buffers for library-owned ones, index-addressed lists for arrays.
// There is no protocol logic — it all stays in the core.

#include "licd_flat.h"

#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  include <windows.h>
#else
#  include <pthread.h>
#endif

// ============================================================================
// Serialization
// ============================================================================

// One lock held for the whole of each call. The callers this API exists for
// (LabVIEW, VBA, Fortran) are not chasing throughput, and serializing removes an
// entire class of question: no handle can be closed underneath an operation, and
// the enumeration snapshot cannot change while it is being read. A caller that
// does need two dongles in parallel should use the core ABI.
#if defined(_WIN32)
static SRWLOCK g_lock = SRWLOCK_INIT;
#  define LOCK() AcquireSRWLockExclusive(&g_lock)
#  define UNLOCK() ReleaseSRWLockExclusive(&g_lock)
#else
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
#  define LOCK() pthread_mutex_lock(&g_lock)
#  define UNLOCK() pthread_mutex_unlock(&g_lock)
#endif

// ============================================================================
// Handle table
// ============================================================================

#define LICDF_MAX_HANDLES 32

typedef struct {
    int32_t id; // 0 = free
    licd_ctx *ctx;
    licd_device *dev;
} slot_t;

static slot_t g_slots[LICDF_MAX_HANDLES];
static int32_t g_next_id = 1;

// Snapshot from the last licdf_device_count, so the _serial/_path accessors can be
// index-addressed without a handle.
static licd_device_info *g_snapshot;
static size_t g_snapshot_count;

static slot_t *find_slot(int32_t handle) {
    if (handle <= 0) {
        return NULL;
    }
    for (int i = 0; i < LICDF_MAX_HANDLES; i++) {
        if (g_slots[i].id == handle) {
            return &g_slots[i];
        }
    }
    return NULL;
}

static slot_t *claim_slot(void) {
    for (int i = 0; i < LICDF_MAX_HANDLES; i++) {
        if (g_slots[i].id == 0) {
            g_slots[i].id = g_next_id++;
            if (g_next_id <= 0) {
                g_next_id = 1; // wrap defensively; ids are only unique among live slots
            }
            return &g_slots[i];
        }
    }
    return NULL;
}

static void release_slot(slot_t *s) {
    if (s->dev != NULL) {
        licd_close(s->dev);
        s->dev = NULL;
    }
    if (s->ctx != NULL) {
        licd_free(s->ctx);
        s->ctx = NULL;
    }
    s->id = 0;
}

// ============================================================================
// Small helpers
// ============================================================================

static int32_t copy_string(const char *src, char *out, int32_t out_size) {
    if (out == NULL || out_size <= 0) {
        return LICD_E_INVALID_ARG;
    }
    if (src == NULL) {
        src = "";
    }
    size_t len = strlen(src);
    if (len + 1 > (size_t)out_size) {
        out[0] = '\0';
        return LICD_E_RANGE;
    }
    memcpy(out, src, len + 1);
    return LICD_OK;
}

// Applies the "caller-allocated buffer" contract: too small is LICD_E_RANGE with
// the required size reported, so a caller can ask with a capacity of 0 first.
static int32_t copy_bytes(const uint8_t *src, size_t len, uint8_t *out, int32_t out_cap,
                          int32_t *out_len) {
    if (out_len != NULL) {
        *out_len = (int32_t)len;
    }
    if (out_cap < 0 || (size_t)out_cap < len) {
        return LICD_E_RANGE;
    }
    if (len != 0) {
        if (out == NULL) {
            return LICD_E_INVALID_ARG;
        }
        memcpy(out, src, len);
    }
    return LICD_OK;
}

static void set_int(int32_t *out, int32_t value) {
    if (out != NULL) {
        *out = value;
    }
}

// An empty string means "not specified", the way a null pointer does in the core.
static const char *or_null(const char *s) {
    return (s != NULL && s[0] != '\0') ? s : NULL;
}

static int32_t require_len(int32_t len) {
    return (len < 0) ? LICD_E_INVALID_ARG : LICD_OK;
}

// ============================================================================
// Version
// ============================================================================

int32_t licdf_version(int32_t *out_major, int32_t *out_minor, int32_t *out_patch) {
    int major = 0, minor = 0, patch = 0;
    licd_version(&major, &minor, &patch);
    set_int(out_major, major);
    set_int(out_minor, minor);
    set_int(out_patch, patch);
    return LICD_OK;
}

int32_t licdf_strerror(int32_t status, char *out, int32_t out_size) {
    return copy_string(licd_strerror(status), out, out_size);
}

// ============================================================================
// Discovery
// ============================================================================

int32_t licdf_device_count(int32_t *out_count) {
    set_int(out_count, 0);
    LOCK();
    if (g_snapshot != NULL) {
        licd_free_device_list(g_snapshot, g_snapshot_count);
        g_snapshot = NULL;
        g_snapshot_count = 0;
    }
    licd_ctx *ctx = NULL;
    int32_t rc = (int32_t)licd_init(&ctx);
    if (rc == LICD_OK) {
        licd_device_info *list = NULL;
        size_t count = 0;
        rc = (int32_t)licd_enumerate(ctx, &list, &count);
        if (rc == LICD_OK) {
            g_snapshot = list;
            g_snapshot_count = count;
            set_int(out_count, (int32_t)count);
        }
        licd_free(ctx);
    }
    UNLOCK();
    return rc;
}

static int32_t snapshot_field(int32_t index, int want_path, char *out, int32_t out_size) {
    LOCK();
    int32_t rc;
    if (index < 0 || (size_t)index >= g_snapshot_count || g_snapshot == NULL) {
        rc = LICD_E_RANGE; // includes "licdf_device_count was never called"
    } else {
        rc = copy_string(want_path ? g_snapshot[index].path : g_snapshot[index].serial, out,
                         out_size);
    }
    UNLOCK();
    return rc;
}

int32_t licdf_device_serial(int32_t index, char *out, int32_t out_size) {
    return snapshot_field(index, 0, out, out_size);
}

int32_t licdf_device_path(int32_t index, char *out, int32_t out_size) {
    return snapshot_field(index, 1, out, out_size);
}

// ============================================================================
// Open / close
// ============================================================================

// by_path == 0: `target` is a serial (empty = first dongle). Otherwise a path.
static int32_t open_common(const char *target, int by_path) {
    LOCK();
    slot_t *s = claim_slot();
    if (s == NULL) {
        UNLOCK();
        return LICD_E_BUSY; // handle table full
    }
    int32_t rc = (int32_t)licd_init(&s->ctx);
    if (rc == LICD_OK) {
        rc = by_path ? (int32_t)licd_open_path(s->ctx, target, &s->dev)
                     : (int32_t)licd_open(s->ctx, or_null(target), &s->dev);
    }
    if (rc != LICD_OK) {
        release_slot(s);
        UNLOCK();
        return rc;
    }
    int32_t handle = s->id;
    UNLOCK();
    return handle;
}

int32_t licdf_open(const char *serial_or_empty) { return open_common(serial_or_empty, 0); }

int32_t licdf_open_path(const char *path) {
    if (or_null(path) == NULL) {
        return LICD_E_INVALID_ARG;
    }
    return open_common(path, 1);
}

int32_t licdf_close(int32_t handle) {
    LOCK();
    slot_t *s = find_slot(handle);
    int32_t rc = LICD_OK;
    if (s == NULL) {
        rc = LICD_E_INVALID_ARG;
    } else {
        release_slot(s);
    }
    UNLOCK();
    return rc;
}

// Boilerplate every handle-taking function shares: look the handle up under the
// lock, and unlock on every exit path.
#define WITH_SLOT(handle, body)                       \
    do {                                              \
        LOCK();                                       \
        slot_t *s = find_slot(handle);                \
        int32_t rc;                                   \
        if (s == NULL) {                              \
            rc = LICD_E_INVALID_ARG;                  \
        } else {                                      \
            body                                      \
        }                                             \
        UNLOCK();                                     \
        return rc;                                    \
    } while (0)

int32_t licdf_set_trust_root(int32_t handle, const uint8_t *der, int32_t der_len) {
    WITH_SLOT(handle, {
        rc = require_len(der_len);
        if (rc == LICD_OK) {
            rc = (int32_t)licd_set_trust_root(s->ctx, der, (size_t)der_len);
        }
    });
}

int32_t licdf_last_error(int32_t handle, char *out, int32_t out_size) {
    WITH_SLOT(handle, { rc = copy_string(licd_error_detail(s->ctx), out, out_size); });
}

// ============================================================================
// Plaintext info
// ============================================================================

int32_t licdf_get_serial(int32_t handle, char *out, int32_t out_size) {
    WITH_SLOT(handle, {
        char serial[LICD_SERIAL_HEX_LEN + 1];
        rc = (int32_t)licd_get_serial(s->dev, serial, sizeof(serial));
        if (rc == LICD_OK) {
            rc = copy_string(serial, out, out_size);
        }
    });
}

int32_t licdf_get_info(int32_t handle, int32_t *out_proto_major, int32_t *out_proto_minor,
                       int32_t *out_fw_major, int32_t *out_fw_minor, int32_t *out_fw_patch,
                       int32_t *out_flags, int32_t *out_capacity, int32_t *out_free) {
    WITH_SLOT(handle, {
        licd_info info;
        memset(&info, 0, sizeof(info));
        rc = (int32_t)licd_get_info(s->dev, &info);
        if (rc == LICD_OK) {
            set_int(out_proto_major, info.proto_version_major);
            set_int(out_proto_minor, info.proto_version_minor);
            set_int(out_fw_major, info.fw_version_major);
            set_int(out_fw_minor, info.fw_version_minor);
            set_int(out_fw_patch, info.fw_version_patch);
            int32_t flags = 0;
            if (info.se_ready) {
                flags |= LICDF_FLAG_SE_READY;
            }
            if (info.provisioned) {
                flags |= LICDF_FLAG_PROVISIONED;
            }
            if (info.watchdog_reboot) {
                flags |= LICDF_FLAG_WATCHDOG_REBOOT;
            }
            if (info.isolated) {
                flags |= LICDF_FLAG_ISOLATED;
            }
            if (info.writeauth_rotated) {
                flags |= LICDF_FLAG_WRITEAUTH_ROTATED;
            }
            set_int(out_flags, flags);
            set_int(out_capacity, (int32_t)info.data_capacity);
            set_int(out_free, (int32_t)info.data_free);
        }
    });
}

int32_t licdf_verify_genuine(int32_t handle, int32_t *out_genuine, char *out_serial,
                             int32_t serial_size, char *out_provisioned_date,
                             int32_t date_size) {
    set_int(out_genuine, 0);
    WITH_SLOT(handle, {
        licd_genuine_result result;
        memset(&result, 0, sizeof(result));
        rc = (int32_t)licd_verify_genuine(s->dev, &result);
        if (rc == LICD_OK) {
            set_int(out_genuine, result.genuine != 0 ? 1 : 0);
            if (out_serial != NULL) {
                rc = copy_string(result.serial, out_serial, serial_size);
            }
            // Only if the caller asked, and never at the cost of the verdict: a
            // buffer too small for the date must not turn a genuine dongle into
            // a failure, so its status is taken only when nothing else failed.
            if (rc == LICD_OK && out_provisioned_date != NULL) {
                rc = copy_string(result.provisioned_date, out_provisioned_date, date_size);
            }
        }
    });
}

// ============================================================================
// Session
// ============================================================================

int32_t licdf_session_open(int32_t handle) {
    WITH_SLOT(handle, { rc = (int32_t)licd_session_open(s->dev); });
}

int32_t licdf_session_close(int32_t handle) {
    WITH_SLOT(handle, { rc = (int32_t)licd_session_close(s->dev); });
}

int32_t licdf_write_auth(int32_t handle, const uint8_t *der, int32_t der_len) {
    WITH_SLOT(handle, {
        rc = require_len(der_len);
        if (rc == LICD_OK) {
            rc = (int32_t)licd_write_auth(s->dev, der, (size_t)der_len);
        }
    });
}

int32_t licdf_write_auth_rotate(int32_t handle, const uint8_t *der, int32_t der_len) {
    WITH_SLOT(handle, {
        rc = require_len(der_len);
        if (rc == LICD_OK) {
            rc = (int32_t)licd_write_auth_rotate(s->dev, der, (size_t)der_len);
        }
    });
}

// ============================================================================
// Records
// ============================================================================

int32_t licdf_record_count(int32_t handle, int32_t *out_count) {
    set_int(out_count, 0);
    WITH_SLOT(handle, {
        char **names = NULL;
        uint32_t *sizes = NULL;
        size_t count = 0;
        rc = (int32_t)licd_record_list(s->dev, &names, &sizes, &count);
        if (rc == LICD_OK) {
            set_int(out_count, (int32_t)count);
            licd_free_record_list(names, sizes, count);
        }
    });
}

int32_t licdf_record_name(int32_t handle, int32_t index, char *out, int32_t out_size,
                          int32_t *out_record_size) {
    set_int(out_record_size, 0);
    WITH_SLOT(handle, {
        char **names = NULL;
        uint32_t *sizes = NULL;
        size_t count = 0;
        rc = (int32_t)licd_record_list(s->dev, &names, &sizes, &count);
        if (rc == LICD_OK) {
            if (index < 0 || (size_t)index >= count) {
                rc = LICD_E_RANGE;
            } else {
                set_int(out_record_size, (int32_t)sizes[index]);
                rc = copy_string(names[index], out, out_size);
            }
            licd_free_record_list(names, sizes, count);
        }
    });
}

// Reads with a one-byte buffer purely to learn the total, which is how the core
// reports a record's size.
static int32_t probe_size(licd_device *dev, const char *name, uint32_t *out_total) {
    uint8_t probe = 0;
    uint32_t got = 0;
    *out_total = 0;
    return (int32_t)licd_record_read(dev, name, 0, &probe, 1, &got, out_total, NULL, NULL);
}

int32_t licdf_record_size(int32_t handle, const char *name, int32_t *out_size) {
    set_int(out_size, 0);
    WITH_SLOT(handle, {
        if (or_null(name) == NULL) {
            rc = LICD_E_INVALID_ARG;
        } else {
            uint32_t total = 0;
            rc = probe_size(s->dev, name, &total);
            if (rc == LICD_OK) {
                set_int(out_size, (int32_t)total);
            }
        }
    });
}

int32_t licdf_record_read(int32_t handle, const char *name, uint8_t *out, int32_t out_cap,
                          int32_t *out_len) {
    set_int(out_len, 0);
    WITH_SLOT(handle, {
        if (or_null(name) == NULL || out_cap < 0) {
            rc = LICD_E_INVALID_ARG;
        } else {
            uint32_t total = 0;
            rc = probe_size(s->dev, name, &total);
            if (rc == LICD_OK) {
                set_int(out_len, (int32_t)total);
                if ((uint32_t)out_cap < total) {
                    // The two-call pattern: ask with out_cap 0, allocate, ask again.
                    rc = LICD_E_RANGE;
                } else if (total == 0) {
                    rc = LICD_OK;
                } else {
                    uint32_t got = 0;
                    rc = (int32_t)licd_record_read(s->dev, name, 0, out, total, &got, &total,
                                                  NULL, NULL);
                    set_int(out_len, (rc == LICD_OK) ? (int32_t)got : 0);
                }
            }
        }
    });
}

int32_t licdf_record_write(int32_t handle, const char *name, const uint8_t *data,
                           int32_t data_len) {
    WITH_SLOT(handle, {
        if (or_null(name) == NULL) {
            rc = LICD_E_INVALID_ARG;
        } else {
            rc = require_len(data_len);
            if (rc == LICD_OK) {
                rc = (int32_t)licd_record_write(s->dev, name, data, (uint32_t)data_len, NULL,
                                                NULL);
            }
        }
    });
}

int32_t licdf_record_erase(int32_t handle, const char *name) {
    WITH_SLOT(handle, {
        if (or_null(name) == NULL) {
            // Never fall through to the core's "null name erases everything": in a
            // language without optional arguments an uninitialised string is the
            // normal kind of mistake, and it must not wipe the dongle.
            rc = LICD_E_INVALID_ARG;
        } else {
            rc = (int32_t)licd_record_erase(s->dev, name);
        }
    });
}

int32_t licdf_record_erase_all(int32_t handle) {
    WITH_SLOT(handle, { rc = (int32_t)licd_record_erase(s->dev, NULL); });
}

// ============================================================================
// Counters
// ============================================================================

static int32_t counter_id_ok(int32_t counter_id) {
    return (counter_id >= 0 && counter_id <= 255) ? LICD_OK : LICD_E_INVALID_ARG;
}

int32_t licdf_counter_read(int32_t handle, int32_t counter_id, int32_t *out_value) {
    set_int(out_value, 0);
    WITH_SLOT(handle, {
        rc = counter_id_ok(counter_id);
        if (rc == LICD_OK) {
            uint32_t value = 0;
            rc = (int32_t)licd_counter_read(s->dev, (uint8_t)counter_id, &value);
            if (rc == LICD_OK) {
                set_int(out_value, (int32_t)value);
            }
        }
    });
}

int32_t licdf_counter_increment(int32_t handle, int32_t counter_id, int32_t *out_value) {
    set_int(out_value, 0);
    WITH_SLOT(handle, {
        rc = counter_id_ok(counter_id);
        if (rc == LICD_OK) {
            uint32_t value = 0;
            rc = (int32_t)licd_counter_increment(s->dev, (uint8_t)counter_id, &value);
            if (rc == LICD_OK) {
                set_int(out_value, (int32_t)value);
            }
        }
    });
}

// ============================================================================
// App-data envelope encryption
// ============================================================================

int32_t licdf_app_encrypt(int32_t handle, int32_t scope, const uint8_t *plaintext,
                          int32_t plaintext_len, uint8_t *out, int32_t out_cap,
                          int32_t *out_len) {
    set_int(out_len, 0);
    WITH_SLOT(handle, {
        if (scope != LICD_SCOPE_DEVICE && scope != LICD_SCOPE_DEVELOPER) {
            rc = LICD_E_INVALID_ARG;
        } else {
            rc = require_len(plaintext_len);
            if (rc == LICD_OK) {
                uint8_t *buf = NULL;
                uint32_t buf_len = 0;
                rc = (int32_t)licd_app_encrypt(s->dev, (licd_scope)scope, plaintext,
                                              (uint32_t)plaintext_len, &buf, &buf_len);
                if (rc == LICD_OK) {
                    rc = copy_bytes(buf, buf_len, out, out_cap, out_len);
                    licd_free_buffer(buf);
                }
            }
        }
    });
}

int32_t licdf_app_decrypt(int32_t handle, const uint8_t *packed, int32_t packed_len,
                          uint8_t *out, int32_t out_cap, int32_t *out_len) {
    set_int(out_len, 0);
    WITH_SLOT(handle, {
        rc = require_len(packed_len);
        if (rc == LICD_OK) {
            uint8_t *buf = NULL;
            uint32_t buf_len = 0;
            rc = (int32_t)licd_app_decrypt(s->dev, packed, (uint32_t)packed_len, &buf, &buf_len);
            if (rc == LICD_OK) {
                rc = copy_bytes(buf, buf_len, out, out_cap, out_len);
                licd_free_buffer(buf);
            }
        }
    });
}

