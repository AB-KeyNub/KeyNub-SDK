// KeyNub SDK - Odin sample: take ownership of a new dongle.
//
// A dongle ships holding KeyNub's write-auth key. This replaces it with yours,
// so that from the next session onward only your key can write records, erase
// them or increment counters. Run it once per dongle, when it arrives.
//
// Both keys are P-256 private keys in PKCS#8 DER. Generate yours with:
//
//	openssl ecparam -name prime256v1 -genkey -noout |
//	  openssl pkcs8 -topk8 -nocrypt -outform DER -out my-key.der
//
//	odin run samples/odin/rotate_write_key.odin -file -collection:keynub=bindings/odin -- keys/keynub-shipping-writeauth.key.der my-key.der
//
// Targets real hardware: with no dongle attached it prints guidance and exits 0.
// -collection:keynub=bindings/odin makes the package importable as
// "keynub:keynub_licdongle".
//
// Guard the replacement key as you guard your licence-signing key. It cannot
// be recovered from the dongle, and a unit rotated to a key you have lost has
// to come back to be re-provisioned.
package main

import "core:fmt"
import "core:os"
import kn "keynub:keynub_licdongle"

rotate :: proc(d: kn.Dongle, current, replacement: []u8) -> kn.Error {
	kn.open_session(d) or_return
	defer kn.close_session(d)
	kn.authorize_write(d, current) or_return // the key the dongle accepts today
	kn.rotate_write_key(d, replacement) or_return // from the next session: only the new one
	return nil
}

run :: proc(current, replacement: []u8) -> kn.Error {
	devices := kn.devices() or_return
	count := len(devices)
	kn.delete_devices(devices)
	if count == 0 {
		fmt.println("Connect a KeyNub dongle and re-run.")
		return nil
	}
	d := kn.open() or_return
	defer kn.close(&d)
	serial := kn.serial(d) or_return
	defer delete(serial)
	fmt.printfln("Dongle %s", serial)
	if (kn.info(d) or_return).write_auth_rotated {
		fmt.println("This dongle's write key has already been rotated away from the factory one.")
	}
	rotate(d, current, replacement) or_return
	rotated := "yes" if (kn.info(d) or_return).write_auth_rotated else "no"
	fmt.printfln("Write key rotated: %s", rotated)
	return nil
}

main :: proc() {
	args := os.args
	if len(args) != 3 {
		fmt.println("usage: rotate_write_key <current-key.der> <new-key.der>")
		os.exit(2)
	}
	current, current_err := os.read_entire_file(args[1], context.allocator)
	if current_err != nil {
		fmt.printfln("cannot read %s: %v", args[1], current_err)
		os.exit(1)
	}
	defer delete(current)
	replacement, replacement_err := os.read_entire_file(args[2], context.allocator)
	if replacement_err != nil {
		fmt.printfln("cannot read %s: %v", args[2], replacement_err)
		os.exit(1)
	}
	defer delete(replacement)
	if err := run(current, replacement); err != nil {
		fmt.printfln("KeyNub error: %v: %s", err, kn.error_message(err, context.temp_allocator))
		os.exit(1)
	}
}
