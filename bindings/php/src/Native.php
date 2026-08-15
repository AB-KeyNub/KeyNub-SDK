<?php

declare(strict_types=1);

namespace KeyNub\LicDongle;

use FFI;

/**
 * FFI layer: locates the native core and declares the C ABI
 * (`include/licdongle.h`).
 *
 * PHP's own FFI extension, bundled since 8.0 — no PECL module, no compiler. The
 * declarations below are C, pasted, which is the pleasant part: they are the
 * header's own text rather than a translation of it, so there is one less
 * transformation to get wrong.
 *
 * Not part of the supported API — use Context, Dongle and Session.
 *
 * @internal
 */
final class Native
{
    /**
     * The subset of licdongle.h this binding calls. FFI::cdef parses real C, so
     * this is copied from the header rather than restated in another notation.
     */
    private const DECLARATIONS = <<<'CDEF'
        typedef struct licd_ctx licd_ctx;
        typedef struct licd_device licd_device;

        typedef struct {
            char serial[15];
            char path[512];
            uint16_t vendor_id;
            uint16_t product_id;
        } licd_device_info;

        typedef struct {
            uint8_t proto_version_major;
            uint8_t proto_version_minor;
            uint8_t fw_version_major;
            uint8_t fw_version_minor;
            uint8_t fw_version_patch;
            int se_ready;
            int provisioned;
            uint32_t data_capacity;
            uint32_t data_free;
            int watchdog_reboot;
            int isolated;
            int writeauth_rotated;
        } licd_info;

        typedef struct {
            int genuine;
            char serial[15];
            char provisioned_date[11];
        } licd_genuine_result;

        typedef int (*licd_progress_cb)(uint32_t done, uint32_t total, void *user);

        void licd_version(int *major, int *minor, int *patch);
        int licd_init(licd_ctx **out_ctx);
        void licd_free(licd_ctx *ctx);
        int licd_set_trust_root(licd_ctx *ctx, const uint8_t *der, size_t len);

        int licd_enumerate(licd_ctx *ctx, licd_device_info **out_list, size_t *out_count);
        void licd_free_device_list(licd_device_info *list, size_t count);
        int licd_open(licd_ctx *ctx, const char *serial_or_null, licd_device **out_dev);
        int licd_open_path(licd_ctx *ctx, const char *path, licd_device **out_dev);
        void licd_close(licd_device *dev);

        int licd_get_info(licd_device *dev, licd_info *out_info);
        int licd_get_serial(licd_device *dev, char *out_serial, size_t serial_size);

        int licd_verify_genuine(licd_device *dev, licd_genuine_result *out_result);
        int licd_session_open(licd_device *dev);
        int licd_session_close(licd_device *dev);
        int licd_write_auth(licd_device *dev, const uint8_t *master_key_der, size_t len);
        int licd_write_auth_rotate(licd_device *dev, const uint8_t *new_key_der, size_t len);

        int licd_record_list(licd_device *dev, char ***out_names, uint32_t **out_sizes,
                             size_t *out_count);
        void licd_free_record_list(char **names, uint32_t *sizes, size_t count);
        int licd_record_read(licd_device *dev, const char *name, uint32_t offset,
                             void *buf, uint32_t buf_size, uint32_t *out_len,
                             uint32_t *out_total, licd_progress_cb progress, void *user);
        int licd_record_write(licd_device *dev, const char *name, const void *data,
                              uint32_t len, licd_progress_cb progress, void *user);
        int licd_record_erase(licd_device *dev, const char *name);

        int licd_counter_read(licd_device *dev, uint8_t counter_id, uint32_t *out_value);
        int licd_counter_increment(licd_device *dev, uint8_t counter_id, uint32_t *out_value);

        int licd_app_encrypt(licd_device *dev, int scope, const void *plaintext,
                             uint32_t len, uint8_t **out, uint32_t *out_len);
        int licd_app_decrypt(licd_device *dev, const void *packed, uint32_t packed_len,
                             uint8_t **out, uint32_t *out_len);
        void licd_free_buffer(uint8_t *buf);

        const char *licd_strerror(int status);
        const char *licd_error_detail(licd_ctx *ctx);
        CDEF;

    private static ?FFI $ffi = null;

    public static function ffi(): FFI
    {
        if (self::$ffi === null) {
            if (!\extension_loaded('ffi')) {
                throw new \RuntimeException(
                    'the PHP FFI extension is not enabled; add extension=ffi to php.ini '
                    . '(it ships with PHP 8.0 and later)'
                );
            }
            $errors = [];
            foreach (self::candidatePaths() as $path) {
                try {
                    self::$ffi = FFI::cdef(self::DECLARATIONS, $path);
                    break;
                } catch (\FFI\Exception $e) {
                    $errors[] = $path . ': ' . $e->getMessage();
                }
            }
            if (self::$ffi === null) {
                throw new \RuntimeException(
                    "could not load the keynub_licdongle native library; tried:\n  "
                    . \implode("\n  ", $errors)
                );
            }
        }
        return self::$ffi;
    }

    /** @return list<string> */
    public static function candidatePaths(): array
    {
        $override = \getenv('KEYNUB_LICDONGLE_LIBRARY');
        if (\is_string($override) && $override !== '') {
            return [$override];
        }
        $name = match (true) {
            \PHP_OS_FAMILY === 'Windows' => 'keynub_licdongle.dll',
            \PHP_OS_FAMILY === 'Darwin' => 'libkeynub_licdongle.dylib',
            default => 'libkeynub_licdongle.so',
        };
        $here = __DIR__;
        return [
            $here . '/../vendor-native/' . $name, // shipped inside the package
            // The prebuilt library a checkout of the SDK carries, per platform:
            // what makes a clone runnable with nothing set.
            $here . '/../../../natives/' . self::repoRid() . '/' . $name,
            $here . '/' . $name,
            $name,                               // system search path
        ];
    }

    /** The natives/<rid> directory name for this build of PHP. */
    public static function repoRid(): string
    {
        $os = match (\PHP_OS_FAMILY) {
            'Windows' => 'win',
            'Darwin' => 'osx',
            default => 'linux',
        };
        $arch = match (\strtolower(\php_uname('m'))) {
            'amd64', 'x86_64' => 'x64',
            'i386', 'i586', 'i686', 'x86' => 'x86',
            'arm64', 'aarch64' => 'arm64',
            default => 'unknown',
        };
        return $os . '-' . $arch;
    }

    /**
     * A PHP string from a C `const char *` return value.
     *
     * PHP's FFI converts a `const char *` result to a PHP string on its own, but
     * only sometimes — an unqualified `char *` comes back as CData. Handling both
     * here keeps every call site from having to know which.
     */
    public static function toString(mixed $value): string
    {
        if ($value === null) {
            return '';
        }
        if (\is_string($value)) {
            return $value;
        }
        return FFI::string($value);
    }

    /** Reads a NUL-terminated string out of a fixed-size C char array. */
    public static function fixedString(FFI\CData $array, int $size): string
    {
        $bytes = '';
        for ($i = 0; $i < $size; $i++) {
            $char = $array[$i];
            if ($char === "\0" || $char === '' || \ord($char) === 0) {
                break;
            }
            $bytes .= $char;
        }
        return $bytes;
    }

    /** Copies `$length` bytes out of a library-allocated buffer, then frees it. */
    public static function takeBuffer(FFI\CData $outPointer, int $length): string
    {
        $pointer = $outPointer[0];
        if ($pointer === null) {
            return '';
        }
        try {
            return $length === 0 ? '' : FFI::string($pointer, $length);
        } finally {
            self::ffi()->licd_free_buffer($pointer);
        }
    }

    /**
     * A C uint8_t buffer holding the given bytes, for passing into the SDK.
     *
     * Allocated through the FFI instance rather than the static FFI::new, which is
     * deprecated as of PHP 8.3. The buffer is PHP-owned; callers pass it straight
     * into the call that uses it, so it stays alive for exactly as long as needed.
     */
    public static function bytes(string $data): ?FFI\CData
    {
        $length = \strlen($data);
        if ($length === 0) {
            return null;
        }
        $buffer = self::ffi()->new("uint8_t[$length]");
        FFI::memcpy($buffer, $data, $length);
        return $buffer;
    }
}
