<?php

declare(strict_types=1);

/**
 * KeyNub License Dongle — PHP binding.
 *
 *   require 'src/KeyNub.php';
 *
 *   $ctx = new KeyNub\LicDongle\Context();
 *   $dongle = $ctx->open();                  // first dongle, or open('serial')
 *   $dongle->verifyGenuine();                // throws unless genuine
 *   $session = $dongle->openSession();
 *   $data = $session->appDecrypt($blob);     // <- build the licence check on this
 *
 * Uses PHP's own FFI extension (bundled since 8.0) — no PECL module, no compiler.
 *
 * Read docs/integration-security.md before deciding where the check goes.
 * `if (!$licensed) die();` is one line to delete, and PHP ships as source. What
 * cannot be deleted is data the application needs and only the dongle can
 * decrypt — a rate table, a licensed data set, the parameters of a calculation.
 */

namespace KeyNub\LicDongle;

use FFI;

require_once __DIR__ . '/Native.php';

/** Native status codes (mirrors licd_status). OK is 0; errors are negative. */
final class Status
{
    public const OK = 0;
    public const INVALID_ARGUMENT = -1;
    public const NO_DEVICE = -2;
    public const ACCESS_DENIED = -3;
    public const IO = -4;
    public const TIMEOUT = -5;
    public const PROTOCOL = -6;
    public const NOT_GENUINE = -7;
    public const CERTIFICATE_INVALID = -8;
    public const SESSION_EXPIRED = -9;
    public const TAG_MISMATCH = -10;
    public const RANGE = -11;
    public const STORAGE_FULL = -12;
    public const BUSY = -13;
    public const NOT_FOUND = -14;
    public const AUTH_REQUIRED = -15;
    public const FIRMWARE_INCOMPATIBLE = -16;
    public const SDK_TOO_OLD = -17;
    public const CANCELLED = -18;
    public const NOT_IMPLEMENTED = -19;
    public const INTERNAL = -20;
}

/** Who can decrypt data produced by Session::appEncrypt(). */
final class Scope
{
    /** Only this one physical dongle. */
    public const DEVICE = 0;
    /** Any dongle from the same developer batch — one blob for every customer. */
    public const DEVELOPER = 1;
}

/** Thrown when a dongle operation fails. */
class LicenseDongleException extends \RuntimeException
{
    public function __construct(
        public readonly int $status,
        string $message,
        public readonly string $operation = '',
        /** The SDK's diagnostic text. Log it; do not parse it. */
        public readonly string $detail = ''
    ) {
        parent::__construct($message, 0);
    }
}

final class NotGenuineException extends LicenseDongleException {}
final class CertificateInvalidException extends LicenseDongleException {}
final class WriteAuthorizationRequiredException extends LicenseDongleException {}
final class SessionExpiredException extends LicenseDongleException {}
final class DeviceNotFoundException extends LicenseDongleException {}
final class RecordNotFoundException extends LicenseDongleException {}
final class OperationCancelledException extends LicenseDongleException {}

/** @internal */
final class Errors
{
    private const SUBCLASS = [
        Status::NOT_GENUINE => NotGenuineException::class,
        Status::CERTIFICATE_INVALID => CertificateInvalidException::class,
        Status::AUTH_REQUIRED => WriteAuthorizationRequiredException::class,
        Status::SESSION_EXPIRED => SessionExpiredException::class,
        Status::NO_DEVICE => DeviceNotFoundException::class,
        Status::NOT_FOUND => RecordNotFoundException::class,
        Status::CANCELLED => OperationCancelledException::class,
    ];

    public static function make(int $status, string $operation, string $detail = ''): LicenseDongleException
    {
        $ffi = Native::ffi();
        $text = Native::toString($ffi->licd_strerror($status));
        $message = $operation . ': ' . $text . ($detail !== '' ? " ($detail)" : '');
        $class = self::SUBCLASS[$status] ?? LicenseDongleException::class;
        return new $class($status, $message, $operation, $detail);
    }
}

/** The library context: the entry point for finding and opening dongles. */
final class Context
{
    private ?FFI\CData $handle;
    private FFI $ffi;

    public function __construct()
    {
        $this->ffi = Native::ffi();
        // A single owned pointer, not an element of a temporary array: PHP frees the
        // array as soon as the constructor returns, and an element CData can be a
        // view into it rather than a copy — which segfaults on first use. Keeping
        // the pointer itself as the property makes the lifetime unambiguous.
        $handle = $this->ffi->new('licd_ctx*');
        $rc = $this->ffi->licd_init(FFI::addr($handle));
        if ($rc !== Status::OK) {
            throw Errors::make($rc, 'licd_init');
        }
        $this->handle = $handle;
    }

    /** The native core's version, as [major, minor, patch]. */
    public static function libraryVersion(): array
    {
        $ffi = Native::ffi();
        $parts = $ffi->new('int[3]');
        $ffi->licd_version(FFI::addr($parts[0]), FFI::addr($parts[1]), FFI::addr($parts[2]));
        return [$parts[0], $parts[1], $parts[2]];
    }

    public function isOpen(): bool
    {
        return $this->handle !== null;
    }

    public function close(): void
    {
        if ($this->handle !== null) {
            $handle = $this->handle;
            $this->handle = null;
            $this->ffi->licd_free($handle);
        }
    }

    public function __destruct()
    {
        $this->close();
    }

    /** @internal */
    public function handle(): FFI\CData
    {
        if ($this->handle === null) {
            throw Errors::make(Status::INVALID_ARGUMENT, 'context', 'the context has been closed');
        }
        return $this->handle;
    }

    /** @internal */
    public function ffi(): FFI
    {
        return $this->ffi;
    }

    /** The SDK's diagnostic detail for the most recent failure on this thread. */
    public function lastErrorDetail(): string
    {
        return Native::toString($this->ffi->licd_error_detail($this->handle()));
    }

    /** @internal */
    public function check(int $rc, string $operation): void
    {
        if ($rc !== Status::OK) {
            throw Errors::make($rc, $operation, $this->handle === null ? '' : $this->lastErrorDetail());
        }
    }

    /**
     * Overrides the CA root that verifyGenuine() checks against. Applications do
     * not need this: a release build embeds the KeyNub production root. It exists
     * for dongles provisioned against a different CA, and for vendor tooling.
     */
    public function setTrustRoot(string $der): void
    {
        $buffer = Native::bytes($der);
        $this->check(
            $this->ffi->licd_set_trust_root($this->handle(), $buffer, \strlen($der)),
            'licd_set_trust_root'
        );
    }

    /**
     * Connected dongles. An empty array means none are attached, which is normal.
     *
     * @return list<array{serial: string, path: string, vendorId: int, productId: int}>
     */
    public function enumerate(): array
    {
        $list = $this->ffi->new('licd_device_info*[1]');
        $count = $this->ffi->new('size_t[1]');
        $this->check(
            $this->ffi->licd_enumerate($this->handle(), FFI::addr($list[0]), FFI::addr($count[0])),
            'licd_enumerate'
        );
        $out = [];
        if ($list[0] !== null && $count[0] > 0) {
            try {
                for ($i = 0; $i < $count[0]; $i++) {
                    $entry = $list[0][$i];
                    $out[] = [
                        'serial' => Native::fixedString($entry->serial, 19),
                        'path' => Native::fixedString($entry->path, 512),
                        'vendorId' => $entry->vendor_id,
                        'productId' => $entry->product_id,
                    ];
                }
            } finally {
                $this->ffi->licd_free_device_list($list[0], $count[0]);
            }
        }
        return $out;
    }

    /** Opens the dongle with this serial, or the first one found. */
    public function open(?string $serial = null): Dongle
    {
        $handle = $this->ffi->new('licd_device*');
        $this->check(
            $this->ffi->licd_open($this->handle(), $serial, FFI::addr($handle)),
            'licd_open'
        );
        return new Dongle($this, $handle);
    }

    /** Opens a specific dongle by the path from enumerate(). */
    public function openPath(string $path): Dongle
    {
        $handle = $this->ffi->new('licd_device*');
        $this->check(
            $this->ffi->licd_open_path($this->handle(), $path, FFI::addr($handle)),
            'licd_open_path'
        );
        return new Dongle($this, $handle);
    }

    /**
     * Adopts a device opened through the C ABI directly, so this binding can be
     * introduced into existing FFI code a call at a time.
     */
    public function adopt(FFI\CData $device): Dongle
    {
        return new Dongle($this, $device);
    }
}

/** An open connection to a dongle. Stored data needs a Session. */
final class Dongle
{
    private ?FFI\CData $handle;

    /** @internal */
    public function __construct(private Context $context, FFI\CData $handle)
    {
        $this->handle = $handle;
    }

    public function isOpen(): bool
    {
        return $this->handle !== null;
    }

    public function close(): void
    {
        if ($this->handle !== null) {
            $handle = $this->handle;
            $this->handle = null;
            $this->context->ffi()->licd_close($handle);
        }
    }

    /** @internal */
    public function handle(): FFI\CData
    {
        if ($this->handle === null) {
            throw Errors::make(Status::INVALID_ARGUMENT, 'dongle', 'the dongle has been closed');
        }
        return $this->handle;
    }

    /** @internal */
    public function context(): Context
    {
        return $this->context;
    }

    /**
     * Plaintext device info.
     *
     * `watchdogReboot` means the dongle's *previous* boot ended in a watchdog
     * timeout: the firmware hung and reset itself. It is the only trace a field
     * hang leaves behind, and a power cycle clears it, so log it.
     *
     * @return array{protocolVersion: array{int, int}, firmwareVersion: array{int, int, int},
     *               seReady: bool, provisioned: bool, dataCapacity: int, dataFree: int,
     *               watchdogReboot: bool, isolated: bool}
     */
    public function getInfo(): array
    {
        $ffi = $this->context->ffi();
        $raw = $ffi->new('licd_info');
        $this->context->check($ffi->licd_get_info($this->handle(), FFI::addr($raw)), 'licd_get_info');
        return [
            'protocolVersion' => [$raw->proto_version_major, $raw->proto_version_minor],
            'firmwareVersion' => [$raw->fw_version_major, $raw->fw_version_minor, $raw->fw_version_patch],
            'seReady' => $raw->se_ready !== 0,
            'provisioned' => $raw->provisioned !== 0,
            'dataCapacity' => $raw->data_capacity,
            'dataFree' => $raw->data_free,
            'watchdogReboot' => $raw->watchdog_reboot !== 0,
            'isolated' => $raw->isolated !== 0,
        ];
    }

    /** The dongle serial as hex. */
    public function getSerial(): string
    {
        $ffi = $this->context->ffi();
        $buffer = $ffi->new('char[19]');
        $this->context->check(
            $ffi->licd_get_serial($this->handle(), $buffer, 19),
            'licd_get_serial'
        );
        return Native::fixedString($buffer, 19);
    }

    /**
     * Proves authenticity: the certificate chain to the trusted root plus a live
     * ECDSA challenge-response. Throws unless the dongle is genuine.
     *
     * @return array{genuine: bool, serial: string, batch: string, provisionedDate: string}
     */
    public function verifyGenuine(): array
    {
        $ffi = $this->context->ffi();
        $raw = $ffi->new('licd_genuine_result');
        $this->context->check(
            $ffi->licd_verify_genuine($this->handle(), FFI::addr($raw)),
            'licd_verify_genuine'
        );
        return [
            'genuine' => $raw->genuine !== 0,
            'serial' => Native::fixedString($raw->serial, 19),
            'batch' => Native::fixedString($raw->batch, 64),
            'provisionedDate' => Native::fixedString($raw->provisioned_date, 11),
        ];
    }

    /**
     * The non-throwing form, for a licence gate. Fails closed: a missing dongle,
     * an I/O error and an invalid certificate all return false.
     */
    public function isGenuine(): bool
    {
        try {
            return $this->verifyGenuine()['genuine'];
        } catch (LicenseDongleException) {
            return false;
        }
    }

    /** Opens an encrypted session (P-256 ECDH, HKDF-SHA256, AES-256-GCM). */
    public function openSession(): Session
    {
        $ffi = $this->context->ffi();
        $this->context->check($ffi->licd_session_open($this->handle()), 'licd_session_open');
        return new Session($this);
    }
}

/** An open encrypted session: records, counters and app-crypto. */
final class Session
{
    private bool $closed = false;

    /** @internal */
    public function __construct(private Dongle $dongle) {}

    public function isOpen(): bool
    {
        return !$this->closed;
    }

    /** Ends the session, zeroizing the session keys on the dongle. Never throws. */
    public function close(): void
    {
        if (!$this->closed) {
            $this->closed = true;
            if ($this->dongle->isOpen()) {
                $this->dongle->context()->ffi()->licd_session_close($this->dongle->handle());
            }
        }
    }

    private function device(): FFI\CData
    {
        if ($this->closed) {
            throw Errors::make(Status::SESSION_EXPIRED, 'session', 'the session has been closed');
        }
        return $this->dongle->handle();
    }

    private function ffi(): FFI
    {
        return $this->dongle->context()->ffi();
    }

    private function check(int $rc, string $operation): void
    {
        $this->dongle->context()->check($rc, $operation);
    }

    private static function requireName(string $name): string
    {
        if ($name === '') {
            throw new \InvalidArgumentException('the record name must not be empty');
        }
        return $name;
    }

    /**
     * Elevates to the write role with the developer master key (a DER EC private
     * key). Vendor tooling only — never ship that key in an application.
     */
    public function authorizeWrite(string $masterKeyDer): void
    {
        $this->check(
            $this->ffi()->licd_write_auth($this->device(), Native::bytes($masterKeyDer), \strlen($masterKeyDer)),
            'licd_write_auth'
        );
    }

    /** @return list<array{name: string, size: int}> */
    public function listRecords(): array
    {
        $ffi = $this->ffi();
        $names = $ffi->new('char**[1]');
        $sizes = $ffi->new('uint32_t*[1]');
        $count = $ffi->new('size_t[1]');
        $this->check(
            $ffi->licd_record_list($this->device(), FFI::addr($names[0]), FFI::addr($sizes[0]), FFI::addr($count[0])),
            'licd_record_list'
        );
        $out = [];
        if ($names[0] !== null && $count[0] > 0) {
            try {
                for ($i = 0; $i < $count[0]; $i++) {
                    $out[] = ['name' => Native::toString($names[0][$i]), 'size' => $sizes[0][$i]];
                }
            } finally {
                $ffi->licd_free_record_list($names[0], $sizes[0], $count[0]);
            }
        }
        return $out;
    }

    /**
     * Reads a record. $progress is called as ($done, $total); return false to
     * cancel, which throws OperationCancelledException.
     */
    public function readRecord(string $name, ?callable $progress = null): string
    {
        self::requireName($name);
        $ffi = $this->ffi();
        $device = $this->device();
        $got = $ffi->new('uint32_t[1]');
        $total = $ffi->new('uint32_t[1]');

        // Probe for the size first, so progress runs monotonically from 0 to total.
        $probe = $ffi->new('uint8_t[1]');
        $this->check(
            $ffi->licd_record_read($device, $name, 0, $probe, 1, FFI::addr($got[0]), FFI::addr($total[0]), null, null),
            'licd_record_read'
        );
        if ($total[0] === 0) {
            return '';
        }

        $size = $total[0];
        $buffer = $ffi->new("uint8_t[$size]");
        [$callback, $rethrow] = $this->progressBridge($progress);
        $rc = $ffi->licd_record_read(
            $device, $name, 0, $buffer, $size,
            FFI::addr($got[0]), FFI::addr($total[0]), $callback, null
        );
        $rethrow();
        $this->check($rc, 'licd_record_read');
        return FFI::string($buffer, $got[0]);
    }

    /** Atomically replaces a record. Requires the write role. */
    public function writeRecord(string $name, string $data, ?callable $progress = null): void
    {
        self::requireName($name);
        $ffi = $this->ffi();
        [$callback, $rethrow] = $this->progressBridge($progress);
        $rc = $ffi->licd_record_write(
            $this->device(), $name, Native::bytes($data), \strlen($data), $callback, null
        );
        $rethrow();
        $this->check($rc, 'licd_record_write');
    }

    /** Erases one record. Requires the write role. */
    public function eraseRecord(string $name): void
    {
        // A null name means "erase everything" to the C API; that is
        // eraseAllRecords() here, so an empty string cannot wipe the dongle.
        self::requireName($name);
        $this->check($this->ffi()->licd_record_erase($this->device(), $name), 'licd_record_erase');
    }

    /** Erases every record. Requires the write role. */
    public function eraseAllRecords(): void
    {
        $this->check($this->ffi()->licd_record_erase($this->device(), null), 'licd_record_erase');
    }

    public function readCounter(int $counterId): int
    {
        $ffi = $this->ffi();
        $value = $ffi->new('uint32_t[1]');
        $this->check(
            $ffi->licd_counter_read($this->device(), $counterId, FFI::addr($value[0])),
            'licd_counter_read'
        );
        return $value[0];
    }

    /** Irreversible: the counter is monotonic in hardware. Requires the write role. */
    public function incrementCounter(int $counterId): int
    {
        $ffi = $this->ffi();
        $value = $ffi->new('uint32_t[1]');
        $this->check(
            $ffi->licd_counter_increment($this->device(), $counterId, FFI::addr($value[0])),
            'licd_counter_increment'
        );
        return $value[0];
    }

    /**
     * Encrypts so that only a dongle of $scope can decrypt. This is the pair to
     * build a licence check on: put something the application genuinely needs
     * through it, so removing the check removes the data.
     */
    public function appEncrypt(int $scope, string $plaintext): string
    {
        if ($scope !== Scope::DEVICE && $scope !== Scope::DEVELOPER) {
            throw new \InvalidArgumentException('scope must be Scope::DEVICE or Scope::DEVELOPER');
        }
        $ffi = $this->ffi();
        $out = $ffi->new('uint8_t*[1]');
        $outLen = $ffi->new('uint32_t[1]');
        $this->check(
            $ffi->licd_app_encrypt(
                $this->device(), $scope, Native::bytes($plaintext), \strlen($plaintext),
                FFI::addr($out[0]), FFI::addr($outLen[0])
            ),
            'licd_app_encrypt'
        );
        return Native::takeBuffer($out, $outLen[0]);
    }

    /** Decrypts a blob produced by appEncrypt(), using the dongle. */
    public function appDecrypt(string $packed): string
    {
        $ffi = $this->ffi();
        $out = $ffi->new('uint8_t*[1]');
        $outLen = $ffi->new('uint32_t[1]');
        $this->check(
            $ffi->licd_app_decrypt(
                $this->device(), Native::bytes($packed), \strlen($packed),
                FFI::addr($out[0]), FFI::addr($outLen[0])
            ),
            'licd_app_decrypt'
        );
        return Native::takeBuffer($out, $outLen[0]);
    }

    /**
     * Wraps a PHP callable as a C progress callback.
     *
     * Returns [callback, rethrow]. An exception from the callback is held and
     * re-raised by rethrow() once the SDK has unwound its own transfer — letting
     * it escape through the C frames would skip that cleanup and strand the
     * device mid-transfer.
     *
     * @return array{0: ?\Closure, 1: \Closure}
     */
    private function progressBridge(?callable $progress): array
    {
        if ($progress === null) {
            return [null, static function (): void {}];
        }
        $thrown = null;
        $callback = function (int $done, int $total, $user) use ($progress, &$thrown): int {
            if ($thrown !== null) {
                return 0;
            }
            try {
                // Anything but an explicit false continues, so a callback that
                // only draws a progress bar is safe.
                return $progress($done, $total) === false ? 0 : 1;
            } catch (\Throwable $e) {
                $thrown = $e;
                return 0;
            }
        };
        $rethrow = static function () use (&$thrown): void {
            if ($thrown !== null) {
                throw $thrown;
            }
        };
        return [$callback, $rethrow];
    }
}
