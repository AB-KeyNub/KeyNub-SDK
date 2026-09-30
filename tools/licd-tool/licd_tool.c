/*
 * licd-tool - command-line access to a KeyNub license dongle.
 *
 * Lists attached dongles, shows what a dongle is and whether it is genuine,
 * reads and writes its license records, reads and increments its counters, and
 * encrypts and decrypts data that only a dongle can decrypt. Commands that
 * change the dongle need the write key (--write-key); irreversible ones also
 * need --yes. --json gives machine-readable output on stdout.
 *
 * Copyright (c) KeyNub. Licensed under the Apache License, Version 2.0.
 */
#include "licdongle.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#define TOOL_NAME "licd-tool"

/* Exit codes: 0 success, 1 failure (and list with no dongle attached), 2 usage
 * error or a dongle that is not genuine. */
enum { EXIT_OK = 0, EXIT_FAIL = 1, EXIT_USAGE = 2 };

typedef struct {
    const char *serial;
    const char *trust_root;
    const char *write_key;
    int json;
    int yes;
    int all;
    const char *output;
    const char *scope;
    int argc;
    char **argv; /* the command and its positional arguments */
} options;

static licd_ctx *g_ctx;

/* --- output ---------------------------------------------------------------- */

static void fail(const char *fmt, ...)
{
    va_list ap;
    fputs("error: ", stderr);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

/* The library's text for a failed call, with its detail when there is one. */
static void fail_status(const char *what, int rc)
{
    const char *detail = g_ctx ? licd_error_detail(g_ctx) : "";
    if (detail && *detail)
        fail("%s: %s (%s)", what, licd_strerror(rc), detail);
    else
        fail("%s: %s", what, licd_strerror(rc));
}

static void json_string(FILE *f, const char *s)
{
    fputc('"', f);
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (*p == '"' || *p == '\\')
            fprintf(f, "\\%c", *p);
        else if (*p < 0x20)
            fprintf(f, "\\u%04x", *p);
        else
            fputc(*p, f);
    }
    fputc('"', f);
}

static void json_hex(FILE *f, const uint8_t *data, uint32_t len)
{
    fputc('"', f);
    for (uint32_t i = 0; i < len; i++)
        fprintf(f, "%02x", data[i]);
    fputc('"', f);
}

/* --- files ----------------------------------------------------------------- */

/* Reads a whole file, or stdin for "-". Returns 0 and a malloc'd buffer. */
static int read_input(const char *path, const char *what, uint8_t **out, uint32_t *out_len)
{
    FILE *f = strcmp(path, "-") == 0 ? stdin : fopen(path, "rb");
    if (!f) {
        fail("cannot read %s (%s): %s", what, path, strerror(errno));
        return -1;
    }
    size_t cap = 4096, len = 0;
    uint8_t *buf = malloc(cap);
    for (;;) {
        if (!buf) {
            fail("out of memory reading %s", what);
            if (f != stdin)
                fclose(f);
            return -1;
        }
        size_t n = fread(buf + len, 1, cap - len, f);
        len += n;
        if (n == 0)
            break;
        if (len == cap) {
            uint8_t *bigger = cap < ((size_t)1 << 30) ? realloc(buf, cap * 2) : NULL;
            if (!bigger)
                free(buf);
            buf = bigger;
            cap *= 2;
        }
    }
    int bad = ferror(f);
    if (f != stdin)
        fclose(f);
    if (bad || len > UINT32_MAX) {
        free(buf);
        fail("cannot read %s (%s)", what, path);
        return -1;
    }
    *out = buf;
    *out_len = (uint32_t)len;
    return 0;
}

/* Writes data to a file, or to stdout when path is NULL. */
static int write_output(const char *path, const uint8_t *data, uint32_t len)
{
    if (!path) {
        if (len && fwrite(data, 1, len, stdout) != len) {
            fail("cannot write to standard output");
            return -1;
        }
        fflush(stdout);
        return 0;
    }
    FILE *f = fopen(path, "wb");
    if (!f) {
        fail("cannot write %s: %s", path, strerror(errno));
        return -1;
    }
    int ok = (len == 0 || fwrite(data, 1, len, f) == len);
    ok = (fclose(f) == 0) && ok;
    if (!ok)
        fail("cannot write %s", path);
    return ok ? 0 : -1;
}

/* --- connecting ------------------------------------------------------------ */

static int context_open(const options *o)
{
    int rc = licd_init(&g_ctx);
    if (rc != LICD_OK) {
        fail("could not start the KeyNub library: %s", licd_strerror(rc));
        return -1;
    }
    if (o->trust_root) {
        uint8_t *der;
        uint32_t len;
        if (read_input(o->trust_root, "trust root", &der, &len) != 0)
            return -1;
        rc = licd_set_trust_root(g_ctx, der, len);
        free(der);
        if (rc != LICD_OK) {
            fail_status("trust root", rc);
            return -1;
        }
    }
    return 0;
}

static licd_device *dongle_open(const options *o)
{
    licd_device *dev = NULL;
    int rc = licd_open(g_ctx, o->serial, &dev);
    if (rc == LICD_E_NO_DEVICE) {
        if (o->serial)
            fail("no dongle found with serial %s", o->serial);
        else
            fail("no dongle found; check the cable, and on Linux the udev rule described in NATIVES.md");
        return NULL;
    }
    if (rc != LICD_OK) {
        fail_status("could not open the dongle", rc);
        return NULL;
    }
    return dev;
}

/* Opens the dongle, a session, and with need_write the write role. */
static licd_device *session_open(const options *o, int need_write)
{
    licd_device *dev = dongle_open(o);
    if (!dev)
        return NULL;
    int rc = licd_session_open(dev);
    if (rc != LICD_OK) {
        fail_status("could not open a session", rc);
        licd_close(dev);
        return NULL;
    }
    if (need_write) {
        if (!o->write_key) {
            fail("this command changes the dongle and needs its write key: --write-key <key.der>");
            licd_close(dev);
            return NULL;
        }
        uint8_t *der;
        uint32_t len;
        if (read_input(o->write_key, "write key", &der, &len) != 0) {
            licd_close(dev);
            return NULL;
        }
        rc = licd_write_auth(dev, der, len);
        free(der);
        if (rc != LICD_OK) {
            fail_status("the dongle did not accept the write key", rc);
            licd_close(dev);
            return NULL;
        }
    }
    return dev;
}

static void session_close(licd_device *dev)
{
    if (dev) {
        licd_session_close(dev);
        licd_close(dev);
    }
}

/* Reads a whole record into a malloc'd buffer. */
static int record_read_all(licd_device *dev, const char *name, uint8_t **out, uint32_t *out_len)
{
    uint8_t probe;
    uint32_t got = 0, total = 0;
    int rc = licd_record_read(dev, name, 0, &probe, 1, &got, &total, NULL, NULL);
    if (rc != LICD_OK)
        return rc;
    uint8_t *buf = malloc(total ? total : 1);
    if (!buf)
        return LICD_E_INTERNAL;
    if (total) {
        rc = licd_record_read(dev, name, 0, buf, total, &got, &total, NULL, NULL);
        if (rc != LICD_OK) {
            free(buf);
            return rc;
        }
    }
    *out = buf;
    *out_len = total ? got : 0;
    return LICD_OK;
}

/* --- commands -------------------------------------------------------------- */

static int cmd_version(const options *o)
{
    int ma, mi, pa;
    licd_version(&ma, &mi, &pa);
    if (o->json)
        printf("{\n  \"licd_tool\": \"%d.%d.%d\",\n  \"native_core\": \"%d.%d.%d\"\n}\n", ma, mi, pa, ma, mi, pa);
    else
        printf(TOOL_NAME "     %d.%d.%d\nnative core   %d.%d.%d (built in)\n", ma, mi, pa, ma, mi, pa);
    return EXIT_OK;
}

static int cmd_list(const options *o)
{
    licd_device_info *list = NULL;
    size_t count = 0;
    int rc = licd_enumerate(g_ctx, &list, &count);
    if (rc != LICD_OK) {
        fail_status("could not list the dongles", rc);
        return EXIT_FAIL;
    }
    if (o->json) {
        printf("{\n  \"count\": %u,\n  \"dongles\": [", (unsigned)count);
        for (size_t i = 0; i < count; i++) {
            printf("%s\n    {\"serial\": ", i ? "," : "");
            json_string(stdout, list[i].serial);
            printf(", \"vendor_id\": \"0x%04X\", \"product_id\": \"0x%04X\", \"path\": ",
                   list[i].vendor_id, list[i].product_id);
            json_string(stdout, list[i].path);
            printf("}");
        }
        printf("%s]\n}\n", count ? "\n  " : "");
    } else if (count == 0) {
        printf("no dongles found\n");
    } else {
        printf("%u dongle(s):\n", (unsigned)count);
        for (size_t i = 0; i < count; i++)
            printf("  %s  (VID 0x%04X PID 0x%04X)\n", list[i].serial, list[i].vendor_id, list[i].product_id);
    }
    licd_free_device_list(list, count);
    return count ? EXIT_OK : EXIT_FAIL;
}

static int cmd_info(const options *o)
{
    licd_device *dev = dongle_open(o);
    if (!dev)
        return EXIT_FAIL;
    licd_info info;
    char serial[LICD_SERIAL_HEX_LEN + 1];
    int rc = licd_get_info(dev, &info);
    if (rc == LICD_OK)
        rc = licd_get_serial(dev, serial, sizeof serial);
    if (rc != LICD_OK) {
        fail_status("could not read the dongle", rc);
        licd_close(dev);
        return EXIT_FAIL;
    }
    if (o->json) {
        printf("{\n  \"serial\": ");
        json_string(stdout, serial);
        printf(",\n  \"protocol_version\": \"%u.%u\",\n  \"firmware_version\": \"%u.%u.%u\",\n"
               "  \"se_ready\": %s,\n  \"provisioned\": %s,\n  \"data_capacity\": %u,\n  \"data_free\": %u,\n"
               "  \"watchdog_reboot\": %s,\n  \"isolated\": %s,\n  \"write_key_rotated\": %s\n}\n",
               info.proto_version_major, info.proto_version_minor, info.fw_version_major,
               info.fw_version_minor, info.fw_version_patch, info.se_ready ? "true" : "false",
               info.provisioned ? "true" : "false", (unsigned)info.data_capacity, (unsigned)info.data_free,
               info.watchdog_reboot ? "true" : "false", info.isolated ? "true" : "false",
               info.writeauth_rotated ? "true" : "false");
    } else {
        printf("serial            %s\n", serial);
        printf("protocol          %u.%u\n", info.proto_version_major, info.proto_version_minor);
        printf("firmware          %u.%u.%u\n", info.fw_version_major, info.fw_version_minor, info.fw_version_patch);
        printf("secure element    %s\n", info.se_ready ? "ready" : "NOT READY");
        printf("provisioned       %s\n", info.provisioned ? "yes" : "no");
        printf("data              %u of %u bytes free\n", (unsigned)info.data_free, (unsigned)info.data_capacity);
        printf("isolated          %s\n", info.isolated ? "yes" : "no");
        printf("write key         %s\n", info.writeauth_rotated ? "your own" : "the factory key (rotate it)");
        if (info.watchdog_reboot)
            printf("WARNING: the previous boot ended in a watchdog reset\n");
    }
    licd_close(dev);
    return EXIT_OK;
}

static int cmd_verify(const options *o)
{
    licd_device *dev = dongle_open(o);
    if (!dev)
        return EXIT_FAIL;
    licd_genuine_result res;
    int rc = licd_verify_genuine(dev, &res);
    if (rc != LICD_OK || !res.genuine) {
        const char *why = rc != LICD_OK ? licd_strerror(rc) : "not genuine";
        const char *detail = licd_error_detail(g_ctx);
        if (o->json) {
            printf("{\n  \"genuine\": false,\n  \"error\": ");
            json_string(stdout, why);
            printf(",\n  \"detail\": ");
            json_string(stdout, detail ? detail : "");
            printf("\n}\n");
        } else {
            printf("NOT GENUINE: %s%s%s%s\n", why, detail && *detail ? " (" : "", detail ? detail : "",
                   detail && *detail ? ")" : "");
        }
        licd_close(dev);
        return EXIT_USAGE;
    }
    if (o->json) {
        printf("{\n  \"genuine\": true,\n  \"serial\": ");
        json_string(stdout, res.serial);
        printf(",\n  \"provisioned_date\": ");
        json_string(stdout, res.provisioned_date);
        printf("\n}\n");
    } else {
        printf("GENUINE           %s\n", res.serial);
        printf("provisioned       %s\n", res.provisioned_date[0] ? res.provisioned_date : "(none)");
    }
    licd_close(dev);
    return EXIT_OK;
}

static int cmd_records_list(const options *o)
{
    licd_device *dev = session_open(o, 0);
    if (!dev)
        return EXIT_FAIL;
    char **names = NULL;
    uint32_t *sizes = NULL;
    size_t count = 0;
    int rc = licd_record_list(dev, &names, &sizes, &count);
    if (rc != LICD_OK) {
        fail_status("could not list the records", rc);
        session_close(dev);
        return EXIT_FAIL;
    }
    if (o->json) {
        printf("{\n  \"count\": %u,\n  \"records\": [", (unsigned)count);
        for (size_t i = 0; i < count; i++) {
            printf("%s\n    {\"name\": ", i ? "," : "");
            json_string(stdout, names[i]);
            printf(", \"size\": %u}", (unsigned)sizes[i]);
        }
        printf("%s]\n}\n", count ? "\n  " : "");
    } else if (count == 0) {
        printf("no records stored\n");
    } else {
        printf("%u record(s):\n", (unsigned)count);
        for (size_t i = 0; i < count; i++)
            printf("  %-34s %u bytes\n", names[i], (unsigned)sizes[i]);
    }
    licd_free_record_list(names, sizes, count);
    session_close(dev);
    return EXIT_OK;
}

static int cmd_records_read(const options *o, const char *name)
{
    licd_device *dev = session_open(o, 0);
    if (!dev)
        return EXIT_FAIL;
    uint8_t *data = NULL;
    uint32_t len = 0;
    int rc = record_read_all(dev, name, &data, &len);
    session_close(dev);
    if (rc == LICD_E_NOT_FOUND) {
        fail("no such record: %s", name);
        return EXIT_FAIL;
    }
    if (rc != LICD_OK) {
        fail_status("could not read the record", rc);
        return EXIT_FAIL;
    }
    int result = EXIT_OK;
    if (o->output) {
        if (write_output(o->output, data, len) != 0)
            result = EXIT_FAIL;
        else if (o->json) {
            printf("{\n  \"name\": ");
            json_string(stdout, name);
            printf(",\n  \"bytes\": %u,\n  \"output\": ", (unsigned)len);
            json_string(stdout, o->output);
            printf("\n}\n");
        } else {
            printf("wrote %u bytes to %s\n", (unsigned)len, o->output);
        }
    } else if (o->json) {
        printf("{\n  \"name\": ");
        json_string(stdout, name);
        printf(",\n  \"bytes\": %u,\n  \"hex\": ", (unsigned)len);
        json_hex(stdout, data, len);
        printf("\n}\n");
    } else {
        if (write_output(NULL, data, len) != 0)
            result = EXIT_FAIL;
        fprintf(stderr, "(%u bytes)\n", (unsigned)len);
    }
    free(data);
    return result;
}

static int cmd_records_write(const options *o, const char *name, const char *input)
{
    uint8_t *payload;
    uint32_t len;
    if (read_input(input, "record data", &payload, &len) != 0)
        return EXIT_FAIL;
    licd_device *dev = session_open(o, 1);
    if (!dev) {
        free(payload);
        return EXIT_FAIL;
    }
    int result = EXIT_FAIL;
    int rc = licd_record_write(dev, name, payload, len, NULL, NULL);
    if (rc != LICD_OK) {
        fail_status("could not write the record", rc);
    } else {
        /* Read back: the record is license data, and a difference is better found here. */
        uint8_t *back = NULL;
        uint32_t back_len = 0;
        rc = record_read_all(dev, name, &back, &back_len);
        if (rc != LICD_OK)
            fail_status("could not read the record back", rc);
        else if (back_len != len || (len && memcmp(back, payload, len) != 0))
            fail("verification failed: wrote %u bytes, read back %u", (unsigned)len, (unsigned)back_len);
        else
            result = EXIT_OK;
        free(back);
    }
    session_close(dev);
    free(payload);
    if (result == EXIT_OK) {
        if (o->json) {
            printf("{\n  \"name\": ");
            json_string(stdout, name);
            printf(",\n  \"bytes\": %u,\n  \"verified\": true\n}\n", (unsigned)len);
        } else {
            printf("wrote and verified %u bytes to '%s'\n", (unsigned)len, name);
        }
    }
    return result;
}

static int cmd_records_erase(const options *o, const char *name)
{
    if (o->all && name) {
        fail("give a record name or --all, not both");
        return EXIT_USAGE;
    }
    if (!o->all && !name) {
        fail("give a record name, or --all");
        return EXIT_USAGE;
    }
    if (o->all && !o->yes) {
        fail("--all erases every record on the dongle; add --yes to confirm");
        return EXIT_USAGE;
    }
    licd_device *dev = session_open(o, 1);
    if (!dev)
        return EXIT_FAIL;
    int rc = licd_record_erase(dev, o->all ? NULL : name);
    session_close(dev);
    if (rc == LICD_E_NOT_FOUND) {
        fail("no such record: %s", name);
        return EXIT_FAIL;
    }
    if (rc != LICD_OK) {
        fail_status("could not erase", rc);
        return EXIT_FAIL;
    }
    if (o->json) {
        printf("{\n  \"erased\": ");
        json_string(stdout, o->all ? "all" : name);
        printf("\n}\n");
    } else if (o->all) {
        printf("erased all records\n");
    } else {
        printf("erased '%s'\n", name);
    }
    return EXIT_OK;
}

static int parse_counter(const char *s, uint8_t *out)
{
    char *end;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno || end == s || *end || v < 0 || v > 255) {
        fail("not a counter id (0 to 255): %s", s);
        return -1;
    }
    *out = (uint8_t)v;
    return 0;
}

static int cmd_counter_read(const options *o, int n, char **ids)
{
    static char *defaults[] = {"0", "1"};
    if (n == 0) {
        n = 2;
        ids = defaults;
    }
    uint8_t id[64];
    if (n > 64) {
        fail("at most 64 counters at a time");
        return EXIT_USAGE;
    }
    for (int i = 0; i < n; i++)
        if (parse_counter(ids[i], &id[i]) != 0)
            return EXIT_USAGE;
    licd_device *dev = session_open(o, 0);
    if (!dev)
        return EXIT_FAIL;
    uint32_t value[64];
    for (int i = 0; i < n; i++) {
        int rc = licd_counter_read(dev, id[i], &value[i]);
        if (rc != LICD_OK) {
            fail_status("could not read the counter", rc);
            session_close(dev);
            return EXIT_FAIL;
        }
    }
    session_close(dev);
    if (o->json) {
        printf("{\n  \"counters\": {");
        for (int i = 0; i < n; i++)
            printf("%s\n    \"%u\": %u", i ? "," : "", id[i], (unsigned)value[i]);
        printf("\n  }\n}\n");
    } else {
        for (int i = 0; i < n; i++)
            printf("counter %u: %u\n", id[i], (unsigned)value[i]);
    }
    return EXIT_OK;
}

static int cmd_counter_increment(const options *o, const char *id_text)
{
    uint8_t id;
    if (parse_counter(id_text, &id) != 0)
        return EXIT_USAGE;
    if (!o->yes) {
        fail("incrementing a counter cannot be undone; add --yes if you are sure");
        return EXIT_USAGE;
    }
    licd_device *dev = session_open(o, 1);
    if (!dev)
        return EXIT_FAIL;
    uint32_t before = 0, after = 0;
    int rc = licd_counter_read(dev, id, &before);
    if (rc == LICD_OK)
        rc = licd_counter_increment(dev, id, &after);
    session_close(dev);
    if (rc != LICD_OK) {
        fail_status("could not increment the counter", rc);
        return EXIT_FAIL;
    }
    if (o->json)
        printf("{\n  \"counter\": %u,\n  \"before\": %u,\n  \"after\": %u\n}\n", id, (unsigned)before, (unsigned)after);
    else
        printf("counter %u: %u -> %u (cannot be undone)\n", id, (unsigned)before, (unsigned)after);
    return EXIT_OK;
}

static int cmd_appcrypto(const options *o, int encrypt, const char *input)
{
    licd_scope scope = LICD_SCOPE_DEVICE;
    if (encrypt && o->scope) {
        if (strcmp(o->scope, "developer") == 0)
            scope = LICD_SCOPE_DEVELOPER;
        else if (strcmp(o->scope, "device") != 0) {
            fail("--scope is device or developer");
            return EXIT_USAGE;
        }
    }
    uint8_t *in;
    uint32_t in_len;
    if (read_input(input, encrypt ? "input" : "envelope", &in, &in_len) != 0)
        return EXIT_FAIL;
    licd_device *dev = session_open(o, 0);
    if (!dev) {
        free(in);
        return EXIT_FAIL;
    }
    uint8_t *out = NULL;
    uint32_t out_len = 0;
    int rc = encrypt ? licd_app_encrypt(dev, scope, in, in_len, &out, &out_len)
                     : licd_app_decrypt(dev, in, in_len, &out, &out_len);
    session_close(dev);
    free(in);
    if (rc != LICD_OK) {
        fail_status(encrypt ? "could not encrypt" : "could not decrypt", rc);
        return EXIT_FAIL;
    }
    int result = write_output(o->output, out, out_len) == 0 ? EXIT_OK : EXIT_FAIL;
    if (result == EXIT_OK && o->output) {
        if (o->json) {
            printf("{\n  \"input_bytes\": %u,\n  \"output_bytes\": %u,\n  \"output\": ", (unsigned)in_len,
                   (unsigned)out_len);
            json_string(stdout, o->output);
            printf("\n}\n");
        } else if (encrypt)
            printf("encrypted %u bytes -> %u byte envelope (%s scope) in %s\n", (unsigned)in_len,
                   (unsigned)out_len, scope == LICD_SCOPE_DEVELOPER ? "developer" : "device", o->output);
        else
            printf("decrypted %u bytes -> %u bytes in %s\n", (unsigned)in_len, (unsigned)out_len, o->output);
    }
    licd_free_buffer(out);
    return result;
}

static int cmd_rotate_write_key(const options *o, const char *new_key)
{
    if (!o->yes) {
        fail("from the next session on only the new key writes to this dongle, and a lost key cannot be "
             "recovered from it; add --yes if you are sure");
        return EXIT_USAGE;
    }
    uint8_t *der;
    uint32_t len;
    if (read_input(new_key, "new write key", &der, &len) != 0)
        return EXIT_FAIL;
    licd_device *dev = session_open(o, 1);
    if (!dev) {
        free(der);
        return EXIT_FAIL;
    }
    int rc = licd_write_auth_rotate(dev, der, len);
    free(der);
    session_close(dev);
    if (rc != LICD_OK) {
        fail_status("could not replace the write key", rc);
        return EXIT_FAIL;
    }
    if (o->json)
        printf("{\n  \"write_key_rotated\": true\n}\n");
    else
        printf("write key replaced; from the next session on only the new key writes\n");
    return EXIT_OK;
}

/* --- arguments ------------------------------------------------------------- */

static void usage(FILE *f)
{
    fputs("usage: " TOOL_NAME " [options] <command> [arguments]\n"
          "\n"
          "Command-line access to a KeyNub license dongle.\n"
          "\n"
          "commands:\n"
          "  list                                list attached dongles\n"
          "  info                                show device and storage information\n"
          "  verify                              prove the dongle is genuine\n"
          "  records list                        list records\n"
          "  records read <name> [-o FILE]       read a record (to stdout by default)\n"
          "  records write <name> <FILE|->       write a record and read it back (needs --write-key)\n"
          "  records erase <name>                erase a record (needs --write-key)\n"
          "  records erase --all --yes           erase every record (needs --write-key)\n"
          "  counter read [ID...]                read counters (default: 0 1)\n"
          "  counter increment <ID> --yes        increment a counter; cannot be undone (needs --write-key)\n"
          "  appcrypto encrypt <FILE|-> [-o FILE] [--scope device|developer]\n"
          "                                      encrypt data so that only a dongle can decrypt it\n"
          "  appcrypto decrypt <FILE|-> [-o FILE]\n"
          "                                      decrypt such data\n"
          "  rotate-write-key <new.der> --yes    replace the dongle's write key (needs --write-key)\n"
          "\n"
          "options:\n"
          "  --serial SERIAL      the dongle to use (default: the first one attached)\n"
          "  --write-key DER      the dongle's write key, a P-256 private key in PKCS#8 DER\n"
          "  --trust-root DER     a CA root other than the KeyNub root built in\n"
          "  --json               machine-readable output on stdout\n"
          "  --yes                confirm an irreversible command\n"
          "  --version            print the version and exit\n"
          "  -h, --help           show this help\n"
          "\n"
          "Exit status: 0 success, 1 failure (list: no dongle attached), 2 usage error or a\n"
          "dongle that is not genuine.\n"
          "https://www.keynub.com/\n",
          f);
}

/* Options may come before or after the command; the rest are positional. */
static int parse(int argc, char **argv, options *o, int *want_version)
{
    static char *positional[64];
    memset(o, 0, sizeof *o);
    o->argv = positional;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char **value = NULL;
        if (strcmp(a, "--serial") == 0)
            value = &o->serial;
        else if (strcmp(a, "--trust-root") == 0)
            value = &o->trust_root;
        else if (strcmp(a, "--write-key") == 0 || strcmp(a, "--master-key") == 0)
            value = &o->write_key;
        else if (strcmp(a, "-o") == 0 || strcmp(a, "--output") == 0)
            value = &o->output;
        else if (strcmp(a, "--scope") == 0)
            value = &o->scope;
        else if (strcmp(a, "--json") == 0)
            o->json = 1;
        else if (strcmp(a, "--yes") == 0)
            o->yes = 1;
        else if (strcmp(a, "--all") == 0)
            o->all = 1;
        else if (strcmp(a, "--version") == 0)
            *want_version = 1;
        else if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0)
            return 1;
        else if (a[0] == '-' && a[1] != '\0') {
            fail("unknown option %s", a);
            return -1;
        } else if (o->argc < 64) {
            positional[o->argc++] = argv[i];
        }
        if (value) {
            if (i + 1 >= argc) {
                fail("%s needs a value", a);
                return -1;
            }
            *value = argv[++i];
        }
    }
    return 0;
}

static int dispatch(const options *o)
{
    const char *cmd = o->argv[0];
    const char *sub = o->argc > 1 ? o->argv[1] : NULL;
    int n = o->argc;
    if (strcmp(cmd, "list") == 0 && n == 1)
        return cmd_list(o);
    if (strcmp(cmd, "info") == 0 && n == 1)
        return cmd_info(o);
    if (strcmp(cmd, "verify") == 0 && n == 1)
        return cmd_verify(o);
    if (strcmp(cmd, "records") == 0 && sub) {
        if (strcmp(sub, "list") == 0 && n == 2)
            return cmd_records_list(o);
        if (strcmp(sub, "read") == 0 && n == 3)
            return cmd_records_read(o, o->argv[2]);
        if (strcmp(sub, "write") == 0 && n == 4)
            return cmd_records_write(o, o->argv[2], o->argv[3]);
        if (strcmp(sub, "erase") == 0 && n <= 3)
            return cmd_records_erase(o, n == 3 ? o->argv[2] : NULL);
    }
    if (strcmp(cmd, "counter") == 0 && sub) {
        if (strcmp(sub, "read") == 0)
            return cmd_counter_read(o, n - 2, o->argv + 2);
        if (strcmp(sub, "increment") == 0 && n == 3)
            return cmd_counter_increment(o, o->argv[2]);
    }
    if (strcmp(cmd, "appcrypto") == 0 && sub && n == 3) {
        if (strcmp(sub, "encrypt") == 0)
            return cmd_appcrypto(o, 1, o->argv[2]);
        if (strcmp(sub, "decrypt") == 0)
            return cmd_appcrypto(o, 0, o->argv[2]);
    }
    if (strcmp(cmd, "rotate-write-key") == 0 && n == 2)
        return cmd_rotate_write_key(o, o->argv[1]);
    fail("unknown command or wrong arguments; see " TOOL_NAME " --help");
    return EXIT_USAGE;
}

int main(int argc, char **argv)
{
#ifdef _WIN32
    /* Record data, envelopes and plaintext pass through stdin and stdout unchanged. */
    _setmode(_fileno(stdout), _O_BINARY);
    _setmode(_fileno(stdin), _O_BINARY);
#endif
    options o;
    int want_version = 0;
    int p = parse(argc, argv, &o, &want_version);
    if (p != 0) {
        usage(p > 0 ? stdout : stderr);
        return p > 0 ? EXIT_OK : EXIT_USAGE;
    }
    if (want_version)
        return cmd_version(&o);
    if (o.argc == 0) {
        usage(stderr);
        return EXIT_USAGE;
    }
    if (context_open(&o) != 0) {
        if (g_ctx)
            licd_free(g_ctx);
        return EXIT_FAIL;
    }
    int rc = dispatch(&o);
    licd_free(g_ctx);
    return rc;
}
