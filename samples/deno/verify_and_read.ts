// KeyNub SDK - Deno sample: verify a dongle and read what it holds.
//
//     deno run --allow-ffi --allow-env --allow-read samples/deno/verify_and_read.ts      (from the repository root)
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
// In your own project: import { ... } from "jsr:@keynub/licdongle";
import {
  devices,
  type Dongle,
  LibraryError,
  libraryVersion,
  LicDongleError,
  Scope,
  withDongle,
} from "../../bindings/deno/mod.ts";

function report(d: Dongle): void {
  const i = d.info();
  console.log(
    `Protocol v${i.protocolMajor}.${i.protocolMinor}, firmware ` +
      `v${i.firmwareMajor}.${i.firmwareMinor}.${i.firmwarePatch}, ` +
      `${i.dataFree} of ${i.dataCapacity} bytes free.`,
  );
  // The only trace a firmware hang leaves behind. Worth reporting to support.
  if (i.watchdogReboot) console.log("WARNING: this dongle's previous boot ended in a watchdog reset.");
  const g = d.verifyGenuine();
  console.log(`Genuine: yes (serial ${g.serial}, provisioned ${g.provisionedDate})`);
}

function readRecords(d: Dongle): void {
  const recs = d.records();
  console.log(`${recs.length} record(s) on the dongle:`);
  for (const r of recs) console.log(`  ${r.name.padEnd(16)} ${r.size} bytes`);
  // A missing record is a normal state, not an error.
  if (recs.some((r) => r.name === "license")) {
    console.log(`Read ${d.readRecord("license").length} bytes from the license record.`);
  }
}

// The part that protects something. At licence-issue time you would
// call appEncrypt once, with a developer dongle, and ship only the sealed data;
// the program then cannot proceed without a dongle, because it holds no other
// copy. Scope.Developer lets any dongle you have issued decrypt it, so one file
// serves every customer; Scope.Device locks it to one dongle.
function protectSomething(d: Dongle): void {
  const needed = new TextEncoder().encode("the data this program cannot run without");
  const sealed = d.appEncrypt(Scope.Developer, needed);
  const recovered = d.appDecrypt(sealed);
  const intact = recovered.length === needed.length && recovered.every((v, k) => v === needed[k]);
  console.log(
    `App-crypto round trip: ${needed.length} bytes -> ${sealed.length} sealed -> ` +
      `${intact ? "recovered intact" : "MISMATCH"}`,
  );
}

try {
  const v = libraryVersion();
  console.log(`KeyNub library v${v.major}.${v.minor}.${v.patch}`);
  if (devices().length === 0) {
    console.log("Connect a KeyNub dongle and re-run.");
    Deno.exit(0);
  }
  withDongle((d) => { // first dongle, or withDongle(fn, "serial")
    report(d);
    d.withSession(() => { // closed on every exit path
      readRecords(d);
      protectSomething(d);
    });
  });
} catch (e) {
  if (!(e instanceof LicDongleError || e instanceof LibraryError)) throw e;
  console.log(`KeyNub error: ${e.message}`);
  Deno.exit(1);
}
