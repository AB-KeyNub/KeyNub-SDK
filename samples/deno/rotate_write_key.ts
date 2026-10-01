// KeyNub SDK - Deno sample: take ownership of a new dongle.
//
// A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
// so that from the next session onward only your key can write records, erase
// them or increment counters. Run it once per dongle, when it arrives.
//
// Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
//
//     openssl ecparam -name prime256v1 -genkey -noout |
//       openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
//
//     deno run --allow-ffi --allow-env --allow-read samples/deno/rotate_write_key.ts keys/keynub-shipping-writeauth.key.der my-key.der
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
//
// The replacement key is worth what your licence-signing key is worth. It
// cannot be recovered from the dongle, and a unit rotated to a key you have
// lost has to come back to be re-provisioned.
import { devices, LibraryError, LicDongleError, withDongle } from "../../bindings/deno/mod.ts";

if (Deno.args.length !== 2) {
  console.log("usage: rotate_write_key <current-key.der> <new-key.der>");
  Deno.exit(2);
}

try {
  const current = Deno.readFileSync(Deno.args[0]);
  const replacement = Deno.readFileSync(Deno.args[1]);
  if (devices().length === 0) {
    console.log("Connect a KeyNub dongle and re-run.");
    Deno.exit(0);
  }
  withDongle((d) => {
    console.log(`Dongle ${d.serial}`);
    if (d.info().writeAuthRotated) {
      console.log("This dongle's write key has already been rotated away from the factory one.");
    }
    d.withSession(() => {
      d.authorizeWrite(current); // the key the dongle accepts today
      d.rotateWriteKey(replacement); // from the next session: only the new one
    });
    console.log(`Write key rotated: ${d.info().writeAuthRotated ? "yes" : "no"}`);
  });
} catch (e) {
  if (!(e instanceof LicDongleError || e instanceof LibraryError || e instanceof Deno.errors.NotFound)) throw e;
  console.log(`KeyNub error: ${e.message}`);
  Deno.exit(1);
}
