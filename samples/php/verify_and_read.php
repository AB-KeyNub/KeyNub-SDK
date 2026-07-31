<?php
// KeyNub dongle check from PHP: enumerate -> open -> verify -> session ->
// read a record -> app-crypto round trip.
//
//   KEYNUB_LICDONGLE_LIBRARY=../../build/keynub_licdongle.dll php verify_and_read.php
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
//
// READ FIRST: docs/integration-security.md. This sample prints whether the dongle
// is genuine, which is the one thing a real licence check must not do — a printed
// boolean is a deleted line away from nothing. protectSomething() shows the shape
// that actually protects something.
//
// PHP is the case where the dongle earns its place specifically for *on-premise*
// installs: if you host the application yourself you do not need one, but PHP
// business software is very often installed on a customer's own server, where they
// hold your source and an encoder's licence file is a file, which copies.

declare(strict_types=1);

require __DIR__ . '/../../bindings/php/src/KeyNub.php';

use KeyNub\LicDongle\Context;
use KeyNub\LicDongle\Dongle;
use KeyNub\LicDongle\LicenseDongleException;
use KeyNub\LicDongle\Scope;
use KeyNub\LicDongle\Session;

function report(Dongle $dongle): void
{
    $info = $dongle->getInfo();
    printf(
        "Protocol v%d.%d, firmware v%d.%d.%d, %d of %d bytes free.\n",
        $info->protocolMajor, $info->protocolMinor,
        $info->firmwareMajor, $info->firmwareMinor, $info->firmwarePatch,
        $info->dataFree, $info->dataCapacity
    );

    if ($info->watchdogReboot) {
        // The only trace a firmware hang leaves behind. Worth reporting to support.
        echo "WARNING: this dongle's previous boot ended in a watchdog reset.\n";
    }

    $result = $dongle->verifyGenuine();
    printf(
        "Genuine: %s (serial %s, batch %s, provisioned %s)\n",
        $result->genuine ? 'true' : 'false',
        $result->serial, $result->batch, $result->provisionedDate
    );
}

function readRecords(Session $session): void
{
    $records = $session->listRecords();
    printf("%d record(s) on the dongle:\n", count($records));
    foreach ($records as $record) {
        printf("  %-16s %6d bytes\n", $record->name, $record->size);
    }

    foreach ($records as $record) {
        if ($record->name === 'license') {
            $data = $session->readRecord('license');
            printf("Read %d bytes from the license record.\n", strlen($data));
            break;
        }
    }
}

// The part that actually protects something. At licence-issue time you would call
// appEncrypt once, with a developer dongle, and ship only the blob; the application
// then cannot proceed without a dongle, because it holds no other copy of the data.
// Scope::DEVELOPER lets any dongle from your batch decrypt it, so one file serves
// every customer; Scope::DEVICE locks it to one dongle.
//
// Check on boot or on a schedule rather than per request: a USB round trip is fast
// but not free, and a per-request check buys nothing an hourly one does not.
function protectSomething(Session $session): void
{
    $needed = 'the data this program cannot run without';

    $sealed = $session->appEncrypt(Scope::DEVELOPER, $needed);
    $recovered = $session->appDecrypt($sealed);

    printf(
        "App-crypto round trip: %d bytes -> %d sealed -> %s\n",
        strlen($needed),
        strlen($sealed),
        // hash_equals, not ===: constant-time comparison is the habit worth having
        // anywhere a mismatch is security-relevant.
        hash_equals($needed, $recovered) ? 'recovered intact' : 'MISMATCH'
    );
}

[$major, $minor, $patch] = Context::libraryVersion();
printf("KeyNub SDK %d.%d.%d\n", $major, $minor, $patch);

try {
    $ctx = new Context();

    $devices = $ctx->enumerate();
    printf("Found %d KeyNub dongle(s).\n", count($devices));
    foreach ($devices as $i => $d) {
        printf("  [%d] serial %s (VID %04X PID %04X)\n", $i, $d->serial, $d->vendorId, $d->productId);
    }
    if (count($devices) === 0) {
        echo "No dongle attached; nothing to do.\n";
        exit(0);
    }

    // No argument = first dongle found; pass a serial to pick a specific one.
    $dongle = $ctx->open();
    report($dongle);

    $session = $dongle->openSession();
    readRecords($session);
    protectSomething($session);

    $session->close();
    $dongle->close();
    $ctx->close();
} catch (LicenseDongleException $e) {
    // The exception subclass distinguishes the cases; the detail carries the SDK's
    // diagnostic text, which is what tells "no dongle" from "certificate rejected".
    fprintf(STDERR, "KeyNub error: %s\n", $e->getMessage());
    exit(1);
}
