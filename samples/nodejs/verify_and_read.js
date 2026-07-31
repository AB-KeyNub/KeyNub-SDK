#!/usr/bin/env node
'use strict';
// KeyNub dongle check from Node.js: enumerate -> open -> verify -> session ->
// read a record -> app-crypto round trip. The Node equivalent of
// samples/c/verify_and_read.
//
//   npm install @keynub/licdongle
//   node verify_and_read.js
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
//
// NOTE what this sample is not. It prints whether the dongle is genuine, which is
// the one thing a real licence check must not do — a printed boolean is a deleted
// line away from nothing. The last section shows the shape that actually protects
// something. See docs/integration-security.md.

const { Context, Scope, DeviceNotFoundError } = require('@keynub/licdongle');

function main() {
  const version = Context.libraryVersion();
  console.log(`KeyNub SDK ${version.major}.${version.minor}.${version.patch}`);

  const ctx = new Context();
  try {
    const devices = ctx.enumerate();
    console.log(`Found ${devices.length} KeyNub dongle(s).`);
    for (const [i, d] of devices.entries()) {
      console.log(
        `  [${i}] serial ${d.serial} ` +
          `(VID ${d.vendorId.toString(16).padStart(4, '0')} ` +
          `PID ${d.productId.toString(16).padStart(4, '0')})`
      );
    }
    if (devices.length === 0) {
      console.log('No dongle attached; nothing to do.');
      return 0;
    }

    const dongle = ctx.open();
    try {
      const info = dongle.getInfo();
      console.log(
        `Protocol v${info.protocolVersion.join('.')}, ` +
          `firmware v${info.firmwareVersion.join('.')}, ` +
          `${info.dataFree} of ${info.dataCapacity} bytes free.`
      );
      if (info.watchdogReboot) {
        // The only trace a firmware hang leaves behind. Worth reporting.
        console.warn("WARNING: this dongle's previous boot ended in a watchdog reset.");
      }

      const result = dongle.verifyGenuine();
      console.log(
        `Genuine: ${result.genuine} (serial ${result.serial}, batch ${result.batch}, ` +
          `provisioned ${result.provisionedDate || 'unknown'})`
      );

      const session = dongle.openSession();
      try {
        const records = session.listRecords();
        console.log(`${records.length} record(s) on the dongle:`);
        for (const record of records) {
          console.log(`  ${record.name.padEnd(16)} ${String(record.size).padStart(6)} bytes`);
        }

        const licence = records.find((r) => r.name === 'license');
        if (licence) {
          const data = session.readRecord('license', (done, total) => {
            process.stdout.write(`\r  reading license: ${done}/${total}`);
            return true;
          });
          process.stdout.write('\n');
          console.log(`Read ${data.length} bytes from the license record.`);
        }

        // --- the part that actually protects something ---------------------
        // At licence-issue time you would run appEncrypt once, with a developer
        // dongle, and ship only the blob. At run time the application cannot
        // proceed without a dongle, because it has no other copy of the data.
        const needed = Buffer.from('the data this program cannot run without');
        const blob = session.appEncrypt(Scope.DEVELOPER, needed);
        const recovered = session.appDecrypt(blob);
        console.log(
          `App-crypto round trip: ${needed.length} bytes -> ${blob.length} sealed -> ` +
            `${recovered.equals(needed) ? 'recovered intact' : 'MISMATCH'}`
        );
      } finally {
        session.close();
      }
    } finally {
      dongle.close();
    }
  } catch (err) {
    if (err instanceof DeviceNotFoundError) {
      console.log('The dongle was disconnected while we were talking to it.');
      return 0;
    }
    console.error(`KeyNub error: ${err.message}`);
    if (err.detail) {
      console.error(`  detail: ${err.detail}`);
    }
    return 1;
  } finally {
    ctx.close();
  }
  return 0;
}

process.exit(main());
