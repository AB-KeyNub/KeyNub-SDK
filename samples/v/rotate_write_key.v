// KeyNub SDK - V sample: take ownership of a new dongle.
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
//     v -path "@vlib|@vmodules|bindings/v" run samples/v/rotate_write_key.v keys/keynub-shipping-writeauth.key.der my-key.der
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
// -path makes bindings/v/keynub_licdongle importable as keynub_licdongle.
//
// Guard the replacement key as you guard your licence-signing key. It cannot
// be recovered from the dongle, and a unit rotated to a key you have lost has
// to come back to be re-provisioned.
module main

import os
import keynub_licdongle as licdongle

fn rotate(d &licdongle.Dongle, current []u8, replacement []u8) ! {
	d.open_session()!
	defer {
		d.close_session()
	}
	d.authorize_write(current)! // the key the dongle accepts today
	d.rotate_write_key(replacement)! // from the next session: only the new one
}

fn run(current_path string, replacement_path string) ! {
	current := os.read_bytes(current_path)!
	replacement := os.read_bytes(replacement_path)!
	if licdongle.devices()!.len == 0 {
		println('Connect a KeyNub dongle and re-run.')
		return
	}
	mut d := licdongle.open('')!
	defer {
		d.close()
	}
	println('Dongle ${d.serial()!}')
	if d.info()!.write_auth_rotated {
		println("This dongle's write key has already been rotated away from the factory one.")
	}
	rotate(d, current, replacement)!
	rotated := if d.info()!.write_auth_rotated { 'yes' } else { 'no' }
	println('Write key rotated: ${rotated}')
}

fn main() {
	if os.args.len != 3 {
		println('usage: rotate_write_key <current-key.der> <new-key.der>')
		exit(2)
	}
	run(os.args[1], os.args[2]) or {
		println('KeyNub error: ${err.msg()}')
		exit(1)
	}
}
