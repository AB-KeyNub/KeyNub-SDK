<?php
// KeyNub SDK - PHP sample: take ownership of a new dongle.
//
// A dongle ships holding KeyNub's write-auth key. This replaces it with yours, so
// that from the next session onward only your key can write records, erase them or
// increment counters. Run it once per dongle, when it arrives.
//
// Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
//
//   openssl ecparam -name prime256v1 -genkey -noout |
//     openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
//
//   KEYNUB_LICDONGLE_LIBRARY=../../build/keynub_licdongle.dll \
//     php rotate_write_key.php ../../keys/keynub-shipping-writeauth.key.der my-key.der
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
//
// The replacement key is worth what your licence-signing key is worth. It cannot be
// recovered from the dongle, and a unit rotated to a key you have lost has to come
// back to be re-provisioned.

declare(strict_types=1);

require __DIR__ . '/../../bindings/php/src/KeyNub.php';

use KeyNub\LicDongle\Context;
use KeyNub\LicDongle\LicenseDongleException;

if ($argc !== 3) {
    \fwrite(\STDERR, "usage: php rotate_write_key.php <current-key.der> <new-key.der>\n");
    exit(2);
}
$current = \file_get_contents($argv[1]);
$replacement = \file_get_contents($argv[2]);
if ($current === false || $replacement === false) {
    \fwrite(\STDERR, "could not read both key files\n");
    exit(2);
}

$ctx = new Context();
try {
    if ($ctx->enumerate() === []) {
        echo "Connect a KeyNub dongle and re-run.\n";
        exit(0);
    }

    $dongle = $ctx->open();
    echo "dongle {$dongle->getSerial()}\n";

    $session = $dongle->openSession();
    $session->authorizeWrite($current);
    $session->rotateWriteKey($replacement);
    echo "rotated: this dongle now answers only to your key\n";
    $session->close();

    // A fresh session is the only place the change is observable: the session
    // above keeps the role it was already granted.
    $session = $dongle->openSession();
    try {
        $session->authorizeWrite($current);
        \fwrite(\STDERR, "WARNING: the old key still works -- do not ship this unit\n");
        exit(1);
    } catch (LicenseDongleException $e) {
        echo "confirmed: the old key no longer elevates\n";
    }
    $session->authorizeWrite($replacement);
    echo "confirmed: your key elevates\n";
    $session->close();
    $dongle->close();

    echo "\nKeep the replacement key safe. Every future write to this dongle needs it.\n";
} catch (LicenseDongleException $e) {
    \fwrite(\STDERR, "KeyNub error: {$e->getMessage()}\n");
    exit(1);
} finally {
    $ctx->close();
}
