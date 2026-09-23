<?php

declare(strict_types=1);

/**
 * Every call of the binding against a stand-in for the C ABI
 * (bindings/julia/test/stub/licd_stub.c, one imaginary dongle held in memory),
 * compiled into a shared library with a C compiler from the path (cc, gcc,
 * clang, zig cc or cl). KEYNUB_LICDONGLE_LIBRARY naming an already compiled
 * stand-in skips the build; KEYNUB_SDK_ROOT names the SDK sources when the test
 * does not run inside a clone. Exit code 0 when every check passed.
 *
 *     php test/test_standin.php        (from bindings/php)
 */

use KeyNub\LicDongle\CertificateInvalidException;
use KeyNub\LicDongle\Context;
use KeyNub\LicDongle\DeviceNotFoundException;
use KeyNub\LicDongle\LicenseDongleException;
use KeyNub\LicDongle\NotGenuineException;
use KeyNub\LicDongle\OperationCancelledException;
use KeyNub\LicDongle\RecordNotFoundException;
use KeyNub\LicDongle\Scope;
use KeyNub\LicDongle\SessionExpiredException;
use KeyNub\LicDongle\Status;
use KeyNub\LicDongle\WriteAuthorizationRequiredException;

// ---- the stand-in ------------------------------------------------------------

function sdkRoot(): string
{
    $given = \getenv('KEYNUB_SDK_ROOT');
    if (\is_string($given) && $given !== '') {
        return $given;
    }
    $dir = \getcwd();
    while (true) {
        if (\is_file($dir . '/bindings/flat/licd_flat.c')) {
            return $dir;
        }
        $parent = \dirname($dir);
        if ($parent === $dir) {
            break;
        }
        $dir = $parent;
    }
    echo "the SDK sources were not found above the working directory; set KEYNUB_SDK_ROOT\n";
    exit(1);
}

function buildStandIn(): string
{
    $root = sdkRoot();
    $windows = \PHP_OS_FAMILY === 'Windows';
    $tmp = \sys_get_temp_dir();
    // Not the library's own name: macOS dyld searches DYLD_LIBRARY_PATH by leaf
    // name even for an absolute-path dlopen, and a build tree on that path holds
    // the real library under that name.
    $output = $tmp . \DIRECTORY_SEPARATOR
        . ($windows ? 'keynub_licdongle_standin.dll' : 'libkeynub_licdongle_standin.so');
    $include = $root . '/core/include';
    if (!\is_file($include . '/licdongle.h')) {
        $include = $root . '/include';
    }
    $source = $root . '/bindings/julia/test/stub/licd_stub.c';
    $gcc = ['-shared', '-O1', '-DLICD_BUILD_SHARED', "-I$include", '-o', $output, $source];
    if (!$windows) {
        $gcc[] = '-fPIC';
    }
    $cl = ['/nologo', '/LD', '/O1', '/DLICD_BUILD_SHARED', "/I$include", "/Fe:$output", $source];
    $null = $windows ? 'NUL' : '/dev/null';
    foreach ([['cc', ...$gcc], ['gcc', ...$gcc], ['clang', ...$gcc], ['zig', 'cc', ...$gcc], ['cl', ...$cl]] as $command) {
        // In the temporary folder, where the compilers leave their byproducts.
        $process = @\proc_open($command, [1 => ['file', $null, 'w'], 2 => ['file', $null, 'w']], $pipes, $tmp);
        if ($process !== false && \proc_close($process) === 0 && \is_file($output)) {
            return $output;
        }
    }
    echo "the C ABI stand-in could not be compiled: no C compiler (cc, gcc, clang, zig cc, cl) on the path\n";
    exit(1);
}

$given = \getenv('KEYNUB_LICDONGLE_LIBRARY');
if (!\is_string($given) || $given === '') {
    \putenv('KEYNUB_LICDONGLE_LIBRARY=' . buildStandIn());
}
require_once __DIR__ . '/../src/KeyNub.php';

// ---- the checks ------------------------------------------------------------------

const SERIAL = '04A1B2C3D4E5F6';
const FACTORY_KEY = "\x30\x10\x01\x02\x03";
const REPLACEMENT_KEY = "\x30\x11\x09\x08\x07\x06";

$failures = 0;

/**
 * Announces a section on STDERR, unbuffered: an FFI mistake is an access
 * violation rather than an exception, and buffered stdout is lost with it.
 */
function section(string $name): void
{
    \fwrite(\STDERR, "-- $name\n");
}

function check(bool $condition, string $what): void
{
    global $failures;
    if (!$condition) {
        $failures++;
        echo "  FAIL  $what\n";
    }
}

/** Checks that $action throws $class, carrying $status when one is given. */
function fails(string $class, ?int $status, string $what, callable $action): void
{
    try {
        $action();
    } catch (\Throwable $e) {
        $statusOk = $status === null || ($e instanceof LicenseDongleException && $e->status === $status);
        check($e instanceof $class && $statusOk, "$what: " . \get_class($e) . ': ' . $e->getMessage());
        return;
    }
    check(false, "$what: no failure");
}

section('version and status text');
check(Context::libraryVersion() === [9, 8, 7], 'library version');
check(Status::NO_DEVICE === -2, 'status code');

$ctx = new Context();
try {
    $ctx->open('nope');
    check(false, 'status text: no failure');
} catch (DeviceNotFoundException $e) {
    check($e->status === Status::NO_DEVICE, 'status');
    check($e->getMessage() === 'licd_open: no device (no dongle with that serial)', 'status text');
    check($e->operation === 'licd_open', 'operation');
    check($e->detail === 'no dongle with that serial', 'detail');
}
check($ctx->lastErrorDetail() === 'no dongle with that serial', 'last error detail');

section('devices');
check($ctx->enumerate() === [['serial' => SERIAL, 'path' => 'stub:0', 'vendorId' => 0x1234, 'productId' => 0xABCD]],
      'devices');
fails(DeviceNotFoundException::class, Status::NO_DEVICE, 'open by unknown serial', fn() => $ctx->open('nope'));
fails(DeviceNotFoundException::class, Status::NO_DEVICE, 'open by unknown path', fn() => $ctx->openPath('stub:9'));
$bySerial = $ctx->open(SERIAL);
check($bySerial->getSerial() === SERIAL, 'open by serial');
$bySerial->close();
$byPath = $ctx->openPath('stub:0');
check($byPath->getSerial() === SERIAL, 'open by path');
$byPath->close();

section('info');
$d = $ctx->open();
check($d->isOpen(), 'open');
check($d->getSerial() === SERIAL, 'serial');
check($d->getInfo() === [
    'protocolVersion' => [1, 0],
    'firmwareVersion' => [2, 3, 4],
    'seReady' => true,
    'provisioned' => true,
    'dataCapacity' => 1024 * 1024,
    'dataFree' => 1000000,
    'watchdogReboot' => false,
    'isolated' => true,
    'writeAuthRotated' => false,
], 'info fields and flags');

section('genuine and trust root');
check($d->verifyGenuine() === ['genuine' => true, 'serial' => SERIAL, 'provisionedDate' => '2026-08-15'], 'genuine');
check($d->isGenuine() === true, 'isGenuine');
fails(CertificateInvalidException::class, Status::CERTIFICATE_INVALID, 'malformed trust root',
      fn() => $ctx->setTrustRoot("\x02\x01\x00"));
fails(LicenseDongleException::class, Status::INVALID_ARGUMENT, 'empty trust root', fn() => $ctx->setTrustRoot(''));
$ctx->setTrustRoot("\x30\x82\x01\x00" . \str_repeat("\xAB", 128));
fails(CertificateInvalidException::class, Status::CERTIFICATE_INVALID, 'verify against a foreign root',
      fn() => $d->verifyGenuine());
check($d->isGenuine() === false, 'isGenuine fails closed');
$ctx->setTrustRoot("\x30\x82\x01\x00" . \str_repeat("\x01", 128));
check($d->isGenuine() === true, 'isGenuine after the right root');

section('session and write role');
// A second Session object ends the dongle's session under the first one.
$first = $d->openSession();
$second = $d->openSession();
$second->close();
fails(SessionExpiredException::class, Status::SESSION_EXPIRED, 'records without a session', fn() => $first->listRecords());
$first->close();
check(!$first->isOpen(), 'closed session reports closed');
fails(SessionExpiredException::class, Status::SESSION_EXPIRED, 'closed session', fn() => $first->listRecords());
$first->close(); // idempotent

$s = $d->openSession();
$payload = 'license-blob-0123456789';
fails(WriteAuthorizationRequiredException::class, Status::AUTH_REQUIRED, 'write before the write role',
      fn() => $s->writeRecord('lic', $payload));
fails(WriteAuthorizationRequiredException::class, Status::AUTH_REQUIRED, 'increment before the write role',
      fn() => $s->incrementCounter(0));
fails(NotGenuineException::class, Status::NOT_GENUINE, 'write role with a bad key', fn() => $s->authorizeWrite("\x30\x00"));
$s->authorizeWrite(FACTORY_KEY);

section('records');
$s->writeRecord('lic', $payload);
check($s->readRecord('lic') === $payload, 'read back');
$s->writeRecord('cfg', 'cfgdata');
$recs = $s->listRecords();
$names = \array_column($recs, 'name');
\sort($names);
check($names === ['cfg', 'lic'], 'record names');
check(\in_array(['name' => 'lic', 'size' => \strlen($payload)], $recs, true), 'record size');
check($s->readRecord('cfg') === 'cfgdata', 'second record');
fails(RecordNotFoundException::class, Status::NOT_FOUND, 'read a missing record', fn() => $s->readRecord('nope'));
fails(RecordNotFoundException::class, Status::NOT_FOUND, 'erase a missing record', fn() => $s->eraseRecord('nope'));
fails(\InvalidArgumentException::class, null, 'erase with an empty name', fn() => $s->eraseRecord(''));
fails(\InvalidArgumentException::class, null, 'read with an empty name', fn() => $s->readRecord(''));
check(\count($s->listRecords()) === 2, 'two records');
$s->eraseRecord('cfg');
check(\array_column($s->listRecords(), 'name') === ['lic'], 'one record left');
$s->writeRecord('empty', '');
check($s->readRecord('empty') === '', 'empty record');
$big = '';
for ($k = 0; $k < 2000; $k++) {
    $big .= \chr(($k * 31 + 5) & 0xFF);
}
$s->writeRecord('big', $big);
check($s->readRecord('big') === $big, 'record larger than one transfer chunk');

section('progress');
$writes = [];
$s->writeRecord('big', $big, function (int $done, int $total) use (&$writes): void {
    $writes[] = [$done, $total];
});
check(\end($writes) === [2000, 2000], 'write progress');
$reads = [];
$data = $s->readRecord('big', function (int $done, int $total) use (&$reads): bool {
    $reads[] = [$done, $total];
    return true;
});
check($data === $big && \end($reads) === [2000, 2000], 'read progress');
fails(OperationCancelledException::class, Status::CANCELLED, 'read cancelled', fn() => $s->readRecord('big', fn() => false));
fails(OperationCancelledException::class, Status::CANCELLED, 'write cancelled',
      fn() => $s->writeRecord('big', $big, fn() => false));
fails(\DomainException::class, null, 'an exception in the callback is re-raised', fn() => $s->readRecord('big', function (): void {
    throw new \DomainException('callback exploded');
}));
check($s->readRecord('big', fn() => null) === $big, 'a callback returning nothing does not cancel');

section('counters');
$before = $s->readCounter(0);
check($s->incrementCounter(0) === $before + 1, 'increment');
check($s->readCounter(0) === $before + 1 && $s->readCounter(1) === 0, 'counters');
fails(LicenseDongleException::class, Status::RANGE, 'counter out of range', fn() => $s->readCounter(7));
fails(LicenseDongleException::class, Status::RANGE, 'increment out of range', fn() => $s->incrementCounter(7));

section('app crypto');
$secret = '';
for ($k = 0; $k < 100; $k++) {
    $secret .= \chr((3 * $k + 7) % 256);
}
foreach ([Scope::DEVICE => 'device', Scope::DEVELOPER => 'developer'] as $scope => $name) {
    $blob = $s->appEncrypt($scope, $secret);
    check(\strlen($blob) > \strlen($secret), "sealed data is longer, $name");
    check(\ord($blob[0]) === $scope, "scope byte, $name");
    check($s->appDecrypt($blob) === $secret, "round trip, $name");
    $tampered = $blob;
    $tampered[\strlen($tampered) - 1] = \chr(\ord($tampered[\strlen($tampered) - 1]) ^ 1);
    fails(LicenseDongleException::class, Status::TAG_MISMATCH, "tampered blob, $name", fn() => $s->appDecrypt($tampered));
}
fails(\InvalidArgumentException::class, null, 'unknown scope', fn() => $s->appEncrypt(7, $secret));
check($s->appDecrypt($s->appEncrypt(Scope::DEVICE, '')) === '', 'empty plaintext');
fails(LicenseDongleException::class, Status::INVALID_ARGUMENT, 'short blob', fn() => $s->appDecrypt("\x00\x01"));

$s->eraseAllRecords();
check($s->listRecords() === [], 'erase all');

section('rotation');
$s->close();
$s = $d->openSession();
fails(WriteAuthorizationRequiredException::class, Status::AUTH_REQUIRED, 'rotate before the write role',
      fn() => $s->rotateWriteKey(REPLACEMENT_KEY));
$s->authorizeWrite(FACTORY_KEY);
$s->rotateWriteKey(REPLACEMENT_KEY);
$s->writeRecord('lic', 'still-writable');
$s->close();
check($d->getInfo()['writeAuthRotated'] === true, 'rotated flag');
$s = $d->openSession();
fails(NotGenuineException::class, Status::NOT_GENUINE, 'factory key after rotation', fn() => $s->authorizeWrite(FACTORY_KEY));
$s->authorizeWrite(REPLACEMENT_KEY);
$s->writeRecord('lic', 'new-key-writes');
check($s->readRecord('lic') === 'new-key-writes', 'write with the new key');

section('close');
$d->close();
$d->close(); // idempotent
check(!$d->isOpen(), 'closed');
fails(LicenseDongleException::class, Status::INVALID_ARGUMENT, 'serial after close', fn() => $d->getSerial());
// A session whose dongle was closed refuses, and closing it does not touch the device.
fails(LicenseDongleException::class, Status::INVALID_ARGUMENT, 'session after its dongle closed', fn() => $s->listRecords());
$s->close();

$handle = $ctx->ffi()->new('licd_device*');
check($ctx->ffi()->licd_open($ctx->handle(), null, FFI::addr($handle)) === 0, 'raw open');
$adopted = $ctx->adopt($handle);
check($adopted->getSerial() === SERIAL, 'adopt');
$adopted->close();

$ctx->close();
$ctx->close(); // idempotent
check(!$ctx->isOpen(), 'context closed');
fails(LicenseDongleException::class, Status::INVALID_ARGUMENT, 'context after close', fn() => $ctx->enumerate());

if ($failures > 0) {
    echo "$failures check(s) failed\n";
    exit(1);
}
echo "keynub/licdongle: every call passed against the ABI stand-in\n";
exit(0);
