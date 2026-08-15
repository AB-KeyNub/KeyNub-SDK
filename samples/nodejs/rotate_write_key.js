#!/usr/bin/env node
'use strict';

// KeyNub SDK - Node.js sample: take ownership of a new dongle.
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
//   npm install @keynub/licdongle
//   node rotate_write_key.js ../../keys/keynub-shipping-writeauth.key.der my-key.der
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
//
// The replacement key is worth what your licence-signing key is worth. It cannot be
// recovered from the dongle, and a unit rotated to a key you have lost has to come
// back to be re-provisioned.

const fs = require('fs');
// The package name is what an application uses; the fallback is for running
// from a checkout, where it is not installed (`npm install` there first, for the
// FFI dependency).
let binding;
try {
  binding = require('@keynub/licdongle');
} catch {
  binding = require('../../bindings/nodejs');
}
const { Context, LicenseDongleError } = binding;

function main(argv) {
  if (argv.length !== 2) {
    console.error('usage: node rotate_write_key.js <current-key.der> <new-key.der>');
    return 2;
  }
  const current = fs.readFileSync(argv[0]);
  const replacement = fs.readFileSync(argv[1]);

  const ctx = new Context();
  try {
    if (ctx.enumerate().length === 0) {
      console.log('Connect a KeyNub dongle and re-run.');
      return 0;
    }

    const dongle = ctx.open();
    try {
      console.log(`dongle ${dongle.getSerial()}`);

      let session = dongle.openSession();
      try {
        session.authorizeWrite(current);
        session.rotateWriteKey(replacement);
        console.log('rotated: this dongle now answers only to your key');
      } finally {
        session.close();
      }

      // A fresh session is the only place the change is observable: the session
      // above keeps the role it was already granted.
      session = dongle.openSession();
      try {
        try {
          session.authorizeWrite(current);
          console.error('WARNING: the old key still works -- do not ship this unit');
          return 1;
        } catch (err) {
          if (!(err instanceof LicenseDongleError)) throw err;
          console.log('confirmed: the old key no longer elevates');
        }
        session.authorizeWrite(replacement);
        console.log('confirmed: your key elevates');
      } finally {
        session.close();
      }
    } finally {
      dongle.close();
    }
  } catch (err) {
    if (!(err instanceof LicenseDongleError)) throw err;
    console.error(`KeyNub error: ${err.message}`);
    return 1;
  } finally {
    ctx.close();
  }

  console.log('\nKeep the replacement key safe. Every future write to this dongle needs it.');
  return 0;
}

process.exitCode = main(process.argv.slice(2));
